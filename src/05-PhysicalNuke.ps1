# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在执行系统冗余物理文件清理..." -ForegroundColor Cyan
$winDir = "$scratchDir\Windows"

# 1. 字体库精简 (保护微软雅黑与核心英文字体)
$fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
if (Test-Path $fontsPath) { 
    Write-Host "Cleaning up Fonts..."
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# 2. 语音引擎、病毒定义更新与输入法
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 3. 临时目录、Web 壁纸、Help、Cursors
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# 保留 Windows\Web 下的 Screen/Shell 等资源，仅清理 Wallpaper 大体积内容，避免 Shell 资源加载失败
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 4. 移除 Edge, WinRE (建立 0 字节占位文件), 和 OneDrive
Write-Host "Removing Edge, WinRE, and OneDrive..."
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue

if ($global:architecture -eq 'amd64') { 
    $edgeFolder = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName 
    if ($edgeFolder) { Remove-Item -Path $edgeFolder -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# WinRE 处置：物理删除并建立 0 字节文件占位 (原版核心防报错细节)
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

Write-Host "[完成] 冗余物理文件与 Edge/WinRE 处理完毕。" -ForegroundColor Green
