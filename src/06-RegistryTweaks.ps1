# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 挂载离线注册表配置单元
$hiveLoads = @(
    @{ Name = "HKLM\zCOMPONENTS"; Path = "$scratchDir\Windows\System32\config\COMPONENTS" },
    @{ Name = "HKLM\zDEFAULT";    Path = "$scratchDir\Windows\System32\config\default" },
    @{ Name = "HKLM\zNTUSER";     Path = "$scratchDir\Users\Default\ntuser.dat" },
    @{ Name = "HKLM\zSOFTWARE";   Path = "$scratchDir\Windows\System32\config\SOFTWARE" },
    @{ Name = "HKLM\zSYSTEM";     Path = "$scratchDir\Windows\System32\config\SYSTEM" }
)
foreach ($h in $hiveLoads) {
    & reg.exe load $h.Name $h.Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[严重错误] 注册表配置单元加载失败: $($h.Name) <- $($h.Path)，退出码 $LASTEXITCODE" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
}

# ==============================================================================
# 1.5 修复“打开方式 -> 更多应用”列表崩溃问题
# ==============================================================================
Write-Host "Repairing OpenWith application associations..." -ForegroundColor Yellow

if ($global:removedAppxExeNames -and $global:removedAppxExeNames.Count -gt 0) {
    $commonExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.txt', '.log', '.ini', '.md', '.csv', '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov'
    )
    $classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')

    foreach ($exe in $global:removedAppxExeNames) {
        foreach ($croot in $classesRoots) {
            & reg.exe delete "$croot\Applications\$exe" /f 2>&1 | Out-Null
            foreach ($ext in $commonExtensions) {
                & reg.exe delete "$croot\$ext\OpenWithList\$exe" /f 2>&1 | Out-Null
                & reg.exe delete "$croot\$ext\OpenWithProgids" /v $exe /f 2>&1 | Out-Null
            }
        }
    }
}

$essentialApps = @(
    @{ Exe = 'notepad.exe'; Name = 'Notepad' },
    @{ Exe = 'mspaint.exe'; Name = 'Paint' }
)
foreach ($app in $essentialApps) {
    foreach ($croot in @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')) {
        & 'reg' 'add' "$croot\Applications\$($app.Exe)\shell\open\command" '/ve' '/t' 'REG_SZ' '/d' "`"%SystemRoot%\system32\$($app.Exe)`" `"%1`"" '/f' 2>&1 | Out-Null
        & 'reg' 'add' "$croot\Applications\$($app.Exe)" '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' $app.Name '/f' 2>&1 | Out-Null
    }
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithList\notepad.exe' '/ve' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids' '/v' 'txtfile' '/t' 'REG_NONE' '/d' '' '/f' 2>&1 | Out-Null

Write-Host "[完成] OpenWith 关联修复完毕。" -ForegroundColor Green

# ==============================================================================
# 2. 常规注册表精简与优化
# ==============================================================================

Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch' '/v' 'DriverLoadPolicy' '/t' 'REG_DWORD' '/d' '8' '/f' 2>&1 | Out-Null

Write-Host "Bypassing system requirements(on the system image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Sponsored Apps:"
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableWindowsConsumerFeatures' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' '/v' 'ConfigureStartPins' '/t' 'REG_SZ' '/d' '{"pinnedList": [{}]}' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'FeatureManagementEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEverEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SoftLandingEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-310093Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338388Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338389Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338393Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353694Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353696Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SystemPaneSuggestionsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' '/v' 'DisablePushToInstall' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' '/v' 'DontOfferThroughWUAU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' '/f' 2>&1 | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableConsumerAccountStateContent' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableCloudOptimizedContent' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Enabling Local Accounts on OOBE:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'BypassNRO' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Reserved Storage:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' '/v' 'ShippedWithReserves' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Chat icon:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' '/v' 'ChatIcon' '/t' 'REG_DWORD' '/d' '3' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' '/v' 'TaskbarMn' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null

# ==============================================================================
# 彻底清理并禁用 Edge 自愈 / 更新机制 (加强版)
# ==============================================================================
Write-Host "Removing Edge registries and disabling update mechanisms..." -ForegroundColor Yellow

# 1. 删除卸载项
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f 2>&1 | Out-Null

# 2. 禁用 Edge 更新服务和计划任务
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\edgeupdate' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\edgeupdatem' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\MicrosoftEdgeElevationService' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null

# 3. 阻止系统静默重装 Edge 的策略
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate' '/v' 'DoNotUpdateToEdgeWithChromium' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' '/v' 'UpdateDefault' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' '/v' 'InstallDefault' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null

# 4. 删除 Edge 相关的任务文件
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\MicrosoftEdgeUpdateTaskMachineCore" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\MicrosoftEdgeUpdateTaskMachineUA" -Force -ErrorAction SilentlyContinue

# ==============================================================================

Write-Host "Disabling OneDrive folder backup"
& 'reg' 'add' "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" '/v' 'DisableFileSyncNGSC' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Telemetry:"
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' '/v' 'TailoredExperiencesWithDiagnosticDataEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' '/v' 'HasAccepted' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitInkCollection' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitTextCollection' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' '/v' 'HarvestContacts' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' '/v' 'AcceptedPrivacyPolicy' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' '/v' 'AllowTelemetry' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null

Write-Host "Prevents installation or DevHome and Outlook:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" /f 2>&1 | Out-Null
Write-Host "Disabling Copilot"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' '/v' 'TurnOffWindowsCopilot' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' '/v' 'HubsSidebarEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' '/v' 'DisableSearchBoxSuggestions' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
Write-Host "Prevents installation of Teams:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' '/v' 'DisableInstallation' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
Write-Host "Prevent installation of New Outlook":
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' '/v' 'PreventRun' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Deleting scheduled task definition files..."
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."

Write-Host "Disabling Windows Update..."
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE1' '/t' 'REG_SZ' '/d' 'net stop wuauserv' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE2' '/t' 'REG_SZ' '/d' 'sc stop wuauserv' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE3' '/t' 'REG_SZ' '/d' 'sc config wuauserv start= disabled' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE1' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE2' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DoNotConnectToWindowsUpdateInternetLocations' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DisableWindowsUpdateAccess' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUStatusServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'UpdateServiceUrlAlternate' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'UseWUServer' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'DisableOnline' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '
