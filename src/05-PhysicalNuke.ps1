# ==============================================================================
#  win11 Builder - [模块 6/11] 大文件实体深度物理粉碎 (src/05-PhysicalNuke.ps1)
#  [终极修复加固版]：剔除 Client.CBS 破损隐患 + 保护记事本原生硬链接与安全 ACL
# ==============================================================================

Write-Host "`n[步骤 7/11] 深度物理粉碎非必要大文件实体 (Edge/Defender/OneDrive/Speech)..." -ForegroundColor Cyan
Write-Host "   [模式说明] 普通模式与极限模式均完整执行以下实体物理粉碎：" -ForegroundColor DarkCyan

# ----------------- 1. 恢复环境 (WinRE) -----------------
$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Write-Host "   -> 正在物理粉碎 WinRE 恢复环境文件..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

# ----------------- 2. Microsoft Edge 完整生态 -----------------
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

# ----------------- 3. Microsoft OneDrive -----------------
Write-Host "   -> 正在物理粉碎 OneDrive 各层级安装与运行实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

# ----------------- 4. Windows Defender 全栈驱动与服务组件 -----------------
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

# ----------------- 5. 日语、韩语、繁体中文输入法字库实体 -----------------
Write-Host "   -> 正在物理粉碎繁体/日语/韩语输入法实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

# ----------------- 6. 独立 Cortana 专属残留包 (严格保护 Client.CBS 核心) -----------------
# 【关键】：绝对不能递归粉碎 Client.CBS 内的 SearchHost.exe，否则 XAML 打开方式弹窗必崩！
Write-Host "   -> 正在物理清理独立 Cortana 专属残留应用包..." -ForegroundColor DarkGray
if (Test-Path -LiteralPath $systemApps) {
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
# 注意：原脚本下方删除 SearchIndexer.exe / SearchFilterHost.exe 的语句必须全部删掉！

# ----------------- 7. 语音引擎与离线帮助文档 -----------------
Write-Host "   -> 正在物理粉碎语音引擎与帮助文档..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\TTS\en-US")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Help")

# ----------------- 8. 冗余壁纸 (严格保护保留默认 img0.jpg) -----------------
$wallpapers = Join-Path $scratchDir "Windows\Web\Wallpaper"
if (Test-Path -LiteralPath $wallpapers) {
    Write-Host "   -> 正在清理多余壁纸 (严格保留默认 img0.jpg)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $wallpapers -Recurse -File | Where-Object { $_.Name -ne "img0.jpg" } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\Screen")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\TouchKeyboard")

# ----------------- 9. 系统提示音 (严格保护保留核心事件声音) -----------------
$mediaDir = Join-Path $scratchDir "Windows\Media"
if (Test-Path -LiteralPath $mediaDir) {
    Write-Host "   -> 正在精炼系统提示音 (保留核心事件声音)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $mediaDir -Filter "*.wav" | Where-Object { 
        $_.Name -notmatch "Windows (Background|Foreground|Error|Ding|Default)\.wav" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# ----------------- 10. 中文字体库深度精炼 -----------------
$fontsPath = Join-Path $scratchDir "Windows\Fonts"
if (Test-Path -LiteralPath $fontsPath) {
    Write-Host "   -> 正在精炼中文字体库..." -ForegroundColor DarkGray
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "calibri*.*", "arial*.*", "times*.*", "msyh*.*", "simsun*.*", "simhei*.*", "kaiu*.*", "mingliu*.*" | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# 【关键修复说明】：
# 原第 11 节【修复记事本物理执行实体】已被彻底移除！
# 严禁用 System32\notepad.exe 强行覆盖 C:\Windows\notepad.exe。
# 移除该节后，系统原生硬链接及其 TrustedInstaller/Users 组的安全 ACL 得到 100% 完整保留。

Write-Host "[完成] 大文件实体物理粉碎完毕 (底层核心框架完整性已得到妥善保护)。" -ForegroundColor Green
