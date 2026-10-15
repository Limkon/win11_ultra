# ==============================================================================
#  win11 Builder - [模块 6/11] 实体物理清理 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在执行大文件实体物理删除 (nano11 原版)..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# 1. 字体精简 (nano11 原版白名单)
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# 2. TTS 引擎与 Defender 更新缓存
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# 3. 繁体、日文、韩文输入法
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Temp、Web、Help、Cursors
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 5. 移除 Edge、WinRE (空桩占位)、OneDrive (nano11 原生)
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# 6. nano11 原版第一轮基础清理
& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "[完成] 实体物理清理完毕。" -ForegroundColor Green
