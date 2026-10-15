# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 物理重构与卸载提交 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在重构 WinSxS 运行库目录 (nano11 原版)..." -ForegroundColor Cyan

$sourceDirectory = "$scratchDir\Windows\WinSxS"
$destinationDirectory = "$scratchDir\Windows\WinSxS_edit"
New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

# 严格遵照 nano11 原版指定的 28 个目录
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
    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
)

foreach ($dir in $dirsToCopy) {
    $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
    foreach ($sDir in $sourceDirs) {
        $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
        Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force
    }
}

# 物理粉碎原 WinSxS 并重命名 (nano11 原生)
Remove-Item -Path $sourceDirectory -Recurse -Force
Rename-Item -Path $destinationDirectory -NewName "WinSxS"

# 最终第二轮组件重置与提交卸载
& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# 最终导出紧凑单卷 (nano11 原版做法)
$finalWim = Join-Path $sourcesDir "install_final.wim"
& dism.exe /English /Export-Image "/SourceImageFile:$wimFilePath" "/SourceIndex:1" "/DestinationImageFile:$finalWim" /Compress:max
Remove-Item -Path $wimFilePath -Force
Rename-Item -Path $finalWim -NewName "install.wim"

Write-Host "[完成] 映像处理与提交导出完毕 (100% 对齐 nano11)。" -ForegroundColor Green
