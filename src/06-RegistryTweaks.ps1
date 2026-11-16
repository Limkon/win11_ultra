# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
#  [重构核心]：
#   1. 打印体系绝对保护（双模式通用）：
#      - 彻底剔除针对 Spooler 和 PrintNotify 的删除指令！
#      - 显式锁定 Spooler (Start=2 自动) 与 PrintNotify (Start=3 手动)，根治 RPC 崩溃。
#   2. 普通模式 (健康精简)：
#      - 蓝牙生态保护：坚决保留 BthAvctpSvc (耳机切歌/音量) 与 BluetoothUserService (蓝牙配对)。
#      - Windows Update 策略优化：采用“策略防打扰 + 按需启动 (Start=3)”方案，不堵死 localhost，
#        确保【微软商店正常下载】、【新插外设自动拉取官方驱动】、【.NET 3.5 / 功能包按需启用】。
#   3. 极限模式 (极限压榨)：
#      - 保留原有对 Windows Update 的极限封死策略及非关键服务清理，但绝对保护打印服务存活。
#   4. 完整保留 OpenWith 现代死锁修复、Notepad/照片查看器全链路修复、硬件限制跳过。
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# ==============================================================================
# 1. 挂载非 zSOFTWARE 的注册表配置单元 (带失败检查)
# ==============================================================================
$hiveLoads = @(
    @{ Name = "HKLM\zCOMPONENTS"; Path = "$scratchDir\Windows\System32\config\COMPONENTS" },
    @{ Name = "HKLM\zDEFAULT";    Path = "$scratchDir\Windows\System32\config\default" },
    @{ Name = "HKLM\zNTUSER";     Path = "$scratchDir\Users\Default\ntuser.dat" },
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
# 1.2 [方案C-第一轮] 挂载 zSOFTWARE → 只写 Appx Deprovisioned → 立即卸载
# ==============================================================================
Write-Host "[方案C-第一轮] 加载 zSOFTWARE 用于写入 Appx Deprovisioned 标记..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 配置单元加载失败，退出码 $LASTEXITCODE，Appx 防重装标记无法写入。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "Writing Appx Deprovisioned markers to prevent bloatware re-provisioning..." -ForegroundColor Yellow

$deprovisionedBase = "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
if ($global:deprovisionedAppxFamilies -and $global:deprovisionedAppxFamilies.Count -gt 0) {
    foreach ($familyName in $global:deprovisionedAppxFamilies) {
        $null = Invoke-RegSilent @('add', "$deprovisionedBase\$familyName", '/f')
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

Write-Host "[方案C-第一轮] 写入完毕，强制卸载 zSOFTWARE（阻断半挂载态）..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $true | Out-Null

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

# ==============================================================================
# 1.5 [方案C-第二轮] 重新挂载 zSOFTWARE → OpenWith 修复 + Notepad + Photo Viewer
# ==============================================================================
Write-Host "[方案C-第二轮] 干净重挂 zSOFTWARE 用于 OpenWith / Notepad / Photo Viewer 修复..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 第二轮重挂失败，退出码 $LASTEXITCODE，关联链修复无法执行。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 步骤 A: 彻底根治“打开方式 -> 更多应用”无反应 -----------------
Write-Host "Applying ultimate fix for 'Open With -> More Apps' deadlock..." -ForegroundColor Green

$blockedGuid = '{e44e9428-bdbc-4987-a099-40dc8fd255e7}'
$blockedRoots = @(
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
    'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
)
foreach ($br in $blockedRoots) {
    $null = Invoke-RegSilent @('add', $br, '/v', $blockedGuid, '/t', 'REG_SZ', '/d', 'OpenWith Modern Dialog Bypass', '/f')
}

$explorerPolicies = @(
    'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer',
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
)
foreach ($ep in $explorerPolicies) {
    $null = Invoke-RegSilent @('add', $ep, '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer', '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer', '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')

$openWithRoots = @('HKLM\zSOFTWARE\Classes\Applications\OpenWith.exe', 'HKLM\zSOFTWARE\WOW6432Node\Classes\Applications\OpenWith.exe')
foreach ($ow in $openWithRoots) {
    $null = Invoke-RegSilent @('add', $ow, '/v', 'NoOpenWith', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$ow\shell\open", '/v', 'MultiSelectModel', '/t', 'REG_SZ', '/d', 'Single', '/f')
    $null = Invoke-RegSilent @('add', "$ow\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\OpenWith.exe "%1"', '/f')
}

if ($global:removedAppxExeNames -and $global:removedAppxExeNames.Count -gt 0) {
    $commonExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.txt', '.log', '.ini', '.md', '.csv', '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov'
    )
    $classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')

    foreach ($exe in $global:removedAppxExeNames) {
        foreach ($croot in $classesRoots) {
            $null = Invoke-RegSilent @('delete', "$croot\Applications\$exe", '/f')
            foreach ($ext in $commonExtensions) {
                $null = Invoke-RegSilent @('delete', "$croot\$ext\OpenWithList\$exe", '/f')
                $null = Invoke-RegSilent @('delete', "$croot\$ext\OpenWithProgids", '/v', $exe, '/f')
            }
        }
    }
}

# ----------------- 步骤 B: 完整重建 Notepad 与 txtfile 关联链 -----------------
Write-Host "Rebuilding Notepad and txtfile association chain..." -ForegroundColor Yellow

$classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')
$notepadCmd   = '%SystemRoot%\System32\notepad.exe %1'

foreach ($croot in $classesRoots) {
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe", '/v', 'FriendlyAppName', '/t', 'REG_SZ', '/d', 'Notepad', '/f')
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt", '/ve', '/t', 'REG_SZ', '/d', 'txtfile', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt", '/v', 'Content Type', '/t', 'REG_SZ', '/d', 'text/plain', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt", '/v', 'PerceivedType', '/t', 'REG_SZ', '/d', 'text', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt\ShellNew", '/v', 'ItemName', '/t', 'REG_EXPAND_SZ', '/d', '@%SystemRoot%\System32\notepad.exe,-470', '/f')

    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/ve', '/t', 'REG_SZ', '/d', '文本文档', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/v', 'AlwaysShowExt', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/v', 'PerceivedType', '/t', 'REG_SZ', '/d', 'text', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')

    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy", '/ve', '/t', 'REG_SZ', '/d', '文本文档', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt\OpenWithList\notepad.exe", '/ve', '/t', 'REG_SZ', '/d', '', '/f')
}
Write-Host "[完成] Notepad 与 txtfile 关联链重建完毕。" -ForegroundColor Green

# ----------------- 步骤 C: 强制恢复 Windows 照片查看器 -----------------
$photoViewerCroot = 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities'
$null = Invoke-RegSilent @('add', $photoViewerCroot, '/v', 'ApplicationName', '/t', 'REG_SZ', '/d', '@%SystemRoot%\System32\PhotoViewer.dll,-24513', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.bmp', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.dib', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.gif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpe', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpeg', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpg', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jfif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.png', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Png', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.tif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
$null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.tiff', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll', '/v', 'FriendlyAppName', '/t', 'REG_SZ', '/d', '@%SystemRoot%\System32\PhotoViewer.dll,-24513', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command', '/ve', '/t', 'REG_SZ', '/d', 'rundll32.exe "%SystemRoot%\System32\PhotoViewer.dll", ImageView_Fullscreen %1', '/f')

Write-Host "[完成] OpenWith 关联修复及照片查看器注册完毕。" -ForegroundColor Green

Write-Host "[方案C-第二轮] 关联链修复完毕，卸载 zSOFTWARE..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $false | Out-Null

# ==============================================================================
# 2. 常规注册表精简与优化策略
# ==============================================================================
Write-Host "[方案C-第三轮] 重新挂载 zSOFTWARE 以承载 2/2.5/3 节的策略与服务写入..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 第三轮重挂失败，退出码 $LASTEXITCODE，后续策略写入无法执行。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch', '/v', 'DriverLoadPolicy', '/t', 'REG_DWORD', '/d', '8', '/f')

Write-Host "Bypassing system requirements(on the system image):"
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassCPUCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassRAMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassSecureBootCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassStorageCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassTPMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\MoSetup', '/v', 'AllowUpgradesWithUnsupportedTPMOrCPU', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Sponsored Apps:"
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'OemPreInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'PreInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SilentInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableWindowsConsumerFeatures', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'ContentDeliveryAllowed', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start', '/v', 'ConfigureStartPins', '/t', 'REG_SZ', '/d', '{"pinnedList": [{}]}', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'FeatureManagementEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'PreInstalledAppsEverEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SoftLandingEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContentEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-310093Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338388Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338389Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338393Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-353694Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-353696Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SystemPaneSuggestionsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall', '/v', 'DisablePushToInstall', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\MRT', '/v', 'DontOfferThroughWUAU', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableConsumerAccountStateContent', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableCloudOptimizedContent', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Enabling Local Accounts on OOBE:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'BypassNRO', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Reserved Storage:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager', '/v', 'ShippedWithReserves', '/t', 'REG_DWORD', '/d', '0', '/f')
Write-Host "Disabling BitLocker Device Encryption"
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker', '/v', 'PreventDeviceEncryption', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Chat icon:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat', '/v', 'ChatIcon', '/t', 'REG_DWORD', '/d', '3', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced', '/v', 'TaskbarMn', '/t', 'REG_DWORD', '/d', '0', '/f')

Write-Host "Disabling OneDrive folder backup"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive', '/v', 'DisableFileSyncNGSC', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Telemetry:"
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', '/v', 'Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy', '/v', 'TailoredExperiencesWithDiagnosticDataEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy', '/v', 'HasAccepted', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC', '/v', 'Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization', '/v', 'RestrictImplicitInkCollection', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization', '/v', 'RestrictImplicitTextCollection', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore', '/v', 'HarvestContacts', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings', '/v', 'AcceptedPrivacyPolicy', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection', '/v', 'AllowTelemetry', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')

Write-Host "Prevents installation of DevHome and Outlook:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate', '/v', 'workCompleted', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate', '/v', 'workCompleted', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate', '/f')
Write-Host "Disabling Copilot"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', '/v', 'TurnOffWindowsCopilot', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Edge', '/v', 'HubsSidebarEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer', '/v', 'DisableSearchBoxSuggestions', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevents installation of Teams:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Teams', '/v', 'DisableInstallation', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevent installation of New Outlook":
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail', '/v', 'PreventRun', '/t', 'REG_DWORD', '/d', '1', '/f')

# ----------------- 2.5 Edge 策略拦截与 Defender 禁用 -----------------
Write-Host "Disabling Edge at policy level (Defender: disable-only)..." -ForegroundColor Yellow

$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', '/f')
$edgeServices = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
foreach ($svc in $edgeServices) {
    $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$svc", '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate', '/v', 'DoNotUpdateToEdgeWithChromium', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate', '/v', 'UpdateDefault', '/t', 'REG_DWORD', '/d', '0', '/f')

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiSpyware', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiVirus', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', '/v', 'DisableBehaviorMonitoring', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows Defender\Features', '/v', 'TamperProtection', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\SecurityHealthService', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "WdBoot")
foreach ($svc in $defenderServices) {
    $null = Invoke-RegSilent @('add', "HKLM\zSYSTEM\ControlSet001\Services\$svc", '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
}

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer', '/v', 'SettingsPageVisibility', '/t', 'REG_SZ', '/d', 'hide:virus;windowsupdate', '/f')

# ----------------- 计划任务定义删除 -----------------
Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."

# ----------------- Windows Update 策略差异化处理 -----------------
if ($global:trimMode -eq "2") {
    # --------------------------------------------------------------------------
    # 极限模式：保留原有极限彻底断网阻断策略 (注意：会连带商店与自动驱动安装失效)
    # --------------------------------------------------------------------------
    Write-Host ">>> [极限压榨模式] 彻底物理截断 Windows Update (服务设为4 + 伪造本地服务器)..." -ForegroundColor Yellow
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE1', '/t', 'REG_SZ', '/d', 'net stop wuauserv', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE2', '/t', 'REG_SZ', '/d', 'sc stop wuauserv', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE3', '/t', 'REG_SZ', '/d', 'sc config wuauserv start= disabled', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE1', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE2', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DoNotConnectToWindowsUpdateInternetLocations', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DisableWindowsUpdateAccess', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUStatusServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'UpdateServiceUrlAlternate', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'UseWUServer', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'DisableOnline', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '1', '/f')

    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
} else {
    # --------------------------------------------------------------------------
    # 普通健康模式：静默防打扰 + 按需触发 (Start=3 手动)
    # 不篡改 WUServer，保证【微软商店正常下应用】、【插新硬件自动装驱动】、【.NET 3.5 按需安装】
    # --------------------------------------------------------------------------
    Write-Host "   [普通健康模式] 配置 Windows Update 为防打扰按需模式（保留应用商店与外设自动拉取驱动链路）..." -ForegroundColor Green
    
    # 策略级关闭自动强行重启与自动强推，AUOptions=2 (检查到更新但通知用户，绝不静默下载与重启)
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '0', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'AUOptions', '/t', 'REG_DWORD', '/d', '2', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoRebootWithLoggedOnUsers', '/t', 'REG_DWORD', '/d', '1', '/f')

    # 更新核心服务设为 3 (Manual 手动按需启动)，平时后台 0 资源占用，商店下载或插入新设备时自动唤醒
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
}

# ==============================================================================
# 3. 卸载并释放离线配置单元
# ==============================================================================
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zSOFTWARE", "HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zCOMPONENTS", "HKLM\zSYSTEM")) {
    Safely-UnloadHive -HiveName $h | Out-Null
}

# ==============================================================================
# 4. 重新装载 SYSTEM 单元以精炼多余服务实体 (打印与核心蓝牙绝对豁免)
# ==============================================================================
Write-Host "Loading registry hives to clean services..."
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 重新装载 SYSTEM 配置单元失败，退出码 $LASTEXITCODE，服务精炼阶段中止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 核心关键保障：确保 Spooler 服务配置百分之百健康 -----------------
Write-Host ">>> [打印保障] 正在锁定 Print Spooler 服务为自动启动 (Start=2)..." -ForegroundColor Green
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\Spooler', '/v', 'Start', '/t', 'REG_DWORD', '/d', '2', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\PrintNotify', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')

# ----------------- 服务移除/精简差异化处理 -----------------
if ($global:trimMode -eq "2") {
    # 极限模式：清理非关键服务，但【坚决排除 Spooler 和 PrintNotify】
    $servicesToRemove = @( 
        'Fax', 'RemoteRegistry', 'diagsvc', 
        'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc', 
        'BluetoothUserService', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService'
    )
    foreach ($service in $servicesToRemove) { 
        Write-Host "   [极限瘦身] 移除多余服务实体: $service" -ForegroundColor DarkGray
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$service", '/f')
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\CurrentControlSet\Services\$service", '/f')
    }
} else {
    # 普通健康模式：仅清理纯 Edge 更新独立残余，绝对不删系统底层服务，保护蓝牙与打印
    Write-Host "   [普通健康模式] 保留蓝牙核心服务 (BthAvctpSvc, BluetoothUserService) 与打印核心服务。" -ForegroundColor Green
    
    # 确保蓝牙核心服务为手动按需
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\BthAvctpSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    
    $safeToRemoveServices = @('RemoteRegistry', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
    foreach ($service in $safeToRemoveServices) { 
        Write-Host "   [健康清理] 移除无用服务: $service" -ForegroundColor DarkGray
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$service", '/f')
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\CurrentControlSet\Services\$service", '/f')
    }
}

Safely-UnloadHive -HiveName "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 离线注册表配置与服务配置精炼全部就绪。" -ForegroundColor Green
