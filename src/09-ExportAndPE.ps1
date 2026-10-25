# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE/BCD 深度修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在安全提交主映像并优化 WinPE/Legacy 引导资产..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"
$bootWimPath   = Join-Path $sourcesDir "boot.wim"
$legacyBcdPath = Join-Path $workDir "boot\bcd"

# ----------------- 1. 提交并卸载主系统映像 (install.wim) -----------------
Write-Host "正在提交并卸载主系统映像 install.wim (请耐心等待写入磁盘)..." -ForegroundColor Yellow

# 强制垃圾回收以释放可能附着的目录句柄
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] install.wim 提交卸载失败，退出码: $LASTEXITCODE！正在尝试强制放弃挂载以保护母盘..." -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    Stop-Transcript
    pause
    exit 1
}
Write-Host "[完成] 主系统映像修改已安全提交。" -ForegroundColor Green

# 清理挂载点残留，避免后续 boot.wim 挂载失败
if (Test-Path -LiteralPath $scratchDir) {
    Force-NukeFolderOrFile -Target $scratchDir
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

# ----------------- 2. 二次重构 install.wim 消除存储碎片 -----------------
Write-Host "正在二次导出并重构压缩 install.wim (消除内部精简碎片)..." -ForegroundColor Cyan
& dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /Compress:max /CheckIntegrity

if (Test-Path -LiteralPath $destWim2Path) {
    attrib.exe -R -S -H "$destWimPath" 2>&1 | Out-Null
    Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $destWim2Path -NewName "install.wim" -Force
    Write-Host "[完成] install.wim 导出重构完毕，体积已达最佳压缩状态。" -ForegroundColor Green
} else {
    Write-Host "[提示] 二次压缩镜像未能生成，安全保留原镜像继续推进。" -ForegroundColor Yellow
}

# ----------------- 3. 稳固修补 boot.wim (双卷全覆盖·原地提交保全元数据) -----------------
Write-Host "`n正在以【原地修改提交】模式深度修补 boot.wim (彻底解决 Legacy 卡 Logo 问题)..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    Write-Host "[严重错误] 未在 sources 目录中检测到 boot.wim，无法构建可引导介质！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 接管 boot.wim 物理所有权与文件属性
attrib.exe -R -S -H "$bootWimPath" 2>&1 | Out-Null
& takeown.exe /F "$bootWimPath" /A 2>&1 | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
try {
    (Get-Item -LiteralPath $bootWimPath).IsReadOnly = $false
} catch {}

# 解析 boot.wim 内部包含的分卷数量 (行首锚定，避免误计 "Image Index" 等上下文)
$bootWimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$totalBootIndexes = 1
$indexMatches = [regex]::Matches($bootWimInfo, '(?m)^\s*Index\s*:\s*(\d+)\s*$')
if ($indexMatches.Count -gt 0) {
    $totalBootIndexes = $indexMatches.Count
}
Write-Host "检测到 boot.wim 包含 $totalBootIndexes 个分卷，启动全卷深度渗透修补..." -ForegroundColor Green

# 循环修补 boot.wim 的每个分卷（Index 1 和 Index 2 统一注入，杜绝引导盲区）
for ($idx = 1; $idx -le $totalBootIndexes; $idx++) {
    Write-Host "`n>>> 正在原地挂载修补 boot.wim 分卷 [$idx/$totalBootIndexes]..." -ForegroundColor Yellow

    # 挂载当前分卷
    & dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$idx" "/MountDir:$scratchDir"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[错误] 挂载 boot.wim 分卷 $idx 失败，跳过该卷修补。" -ForegroundColor Red
        continue
    }

    # 跟踪本卷已成功加载的 hive，便于 continue 前精确卸载
    $loadedHives = New-Object System.Collections.Generic.List[string]

    $hiveCandidates = @(
        @{ Name = "HKLM\zDEFAULT";  Path = "$scratchDir\Windows\System32\config\default" },
        @{ Name = "HKLM\zNTUSER";   Path = "$scratchDir\Users\Default\ntuser.dat" },
        @{ Name = "HKLM\zSYSTEM";   Path = "$scratchDir\Windows\System32\config\SYSTEM" },
        @{ Name = "HKLM\zSOFTWARE"; Path = "$scratchDir\Windows\System32\config\SOFTWARE" }
    )

    foreach ($hc in $hiveCandidates) {
        if (-not (Test-Path -LiteralPath $hc.Path)) {
            Write-Host "   [跳过] 分卷 $idx 中不存在 hive 文件: $($hc.Path)" -ForegroundColor DarkYellow
            continue
        }
        & reg.exe load $hc.Name $hc.Path 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $loadedHives.Add($hc.Name) | Out-Null
        } else {
            Write-Host "   [警告] hive 加载失败: $($hc.Name) <- $($hc.Path)，退出码 $LASTEXITCODE" -ForegroundColor DarkYellow
        }
    }

    # 1. 注入全套硬件检测豁免规则 (WinPE Setup 阶段)
    if ($loadedHives -contains "HKLM\zDEFAULT") {
        & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
    }
    if ($loadedHives -contains "HKLM\zNTUSER") {
        & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
    }
    if ($loadedHives -contains "HKLM\zSYSTEM") {
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassDiskCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

        # 2. 禁用 WinPE 阶段的 BitLocker 设备自动加密
        & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

        # 3. 【关键：解决 Legacy 卡死】注入内核级早期驱动启动与基本显示豁免策略
        & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch' '/v' 'DriverLoadPolicy' '/t' 'REG_DWORD' '/d' '8' '/f' 2>&1 | Out-Null
        & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\BasicDisplay' '/v' 'Start' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
    }

    # 卸载本卷已加载的注册表配置单元 (带重试，先非 SYSTEM 后 SYSTEM)
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    foreach ($h in @("HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zSOFTWARE", "HKLM\zSYSTEM")) {
        if ($loadedHives -contains $h) {
            Safely-UnloadHive -HiveName $h | Out-Null
        }
    }

    # 原地安全提交修改 (保持微软原始 WIM 头与 Flags 元数据 100% 纯净无损)
    Write-Host "   正在原地提交 boot.wim 分卷 $idx 修改..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   [警告] boot.wim 分卷 $idx 提交异常，执行强制释放..." -ForegroundColor Yellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    }
}
Write-Host "[完成] boot.wim 所有分卷修补完成，原生架构与元数据完全保留。" -ForegroundColor Green

