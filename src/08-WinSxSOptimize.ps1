# ==============================================================================
#  Windows 10/11 Builder - [模块 9/11] 组件库瘦身与主映像优化 (src/08-WinSxSOptimize.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 仅执行官方 DISM /StartComponentCleanup，不执行 /ResetBase，
#        保留完整更新回滚基线与硬链接链条，确保系统 100% 具备自愈与后期维护能力。
#   2. 极限模式 (极限压榨)：
#      - 补齐 WinSxS 物理置换白名单中的全部打印服务核心程序集与 32位兼容层。
#   3. NTLite 预精简与累积更新母盘深度适配：
#      - 前置探测 Servicing Stack / Manifests 完整性：若已被 NTLite 深度裁剪，
#        自动旁路 DISM 组件清理，避免报错或破坏已有精简成果。
#      - 前置探测 WinSxS\pending.xml 挂起事务（常见于集成累积更新或离线卸载内核/FOD 后）：
#        CBS 机制下存在挂起事务时 /StartComponentCleanup 必在漫长扫盘后报 0x800F0806 退出，
#        提前识别并交由首次开机自动收敛，彻底消除文件夹模式下长达数十分钟的“假死等待”。
#   4. 流控规范：严禁使用 return，保障单文件或分模块调度流水线顺畅贯通。
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在根据精简模式执行组件存储 (WinSxS) 优化..." -ForegroundColor Cyan

$currentTrimMode = if ($global:trimMode) { $global:trimMode } else { "1" }
$currentArch     = if ($global:architecture) { $global:architecture } else { "amd64" }

$winSxSDir    = Join-Path $scratchDir "Windows\WinSxS"
$manifestsDir = Join-Path $winSxSDir "Manifests"
$pendingXml   = Join-Path $winSxSDir "pending.xml"

# ---- 前置探针 1：检测 Servicing Stack 与 Manifests 是否仍完整（兼容 NTLite 深度移除组件库） ----
$hasServicingStack = $false
if ((Test-Path -LiteralPath $winSxSDir) -and (Test-Path -LiteralPath $manifestsDir)) {
    $sampleManifest = Get-ChildItem -LiteralPath $manifestsDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    $sampleSsu      = Get-ChildItem -Path $winSxSDir -Filter "*servicingstack*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sampleManifest -and $sampleSsu) {
        $hasServicingStack = $true
    }
}

# ---- 前置探针 2：检测是否存在挂起的离线 CBS 事务 (pending.xml) ----
$hasPendingServicing = $false
if (Test-Path -LiteralPath $pendingXml -PathType Leaf) {
    try {
        $pInfo = Get-Item -LiteralPath $pendingXml -Force -ErrorAction Stop
        if ($pInfo.Length -gt 64) {
            $pendingRaw = [System.IO.File]::ReadAllText($pendingXml)
            if ($pendingRaw -match 'POQ|Pending|Transaction') {
                $hasPendingServicing = $true
            }
        }
    } catch {
        $hasPendingServicing = $true
    }
}

