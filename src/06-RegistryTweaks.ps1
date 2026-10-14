# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表原生 Unicode 导入引擎 (src/06-RegistryTweaks.ps1)
#  [终极重构加固]：彻底根治打开方式“更多应用”死锁 + IFEO 内核绝杀 SearchHost
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
#  B. 组策略安全禁用 SearchHost / Cortana 联网与后台 (移除危险的 IFEO 劫持)
# ==============================================================================
$null = $reg.AppendLine(@"
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
#  D. 终极修复：回归纯净 Win32 打开方式，彻底杜绝 COM 死锁
# ==============================================================================
$null = $reg.AppendLine(@"
; 1. 全域禁用打开方式向应用商店查询推荐应用（提升速度）
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer]
"NoUseStoreOpenWith"=dword:00000001

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Policies\Microsoft\Windows\Explorer]
"NoUseStoreOpenWith"=dword:00000001

; 2. 【核心策略】：彻底移除 DelegateExecute 键值（用负号 - 拔除）
; 让 OpenWith 直接执行纯正的 Win32 OpenWith.exe 进程，永不假死，永不依赖任何损坏的 UWP
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shell\openas\command]
@="%SystemRoot%\\system32\\OpenWith.exe \"%1\""
"DelegateExecute"=-

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Unknown\shell\opendlg\command]
@="%SystemRoot%\\system32\\OpenWith.exe \"%1\""
"DelegateExecute"=-

; 3. 稳固 .txt 文件的原生 Win32 记事本关联（阻断包验证报错）
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt]
@="txtfile"
"Content Type"="text/plain"
"PerceivedType"="text"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell\open\command]
@="\"%SystemRoot%\\System32\\notepad.exe\" \"%1\""
"@)

# ==============================================================================
#  E. 系统基础优化与隐私遥测剥离
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
#  F. 硬件检测全量绕过与 OOBE 免联网
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
#  G. 经典 Windows 照片查看器关联激活
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

# 4. 安全卸载配置单元 (防句柄残留死锁)
Write-Host "   正在安全卸载配置单元 (GC 垃圾回收防锁死机制推进)..." -ForegroundColor Green
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null

Write-Host "[完成] 离线注册表加固优化全部完毕 (记事本保持原生系统配置，打开方式“更多应用”死锁已排除)。" -ForegroundColor Green
