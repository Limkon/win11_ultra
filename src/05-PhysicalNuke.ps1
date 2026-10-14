# ==============================================================================
#  win11 Builder - [模块 6/11] 物理实体精简 (src/05-PhysicalNuke.ps1)
#  [100% 像素级对齐 nano11 源码]：绝不误删系统核心组件
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在同步 nano11 执行实体文件清理..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# 1. 移除 Edge 与 WebView (nano11 原生)
Write-Host "   -> 正在清理 Edge 与 WebView..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue

$destWimPath = Join-Path $sourcesDir "install.wim"
$wimInfoText = & dism.exe /English /Get-WimInfo "/WimFile:$destWimPath" "/Index:1"
$architecture = if ($wimInfoText -match "Architecture\s*:\s*(ARM64|arm64)") { "arm64" } else { "amd64" }

if ($architecture -eq 'amd64') { 
    $folderPath = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName 
    if ($folderPath) { Remove-Item -Path $folderPath -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# 2. 移除 WinRE 恢复环境并建立 nano11 空占位桩 (nano11 原生，防止安装报错)
Write-Host "   -> 正在清理 WinRE (生成占位空文件)..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

# 3. 移除 OneDrive 安装程序 (nano11 原生)
Write-Host "   -> 正在清理 OneDrive 安装包..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# 4. 清理 Defender 病毒库定义缓存 (nano11 原生，不删驱动本体)
Write-Host "   -> 正在清理 Defender 定义库更新残留..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# 5. 清理语音 TTS 引擎 (nano11 原生)
Write-Host "   -> 正在清理语音引擎 TTS..." -ForegroundColor DarkGray
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue

# 6. 输入法清理：仅剔除繁体、日文、韩文 (nano11 原生)
Write-Host "   -> 正在清理繁体/日文/韩文输入法..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 7. 清理 Temp、Web 壁纸、Help 帮助、Cursors 光标 (nano11 原生)
Write-Host "   -> 正在清理临时文件、帮助文档与壁纸..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 8. 字体库精炼 (nano11 原生保留中文字体与 Segoe 核心)
Write-Host "   -> 正在精炼字体库..." -ForegroundColor DarkGray
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

Write-Host "[完成] 物理文件精简完毕 (完全符合 nano11 稳定基线)。" -ForegroundColor Green
