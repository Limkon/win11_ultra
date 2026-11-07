# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
#  [方案 C 重构] 修复 Notepad 关联重建阶段 reg.exe 无限挂起：
#    - 根因：03 模块 Appx 操作 + 本节第 1.2 节 AppxAllUserStore 写入，触发
#      svchost 对 zSOFTWARE hive 加内部 HiveLock；Safely-UnloadHive 失败后
#      仍继续推进，zSOFTWARE 处于半挂载态，后续裸 reg.exe add 在
#      RegOpenKeyExW 上无限等待锁 → 整条流水线挂起。
#    - 修复：zSOFTWARE 拆为两轮独立挂载/卸载周期：
#        第一轮：只写 Appx Deprovisioned → 立即 AbortOnFailure 卸载
#        第二轮：重挂 → OpenWith 修复 + Notepad 重建 + Photo Viewer → 卸载
#      两轮之间插入 GC + Sleep 窗口，给 svchost 释放 Appx 回调锁。
#    - 其他 hive (zCOMPONENTS/zDEFAULT/zNTUSER/zSYSTEM) 节奏不变。
#    - 所有原有注册表项、策略、服务删除、计划任务删除、WU 禁用逻辑一字不动。
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# ==============================================================================
# 1. 挂载非 zSOFTWARE 的注册表配置单元 (带失败检查)
#    zSOFTWARE 延迟到第一轮内联加载，避免长时间持有触发 Appx 回调锁
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
#     目的：把 Appx 相关的注册表写入隔离在最短挂载窗口内，写完立刻切断，
#     避免 svchost 持有的 HiveLock 传染到后续 OpenWith/Notepad 重建。
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

# 第一轮卸载：AbortOnFailure=true，卸载失败立即中止，阻断半挂载态传染
Write-Host "[方案C-第一轮] 写入完毕，强制卸载 zSOFTWARE（失败即中止，阻断半挂载态）..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $true | Out-Null

# 两轮之间的句柄释放窗口：给 svchost 释放 Appx 通知回调锁的时间
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

# ==============================================================================
# 1.5 [方案C-第二轮] 重新挂载 zSOFTWARE → OpenWith 修复 + Notepad + Photo Viewer
#     此时 zSOFTWARE 是干净重挂状态，Appx 回调锁已随第一轮卸载释放。
# ==============================================================================
Write-Host "[方案C-第二轮] 干净重挂 zSOFTWARE 用于 OpenWith / Notepad / Photo Viewer 修复..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 第二轮重挂失败，退出码 $LASTEXITCODE，关联链修复无法执行。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ==============================================================================
# 1.5.1 修复“打开方式 -> 更多应用” 及 恢复照片查看器
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

# ==============================================================================
# 步骤 B: 完整重建 Notepad 与 txtfile 关联链
#  修复目标：
#   1. .txt 默认 ProgID = txtfile
#   2. txtfile 类型含 shell\open\command 指向 notepad.exe
#   3. notepad.exe 在 Applications 下注册完整（含 FriendlyAppName、command）
#   4. OpenWithList / OpenWithProgids 兜底
#  注意：离线操作写 HKLM\zSOFTWARE\Classes 与 WOW6432Node\Classes 双视图
# ==============================================================================
Write-Host "Rebuilding Notepad and txtfile association chain..." -ForegroundColor Yellow

$classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')
$notepadCmd   = '%SystemRoot%\System32\notepad.exe %1'

foreach ($croot in $classesRoots) {

    # --- 1. Applications\notepad.exe 完整注册 ---
    & 'reg' 'add' "$croot\Applications\notepad.exe" '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' 'Notepad' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\Applications\notepad.exe\shell\open\command" '/ve' '/t' 'REG_EXPAND_SZ' '/d' $notepadCmd '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\Applications\notepad.exe\DefaultIcon" '/ve' '/t' 'REG_EXPAND_SZ' '/d' '%SystemRoot%\System32\notepad.exe,0' '/f' 2>&1 | Out-Null

    # --- 2. .txt 扩展名主关联 ---
    & 'reg' 'add' "$croot\.txt" '/ve' '/t' 'REG_SZ' '/d' 'txtfile' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\.txt" '/v' 'Content Type' '/t' 'REG_SZ' '/d' 'text/plain' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\.txt" '/v' 'PerceivedType' '/t' 'REG_SZ' '/d' 'text' '/f' 2>&1 | Out-Null

    # --- 3. .txt\ShellNew —— "新建 → 文本文档"菜单 ---
    & 'reg' 'add' "$croot\.txt\ShellNew" '/v' 'NullFile' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\.txt\ShellNew" '/v' 'ItemName' '/t' 'REG_EXPAND_SZ' '/d' '@%SystemRoot%\System32\notepad.exe,-470' '/f' 2>&1 | Out-Null

    # --- 4. txtfile ProgID 完整定义（含打开命令，这是关联的核心） ---
    & 'reg' 'add' "$croot\txtfile" '/ve' '/t' 'REG_SZ' '/d' '文本文档' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfile" '/v' 'AlwaysShowExt' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfile" '/v' 'PerceivedType' '/t' 'REG_SZ' '/d' 'text' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfile\DefaultIcon" '/ve' '/t' 'REG_EXPAND_SZ' '/d' '%SystemRoot%\System32\notepad.exe,0' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfile\shell\open\command" '/ve' '/t' 'REG_EXPAND_SZ' '/d' $notepadCmd '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfile\ShellNew" '/v' 'NullFile' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null

    # --- 5. txtfilelegacy 兼容定义 ---
    & 'reg' 'add' "$croot\txtfilelegacy" '/ve' '/t' 'REG_SZ' '/d' '文本文档' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfilelegacy\DefaultIcon" '/ve' '/t' 'REG_EXPAND_SZ' '/d' '%SystemRoot%\System32\notepad.exe,0' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfilelegacy\shell\open\command" '/ve' '/t' 'REG_EXPAND_SZ' '/d' $notepadCmd '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\txtfilelegacy\ShellNew" '/v' 'NullFile' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null

    # --- 6. OpenWithList / OpenWithProgids 兜底 ---
    & 'reg' 'add' "$croot\.txt\OpenWithList\notepad.exe" '/ve' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\.txt\OpenWithProgids" '/v' 'txtfile' '/t' 'REG_NONE' '/d' '' '/f' 2>&1 | Out-Null
    & 'reg' 'add' "$croot\.txt\OpenWithProgids" '/v' 'txtfilelegacy' '/t' 'REG_NONE' '/d' '' '/f' 2>&1 | Out-Null
}
Write-Host "[完成] Notepad 与 txtfile 关联链重建完毕。" -ForegroundColor Green

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

# 第二轮卸载：此时已无后续 zSOFTWARE 依赖，失败仅警告继续
Write-Host "[方案C-第二轮] 关联链修复完毕，卸载 zSOFTWARE..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $false | Out-Null

# ==============================================================================
# 2. 常规注册表精简与优化（此时 zSOFTWARE 已卸载，以下仅涉及 zSYSTEM/zDEFAULT/zNTUSER）
#    注：本段所有 HKLM\zSOFTWARE\... 的写入已在上面两轮内完成，这里不再触碰 zSOFTWARE。
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

# ==============================================================================
# 3. 卸载并释放剩余离线配置单元 (zSOFTWARE 已在两轮内卸载，此处只卸 4 个)
# ==============================================================================
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zCOMPONENTS", "HKLM\zSYSTEM")) {
    Safely-UnloadHive -HiveName $h | Out-Null
}

# ==============================================================================
# 4. 重新装载 SYSTEM 单元以深度清除多余服务实体
# ==============================================================================
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