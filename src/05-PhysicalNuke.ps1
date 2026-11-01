# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
#  重构要点：
#   1. 普通精简模式（trimMode != 2）：仅清理与组件注册无冲突的纯冗余资产
#      （字体、语音 TTS、临时目录、Web 壁纸、Help、Cursors、Native Images、
#      WinRE 占位、Default 用户 OneDrive 残留）。不再对 Program Files、
#      System32、SysWOW64、WinSxS、SystemApps 做 Edge/OneDrive 物理粉碎，
#      以避免绕过组件注册造成 DISM 报“可修复”。
#   2. 极限压榨模式（trimMode == 2）：保留原有地毯式物理粉碎逻辑。
#   3. Defender 仍由 06 模块“仅禁用服务 + 策略”，本模块不删除 Defender。
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
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 4. 移除预编译 .NET 程序集 (Native Images)
Write-Host "Removing pre-compiled .NET assemblies (Native Images)..."
$nativeImagePaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)
foreach ($p in $nativeImagePaths) {
    Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. Edge/OneDrive 地毯式物理粉碎（仅极限压榨模式）
if ($global:trimMode -eq "2") {
    Write-Host "Removing Edge and OneDrive (Universal Search)..." -ForegroundColor Yellow

    $searchBases = @(
        "$scratchDir\Program Files",
        "$scratchDir\Program Files (x86)",
        "$scratchDir\Windows\System32",
        "$scratchDir\Windows\SysWOW64",
        "$scratchDir\Windows\WinSxS",
        "$scratchDir\Windows\SystemApps"
    )
    $patternsToDelete = @("*Edge*", "*MicrosoftEdge*", "*OneDrive*")

    foreach ($base in $searchBases) {
        if (Test-Path -LiteralPath $base) {
            foreach ($pattern in $patternsToDelete) {
                $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
                foreach ($item in $items) {
                    Write-Host "   粉碎底层残留: $($item.FullName)" -ForegroundColor DarkGray
                    if ($item.PSIsContainer) {
                        & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                        & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                    }
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
} else {
    Write-Host "   [普通精简] 跳过 Program Files / System32 / SysWOW64 / WinSxS / SystemApps 的 Edge/OneDrive 物理粉碎，改由 Appx 官方移除与策略禁用处理。" -ForegroundColor DarkGray
}

# 6. 处理用户目录下的 OneDrive 残留（两种模式均清理 Default 配置残留）
$userProfileOneDrive = "$scratchDir\Users\Default\AppData\Local\Microsoft\OneDrive"
if (Test-Path $userProfileOneDrive) {
    Remove-Item -LiteralPath $userProfileOneDrive -Recurse -Force -ErrorAction SilentlyContinue
}

# 7. WinRE 零字节占位
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Write-Host "[完成] 冗余物理文件与底层组件清理完毕。" -ForegroundColor Green
