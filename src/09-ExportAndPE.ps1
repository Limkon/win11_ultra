# ==============================================================================
#  win11 Builder - [模块 10/11] 映像格式分支处理与 WinPE 深度免检重构 (src/09-ExportAndPE.ps1)
#  [企业级重构]：多重非空变量安全对齐 + boot.wim 双卷去碎片高压 + 根治 LiteralPath 空值崩溃
# ==============================================================================

# ----------------- 0. 多重非空变量安全对齐与跨作用域兜底 -----------------
# 1. 确保 sources 目录路径有效
if (-not $sourcesDir -or [string]::IsNullOrWhiteSpace($sourcesDir)) {
    if ($workDir -and (Test-Path -LiteralPath $workDir)) {
        $sourcesDir = Join-Path $workDir "sources"
    } elseif ($targetDisk -and (Test-Path -LiteralPath $targetDisk)) {
        $sourcesDir = Join-Path $targetDisk "win11\sources"
    } else {
        $sourcesDir = "D:\win11\sources"
    }
}

# 2. 深度绑定目标安装映像路径，杜绝 $destWim 为空
if (-not $destWim -or [string]::IsNullOrWhiteSpace($destWim)) {
    if ($wimFilePath -and [string]::IsNullOrWhiteSpace($wimFilePath) -eq $false -and (Test-Path -LiteralPath $wimFilePath)) {
        $destWim = $wimFilePath
    } else {
        $destWim = Join-Path $sourcesDir "install.wim"
    }
}

# ----------------- 1. 映像格式条件分支处理 (受控于全局开关 $enableEsdConversion) -----------------
Write-Host "`n[步骤 11/11] 正在处理安装映像输出格式..." -ForegroundColor Cyan

$esdFile = Join-Path $sourcesDir "install.esd"

if ($enableEsdConversion) {
    Write-Host ">>> [开关生效: 开启] 正在导出为高压缩率 install.esd..." -ForegroundColor Yellow
    Write-Host "提示: 压缩 ESD 需高度消耗 CPU 与磁盘算力，下方将实时输出官方百分比进度条：" -ForegroundColor DarkGray

    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

    if (-not [string]::IsNullOrWhiteSpace($esdFile) -and (Test-Path -LiteralPath $esdFile) -and ((Get-Item -LiteralPath $esdFile).Length -gt 500MB)) {
        Write-Host "[成功] install.esd 构建完成，已移除临时 install.wim。" -ForegroundColor Green
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[警告] ESD 转换异常或文件不完整，保留 install.wim 继续推进后续流程。" -ForegroundColor Yellow
    }
} else {
    Write-Host ">>> [开关生效: 默认关闭] 跳过 ESD 高耗时压缩，直接使用 install.wim 进行极速打包！" -ForegroundColor Green
    
    # 前置非空校验，彻底解决参数绑定到 LiteralPath 为空的报错
    if (-not [string]::IsNullOrWhiteSpace($destWim) -and (Test-Path -LiteralPath $destWim)) {
        $wimSizeGB = [math]::Round(((Get-Item -LiteralPath $destWim).Length / 1GB), 2)
        Write-Host "[就绪] 核心安装映像锁定: $destWim (当前体积: $wimSizeGB GB)" -ForegroundColor DarkGray
    } else {
        Write-Host "[提示] 核心安装映像路径待物理校验: $destWim" -ForegroundColor DarkYellow
    }
}

# ----------------- 2. 修补 WinPE (boot.wim) 免硬件检测策略与碎片重构 -----------------
Write-Host "`n正在为 WinPE (boot.wim) 写入免硬件检测策略并执行深度瘦身..." -ForegroundColor Cyan
$bootWimPath     = Join-Path $sourcesDir "boot.wim"
$tempBootWimPath = Join-Path $sourcesDir "boot_optimized.wim"

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    Write-Host "[严重错误] 未在 $sourcesDir 下找到 boot.wim 引导映像！" -ForegroundColor Red
    pause
    exit
}

attrib.exe -R -S -H "$bootWimPath" 2>$null
& takeown.exe /F "$bootWimPath" /A 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
(Get-Item -LiteralPath $bootWimPath).IsReadOnly = $false

# 自适应分卷探查 (探测总卷数与安装引导卷索引)
$bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$hasIndex2 = ($bootInfo -match "Index\s*:\s*2")
$targetBootIndex = if ($hasIndex2) { "2" } else { "1" }

# 清理挂载目录防碰撞
if (Test-Path -LiteralPath $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载 boot.wim 核心引导卷 (分卷 $targetBootIndex)..." -ForegroundColor DarkGray
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$targetBootIndex" "/MountDir:$scratchDir"

if (-not (Test-Path -LiteralPath "$scratchDir\Windows\System32")) {
    Write-Host "[错误] boot.wim 挂载异常，跳过策略写入以防损坏镜像。" -ForegroundColor Red
} else {
    # 挂载 WinPE 的 SYSTEM 注册表单元
    $bootSystemPath = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
    attrib.exe -R -S -H "$bootSystemPath" 2>$null
    & reg.exe load HKLM\zSYSTEM "$bootSystemPath" 2>$null | Out-Null

    # 注入全量 LabConfig 绕过策略 (全规格兼容 Win11 22H2/23H2/24H2)
    $labConfigKeys = @(
        "BypassCPUCheck",
        "BypassRAMCheck",
        "BypassSecureBootCheck",
        "BypassStorageCheck",
        "BypassTPMCheck",
        "BypassDiskCheck"
    )
    foreach ($k in $labConfigKeys) {
        & reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $k /t REG_DWORD /d 1 /f 2>$null | Out-Null
    }
    & reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f 2>$null | Out-Null

    # 安全卸载注册表
    Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

    # 提交修改
    Write-Host "正在提交并保存 boot.wim 引导修改..." -ForegroundColor DarkGray
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
}

# ----------------- 3. boot.wim 碎片物理清剿与原子重构 (企业级关键工程升华) -----------------
Write-Host "正在对 boot.wim 执行二次去碎片极限压缩导出 (重建 BCD 完美兼容双卷)..." -ForegroundColor DarkYellow
if (Test-Path -LiteralPath $tempBootWimPath) {
    Remove-Item -LiteralPath $tempBootWimPath -Force -ErrorAction SilentlyContinue
}

if ($hasIndex2) {
    # 导出卷 1 (标准 WinPE 恢复环境，保持 BCD 序号不变)
    Write-Host "   -> 正在导出并压缩 boot.wim [分卷 1/2: WinPE]..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:1" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
    # 导出卷 2 (已打补丁的 Windows Setup 引导环境)
    Write-Host "   -> 正在导出并压缩 boot.wim [分卷 2/2: Setup]..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:2" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
} else {
    # 单卷环境直接紧凑导出
    Write-Host "   -> 正在单卷导出压缩 boot.wim..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:1" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
}

# 替换旧版高碎片 boot.wim
if (Test-Path -LiteralPath $tempBootWimPath) {
    Remove-Item -LiteralPath $bootWimPath -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tempBootWimPath -Destination $bootWimPath -Force
    Write-Host "[成功] boot.wim 物理去碎片与二次高压完毕 (体积大幅瘦身，脏标记完全清除)。" -ForegroundColor Green
} else {
    Write-Host "[提示] boot.wim 导出重构跳过，保留提交版本。" -ForegroundColor DarkGray
}

Write-Host "[完成] WinPE 引导环境免硬件检测注入与镜像重构完毕。" -ForegroundColor Green
