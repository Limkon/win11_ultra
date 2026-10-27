# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
#  重构要点：
#   1. Defender 改为“仅禁用”：保留策略写入与服务 Start=4，不再删除
#      WinDefend/WdNisSvc/SecurityHealthService 服务注册表键，避免触发自愈。
#   2. Edge 保留物理删除配套：继续删除 edgeupdate/edgeupdatem/
#      MicrosoftEdgeElevationService 服务键与卸载注册项。
#   3. 保留 AppxAllUserStore\Deprovisioned 标记写入，消费 03 模块收集的
#      $global:deprovisionedAppxFamilies（含 Edge 与 Cortana）。
#   4. 保留 OpenWith/照片查看器修复、硬件豁免、赞助应用/遥测/Copilot/
#      Teams/Outlook 禁用、计划任务删除、Windows Update 禁用、双路径服务删除。
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 挂载离线注册表配置单元 (带失败检查，避免静默生成无效母盘)
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
# 1.2 写入 Appx Deprovisioned 标记，阻止已移除预装应用（含 Edge/Cortana）复活
# ==============================================================================
Write-Host "Writing Appx Deprovisioned markers to prevent bloatware re-provisioning..." -ForegroundColor Yellow

$deprovisionedBase = "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
if ($global:deprovisionedAppxFamilies -and $global:deprovisionedAppxFamilies.Count -gt 0) {
    foreach ($familyName in $global:deprovisionedAppxFamilies) {
        & reg.exe add "$deprovisionedBase\$familyName" /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   [Deprovision] 已标记: $familyName" -ForegroundColor DarkGray
        } else {
            Write-Host "   [警告] 标记失败: $familyName (退出码 $LASTEXITCODE)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "   [完成] 共写入 $($global:deprovisionedAppxFamilies.Count) 个 Appx 防重装标记。" -ForegroundColor Green
} else {
    Write-Host "   [跳过] 未收集到任何 PackageFamilyName，未写入 Deprovisioned 标记。" -ForegroundColor DarkGray
}

# ==============================================================================
# 1.5 修复“打开方式 -> 更多应用” 及 恢复照片查看器
# ==============================================================================
Write-Host "Repairing OpenWith application associations and restoring Photo Viewer..." -ForegroundColor Yellow

# 步骤 A: 清理已删 AppX 产生的死链
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

# 步骤 B: 强制恢复 Notepad 核心关联
$essentialApps = @(
    @{ Exe = 'notepad.exe'; Name = 'Notepad' }
)
foreach ($app in $essentialApps) {
    foreach ($croot in @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')) {
        & 'reg' 'add' "$croot\Applications\$($app.Exe)\shell\open\command" '/ve' '/t' 'REG_SZ' '/d' "`"%SystemRoot%\system32\$($app.Exe)`" `"%1`"" '/f' 2>&1 | Out-Null
        & 'reg' 'add' "$croot\Applications\$($app.Exe)" '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' $app.Name '/f' 2>&1 | Out-Null
    }
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithList\notepad.exe' '/ve' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids' '/v' 'txtfile' '/t' 'REG_NONE' '/d' '' '/f' 2>&1 | Out-Null

# 步骤 C: 强制恢复 Windows 照片查看器 (Photo Viewer) 的注册与调用权限
$photoViewerCroot = 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities'
& 'reg' 'add' "$photoViewerCroot" '/v' 'ApplicationName' '/t' 'REG_SZ' '/d' '@%SystemRoot%\System32\PhotoViewer.dll,-24513' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.bmp' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.dib' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.gif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpe' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpeg' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpg' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jfif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.png' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Png' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.tif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.tiff' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null

& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll' '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' '@%SystemRoot%\System32\PhotoViewer.dll,-24513' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command' '/ve' '/t' 'REG_SZ' '/d' 'rundll32.exe "%SystemRoot%\System32\PhotoViewer.dll", ImageView_Fullscreen %1' '/f' 2>&1 | Out-Null

Write-Host "[完成] OpenWith 关联修复及照片查看器注册完毕。" -ForegroundColor Green

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

# ==============================================================================
# 2.5 Edge 物理删除配套：策略拦截 + 服务键删除（Defender 改为仅禁用）
# ==============================================================================
Write-Host "Disabling Edge at the kernel and policy level (Defender: disable-only)..." -ForegroundColor Yellow

# Edge 策略拦截
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
$edgeServices = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
foreach ($svc in $edgeServices) {
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc" /f 2>&1 | Out-Null
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate' '/v' 'DoNotUpdateToEdgeWithChromium' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' '/v' 'UpdateDefault' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null

# Defender 策略拦截（保留策略，不删服务键）
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' '/v' 'DisableAntiSpyware' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' '/v' 'DisableAntiVirus' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' '/v' 'DisableBehaviorMonitoring' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows Defender\Features' '/v' 'TamperProtection' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\SecurityHealthService' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "WdBoot")
foreach ($svc in $defenderServices) {
    & 'reg' 'add' "HKLM\zSYSTEM\ControlSet001\Services\$svc" '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
}

# 屏蔽 UI 入口
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' '/v' 'SettingsPageVisibility' '/t' 'REG_SZ' '/d' 'hide:virus;windowsupdate' '/f' 2>&1 | Out-Null

# ==============================================================================

Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$scratchDir\Windows\System32\Tasks"
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
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc" /f 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'NoAutoUpdate' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

# 3. 卸载并释放离线配置单元
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zCOMPONENTS", "HKLM\zSOFTWARE", "HKLM\zSYSTEM")) {
    Safely-UnloadHive -HiveName $h | Out-Null
}

# 4. 重新装载 SYSTEM 单元以深度清除多余服务实体
Write-Host "Loading registry hives to remove services..."
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 重新装载 SYSTEM 配置单元失败，退出码 $LASTEXITCODE，服务删除阶段中止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}
$servicesToRemove = @( 
    'Spooler', 'PrintNotify', 'Fax', 'RemoteRegistry', 'diagsvc', 
    'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc', 
    'BluetoothUserService', 'wuauserv', 'UsoSvc', 'WaaSMedicSVC',
    'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService'
)
foreach ($service in $servicesToRemove) { 
    Write-Host "Removing service: $service"
    # 双路径删除：ControlSet001 与 CurrentControlSet，避免离线 hive 符号链接差异导致残留
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$service" /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\zSYSTEM\CurrentControlSet\Services\$service" /f 2>&1 | Out-Null
}
Safely-UnloadHive -HiveName "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 离线注册表配置与多余服务清理全部完毕。" -ForegroundColor Green
