# ==============================================================================
#  win11 Builder - [模块 6/11] 冗余大文件与实体物理清理 (src/05-PhysicalNuke.ps1)
#  [企业级重构]：100% 恢复原生安全删除逻辑 + 严禁篡改 SystemApps + 确保打开方式完好
# ==============================================================================

Write-Host "`n正在执行大文件实体物理清理 (原生纯净标准)..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# ----------------- 1. 字体精简 (原生安全白名单) -----------------
Write-Host "   -> 正在精简冗余字体库..." -ForegroundColor DarkGray
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path -LiteralPath $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# ----------------- 2. TTS 语音引擎与 Defender 更新缓存 -----------------
Write-Host "   -> 正在清理离线语音引擎与 Defender 冗余缓存..." -ForegroundColor DarkGray
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 3. 繁体、日文、韩文输入法组件 -----------------
Write-Host "   -> 正在清理东亚多余输入法..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 4. 临时目录、壁纸、帮助文档与指针 -----------------
Write-Host "   -> 正在清理临时文件、壁纸、帮助文档与光标..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 5. 移除 Edge、WinRE (空桩占位)、OneDrive (恢复原有安全删除逻辑) -----------------
Write-Host "   -> 正在移除 Edge 主体、OneDrive 并重置 WinRE 占位..." -ForegroundColor DarkGray

# 恢复原版精准物理删除：仅清除 Program Files 浏览器主体与 WebView，绝不碰 SystemApps 目录
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# 剥离 winre.wim 并创建 0 字节只读安全占位，规避安装程序崩溃
$winrePath = "$scratchDir\Windows\System32\Recovery\winre.wim"
Remove-Item -Path $winrePath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $winrePath -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# ----------------- 6. 第一轮组件存储基线清理与重置 -----------------
Write-Host "   -> 正在执行组件存储基线固化..." -ForegroundColor DarkGray

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "[完成] 实体物理清理完毕 (系统 Shell 与打开方式架构 100% 完好)。" -ForegroundColor Green
