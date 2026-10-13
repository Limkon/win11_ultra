# ==============================================================================
#  win11 Builder - [模块 6/11] 大文件实体深度物理粉碎 (src/05-PhysicalNuke.ps1)
#  [重构加固]：全盘彻底剿灭 SearchHost 实体 + 杜绝后台拉起 + 核心框架保护
# ==============================================================================

Write-Host "`n[步骤 7/11] 深度物理粉碎非必要大文件实体 (Edge/Search/Defender/OneDrive/Speech)..." -ForegroundColor Cyan
Write-Host "   [模式说明] 普通模式与极限模式均完整执行以下实体物理粉碎：" -ForegroundColor DarkCyan

# 1. 恢复环境 (WinRE)
$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Write-Host "   -> 正在物理粉碎 WinRE 恢复环境文件..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

# 2. Microsoft Edge 浏览器完整生态 (Chromium 本体 + WebView + SystemApps 遗留 UWP 桩程序)
Write-Host "   -> 正在物理粉碎 Microsoft Edge 完整生态 (Chromium 本体 + WebView + UWP 桩程序)..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\Edge")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\EdgeUpdate")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Microsoft-Edge-Webview")

$systemApps = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path -LiteralPath $systemApps) {
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*MicrosoftEdge*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 3. Microsoft OneDrive (全路径与预装源)
Write-Host "   -> 正在物理粉碎 OneDrive 各层级安装与运行实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

# 4. Windows Defender 全栈驱动与服务组件
Write-Host "   -> 正在物理粉碎 Windows Defender 全栈驱动与服务组件实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthSystray.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthService.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\smartscreen.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\wd")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\WdFilter.sys")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\WdNisDrv.sys")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\wdboot.sys")

# 5. 日语、韩语、繁体中文输入法字库实体
Write-Host "   -> 正在物理粉碎繁体/日语/韩语输入法实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

# 6. Cortana 与 Windows Search 前后台全套引擎实体 (深度清除 Client.CBS 内部残留)
Write-Host "   -> 正在物理粉碎 Cortana 与 Windows Search (包含 SearchHost/SearchApp)..." -ForegroundColor DarkGray
if (Test-Path -LiteralPath $systemApps) {
    # 清理明确的 Cortana 与 Search 专属包
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" -or $_.Name -like "*Microsoft.Windows.Search*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }

    # 【深度修复】：全盘递归粉碎隐藏在 CBS 或其他宿主目录中的 SearchHost 执行实体
    Get-ChildItem -Path $systemApps -Recurse -Filter "SearchHost.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
    Get-ChildItem -Path $systemApps -Recurse -Filter "SearchApp.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 物理粉碎 System32 传统后台索引二进制文件
$sys32Dir = Join-Path $scratchDir "Windows\System32"
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchIndexer.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchFilterHost.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchProtocolHost.exe")

# 7. 语音引擎与离线帮助文档
Write-Host "   -> 正在物理粉碎语音引擎与帮助文档..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\TTS\en-US")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Help")

# 8. 冗余壁纸 (严格保护保留默认 img0.jpg)
$wallpapers = Join-Path $scratchDir "Windows\Web\Wallpaper"
if (Test-Path -LiteralPath $wallpapers) {
    Write-Host "   -> 正在清理多余壁纸 (严格保留默认 img0.jpg)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $wallpapers -Recurse -File | Where-Object { $_.Name -ne "img0.jpg" } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\Screen")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\TouchKeyboard")

# 9. 系统提示音 (严格保护保留 Windows 核心事件声音)
$mediaDir = Join-Path $scratchDir "Windows\Media"
if (Test-Path -LiteralPath $mediaDir) {
    Write-Host "   -> 正在精炼系统提示音 (保留核心事件声音)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $mediaDir -Filter "*.wav" | Where-Object { 
        $_.Name -notmatch "Windows (Background|Foreground|Error|Ding|Default)\.wav" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 10. 中文字体库深度精炼 (保护保留常见中文字体与核心 UI 字体)
$fontsPath = Join-Path $scratchDir "Windows\Fonts"
if (Test-Path -LiteralPath $fontsPath) {
    Write-Host "   -> 正在精炼中文字体库..." -ForegroundColor DarkGray
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "calibri*.*", "arial*.*", "times*.*", "msyh*.*", "simsun*.*", "simhei*.*", "kaiu*.*", "mingliu*.*" | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[完成] 大文件实体物理粉碎完毕 (SearchHost 物理实体已全面歼灭)。" -ForegroundColor Green
