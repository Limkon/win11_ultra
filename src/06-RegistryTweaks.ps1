# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表原生 Unicode 导入引擎 (src/06-RegistryTweaks.ps1)
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统参数..." -ForegroundColor Cyan

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

# ----------------- 模式分支：服务配置 -----------------
$normalServices = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter", "SecurityHealthService"
)
$defenderFullStack = @("WinDefend", "WdNisSvc", "Sense", "WdFilter", "WdNisDrv", "WdBoot")

# 关键：由于 Search 实体已被 100% 物理粉碎，两模式均彻底物理抹杀 WSearch 服务，防后台死循环拉起
$null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\WSearch]")

if ($trimMode -eq "2") {
    Write-Host "   >>> [极限模式] 构建 Defender 物理抹杀与服务清除指令..." -ForegroundColor DarkYellow
    $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Control\EarlyLaunch]")
    $null = $reg.AppendLine('"DriverLoadPolicy"=dword:00000008' + "`n")
    
    $extremeDeleteServices = $normalServices + $defenderFullStack + @("Spooler", "PrintNotify", "Fax", "RemoteRegistry", "diagsvc")
    foreach ($svc in $extremeDeleteServices) {
        $null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
    }
} else {
    Write-Host "   >>> [普通模式] 构建服务安全停用指令 (Start = 4)..." -ForegroundColor Cyan
    $allServicesToDisable = $normalServices + $defenderFullStack
    foreach ($svc in $allServicesToDisable) {
        $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
        $null = $reg.AppendLine('"Start"=dword:00000004' + "`n")
    }
}

# ----------------- 基础优化与遥测 -----------------
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

; 彻底关闭 Windows 搜索策略
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Windows Search]
"AllowCortana"=dword:00000000
"DisableWebSearch"=dword:00000001
"ConnectedSearchUseWeb"=dword:00000000

; 清理 Edge 相关废弃关联与协议
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgeHTM]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgePDF]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\msedge.exe]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\{1F8766B3-3F96-48DA-B6A8-A013FFC2A5BE}]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\Microsoft.MicrosoftEdge_8wekyb3d8bbwe]

; 关闭 SmartScreen 拦截策略 (防 smartscreen.exe 物理删除后调用挂死)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\System]
"EnableSmartScreen"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"SmartScreenEnabled"="Off"

; 仅保留关闭互联网打开方式搜索，严禁注入 NoUseStoreOpenWith 以免触发 DirectUI 零高度崩溃
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer]
"NoInternetOpenWith"=dword:00000001
"@)

# ----------------- 核心修复：固化 Shell 接口、激活记事本与注入应用池垫片 -----------------
$null = $reg.AppendLine(@"
; 1. 固化写入丢失的 IEnumAssocHandlers 与 IAssocHandler 核心接口 (防 E_NOINTERFACE 报错)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{973810AE-9599-4B88-9E4D-6EE98C0C8AC3}]
@="IEnumAssocHandlers"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{973810AE-9599-4B88-9E4D-6EE98C0C8AC3}\ProxyStubClsid32]
@="{A4A1A128-768F-41E0-BF75-E4FDDD701CBA}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{973810AE-9599-4B88-9E4D-6EE98C0C8AC3}\NumMethods]
@="7"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{F04061AC-1659-4A42-9F4E-E150522B1037}]
@="IAssocHandler"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{F04061AC-1659-4A42-9F4E-E150522B1037}\ProxyStubClsid32]
@="{A4A1A128-768F-41E0-BF75-E4FDDD701CBA}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Interface\{F04061AC-1659-4A42-9F4E-E150522B1037}\NumMethods]
@="10"

; 2. 扩展名关联与 ShellNew 唤醒
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt]
@="txtfile"
"Content Type"="text/plain"
"PerceivedType"="text"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\ShellNew]
"NullFile"=""
"ItemName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,37,00,30,00,00,00

; 彻底清空并重置 OpenWithProgids，抹除原版残留的幽灵 AppX
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
"txtfile"=hex(0):

; 3. txtfile ProgID 实体定义
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile]
@="文本文档"
"FriendlyTypeName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\DefaultIcon]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,69,00,6d,00,61,00,67,00,65,00,72,00,65,00,73,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,31,00,30,00,32,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell]
@="open"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell\open\command]
@=hex(2):22,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,22,00,20,00,22,00,25,00,31,00,22,00,00,00

; 4. XML 文档关联
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.xml]
@="xmlfile"
"Content Type"="text/xml"
"PerceivedType"="text"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\xmlfile]
@="XML 文档"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\xmlfile\shell\open\command]
@=hex(2):22,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,22,00,20,00,22,00,25,00,31,00,22,00,00,00

; 5. 彻底去除记事本劫持并注册全局应用实体
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe]
"UseFilter"=dword:00000000
"Debugger"=-

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,00,00

[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\notepad.exe\NoOpenWith]

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\notepad.exe]
"FriendlyAppName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\notepad.exe\shell\open\command]
@=hex(2):22,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,22,00,20,00,22,00,25,00,31,00,22,00,00,00

; 6. 注册原生资源管理器到应用枚举池 (0 字节垫片，防止应用数为 0 触发 DirectUI 折叠 BUG)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\explorer.exe]
"FriendlyAppName"="Windows 资源管理器"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\explorer.exe\shell\open\command]
@=hex(2):22,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,65,00,78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,00,78,00,65,00,22,00,20,00,22,00,25,00,31,00,22,00,00,00

; 7. 抹除 Default 用户中 UWP 留下的损坏关联
[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
"txtfile"=hex(0):

[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\UserChoice]
"@)

# ----------------- 硬件检测绕过与 OOBE -----------------
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

# ----------------- 照片查看器关联 -----------------
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

# 4. 彻底物理粉碎 Explorer 僵尸缓存 (必须执行，否则 Win11 拒绝刷新新建菜单)
Write-Host "   正在粉碎 Explorer 新建菜单僵尸缓存 (强制唤醒文本文档)..." -ForegroundColor DarkGray
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null

# 5. 安全卸载配置单元
Write-Host "   正在安全卸载配置单元 (防句柄残留)..." -ForegroundColor Green
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Write-Host "[完成] 离线注册表优化全部完毕。" -ForegroundColor Green