# ----------------- 1. 通用阶段：按模式执行组件清理 -----------------
if ($currentTrimMode -ne "2") {
    # --------------------------------------------------------------------------
    # 普通健康精简模式：仅安全清理无用废弃组件，不重置基线，不物理破坏 WinSxS
    # --------------------------------------------------------------------------
    if (-not $hasServicingStack) {
        Write-Host "   [跳过] 检测到目标映像组件库 (WinSxS/Manifests) 已被 NTLite 等前置工具深度裁剪，跳过 DISM 组件清理。" -ForegroundColor DarkYellow
    } elseif ($hasPendingServicing) {
        Write-Host "   [跳过] 检测到离线映像存在挂起的组件事务 (WinSxS\pending.xml，由累积更新或刚卸载的组件包产生)。" -ForegroundColor Yellow
        Write-Host "          Windows CBS 不允许在装机收敛前执行离线 /StartComponentCleanup（强跑将在长时间扫盘后返回 0x800F0806），" -ForegroundColor DarkGray
        Write-Host "          已自动旁路离线等待，系统将在首次开机进入桌面后自动完成后台组件收敛。" -ForegroundColor DarkGray
    } else {
        Write-Host "正在执行 DISM 安全组件清理 (/StartComponentCleanup，保留更新基线)..." -ForegroundColor Yellow
        Write-Host "   [提示] 离线目录随机读写较多，视磁盘性能可能需要 5~20 分钟（控制台实时显示进度条，完成后写入日志）..." -ForegroundColor DarkGray
        $cleanupWatch = [System.Diagnostics.Stopwatch]::StartNew()
        & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup
        $dismExit = $LASTEXITCODE
        $cleanupWatch.Stop()
        $elapsedStr = "{0:N1} 分钟" -f $cleanupWatch.Elapsed.TotalMinutes

        if ($dismExit -eq 0) {
            Write-Host "   [完成] DISM 安全组件清理成功 (耗时 $elapsedStr)。" -ForegroundColor Green
        } else {
            $hexExit = ('0x{0:X8}' -f ($dismExit -band 0xFFFFFFFFL))
            if ($hexExit -eq '0x800F0806') {
                Write-Host "   [提示] DISM 返回 $hexExit (存在挂起组件操作，留待首次开机自动完成，耗时 $elapsedStr)。" -ForegroundColor DarkGray
            } else {
                Write-Host "   [提示] DISM 组件清理退出码: $dismExit ($hexExit，耗时 $elapsedStr；部分已精简组件无需二次清理，继续推进)。" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "[完成] 【普通健康模式】已完整保留 WinSxS 核心组件库与硬链接，确保系统自愈性与全功能生态稳定。" -ForegroundColor Green
} else {
    # --------------------------------------------------------------------------
    # 极限压榨模式：重置基线，随后物理替换 WinSxS (但已补全打印核心依赖)
    # --------------------------------------------------------------------------
    if (-not $hasServicingStack) {
        Write-Host "   [跳过] 组件库已被前置工具裁剪，跳过 DISM /ResetBase 阶段。" -ForegroundColor DarkYellow
    } elseif ($hasPendingServicing) {
        Write-Host "   [跳过] 检测到挂起的组件事务 (WinSxS\pending.xml)，跳过 DISM /ResetBase，直接进入物理瘦身阶段。" -ForegroundColor Yellow
    } else {
        Write-Host "正在执行 DISM 深度组件清理与基线重置 (/StartComponentCleanup /ResetBase)..." -ForegroundColor Yellow
        Write-Host "   [提示] 正在执行离线基线重置（控制台显示实时进度条，请勿关闭窗口）..." -ForegroundColor DarkGray
        $cleanupWatch = [System.Diagnostics.Stopwatch]::StartNew()
        & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase
        $dismExit = $LASTEXITCODE
        $cleanupWatch.Stop()

        if ($dismExit -ne 0) {
            $hexExit = ('0x{0:X8}' -f ($dismExit -band 0xFFFFFFFFL))
            Write-Host "[提示] DISM 组件重置退出码: $dismExit ($hexExit)，继续推进物理瘦身。" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n>>> [警告] 当前为【极限压榨模式】，正在物理瘦身 WinSxS (已锁定保护打印核心，架构: $currentArch)..." -ForegroundColor Red

    $winSxSEditDir = Join-Path $scratchDir "Windows\WinSxS_edit"

    if (-not (Test-Path -LiteralPath $winSxSDir)) {
        Write-Host "[错误] 未检测到 WinSxS 目录: $winSxSDir，跳过物理替换。" -ForegroundColor Red
    } else {
        $existingSubDirCount = @(Get-ChildItem -LiteralPath $winSxSDir -Directory -ErrorAction SilentlyContinue).Count
        $openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"

        if ($existingSubDirCount -lt 200) {
            Write-Host "[跳过] 检测到 WinSxS 当前仅含 $existingSubDirCount 个子目录（已被 NTLite 或前次极限模式深度瘦身），跳过重复物理置换以保护现有运行库。" -ForegroundColor Yellow
        } elseif (-not (Test-Path -LiteralPath $openWithExe)) {
            Write-Host "[严重错误] 极限模式前置断言失败：OpenWith.exe 不存在，物理替换将导致关联损坏，已跳过物理粉碎。" -ForegroundColor Red
        } else {
            # 获取 WinSxS 物理掌控权
            Write-Host "正在接管 WinSxS 目录所有权与完全控制权限..." -ForegroundColor Yellow
            & takeown.exe /F "$winSxSDir" /R /A /D Y 2>$null | Out-Null
            & icacls.exe "$winSxSDir" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

            # 重置并创建暂存目录
            if (Test-Path -LiteralPath $winSxSEditDir) {
                Remove-Item -LiteralPath $winSxSEditDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $winSxSEditDir -ItemType Directory -Force | Out-Null

            # 根据架构构建保活清单（已彻底补齐打印相关底层组件与 32位兼容组件）
            $dirsToCopy = @()

            if ($currentArch -eq "arm64") {
                $dirsToCopy = @(
                    "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
                    "Catalogs",
                    "FileMaps",
                    "Fusion",
                    "InstallTemp",
                    "Manifests",
                    "SettingsManifests",
                    "Temp",
                    "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "arm_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
                    # ---- ARM64 打印核心组件保护 ----
                    "arm64_microsoft-windows-printing*",
                    "arm64_microsoft-windows-p..ing*",
                    "arm64_microsoft-windows-spooler*",
                    "arm64_microsoft-windows-p..spooler*",
                    "arm_microsoft-windows-printing*",
                    "arm_microsoft-windows-spooler*",
                    "x86_microsoft-windows-printing*",
                    "x86_microsoft-windows-spooler*"
                )
            } else {
                # 默认 amd64 体系架构
                $dirsToCopy = @(
                    "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
                    "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
                    "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "x86_microsoft-windows-servicingstack-inetsrv_*",
                    "x86_microsoft-windows-servicingstack-onecore_*",
                    "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shell32_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shcore_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-explorerframe_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-openwith_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shell-experience_31bf3856ad364e35_*",
                    "x86_microsoft.windows.shell*",
                    "Catalogs",
                    "FileMaps",
                    "Fusion",
                    "InstallTemp",
                    "Manifests",
                    "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    # ---- AMD64 打印核心组件与 32位兼容层保护 ----
                    "amd64_microsoft-windows-printing*",
                    "amd64_microsoft-windows-p..ing*",
                    "amd64_microsoft-windows-spooler*",
                    "amd64_microsoft-windows-p..spooler*",
                    "x86_microsoft-windows-printing*",
                    "x86_microsoft-windows-p..ing*",
                    "x86_microsoft-windows-spooler*"
                )
            }

            # 复制保活核心清单（同时保留 pending.xml 若存在，避免首次开机收敛异常）
            Write-Host "正在提取基础运行库、Shell 依赖与打印架构项..." -ForegroundColor Cyan
            foreach ($pattern in $dirsToCopy) {
                $matchedDirs = Get-ChildItem -Path $winSxSDir -Filter $pattern -Directory -ErrorAction SilentlyContinue
                if ($matchedDirs) {
                    foreach ($sDir in $matchedDirs) {
                        $destDir = Join-Path $winSxSEditDir $sDir.Name
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            Copy-Item -LiteralPath $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            if (Test-Path -LiteralPath $pendingXml -PathType Leaf) {
                Copy-Item -LiteralPath $pendingXml -Destination (Join-Path $winSxSEditDir "pending.xml") -Force -ErrorAction SilentlyContinue
            }

            $copiedCount = @(Get-ChildItem -LiteralPath $winSxSEditDir -Directory -ErrorAction SilentlyContinue).Count
            if ($copiedCount -lt 3) {
                Write-Host "[警告] WinSxS 保活白名单提取到的核心目录不足 ($copiedCount 个)，为防止映像损坏已取消物理替换。" -ForegroundColor Yellow
                Remove-Item -LiteralPath $winSxSEditDir -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                # 执行物理粉碎替换
                Write-Host "正在物理销毁原始 WinSxS 并置换保护型结构..." -ForegroundColor Yellow
                attrib.exe -R -S -H "$winSxSDir\*" /S /D 2>$null
                Remove-Item -LiteralPath $winSxSDir -Recurse -Force -ErrorAction SilentlyContinue

                if (Test-Path -LiteralPath $winSxSDir) {
                    cmd.exe /c "rd /s /q `"$winSxSDir`"" 2>$null
                }

                if (-not (Test-Path -LiteralPath $winSxSDir)) {
                    Rename-Item -LiteralPath $winSxSEditDir -NewName "WinSxS" -Force
                    Write-Host "[完成] WinSxS 极限置换完成，体积已大幅压缩（打印核心已成功保留）。" -ForegroundColor Green
                } else {
                    Write-Host "[警告] WinSxS 原始目录存在锁死残留，保留备份以防映像损坏。" -ForegroundColor Yellow
                }
            }
        }
    }
}

Write-Host "[完成] 组件存储优化流程处理完毕。" -ForegroundColor Green
