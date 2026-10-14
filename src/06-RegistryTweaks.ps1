# ==============================================================================
#  win11 Builder - [模块 7/11] 注册表核心优化 (src/06-RegistryTweaks.ps1)
#  [100% 像素级对齐 nano11 注册表配置]：不触动任何 Shell 关联，原生保障打开方式
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在挂载配置单元并 100% 注入 nano11 官方注册表优化项..." -ForegroundColor Cyan

# 1. 挂载注册表配置单元
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

# 2. 绕过硬件检测全量配置 (nano11 原生)
Write-Host "   -> 正在写入硬件限制全量绕过项..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f 2>$null | Out-Null

# 3. 禁用预装推广与商用广告推送 (nano11 原生)
Write-Host "   -> 正在禁用推广应用与流氓广告通道..." -ForegroundColor DarkGray
$cdmKeys = @(
    "OemPreInstalledAppsEnabled", "PreInstalledAppsEnabled", "SilentInstalledAppsEnabled",
    "ContentDeliveryAllowed", "FeatureManagementEnabled", "PreInstalledAppsEverEnabled",
    "SoftLandingEnabled", "SubscribedContentEnabled", "SubscribedContent-310093Enabled",
    "SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-338393Enabled",
    "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled", "SystemPaneSuggestionsEnabled"
)
foreach ($k in $cdmKeys) {
    & reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $k /t REG_DWORD /d 0 /f 2>$null | Out-Null
}
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins /t REG_SZ /d '{"pinnedList": [{}]}' /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v DisablePushToInstall /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v DontOfferThroughWUAU /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" /f 2>$null | Out-Null

# 4. 开启 OOBE 本地账户跳过支持 (nano11 原生)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f 2>$null | Out-Null

# 5. 禁用保留存储与 BitLocker 自动加密 (nano11 原生)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f 2>$null | Out-Null

# 6. 禁用 Chat 图标与任务栏小组件 (nano11 原生)
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 3 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f 2>$null | Out-Null

# 7. 清理 Edge 遗留卸载信息 (nano11 原生)
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f 2>$null | Out-Null

# 8. 禁用 OneDrive 同步与遥测跟踪 (nano11 原生)
Write-Host "   -> 正在禁用遥测与隐私搜集..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v Enabled /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore" /v HarvestContacts /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Personalization\Settings" /v AcceptedPrivacyPolicy /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice" /v Start /t REG_DWORD /d 4 /f 2>$null | Out-Null

# 9. 阻止 DevHome、新版 Outlook、Teams、Copilot 自动拉取 (nano11 原生)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v workCompleted /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v workCompleted /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v DisableInstallation /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v PreventRun /t REG_DWORD /d 1 /f 2>$null | Out-Null

# 10. 删除 nano11 官方指定的 5 个计划任务定义文件 (直接对齐)
Write-Host "   -> 正在删除遥测计划任务定义..." -ForegroundColor DarkGray
$tasksPath = Join-Path $scratchDir "Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

# 11. 禁用 Windows Update 自动更新 (nano11 原生)
Write-Host "   -> 正在关闭 Windows 自动更新通道..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE1 /t REG_SZ /d "net stop wuauserv" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE2 /t REG_SZ /d "sc stop wuauserv" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE3 /t REG_SZ /d "sc config wuauserv start= disabled" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE1 /t REG_SZ /d "reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE2 /t REG_SZ /d "reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "localhost" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "localhost" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UpdateServiceUrlAlternate /t REG_SZ /d "localhost" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisableOnline /t REG_DWORD /d 1 /f 2>$null | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\wuauserv" /v Start /t REG_DWORD /d 4 /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f 2>$null | Out-Null

# 12. 禁用 Windows Defender 服务 (nano11 原生规范：安全停用服务，隐藏设置页，绝不乱删系统文件)
Write-Host "   -> 正在停用 Windows Defender 服务栈..." -ForegroundColor DarkGray
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
foreach ($svc in $defenderServices) {
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v Start /t REG_DWORD /d 4 /f 2>$null | Out-Null
}
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v SettingsPageVisibility /t REG_SZ /d "hide:virus;windowsupdate" /f 2>$null | Out-Null

# 13. 卸载并安全移除冗余服务 (完全遵照 nano11 原版列表)
Write-Host "   -> 正在移除冗余服务项目..." -ForegroundColor DarkGray
$servicesToRemove = @( 
    'Spooler', 'PrintNotify', 'Fax', 'RemoteRegistry', 'diagsvc', 
    'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc', 
    'BluetoothUserService', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc' 
)
if ($trimMode -eq "2") {
    $servicesToRemove += 'WSearch'
}
foreach ($service in $servicesToRemove) { 
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$service" /f 2>$null | Out-Null 
}

# 14. 安全卸载全部配置单元
Write-Host "   -> 正在卸载注册表配置单元..." -ForegroundColor DarkGray
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zDEFAULT" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 注册表配置全部注入完毕 (100% 对齐 nano11，底层 Shell 结构零篡改)。" -ForegroundColor Green
