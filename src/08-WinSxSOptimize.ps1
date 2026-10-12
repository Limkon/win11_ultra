# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 优化与主映像提交卸载 (src/08-WinSxSOptimize.ps1)
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在执行组件库深度瘦身与补丁清理..." -ForegroundColor Cyan

# ----------------- 模式分支：WinSxS 处理 -----------------
if ($trimMode -eq "2") {
    $winsxsPath     = Join-Path $scratchDir "Windows\WinSxS"
    $winsxsEditPath = Join-Path $scratchDir "Windows\WinSxS_edit"
    
    # 架构零碰注册表探查
    $arch = if (Test-Path "$scratchDir\Windows\SysWOW64") { "amd64" } else { "arm64" }

    Write-Host ">>> [极限模式] WinSxS 自适应瘦身 5 阶段引擎启动 (目标架构: $arch)" -ForegroundColor Yellow

    # 阶段 1：底层文件所有权递归接管
    Write-Host "   [阶段 1/5] 正在递归获取 50,000+ 底层文件所有权 (takeown)..." -ForegroundColor Yellow
    Write-Host "              (由于碎文件极其庞大，耗时约 1~3 分钟，硬盘正在读写，请勿关闭)" -ForegroundColor DarkGray
    & takeown.exe /F "$winsxsPath" /R /D Y 2>$null | Out-Null

    # 阶段 2：访问控制列表权限递归重设
    Write-Host "   [阶段 2/5] 正在递归重置访问控制列表权限 (icacls)..." -ForegroundColor Yellow
    Write-Host "              (正在赋权底层文件，耗时约 1~3 分钟，请耐心等待)" -ForegroundColor DarkGray
    & icacls.exe "$winsxsPath" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

    # 阶段 3：保护并复制通用核心清单元数据
    Write-Host "   [阶段 3/5] 正在复制通用核心清单元数据 (Catalogs/Manifests)..." -ForegroundColor Yellow
    New-Item -Path $winsxsEditPath -ItemType Directory -Force | Out-Null
    $metaDirs = @("Catalogs", "FileMaps", "Fusion", "InstallTemp", "Manifests", "Settings")
    foreach ($meta in $metaDirs) {
        $metaSrc = Join-Path $winsxsPath $meta
        if (Test-Path $metaSrc) {
            Write-Host "              -> 同步元数据目录: $meta" -ForegroundColor DarkGray
            Copy-Item -Path $metaSrc -Destination (Join-Path $winsxsEditPath $meta) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 阶段 4：动态通配匹配并提取依赖组件 (带实时动态计数器)
    Write-Host "   [阶段 4/5] 正在通配匹配并提取依赖组件 (带动态计数器)..." -ForegroundColor Yellow
    $featureKeywords = @(
        "*common-controls*",
        "*gdiplus*",
        "*isolationautomation*",
        "*proxystub*",
        "*servicingstack*",
        "*onecore*",
        "*vc*.crt*",
        "*termsrv-extra*"
    )

    $allSxSDirs = Get-ChildItem -Path $winsxsPath -Directory | Where-Object {
        $dirName = $_.Name
        if ($metaDirs -contains $dirName) { return $false }
        if (-not ($dirName.StartsWith($arch) -or $dirName.StartsWith("x86") -or $dirName.StartsWith("msil"))) { 
            return $false 
        }
        foreach ($kw in $featureKeywords) {
            if ($dirName -like $kw) { return $true }
        }
        return $false
    }

    $totalSxS = $allSxSDirs.Count
    $currSxS = 0
    foreach ($dir in $allSxSDirs) {
        $currSxS++
        if ($currSxS % 5 -eq 0 -or $currSxS -eq $totalSxS) {
            $pct = [math]::Round(($currSxS / [math]::Max(1, $totalSxS)) * 100)
            Write-Progress -Activity "正在提取关键运行时依赖组件" -Status "[$currSxS/$totalSxS] 正在迁移: $($dir.Name)" -PercentComplete $pct
        }
        Copy-Item -Path $dir.FullName -Destination (Join-Path $winsxsEditPath $dir.Name) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Progress -Activity "正在提取关键运行时依赖组件" -Completed
    Write-Host "              [完成] 共成功提取并迁移了 $totalSxS 个核心依赖包。" -ForegroundColor Green

    # 阶段 5：粉碎旧库并挂载精简库
    Write-Host "   [阶段 5/5] 正在粉碎替换旧版 WinSxS 目录实体..." -ForegroundColor Yellow
    Force-NukeFolderOrFile $winsxsPath
    Rename-Item -Path $winsxsEditPath -NewName "WinSxS" -Force
    Write-Host "[完成] 自适应 WinSxS 极速瘦身全部完成！" -ForegroundColor Green
} else {
    Write-Host ">>> [普通模式] 执行官方标准 StartComponentCleanup /ResetBase (释放原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
}

# 提交并卸载主映像
Write-Host "`n正在提交更改并卸载 install.wim (展示官方原生百分比进度条)..." -ForegroundColor Cyan
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
Write-Host "[完成] 主映像已成功保存并提交更改。" -ForegroundColor Green
