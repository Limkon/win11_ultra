# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表原生 Unicode 导入引擎 (src/06-RegistryTweaks.ps1)
#  [终极重构]：彻底唤醒新建文本文档 + IFEO 内核绝杀 SearchHost + 修复打开方式死锁
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 定位并挂载离线配置单元文件
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"

attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null

& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null

# 2. 准备原生 .reg 注册表内容 (UTF-16 LE 原生支持中文，无转义 BUG)
$reg = New-Object System.Text.StringBuilder
$null = $reg.AppendLine("Windows Registry Editor Version 5.00`n")

# ==============================================================================
#  A. 全局底层安全加固策略 (普通模式与极限模式均必须执行)
# ==============================================================================

$null = $reg.AppendLine(@"
; 1. 内核级 ELAM 启动策略豁免 (彻底杜绝强删 wdboot.sys 后的 0xc0000428 蓝屏)
[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Control\EarlyLaunch]
"DriverLoadPolicy"=dword:00000008

; 2. 彻底拔除导致盘符属性瘫痪的 BitLocker 幽灵扩展
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\{D9DE8B79-CE8A-421A-98C3-5F17A9EB2269}]

; 3. 彻底抹杀导致右键菜单卡死 1~3 秒的 Defender EPP 幽灵扩展
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP]

; 4. 固化盘符与文件标准属性页 COM 挂载
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\Sharing]
@="{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\Security]
@="{1f2e5c40-9550-11ce-99d2-00aa006e086a}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shellex\PropertySheetHandlers\Security]
@="{1f2e5c40-9550-11ce-99d2-00aa006e086a}"

; 5. 全局切换至 Windows 经典高效右键菜单 (解决现代 XAML 菜单吞点击事件 BUG)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""
"@)

# ==============================================================================
#  B. 内核级绝对拦截 SearchHost / SearchIndexer (彻底杜绝后台常驻拉起)
# ==============================================================================
$null = $reg.AppendLine(@"
; 使用系统内核级 IFEO 机制：任何拉起 SearchHost/SearchApp 的行为直接在 0 毫秒内退出
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchHost.exe]
"Debugger"="systray.exe"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchApp.exe]
"Debugger"="systray.exe"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchIndexer.exe]
"Debugger"="systray.exe"

; 关闭任务栏搜索图标展示
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

; 彻底停用 Windows 搜索与 Cortana 联网策略
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Windows Search]
"AllowCortana"=dword:00000000
"DisableWebSearch"=dword:00000001
"ConnectedSearchUseWeb"=dword:00000000
"PreventIndexingLowDiskSpaceMB"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001
"@)

# ==============================================================================
#  C. 模式分支：服务配置
# ==============================================================================
$normalServices = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter", "SecurityHealthService"
)
$defenderFullStack = @("WinDefend", "WdNisSvc", "Sense", "WdFilter", "WdNisDrv", "WdBoot")

if ($trimMode -eq "2") {
    Write-Host "   >>> [极限模式] 构建 Defender 物理抹杀与服务深度清除指令..." -ForegroundColor DarkYellow
    $null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\WSearch]")
    $extremeDeleteServices = $normalServices + $defenderFullStack + @("Spooler", "PrintNotify", "Fax", "RemoteRegistry", "diagsvc")
    foreach ($svc in $extremeDeleteServices) {
        $null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
    }
} else {
    Write-Host "   >>> [普通模式] 构建服务安全停用指令 (Start = 4)..." -ForegroundColor Cyan
    $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\WSearch]")
    $null = $reg.AppendLine('"Start"=dword:00000004' + "`n")

    $allServicesToDisable = $normalServices + $defenderFullStack
    foreach ($svc in $allServicesToDisable) {
        $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
        $null = $reg.AppendLine('"Start"=dword:00000004' + "`n")
    }
}

# ==============================================================================
#  D. 核心修复：新建文本文档 100% 唤醒机制 (规范化 Win11 字符串间接资源与双 ProgID)
# ==============================================================================
$null = $reg.AppendLine(@"
; 1. 扩展名 .txt 基础关联 (主指 txtfilelegacy)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt]
@="txtfilelegacy"
"Content Type"="text/plain"
"PerceivedType"="text"

; 【关键修复】：必须写入间接字符串资源 @%SystemRoot%\system32\notepad.exe,-470，否则 Win11 判定名称为空直接隐藏
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\ShellNew]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\ShellNew]
"ItemName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,37,00,30,00,00,00
"NullFile"=""

; 清空可能干扰的 OpenWithProgids
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
"txtfilelegacy"=hex(0):
"txtfile"=hex(0):

; 2. Win11 核心实体 txtfilelegacy 深度补全
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy]
@="文本文档"
"FriendlyTypeName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\DefaultIcon]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,69,00,6d,00,61,00,67,00,65,00,72,00,65,00,73,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,31,00,30,00,32,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\shell]
@="open"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00

; 3. 经典 txtfile 回退兼容实体
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile]
@="文本文档"
"FriendlyTypeName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\DefaultIcon]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,32,00,5c,00,69,00,6d,00,61,00,67,00,65,00,72,00,65,00,73,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,31,00,30,00,32,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell]
@="open"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00

; 4. 彻底修正 App Paths，强制直指 System32 经典记事本
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,00,00