# ----------------- 4. 修复 Legacy BCD 显卡防死锁参数 -----------------
# 注：原脚本含 `bcdedit /set {default} winpe Yes`，该参数语义为“此启动项是 WinPE”，
#     会改变 Legacy BCD 默认项类型，反而可能导致 setup 无法正常进入，故移除。
#     仅保留 detecthal（强制 HAL 检测）与 displaybootmenu（关闭引导菜单）两项防死锁参数。
if (Test-Path -LiteralPath $legacyBcdPath) {
    Write-Host "`n正在对 Legacy BIOS BCD 启动菜单注入兼容性保护..." -ForegroundColor Cyan
    attrib.exe -R -S -H "$legacyBcdPath" 2>&1 | Out-Null

    & bcdedit.exe /store "$legacyBcdPath" /set '{default}' detecthal Yes 2>&1 | Out-Null
    & bcdedit.exe /store "$legacyBcdPath" /set '{bootmgr}' displaybootmenu No 2>&1 | Out-Null
    Write-Host "[完成] Legacy BCD 启动项防死锁参数注入完毕。" -ForegroundColor Green
}

# ----------------- 5. ISO 根目录结构规范化清理 -----------------
Write-Host "`n正在对 ISO 根目录执行合规性清洗..." -ForegroundColor Cyan
$keepList = @(
    "boot",
    "efi",
    "sources",
    "support",
    "bootmgr",
    "bootmgr.efi",
    "setup.exe",
    "autorun.inf",
    "autounattend.xml"
)

Get-ChildItem -Path $workDir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Write-Host "   清除根目录多余文件/目录: $($_.Name)" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[完成] WinPE 引导与 BCD 修补全部圆满就绪。" -ForegroundColor Green
