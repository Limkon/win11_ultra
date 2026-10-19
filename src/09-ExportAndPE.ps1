# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE 修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在安全提交主映像并修补 WinPE 引导分卷..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"
$bootWimPath   = Join-Path $sourcesDir "boot.wim"
$tempBootWim   = Join-Path $sourcesDir "boot_temp.wim"

# ----------------- 1. 提交并卸载主映像 (install.wim) -----------------
Write-Host "正在提交并卸载主系统映像 install.wim (请耐心等待写入磁盘)..." -ForegroundColor Yellow

# 强制垃圾回收以释放可能附着的目录句柄
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] install.wim 提交卸载失败，退出码: $LASTEXITCODE！正在尝试强制放弃挂载以保护环境..." -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    Stop-Transcript
    pause
    exit 1
}
Write-Host "[完成] 主映像修改已持久化写入。" -ForegroundColor Green

# ----------------- 2. 二次重构 install.wim 消除存储碎片 -----------------
Write-Host "正在二次导出并重构压缩 install.wim (消除内部精简碎片)..." -ForegroundColor Cyan
& dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /Compress:max /CheckIntegrity

if (Test-Path -LiteralPath $destWim2Path) {
    attrib.exe -R -S -H "$destWimPath" 2>$null
    Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $destWim2Path -NewName "install.wim" -Force
    Write-Host "[完成] install.wim 导出重构完毕，体积已达最佳压缩状态。" -ForegroundColor Green
} else {
    Write-Host "[提示] 二次压缩镜像未能生成，安全保留原镜像继续推进。" -ForegroundColor Yellow
}

# ----------------- 3. 稳固修补 boot.wim (保持双卷 BCD 映射架构) -----------------
Write-Host "`n正在修补 WinPE 引导与安装向导映像 (boot.wim)..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    Write-Host "[严重错误] 未在 sources 目录中检测到 boot.wim，无法构建可引导介质！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 接管 boot.wim 物理所有权与写入属性
attrib.exe -R -S -H "$bootWimPath" 2>$null
& takeown.exe /F "$bootWimPath" /A 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
try {
    (Get-Item -LiteralPath $bootWimPath).IsReadOnly = $false
} catch {}

# 解析 boot.wim 的分卷结构，确定需要注入硬件绕过的 Setup 卷
$bootWimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$totalBootIndexes = 1
$setupIndex = 1

$indexMatches = [regex]::Matches($bootWimInfo, 'Index\s*:\s*(\d+)')
if ($indexMatches.Count -gt 0) {
    $totalBootIndexes = $indexMatches.Count
    # 标准双卷 Windows 介质中，Index 2 为 Setup 安装向导；若为单卷介质则为 Index 1
    $setupIndex = if ($totalBootIndexes -ge 2) { 2 } else { 1 }
}

Write-Host "检测到 boot.wim 共包含 $totalBootIndexes 个分卷，将对核心引导卷 [Index $setupIndex] 实施策略注入..." -ForegroundColor Green

# 挂载指定的 Setup 引导分卷
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$setupIndex" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] boot.wim 分卷 $setupIndex 挂载失败！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 加载 boot.wim 内部离线注册表配置单元
Write-Host "正在加载 WinPE 离线注册表以注入硬件检测跳过策略..." -ForegroundColor Cyan
& reg.exe load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
& reg.exe load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

# 注入底层全套硬件要求绕过注册表策略 (WinPE Setup 阶段)
Write-Host "正在写入硬件检测豁免与策略绕过规则 (CPU/TPM/RAM/SecureBoot/Disk)..." -ForegroundColor Yellow
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null

& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassDiskCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 禁用 WinPE 阶段的 BitLocker 设备自动加密
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 安全卸载注册表并释放句柄
Write-Host "正在安全卸载 WinPE 注册表配置单元..." -ForegroundColor DarkGray
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$hivesToUnload = @("zNTUSER", "zDEFAULT", "zSOFTWARE", "zSYSTEM")
foreach ($hive in $hivesToUnload) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $null = & reg.exe unload "HKLM\$hive" 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 800
    }
}

# 提交并卸载 WinPE 映像修改
Write-Host "正在提交 boot.wim 修改..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] boot.wim 提交失败！" -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    Stop-Transcript
    pause
    exit 1
}

# 二次结构化重构 boot.wim (严格按原生分卷拓扑原样导出，确保 BCD 索引与 GUID 绝对吻合)
Write-Host "正在以原架构重构 boot.wim 保持 BCD 映射一致性..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $tempBootWim) { Remove-Item -LiteralPath $tempBootWim -Force -ErrorAction SilentlyContinue }

for ($i = 1; $i -le $totalBootIndexes; $i++) {
    Write-Host "   正在重构导出 boot.wim 分卷 [$i/$totalBootIndexes]..." -ForegroundColor DarkGray
    $bootFlag = if ($i -eq $setupIndex) { "/Bootable" } else { "" }
    if ($bootFlag) {
        & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:$i" "/DestinationImageFile:$tempBootWim" /Compress:max /Bootable /CheckIntegrity
    } else {
        & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:$i" "/DestinationImageFile:$tempBootWim" /Compress:max /CheckIntegrity
    }
}

if (Test-Path -LiteralPath $tempBootWim) {
    attrib.exe -R -S -H "$bootWimPath" 2>$null
    Remove-Item -LiteralPath $bootWimPath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $tempBootWim -NewName "boot.wim" -Force
    Write-Host "[完成] boot.wim 双卷结构完整保留并优化完毕。" -ForegroundColor Green
} else {
    Write-Host "[提示] boot.wim 原卷修改已就绪 (跳过二次重构)。" -ForegroundColor DarkGray
}

# ----------------- 4. ISO 根目录结构规范化清理 -----------------
Write-Host "`n正在对 ISO 发行根目录执行合规性清洗..." -ForegroundColor Cyan
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

Write-Host "[完成] WinPE 引导重构与母盘清理全部就绪。" -ForegroundColor Green
