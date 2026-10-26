# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在执行系统冗余物理文件清理..." -ForegroundColor Cyan
$winDir = "$scratchDir\Windows"

# 1. 字体库精简
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
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 4. 移除 Edge, WinRE (建立 0 字节占位文件), 和 OneDrive
Write-Host "Removing Edge, WinRE, and OneDrive..." -ForegroundColor Yellow

# 彻底清理 Edge 相关的物理目录
$edgePaths = @(
    "$scratchDir\Program Files (x86)\Microsoft\Edge",
    "$scratchDir\Program Files (x86)\Microsoft\EdgeCore",
    "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
    "$scratchDir\Program Files\Microsoft\Edge",
    "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
)
foreach ($path in $edgePaths) {
    if (Test-Path -LiteralPath $path) {
        Write-Host "   Deleting Edge path: $path" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# WinSxS 里的 Edge WebView
if ($global:architecture -eq 'amd64') { 
    $edgeFolders = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*microsoft-edge-webview*" -Directory -ErrorAction SilentlyContinue
    if ($edgeFolders) {
        foreach ($folder in $edgeFolders) {
            Write-Host "   Deleting WinSxS Edge: $($folder.Name)" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 彻底清理 OneDrive 相关的物理目录
$oneDrivePaths = @(
    "$scratchDir\Windows\System32\OneDriveSetup.exe",
    "$scratchDir\Windows\SysWOW64\OneDriveSetup.exe",
    "$scratchDir\Program Files\Microsoft OneDrive",
    "$scratchDir\Program Files (x86)\Microsoft OneDrive"
)
foreach ($path in $oneDrivePaths) {
    if (Test-Path -LiteralPath $path) {
        Write-Host "   Deleting OneDrive path: $path" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# WinRE 处置：物理删除并建立 0 字节文件占位
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Write-Host "[完成] 冗余物理文件与 Edge/WinRE/OneDrive 处理完毕。" -ForegroundColor Green
