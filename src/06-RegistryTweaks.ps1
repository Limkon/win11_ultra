# ==============================================================================
#  Windows 10/11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
#  [重构核心]：
#   1. 打印体系绝对保护（双模式通用）：
#      - 彻底剔除针对 Spooler 和 PrintNotify 的删除指令！
#      - 仅当映像内存在打印服务时锁定 Spooler (Start=2) 与 PrintNotify (Start=3)。
#   2. 普通模式 (健康精简)：
#      - 蓝牙生态保护：保留 BthAvctpSvc 与 BluetoothUserService。
#      - Windows Update 策略优化：采用“策略防打扰 + 按需启动 (Start=3)”方案，
#        确保微软商店正常下载、新插外设自动拉取官方驱动、功能包按需启用。
#   3. NTLite 预精简母盘深度兼容与修复：
#      - 移除无实际用途的 zCOMPONENTS 挂载，避免脏化 CBS 组件库或因缺失 COMPONENTS 中断。
#      - 通过 SeRestorePrivilege 特权写入 Shell Extensions\Blocked，根治“拒绝访问”。
#      - 所有服务 Start 修改均通过 Set-OfflineServiceStart 前置校验存在性，绝不为已被
#        NTLite 移除的服务（如 Defender、遥测、更新、打印等）误创建残缺幽灵服务项。
#      - 所有删除项改为幂等探测删除，消除离线 CurrentControlSet 误调用及刷屏警告。
#      - 内置旧版引号转义缺陷自愈逻辑，若目标目录曾运行旧版产生尾引号脏键可自动清除。
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# ==============================================================================
# 1. 挂载基础注册表配置单元 (DEFAULT / NTUSER / SYSTEM)
# ==============================================================================
$hiveLoads = @(
    @{ Name = "HKLM\zDEFAULT"; Path = "$scratchDir\Windows\System32\config\default" },
    @{ Name = "HKLM\zNTUSER";  Path = "$scratchDir\Users\Default\ntuser.dat" },
    @{ Name = "HKLM\zSYSTEM";  Path = "$scratchDir\Windows\System32\config\SYSTEM" }
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
# 1.2 [方案C-第一轮] 挂载 zSOFTWARE → 自愈检查 + 写入 Appx Deprovisioned → 立即卸载
# ==============================================================================
Write-Host "[方案C-第一轮] 加载 zSOFTWARE 用于写入 Appx Deprovisioned 标记..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 配置单元加载失败，退出码 $LASTEXITCODE，Appx 防重装标记无法写入。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ---- 自愈修复：若目标文件夹曾运行旧版脚本产生末尾带 `"` 的脏键，毫秒级自动清除 ----
$regHelperType = 'Win32Utils.OfflineRegHelper' -as [type]
if ($regHelperType) {
    $hasDirtyQuotes = (
        $regHelperType::KeyExists('zSYSTEM\Setup\LabConfig"') -or
        $regHelperType::KeyExists('zSOFTWARE\Classes\.txt"') -or
        $regHelperType::KeyExists('zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"')
    )
    if ($hasDirtyQuotes) {
        $dirtyParents = @(
            'zSYSTEM\Setup',
            'zDEFAULT\Control Panel',
            'zDEFAULT\Software\Policies\Microsoft\Windows',
            'zNTUSER\Control Panel',
            'zNTUSER\Software\Policies\Microsoft\Windows',
            'zNTUSER\Software\Microsoft\Windows\CurrentVersion',
            'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer',
            'zNTUSER\Software\Microsoft\Speech_OneCore\Settings',
            'zNTUSER\Software\Microsoft\Input',
            'zNTUSER\Software\Microsoft',
            'zNTUSER\Software\Microsoft\InputPersonalization',
            'zNTUSER\Software\Microsoft\Personalization',
            'zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned',
            'zSOFTWARE\Policies\Microsoft\Windows',
            'zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
            'zSOFTWARE\Policies\Microsoft',
            'zSOFTWARE\Policies\Microsoft\Windows Defender',
            'zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
            'zSOFTWARE\Microsoft\PolicyManager\current\device',
            'zSOFTWARE\Microsoft\Windows\CurrentVersion',
            'zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler',
            'zSOFTWARE\Microsoft',
            'zSOFTWARE\Microsoft\Windows Defender',
            'zSOFTWARE\Microsoft\Windows Photo Viewer',
            'zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities',
            'zSOFTWARE\Classes',
            'zSOFTWARE\Classes\Applications',
            'zSOFTWARE\Classes\Applications\OpenWith.exe\shell',
            'zSOFTWARE\Classes\Applications\OpenWith.exe\shell\open',
            'zSOFTWARE\Classes\Applications\notepad.exe',
            'zSOFTWARE\Classes\Applications\notepad.exe\shell\open',
            'zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open',
            'zSOFTWARE\Classes\.txt',
            'zSOFTWARE\Classes\.txt\OpenWithList',
            'zSOFTWARE\Classes\txtfile',
            'zSOFTWARE\Classes\txtfile\shell\open',
            'zSOFTWARE\Classes\txtfilelegacy',
            'zSOFTWARE\Classes\txtfilelegacy\shell\open',
            'zSOFTWARE\WOW6432Node\Classes',
            'zSOFTWARE\WOW6432Node\Classes\Applications',
            'zSOFTWARE\WOW6432Node\Classes\Applications\OpenWith.exe\shell',
            'zSOFTWARE\WOW6432Node\Classes\Applications\OpenWith.exe\shell\open',
            'zSOFTWARE\WOW6432Node\Classes\Applications\notepad.exe',
            'zSOFTWARE\WOW6432Node\Classes\Applications\notepad.exe\shell\open',
            'zSOFTWARE\WOW6432Node\Classes\.txt',
            'zSOFTWARE\WOW6432Node\Classes\.txt\OpenWithList',
            'zSOFTWARE\WOW6432Node\Classes\txtfile',
            'zSOFTWARE\WOW6432Node\Classes\txtfile\shell\open',
            'zSOFTWARE\WOW6432Node\Classes\txtfilelegacy',
            'zSOFTWARE\WOW6432Node\Classes\txtfilelegacy\shell\open'
        )
        foreach ($cs in (Get-OfflineControlSets -SystemHiveMount 'zSYSTEM')) {
            $dirtyParents += "zSYSTEM\$cs\Control"
            $dirtyParents += "zSYSTEM\$cs\Services"
        }
        $cleanedDirtyCount = 0
        foreach ($dp in $dirtyParents) {
            $cleanedDirtyCount += $regHelperType::CleanTrailingQuoteChildren($dp)
        }
        if ($cleanedDirtyCount -gt 0) {
            Write-Host "   [自愈修复] 已自动清理旧版转义异常遗留的尾部引号脏键: $cleanedDirtyCount 项。" -ForegroundColor Cyan
        }
    }
}

Write-Host "Writing Appx Deprovisioned markers to prevent bloatware re-provisioning..." -ForegroundColor Yellow

$deprovisionedBase = "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
if ($global:deprovisionedAppxFamilies -and $global:deprovisionedAppxFamilies.Count -gt 0) {
    $deprovSuccess = 0
    foreach ($familyName in $global:deprovisionedAppxFamilies) {
        $rc = Invoke-RegSilent @('add', "$deprovisionedBase\$familyName", '/f')
        if ($rc -eq 0) {
            $deprovSuccess++
        } else {
            Write-Host "   [警告] 标记失败: $familyName (退出码 $rc)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "   [完成] 共写入 $deprovSuccess / $($global:deprovisionedAppxFamilies.Count) 个 Appx 防重装标记。" -ForegroundColor Green
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
    # Shell Extensions 由 TrustedInstaller 保护，使用 SeRestorePrivilege 特权直写，避免“拒绝访问”
    $null = Set-OfflineRegSzPrivileged -SubKey $br -ValueName $blockedGuid -ValueData 'OpenWith Modern Dialog Bypass'
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

$openWithBin = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
if (Test-Path -LiteralPath $openWithBin -PathType Leaf) {
    $openWithRoots = @('HKLM\zSOFTWARE\Classes\Applications\OpenWith.exe', 'HKLM\zSOFTWARE\WOW6432Node\Classes\Applications\OpenWith.exe')
    foreach ($ow in $openWithRoots) {
        $null = Invoke-RegSilent @('add', $ow, '/v', 'NoOpenWith', '/t', 'REG_SZ', '/d', '', '/f')
        $null = Invoke-RegSilent @('add', "$ow\shell\open", '/v', 'MultiSelectModel', '/t', 'REG_SZ', '/d', 'Single', '/f')
        $null = Invoke-RegSilent @('add', "$ow\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\OpenWith.exe "%1"', '/f')
    }
}

if ($global:removedAppxExeNames -and $global:removedAppxExeNames.Count -gt 0) {
    $commonExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.txt', '.log', '.ini', '.md', '.csv', '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov'
    )
    $classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')

    foreach ($exe in $global:removedAppxExeNames) {
        foreach ($croot in $classesRoots) {
            $null = Remove-OfflineRegKey -SubKey "$croot\Applications\$exe"
            foreach ($ext in $commonExtensions) {
                $null = Remove-OfflineRegKey -SubKey "$croot\$ext\OpenWithList\$exe"
                $null = Remove-OfflineRegValue -SubKey "$croot\$ext\OpenWithProgids" -ValueName $exe
            }
        }
    }
}

# ----------------- 步骤 B: 完整重建 Notepad 与 txtfile 关联链（仅当映像存在经典 notepad.exe） -----------------
$notepadSys32 = Join-Path $scratchDir "Windows\System32\notepad.exe"
$notepadWin   = Join-Path $scratchDir "Windows\notepad.exe"
if ((Test-Path -LiteralPath $notepadSys32 -PathType Leaf) -or (Test-Path -LiteralPath $notepadWin -PathType Leaf)) {
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
} else {
    Write-Host "[跳过] 映像中未检测到经典 notepad.exe（可能已由 NTLite 移除），保留现有文本关联。" -ForegroundColor DarkGray
}

# ----------------- 步骤 C: 注册 Windows 照片查看器（仅当映像确实包含 DLL） -----------------
$photoViewerDll = Join-Path $scratchDir "Program Files\Windows Photo Viewer\PhotoViewer.dll"
if (Test-Path -LiteralPath $photoViewerDll -PathType Leaf) {
    $photoViewerCroot = 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities'
    $photoViewerResource = '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3053'
    $null = Invoke-RegSilent @('add', $photoViewerCroot, '/v', 'ApplicationName', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerResource, '/f')
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

    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll', '/v', 'FriendlyAppName', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerResource, '/f')
    $photoViewerCommand = 'rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen "%1"'
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command', '/ve', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerCommand, '/f')
    Write-Host "[完成] 已注册映像内存在的 Windows 照片查看器；可在‘打开方式’中选择，不强制覆盖默认应用。" -ForegroundColor Green
} else {
    Write-Host "[跳过] 映像中不存在 Windows Photo Viewer DLL；不写入无效关联。" -ForegroundColor DarkGray
}

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

$offlineControlSets = Get-OfflineControlSets -SystemHiveMount 'zSYSTEM'

Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
foreach ($cs in $offlineControlSets) {
    $null = Invoke-RegSilent @('add', "HKLM\zSYSTEM\$cs\Control\EarlyLaunch", '/v', 'DriverLoadPolicy', '/t', 'REG_DWORD', '/d', '8', '/f')
}

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
$null = Remove-OfflineRegKey -SubKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
$null = Remove-OfflineRegKey -SubKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableConsumerAccountStateContent', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableCloudOptimizedContent', '/t', 'REG_DWORD', '/d', '1', '/f')

if ($global:windowsFamily -eq 'Windows 11') {
    Write-Host "Enabling local-account OOBE path (Windows 11):"
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'BypassNRO', '/t', 'REG_DWORD', '/d', '1', '/f')
}

Write-Host "Disabling Reserved Storage:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager', '/v', 'ShippedWithReserves', '/t', 'REG_DWORD', '/d', '0', '/f')
Write-Host "Disabling BitLocker Device Encryption"
foreach ($cs in $offlineControlSets) {
    $null = Invoke-RegSilent @('add', "HKLM\zSYSTEM\$cs\Control\BitLocker", '/v', 'PreventDeviceEncryption', '/t', 'REG_DWORD', '/d', '1', '/f')
}

if ($global:windowsFamily -eq 'Windows 11') {
    Write-Host "Disabling Windows 11 Chat/Widgets taskbar entry points:"
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat', '/v', 'ChatIcon', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced', '/v', 'TaskbarMn', '/t', 'REG_DWORD', '/d', '0', '/f')
}

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
$null = Set-OfflineServiceStart -ServiceName 'dmwappushservice' -StartType 4

if ($global:windowsFamily -eq 'Windows 11') {
    Write-Host "Disabling Windows 11 Dev Home/Outlook provisioning and Copilot:"
    foreach ($appName in @('OutlookUpdate', 'DevHomeUpdate')) {
        $null = Invoke-RegSilent @('add', "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\$appName", '/v', 'workCompleted', '/t', 'REG_DWORD', '/d', '1', '/f')
        $null = Remove-OfflineRegKey -SubKey "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$appName"
    }
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', '/v', 'TurnOffWindowsCopilot', '/t', 'REG_DWORD', '/d', '1', '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Edge', '/v', 'HubsSidebarEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer', '/v', 'DisableSearchBoxSuggestions', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevents installation of Teams:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Teams', '/v', 'DisableInstallation', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevent installation of New Outlook:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail', '/v', 'PreventRun', '/t', 'REG_DWORD', '/d', '1', '/f')

# ----------------- 2.5 Edge 策略拦截与 Defender 禁用 -----------------
Write-Host "Disabling Edge at policy level (Defender: disable-only)..." -ForegroundColor Yellow

$null = Remove-OfflineRegKey -SubKey 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
$null = Remove-OfflineRegKey -SubKey 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
$edgeServices = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
foreach ($svc in $edgeServices) {
    foreach ($cs in $offlineControlSets) {
        $null = Remove-OfflineRegKey -SubKey "HKLM\zSYSTEM\$cs\Services\$svc"
    }
}
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate', '/v', 'DoNotUpdateToEdgeWithChromium', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate', '/v', 'UpdateDefault', '/t', 'REG_DWORD', '/d', '0', '/f')

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiSpyware', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiVirus', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', '/v', 'DisableBehaviorMonitoring', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows Defender\Features', '/v', 'TamperProtection', '/t', 'REG_DWORD', '/d', '0', '/f')
$defenderServices = @("SecurityHealthService", "WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "WdBoot")
foreach ($svc in $defenderServices) {
    $null = Set-OfflineServiceStart -ServiceName $svc -StartType 4
}

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer', '/v', 'SettingsPageVisibility', '/t', 'REG_SZ', '/d', 'hide:virus;windowsupdate', '/f')

# ----------------- 计划任务定义删除（兼容 NTLite 已删除任务） -----------------
Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$scratchDir\Windows\System32\Tasks"
$targetTaskPaths = @(
    "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
    "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
    "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)
foreach ($tp in $targetTaskPaths) {
    if (Test-Path -LiteralPath $tp) {
        Remove-Item -LiteralPath $tp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Task files have been deleted."

# ----------------- Windows Update 策略差异化处理 -----------------
if ($global:trimMode -eq "2") {
    # --------------------------------------------------------------------------
    # 极限模式：保留原有极限彻底断网阻断策略 (仅当服务存在时修改服务项)
    # --------------------------------------------------------------------------
    Write-Host ">>> [极限压榨模式] 彻底物理截断 Windows Update (服务设为4 + 伪造本地服务器)..." -ForegroundColor Yellow
    if (Test-OfflineRegKey -SubKey 'zSYSTEM\ControlSet001\Services\wuauserv') {
        $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE1', '/t', 'REG_SZ', '/d', 'net stop wuauserv', '/f')
        $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE2', '/t', 'REG_SZ', '/d', 'sc stop wuauserv', '/f')
        $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE3', '/t', 'REG_SZ', '/d', 'sc config wuauserv start= disabled', '/f')
        $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE1', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
        $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE2', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
    }
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DoNotConnectToWindowsUpdateInternetLocations', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DisableWindowsUpdateAccess', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUStatusServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'UpdateServiceUrlAlternate', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'UseWUServer', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'DisableOnline', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '1', '/f')

    $null = Set-OfflineServiceStart -ServiceName 'wuauserv' -StartType 4
    $null = Set-OfflineServiceStart -ServiceName 'UsoSvc' -StartType 4
    $null = Set-OfflineServiceStart -ServiceName 'WaaSMedicSVC' -StartType 4
} else {
    # --------------------------------------------------------------------------
    # 普通健康模式：静默防打扰 + 按需触发 (Start=3 手动)
    # --------------------------------------------------------------------------
    Write-Host "   [普通健康模式] 配置 Windows Update 为防打扰按需模式（保留应用商店与外设自动拉取驱动链路）..." -ForegroundColor Green

    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '0', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'AUOptions', '/t', 'REG_DWORD', '/d', '2', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoRebootWithLoggedOnUsers', '/t', 'REG_DWORD', '/d', '1', '/f')

    $null = Set-OfflineServiceStart -ServiceName 'wuauserv' -StartType 3
    $null = Set-OfflineServiceStart -ServiceName 'UsoSvc' -StartType 3
    $null = Set-OfflineServiceStart -ServiceName 'WaaSMedicSVC' -StartType 3
}

# ==============================================================================
# 3. 卸载并释放离线配置单元
# ==============================================================================
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zSOFTWARE", "HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zSYSTEM")) {
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

$serviceControlSets = Get-OfflineControlSets -SystemHiveMount 'zSYSTEM'

# ----------------- 核心关键保障：确保存在的 Spooler 服务配置健康 -----------------
$spoolerUpdated = Set-OfflineServiceStart -ServiceName 'Spooler' -StartType 2
$null = Set-OfflineServiceStart -ServiceName 'PrintNotify' -StartType 3
if ($spoolerUpdated) {
    Write-Host ">>> [打印保障] 已锁定 Print Spooler 服务为自动启动 (Start=2)。" -ForegroundColor Green
} else {
    Write-Host ">>> [提示] 目标映像中未检测到 Print Spooler 服务（可能已由 NTLite 移除），跳过启动项设置。" -ForegroundColor DarkYellow
}

# ----------------- 服务移除/精简差异化处理 -----------------
if ($global:trimMode -eq "2") {
    $servicesToRemove = @(
        'Fax', 'RemoteRegistry', 'diagsvc',
        'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc',
        'BluetoothUserService', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService'
    )
    $removedSvcCount = 0
    foreach ($service in $servicesToRemove) {
        $svcDeleted = $false
        foreach ($cs in $serviceControlSets) {
            if (Remove-OfflineRegKey -SubKey "HKLM\zSYSTEM\$cs\Services\$service") {
                $svcDeleted = $true
            }
        }
        if ($svcDeleted) {
            $removedSvcCount++
            Write-Host "   [极限瘦身] 已移除多余服务实体: $service" -ForegroundColor DarkGray
        }
    }
    Write-Host "   [极限瘦身] 服务精炼完成（本次清理 $removedSvcCount 个，其余已由前置精简移除）。" -ForegroundColor DarkGray
} else {
    Write-Host "   [普通健康模式] 保留蓝牙核心服务 (BthAvctpSvc, BluetoothUserService) 与打印核心服务。" -ForegroundColor Green

    $null = Set-OfflineServiceStart -ServiceName 'BthAvctpSvc' -StartType 3

    $safeToRemoveServices = @('RemoteRegistry', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
    $removedSvcCount = 0
    foreach ($service in $safeToRemoveServices) {
        $svcDeleted = $false
        foreach ($cs in $serviceControlSets) {
            if (Remove-OfflineRegKey -SubKey "HKLM\zSYSTEM\$cs\Services\$service") {
                $svcDeleted = $true
            }
        }
        if ($svcDeleted) {
            $removedSvcCount++
            Write-Host "   [健康清理] 已移除无用服务: $service" -ForegroundColor DarkGray
        }
    }
    if ($removedSvcCount -eq 0) {
        Write-Host "   [健康清理] 目标无用服务此前已由 NTLite 等前置工具清理完毕。" -ForegroundColor DarkGray
    }
}

Safely-UnloadHive -HiveName "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 离线注册表配置与服务配置精炼全部就绪。" -ForegroundColor Green
