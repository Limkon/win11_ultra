# ==============================================================================
#  win11 Builder - [模块 6/11] 大文件实体深度物理粉碎 (src/05-PhysicalNuke.ps1)
#  [架构重构]：零外壳损伤 + 保护 Client.CBS 签名 + 杜绝字体/记事本误伤
# ==============================================================================

Write-Host "`n[步骤 7/11] 深度物理粉碎非必要独立大文件实体 (Edge/Defender/OneDrive/WinRE)..." -ForegroundColor Cyan
Write-Host "   [设计原则] 仅粉碎 100% 独立且无外壳绑定的实体，严格保护系统核心 XAML 宿主。" -ForegroundColor DarkCyan

# 1. 恢复环境 (WinRE - 释放约 500MB)
$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Write-Host "   -> 正在物理粉碎 WinRE 恢复环境文件..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

# 2. Microsoft Edge 浏览器完整生态 (Chromium 本体 + WebView + 独立更新服务 - 释放约 1.2GB)
Write-Host "   -> 正在物理粉碎 Microsoft Edge 完整生态 (Chromium 本体 + WebView)..." -ForegroundColor DarkGray
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

# 3. Microsoft OneDrive (全路径预装源与运行实体 - 释放约 200MB)
Write-Host "   -> 正在物理粉碎 OneDrive 各层级安装与运行实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

# 4. Windows Defender 全栈驱动与服务组件实体 (配合注册表 ELAM 免蓝屏)
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

# 5. 日语、韩语、繁体中文输入法大字库实体
Write-Host "   -> 正在物理粉碎繁体/日语/韩语输入法字典实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

# 6. 独立 Cortana 与传统后台检索实体 (【绝密级红线】：绝对不进入 Client.CBS 强删内部文件)
Write-Host "   -> 正在物理粉碎独立 Cortana 目录与 System32 传统索引二进制..." -ForegroundColor DarkGray
if (Test-Path -LiteralPath $systemApps) {
    # 仅安全删除独立的 Cortana 目录，杜绝递归检索 Client.CBS
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 物理粉碎 System32 传统后台索引执行程序
$sys32Dir = Join-Path $scratchDir "Windows\System32"
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchIndexer.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchFilterHost.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchProtocolHost.exe")

# 7. 语音引擎与离线帮助文档
Write-Host "   -> 正在物理粉碎离线语音引擎与帮助文档..." -ForegroundColor DarkGray
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

Write-Host "[完成] 独立实体物理粉碎完毕 (系统核心外壳包签名完整无损)。" -ForegroundColor Green
