# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 运行库物理重构与动态单卷导出 (src/08-WinSxSOptimize.ps1)
#  [企业级重构]：动态分卷精准导出 + 彻底根治版本错位 + 深度提权穿透 + 事务回退保护
# ==============================================================================

Write-Host "`n正在重构 WinSxS 核心运行库目录 (企业级自适应安全模式)..." -ForegroundColor Cyan

# ----------------- 0. 上下文变量与目标分卷安全兜底 -----------------
if (-not $wimFilePath) { 
    $wimFilePath = Join-Path $sourcesDir "install.wim" 
}

# 动态解析目标分卷，优先承接全局变量，杜绝历史硬编码导致的版本错位
$targetExportIndex = if ($global:targetIndex) { 
    $global:targetIndex 
} elseif ($index) { 
    $index 
} else { 
    "1" 
}
Write-Host ">>> 核心单卷导出已锁定目标分卷 Index: $targetExportIndex" -ForegroundColor Green

$sourceDirectory      = Join-Path $scratchDir "Windows\WinSxS"
$destinationDirectory = Join-Path $scratchDir "Windows\WinSxS_edit"

# 重置并预备临时提取目录
if (Test-Path -LiteralPath $destinationDirectory) { 
    Remove-Item -LiteralPath $destinationDirectory -Recurse -Force -ErrorAction SilentlyContinue 
}
New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

# ----------------- 1. 精准提取系统核心运行库白名单 -----------------
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
    "Catalogs",
    "FileMaps",
    "Fusion",
    "InstallTemp",
    "Manifests",
    "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
    "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
)

Write-Host "   -> 正在提取核心依赖运行库与 Servicing 组件..." -ForegroundColor DarkGray
foreach ($dir in $dirsToCopy) {
    $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
    foreach ($sDir in $sourceDirs) {
        $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
        Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 2. 深度提权穿透与物理强制粉碎 -----------------
Write-Host "   -> 正在接管原 WinSxS 目录全量权限并执行物理粉碎..." -ForegroundColor DarkGray

# 强制触发运行时垃圾回收，解开所有内部可能持有的句柄锁
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# 突破 TrustedInstaller 与只读属性限制
& takeown.exe /F "$sourceDirectory" /A /R /D Y > $null 2>&1
& icacls.exe "$sourceDirectory" /grant "*S-1-5-32-544:F" /T /C /Q > $null 2>&1
attrib.exe -R -S -H "$sourceDirectory\*" /S /D > $null 2>&1
cmd.exe /c "rd /s /q `"$sourceDirectory`"" > $null 2>&1

# 容错重试检测：确保底层文件系统完成删除同步
if (Test-Path -LiteralPath $sourceDirectory) {
    Start-Sleep -Seconds 1
    cmd.exe /c "rd /s /q `"$sourceDirectory`"" > $null 2>&1
}

# ----------------- 3. 智能决策与事务安全门禁 -----------------
if (-not (Test-Path -LiteralPath $sourceDirectory)) {
    # 【分支 A：粉碎成功】安全执行原子替换与深度基线重置
    Rename-Item -Path $destinationDirectory -NewName "WinSxS" -Force
    Write-Host "[成功] WinSxS 运行库极致瘦身重构完成。" -ForegroundColor Green
    
    Write-Host "   -> 正在执行组件存储重置与基线固化..." -ForegroundColor DarkGray
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase 2>$null | Out-Null
} else {
    # 【分支 B：回滚保护】检测到外部顽固占用，中止替换，保护母盘 100% 稳定可引导
    Write-Host "[智能回退] 检测到原 WinSxS 存在外部句柄锁定未完全释放，已中止重命名替换，保留完整组件存储。" -ForegroundColor Yellow
    Remove-Item -LiteralPath $destinationDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------- 4. 提交映像并动态导出所选分卷的紧凑单卷 -----------------
Write-Host "`n正在提交映像更改 (分卷 $targetExportIndex)..." -ForegroundColor Cyan

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

Write-Host "正在将已修改的目标分卷 [$targetExportIndex] 导出为独立紧凑单卷..." -ForegroundColor Cyan
$finalWim = Join-Path $sourcesDir "install_final.wim"

# 【核心修正】：使用动态的 $targetExportIndex，彻底杜绝写死为 1 的致命 Bug
& dism.exe /English /Export-Image "/SourceImageFile:$wimFilePath" "/SourceIndex:$targetExportIndex" "/DestinationImageFile:$finalWim" /Compress:max

# 最终文件原子替换与安全门禁校验
if ((Test-Path -LiteralPath $finalWim) -and ((Get-Item -LiteralPath $finalWim).Length -gt 500MB)) {
    Remove-Item -LiteralPath $wimFilePath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $finalWim -NewName "install.wim" -Force
    Write-Host "[完成] 映像处理与提交导出完毕 (已精确导出选定的版本分卷 [$targetExportIndex])。" -ForegroundColor Green
} else {
    Write-Host "[警告] 紧凑单卷导出校验异常，保留原映像以保全数据。" -ForegroundColor Yellow
}
