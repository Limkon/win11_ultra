# ==============================================================================
#  win11 Builder - [模块 6/11] 物理实体精简 (src/05-PhysicalNuke.ps1)
#  [100% 像素级对齐 nano11 物理删除逻辑]：绝不破坏系统核心组件与 SmartScreen
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在同步 nano11 执行非必要实体文件清理..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# 1. 彻底移除 Edge 浏览器与 WebView
Write-Host "   -> 正在清理 Edge 与 WebView..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
$arch = if ((Get-CimInstance Win32_OperatingSystem).OSArchitecture -match 'ARM') { "arm64" } else { "amd64" }
if ($arch -eq 'amd64') {
    $folderPath = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    if ($folderPath) { Remove-Item -Path $folderPath -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# 2. 移除 WinRE 恢复环境并建立 nano11 占位桩 (防止 Setup 报错)
Write-Host "   -> 正在清理 WinRE (保留 nano11 占位空文件)..." -ForegroundColor DarkGray
$winreFile = "$scratchDir\Windows\System32\Recovery\winre.wim"
Remove-Item -Path $winreFile -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $winreFile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

# 3. 移除 OneDrive 安装引导实体
Write-Host "   -> 正在清理 OneDrive 安装包..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# 4. 清理 Defender 病毒库更新残留 (绝不强删 smartscreen 和核心驱动，保持 Shell 完好)
Write-Host "   -> 正在清理 Defender 历史残留..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# 5. 清理语音引擎 TTS
Write-Host "   -> 正在清理语音引擎 TTS..." -ForegroundColor DarkGray
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue

# 6. 输入法清理：严格按 nano11 仅剔除繁体、日语、韩语
Write-Host "   -> 正在清理日韩繁输入法实体..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 7. 临时目录、帮助、壁纸、光标清理 (完全对齐 nano11)
Write-Host "   -> 正在清理临时文件、Web、帮助与光标..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 8. 字体库精炼 (100% 对齐 nano11 白名单与剔除规则)
Write-Host "   -> 正在精炼字体库..." -ForegroundColor DarkGray
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

Write-Host "[完成] 实体文件精简完毕 (完全符合 nano11 稳定基准)。" -ForegroundColor Green
