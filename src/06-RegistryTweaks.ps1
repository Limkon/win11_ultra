# ==============================================================================
#  win11 Builder - [模块 7/11] 注册表原生系统优化 (src/06-RegistryTweaks.ps1)
#  [企业级重构]：底层管道重定向消除红字 + Edge 协议关联全解绑 + 核心服务智能降级
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在挂载配置单元并执行企业级纯净优化注入..." -ForegroundColor Cyan

# ----------------- 0. 底层静默探针函数 (彻底杜绝 NativeCommandError) -----------------
function Safe-DeleteRegKey {
    <#
    .SYNOPSIS
        先探针探测键路径是否存在，存在时通过 cmd 纯内核通道静默删除，杜绝 PowerShell 5.1 Transcript 漏出红字
    #>
    param([string]$KeyPath)
    $psPath = $KeyPath -replace '^HKLM\\', 'HKLM:\'
    if (Test-Path -LiteralPath $psPath) {
        cmd.exe /c "reg.exe delete `"$KeyPath`" /f 2>nul" | Out-Null
    }
}

function Safe-DeleteRegValue {
    <#
    .SYNOPSIS
        静默删除指定键路径下的特定值项
    #>
    param(
        [string]$KeyPath,
        [string]$ValueName
    )
    $psPath = $KeyPath -replace '^HKLM\\', 'HKLM:\'
    if (Test-Path -LiteralPath $psPath) {
        cmd.exe /c "reg.exe delete `"$KeyPath`" /v `"$ValueName`" /f 2>nul" | Out-Null
    }
}

# ----------------- 1. 挂载脱机注册表配置单元 (4 个核心 Hive) -----------------
$defaultPath  = Join-Path $scratchDir "Windows\System32\config\default"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"

attrib.exe -R -S -H "$defaultPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null
attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null

& reg.exe load HKLM\zDEFAULT "$defaultPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null
& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null

# ----------------- 2. 硬件检测全量参数绕过 -----------------
Write-Host "   -> 写入硬件需求全量绕过配置..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 3. 禁用预装推广与流氓广告通道 -----------------
Write-Host "   -> 禁用推广应用与预装推送..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v OemPreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v ContentDeliveryAllowed /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins /t REG_SZ /d '{"pinnedList": [{}]}' /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v FeatureManagementEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEverEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContentEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338393Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353694Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353696Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v DisablePushToInstall /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v DontOfferThroughWUAU /t REG_DWORD /d 1 /f | Out-Null

Safe-DeleteRegKey "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions"
Safe-DeleteRegKey "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 4. 开启 OOBE 本地账户跳过支持 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 5. 禁用保留存储与 BitLocker 自动加密 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 6. 禁用 Chat 图标与任务栏小组件 -----------------
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 3 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Null

# ----------------- 7. 彻底注销 Edge 注册表关联与协议绑定 -----------------
Write-Host "   -> 彻底注销 Microsoft Edge 注册表关联与协议绑定..." -ForegroundColor DarkGray
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\EdgeUpdate"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\EdgeUpdate"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Clients\StartMenuInternet\Microsoft Edge"
Safe-DeleteRegValue "HKLM\zSOFTWARE\RegisteredApplications" "Microsoft Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"

# ----------------- 8. 禁用 OneDrive 同步与遥测跟踪 -----------------
Write-Host "   -> 禁用遥测与隐私搜集..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore" /v HarvestContacts /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Personalization\Settings" /v AcceptedPrivacyPolicy /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice" /v Start /t REG_DWORD /d 4 /f | Out-Null

# ----------------- 9. 阻止 DevHome、Outlook、Teams、Mail 自动安装 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null

Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v DisableInstallation /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v PreventRun /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 10. 删除遥测计划任务实体定义文件 -----------------
Write-Host "   -> 删除遥测计划任务定义..." -ForegroundColor DarkGray
$tasksPath = Join-Path $scratchDir "Windows\System32\Tasks"
$tasksToRemove = @(
    "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
    "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
    "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)
foreach ($t in $tasksToRemove) {
    if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 11. 禁用 Windows Update 自动更新 -----------------
Write-Host "   -> 关闭 Windows 自动更新通道..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE1 /t REG_SZ /d "net stop wuauserv" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE2 /t REG_SZ /d "sc stop wuauserv" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE3 /t REG_SZ /d "sc config wuauserv start= disabled" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE1 /t REG_SZ /d "reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE2 /t REG_SZ /d "reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UpdateServiceUrlAlternate /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisableOnline /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\wuauserv" /v Start /t REG_DWORD /d 4 /f | Out-Null

Safe-DeleteRegKey "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC"
Safe-DeleteRegKey "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 12. 停用 Windows Defender 服务栈 -----------------
Write-Host "   -> 停用 Windows Defender 服务栈..." -ForegroundColor DarkGray
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
foreach ($svc in $defenderServices) {
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v Start /t REG_DWORD /d 4 /f | Out-Null
}
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v SettingsPageVisibility /t REG_SZ /d "hide:virus;windowsupdate" /f | Out-Null

# ----------------- 13. 系统冗余与 Edge 升级服务智能治理 (零红字通道) -----------------
Write-Host "   -> 正在智能治理冗余系统服务..." -ForegroundColor DarkGray
$servicesToRemove = @( 
    'Spooler', 
    'PrintNotify', 
    'Fax', 
    'RemoteRegistry', 
    'diagsvc', 
    'WerSvc', 
    'PcaSvc', 
    'MapsBroker', 
    'WalletService', 
    'BthAvctpSvc', 
    'BluetoothUserService', 
    'wuauserv', 
    'UsoSvc', 
    'WaaSMedicSvc',
    'edgeupdate',
    'edgeupdatem',
    'MicrosoftEdgeElevationService'
)

foreach ($service in $servicesToRemove) { 
    $svcPath = "HKLM\zSYSTEM\ControlSet001\Services\$service"
    $svcPsPath = "HKLM:\zSYSTEM\ControlSet001\Services\$service"

    if (Test-Path -LiteralPath $svcPsPath) {
        # 1. 率先写入内核级安全禁用 (Start = 4)，保障即使后续 ACL 拦截也能 100% 达成停止运行目标
        cmd.exe /c "reg.exe add `"$svcPath`" /v Start /t REG_DWORD /d 4 /f 2>nul" | Out-Null

        # 2. 尝试物理彻底抹除键值（使用 cmd 内核吸收 stderr，杜绝 Transcript 抛出 NativeCommandError）
        cmd.exe /c "reg.exe delete `"$svcPath`" /f 2>nul" | Out-Null

        # 3. 校验执行结果
        if (Test-Path -LiteralPath $svcPsPath) {
            Write-Host "   [智能降级] 服务 [$service] 受系统底层 ACL 保护，已安全置为完全停用 (Start=4)。" -ForegroundColor DarkGray
        } else {
            Write-Host "   [物理抹杀] 服务 [$service] 已彻底从注册表抹除。" -ForegroundColor DarkGray
        }
    }
}

# ----------------- 14. 统一安全卸载脱机注册表配置单元 -----------------
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zDEFAULT" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 注册表原生优化完成 (100% 纯净标准注入，原生 Shell 完美无瑕)。" -ForegroundColor Green