; 5. 抹除 Default 用户中 UWP 留下的损坏关联
[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
"txtfilelegacy"=hex(0):
"txtfile"=hex(0):

[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\UserChoice]
"@)

# ==============================================================================
#  E. 核心修复：彻底根治“打开方式 -> 选择其他应用”无反应的死锁
# ==============================================================================
$null = $reg.AppendLine(@"
; 1. 彻底删除导致 Win11 XAML OpenWith 按钮路由断裂的策略
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer\NoInternetOpenWith]
[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Policies\Microsoft\Windows\Explorer\NoInternetOpenWith]

; 2. 【核心修复】：为 openas 与 opendlg 注入原生 COM DelegateExecute 代理契约
; 严禁裸调 OpenWith.exe，必须由 Shell 代理调度器托管拉起
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shell\openas]
@=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,73,00,68,00,65,00,6c,00,6c,00,33,00,32,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,35,00,33,00,37,00,36,00,00,00
"MultiSelectModel"="Single"
"Position"="Bottom"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shell\openas\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,4f,00,70,00,65,00,6e,00,57,00,69,00,74,00,68,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00
"DelegateExecute"="{e44e9428-bdbc-4987-a099-40dc8fd255e7}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Unknown\shell\opendlg\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,4f,00,70,00,65,00,6e,00,57,00,69,00,74,00,68,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00
"DelegateExecute"="{e44e9428-bdbc-4987-a099-40dc8fd255e7}"
"@)
# ==============================================================================
#  F. 系统基础优化与隐私遥测剥离
# ==============================================================================
$null = $reg.AppendLine(@"
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\DataCollection]
"AllowTelemetry"=dword:00000000
"MaxTelemetryAllowed"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting]
"Disabled"=dword:00000001

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"EnableTransparency"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\OneDrive]
"DisableFileSyncNGSC"=dword:00000001
"DisableFileSync"=dword:00000001
"DisableMeteredNetworkFileSync"=dword:00000001
"DisableLibrariesStylePin"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run]
"OneDrive"=-
"OneDriveSetup"=-

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run]
"OneDrive"=-

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}]
"System.IsPinnedToNameSpaceTree"=dword:00000000

; 清理 Edge 遗留卸载项与幽灵 DCOM 契约 (斩断 Event 10001 死锁源)
[-HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgeHTM]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgePDF]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\msedge.exe]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\{1F8766B3-3F96-48DA-B6A8-A013FFC2A5BE}]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\Microsoft.MicrosoftEdge_8wekyb3d8bbwe]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Extensions\ContractId\Windows.File\PackageId\Microsoft.MicrosoftEdge_44.22000.120.0_neutral__8wekyb3d8bbwe]

; 关闭 SmartScreen 拦截策略 (防 smartscreen.exe 物理删除后调用挂起)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\System]
"EnableSmartScreen"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"SmartScreenEnabled"="Off"
"@)

# ==============================================================================
#  G. 硬件检测全量绕过与 OOBE 免联网
# ==============================================================================
$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\Setup\LabConfig]")
foreach ($k in $labConfigKeys) {
    $null = $reg.AppendLine("`"$k`"=dword:00000001")
}

$null = $reg.AppendLine(@"
[HKEY_LOCAL_MACHINE\zSYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\CloudContent]
"DisableWindowsConsumerFeatures"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE]
"BypassNRO"=dword:00000001
"DisableOnline"=dword:00000001
"@)

# ==============================================================================
#  H. 经典 Windows 照片查看器关联激活
# ==============================================================================
$photoExts = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".jfif")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\RegisteredApplications]")
$null = $reg.AppendLine('"Windows Photo Viewer"="SOFTWARE\\Microsoft\\Windows Photo Viewer\\Capabilities"' + "`n")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations]")
foreach ($ext in $photoExts) {
    $null = $reg.AppendLine("`"$ext`"=`"PhotoViewer.FileAssoc.Tiff`"")
}
foreach ($ext in $photoExts) {
    $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\$ext]")
    $null = $reg.AppendLine('@="PhotoViewer.FileAssoc.Tiff"' + "`n")
}

# 3. 写入带 BOM 的 UTF-16 LE 原生 .reg 文件并使用 reg import 原生原子导入
$tempRegFile = Join-Path $env:TEMP "win11_ultra_tweaks.reg"
[System.IO.File]::WriteAllText($tempRegFile, $reg.ToString(), [System.Text.Encoding]::Unicode)

Write-Host "   正在通过 Windows 原生注册表引擎导入 Unicode 策略流..." -ForegroundColor Green
& reg.exe import "$tempRegFile" 2>&1 | Out-Null
Remove-Item -LiteralPath $tempRegFile -Force -ErrorAction SilentlyContinue

# 4. 彻底物理粉碎 Explorer 僵尸缓存 (强制唤醒文本文档与新建菜单项)
Write-Host "   正在粉碎 Explorer 新建菜单僵尸缓存 (强制刷新菜单索引)..." -ForegroundColor DarkGray
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null

# 5. 安全卸载配置单元 (防句柄残留死锁)
Write-Host "   正在安全卸载配置单元 (GC 垃圾回收防锁死机制推进)..." -ForegroundColor Green
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null

Write-Host "[完成] 离线注册表加固优化全部完毕 (文本文档已三重加固，SearchHost 已内核拦截，打开方式死锁已排除)。" -ForegroundColor Green
