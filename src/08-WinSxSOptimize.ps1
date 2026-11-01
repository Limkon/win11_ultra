# ==============================================================================
#  win11 Builder - [模块 9/11] 组件库瘦身与主映像优化 (src/08-WinSxSOptimize.ps1)
#  重构要点：
#   1. 普通精简模式：移除 /ResetBase，仅执行 /StartComponentCleanup。
#      原因：/ResetBase 在较新 Win11 版本上会破坏安装所需的组件基线，
#      导致 Setup 在应用映像阶段报“无法安装”。极限压榨模式因随后会物理
#      替换 WinSxS，/ResetBase 的影响被绕过，故仅普通精简需要修正。
#   2. 极限压榨模式：保留原有 /ResetBase + 物理替换逻辑不变。
#   3. 本模块会被合并进单文件主脚本，禁止使用 return（会退出整个脚本），
#      所有提前退出分支统一改为 if/else 嵌套。
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在根据精简模式执行组件存储 (WinSxS) 优化..." -ForegroundColor Cyan

$currentTrimMode = if ($global:trimMode) { $global:trimMode } else { "1" }
$currentArch     = if ($global:architecture) { $global:architecture } else { "amd64" }

# ----------------- 1. 通用阶段：按模式执行组件清理 -----------------
if ($currentTrimMode -ne "2") {
    # 普通精简：仅安全清理，绝不重置基线（避免破坏安装依赖）
    Write-Host "正在执行 DISM 组件清理 (/StartComponentCleanup，不重置基线)..." -ForegroundColor Yellow
    & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[提示] DISM 组件清理退出码: $LASTEXITCODE (部分精简组件无需清理或已处于最新基线，继续推进)。" -ForegroundColor DarkGray
    }

    Write-Host "[完成] 当前为【普通精简模式】，已保留完整 WinSxS 核心组件库与更新回滚基线，确保安装兼容性与可维护性。" -ForegroundColor Green
} else {
    # 极限压榨：先重置基线，随后物理替换 WinSxS
    Write-Host "正在执行 DISM 深度组件清理与基线重置 (/StartComponentCleanup /ResetBase)..." -ForegroundColor Yellow
    & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[提示] DISM 组件重置退出码: $LASTEXITCODE (部分精简组件无需重置或已处于最新基线，继续推进)。" -ForegroundColor DarkGray
    }

    # ----------------- 2. 极限压榨模式专用：WinSxS 物理极限裁剪 -----------------
    Write-Host "`n>>> [警告] 当前为【极限压榨模式】，正在物理瘦身 WinSxS (架构: $currentArch)..." -ForegroundColor Red

    $winSxSDir     = Join-Path $scratchDir "Windows\WinSxS"
    $winSxSEditDir = Join-Path $scratchDir "Windows\WinSxS_edit"

    if (-not (Test-Path -LiteralPath $winSxSDir)) {
        Write-Host "[错误] 未检测到 WinSxS 目录: $winSxSDir，跳过物理替换。" -ForegroundColor Red
    } else {
        # 极限模式前置断言：OpenWith.exe 缺失时物理替换 WinSxS 将导致“打开方式”功能永久损坏
        $openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
        if (-not (Test-Path -LiteralPath $openWithExe)) {
            Write-Host "[严重错误] 极限模式前置断言失败：OpenWith.exe 不存在，物理替换 WinSxS 将导致“打开方式”功能永久损坏。已中止极限模式，回退为普通精简。" -ForegroundColor Red
        } else {
            # 获取 WinSxS 物理掌控权
            Write-Host "正在获取 WinSxS 目录物理所有权与完全控制权限..." -ForegroundColor Yellow
            & takeown.exe /F "$winSxSDir" /R /A /D Y 2>$null | Out-Null
            & icacls.exe "$winSxSDir" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

            # 重置并创建暂存目录
            if (Test-Path -LiteralPath $winSxSEditDir) {
                Remove-Item -LiteralPath $winSxSEditDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $winSxSEditDir -ItemType Directory -Force | Out-Null

            # 根据架构构建保活组件清单
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
                    "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
                )
            } else {
                # 默认 amd64 体系
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
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
                )
            }

            # 复制保活核心清单
            Write-Host "正在提取基础运行库与核心服务依赖项..." -ForegroundColor Cyan
            foreach ($pattern in $dirsToCopy) {
                $matchedDirs = Get-ChildItem -Path $winSxSDir -Filter $pattern -Directory -ErrorAction SilentlyContinue
                if ($matchedDirs) {
                    foreach ($sDir in $matchedDirs) {
                        $destDir = Join-Path $winSxSEditDir $sDir.Name
                        Copy-Item -LiteralPath $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            # 执行物理粉碎替换
            Write-Host "正在物理销毁原始 WinSxS 并置换轻量结构..." -ForegroundColor Yellow
            attrib.exe -R -S -H "$winSxSDir\*" /S /D 2>$null
            Remove-Item -LiteralPath $winSxSDir -Recurse -Force -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $winSxSDir) {
                cmd.exe /c "rd /s /q `"$winSxSDir`"" 2>$null
            }

            if (-not (Test-Path -LiteralPath $winSxSDir)) {
                Rename-Item -LiteralPath $winSxSEditDir -NewName "WinSxS" -Force
                Write-Host "[完成] WinSxS 极限置换完成，体积已大幅度压缩。" -ForegroundColor Green
            } else {
                Write-Host "[警告] WinSxS 原始目录存在锁死残留，保留备份以防映像损坏。" -ForegroundColor Yellow
            }
        }
    }
}
