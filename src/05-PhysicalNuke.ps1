# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
#  全版本通用：采用通配符地毯式搜索，不依赖具体目录名
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

# 4. 全版本通用：地毯式清理 Edge 和 OneDrive
Write-Host "Removing Edge, WinRE, and OneDrive (Universal Search)..." -ForegroundColor Yellow

$searchBases = @(
    "$scratchDir\Program Files",
    "$scratchDir\Program Files (x86)",
    "$scratchDir\Windows\System32",
    "$scratchDir\Windows\SysWOW64",
    "$scratchDir\Windows\WinSxS"
)
$edgePatterns = @("*Edge*", "*MicrosoftEdge*")
$oneDrivePatterns = @("*OneDrive*")

foreach ($base in $searchBases) {
    if (Test-Path -LiteralPath $base) {
        foreach ($pattern in $edgePatterns) {
            $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Host "   Deleting Edge: $($item.FullName)" -ForegroundColor DarkGray
                if ($item.PSIsContainer) {
                    & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                    & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

foreach ($base in $searchBases) {
    if (Test-Path -LiteralPath $base) {
        foreach ($pattern in $oneDrivePatterns) {
            $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Host "   Deleting OneDrive: $($item.FullName)" -ForegroundColor DarkGray
                if ($item.PSIsContainer) {
                    & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                    & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$userProfileOneDrive = "$scratchDir\Users\Default\AppData\Local\Microsoft\OneDrive"
if (Test-Path $userProfileOneDrive) {
    Write-Host "   Deleting Default User OneDrive..." -ForegroundColor DarkGray
    Remove-Item -LiteralPath $userProfileOneDrive -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Write-Host "[完成] 冗余物理文件与 Edge/WinRE/OneDrive 处理完毕。" -ForegroundColor Green
