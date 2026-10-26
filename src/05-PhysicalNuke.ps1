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

# 彻底清理 Edge 相关的物理目录 (使用通配符摧毁整个 Microsoft 目录下的 Edge* 子目录)
$edgeBasePaths = @(
    "$scratchDir\Program Files (x86)\Microsoft",
    "$scratchDir\Program Files\Microsoft",
    "$scratchDir\Windows\System32",
    "$scratchDir\Windows\SysWOW64"
)
foreach ($base in $edgeBasePaths) {
    if (Test-Path -LiteralPath $base) {
        # 查找 Edge 相关的文件或目录
        $edgeItems = Get-ChildItem -Path $base -Filter "*Edge*" -ErrorAction SilentlyContinue
        foreach ($item in $edgeItems) {
            Write-Host "   Deleting Edge path: $($item.FullName)" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 清理 OneDrive 相关的物理目录
$oneDriveItems = Get-ChildItem -Path "$scratchDir\Windows\System32" -Filter "*OneDrive*" -ErrorAction SilentlyContinue
foreach ($item in $oneDriveItems) {
    Write-Host "   Deleting OneDrive path: $($item.FullName)" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# 清理 Program Files 下的 OneDrive 目录
$oneDriveProgPaths = @("$scratchDir\Program Files\Microsoft OneDrive", "$scratchDir\Program Files (x86)\Microsoft OneDrive")
foreach ($path in $oneDriveProgPaths) {
    if (Test-Path -LiteralPath $path) {
        Write-Host "   Deleting OneDrive path: $path" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# WinRE 处置
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Write-Host "[完成] 冗余物理文件与 Edge/WinRE/OneDrive 处理完毕。" -ForegroundColor Green
