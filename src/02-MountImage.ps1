# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像定位、导出与挂载 (src/02-MountImage.ps1)
# ==============================================================================

# 1. 输入与校验 ISO 光驱盘符
$rawDrive = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
if ([string]::IsNullOrWhiteSpace($rawDrive)) {
    Write-Host "[严重错误] 未输入有效盘符！流程终止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

$normalized = $rawDrive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
if ($normalized -notmatch '^[A-Z]$') {
    Write-Host "[严重错误] 盘符格式非法，请输入单个字母（如 E）！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}
$DriveLetter = "$normalized`:"

$bootWimSrc    = "$DriveLetter\sources\boot.wim"
$installWimSrc = "$DriveLetter\sources\install.wim"
$installEsdSrc = "$DriveLetter\sources\install.esd"

if (-not (Test-Path -LiteralPath $bootWimSrc) -or (-not (Test-Path -LiteralPath $installWimSrc) -and -not (Test-Path -LiteralPath $installEsdSrc))) {
    Write-Host "[严重错误] 在虚拟光驱 $DriveLetter 中未检测到有效的 Windows 安装介质结构！" -ForegroundColor Red
    Write-Host "缺少关键文件: boot.wim 或 install.wim/install.esd，请确认 ISO 已正确挂载。" -ForegroundColor Yellow
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 2. 复制 ISO 引导架构文件 (步骤 1/11)
Write-Host "`n[步骤 1/11] 正在复制 ISO 核心引导架构到工作区..." -ForegroundColor Cyan
$sourceRoot = "$DriveLetter"

$null = & robocopy.exe "$sourceRoot" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NC /NS /NP
if ($LASTEXITCODE -ge 8) {
    $rcMsg = switch ($LASTEXITCODE) {
        8  { "部分文件复制失败（可能被占用）" }
        16 { "严重错误，未复制任何文件" }
        default { "未知严重错误" }
    }
    Write-Host "[严重错误] 基础引导结构复制失败！Robocopy 退出码: $LASTEXITCODE ($rcMsg)" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

$criticalBootFiles = @(
    (Join-Path $workDir "bootmgr"),
    (Join-Path $workDir "boot\bcd"),
    (Join-Path $workDir "boot\boot.sdi")
)

$missingBootFile = $false
foreach ($bf in $criticalBootFiles) {
    if (-not (Test-Path -LiteralPath $bf)) {
        Write-Host "[严重警告] 关键引导文件丢失: $bf" -ForegroundColor Red
        $missingBootFile = $true
    }
}

if ($missingBootFile) {
    Write-Host "[严重错误] 核心引导结构未能完整复制到工作区，无法支持后续引导生成！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}
Write-Host "[完成] ISO 核心引导架构复制完毕，引导链结构完整有效。" -ForegroundColor Green

# 3. 定位源映像文件并导出目标分卷 (步骤 2/11)
$destWim = Join-Path $sourcesDir "install.wim"

if (Test-Path -LiteralPath $installWimSrc) {
    Write-Host "`n[步骤 2/11] 检测到 install.wim，正在解析映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$installWimSrc"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    if ([string]::IsNullOrWhiteSpace($index)) { $index = "1" }

    Write-Host "正在导出目标分卷 $index (展示原生导出进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$installWimSrc" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
} else {
    Write-Host "`n[步骤 2/11] 检测到 install.esd，正在解析映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$installEsdSrc"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    if ([string]::IsNullOrWhiteSpace($index)) { $index = "1" }

    Write-Host "正在将目标分卷 $index 从 ESD 高压格式转换为 install.wim (展示原生进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$installEsdSrc" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
}

if (-not (Test-Path -LiteralPath $destWim)) {
    Write-Host "[严重错误] install.wim 导出生成失败！流程终止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 导出后独立单一镜像的 Index 固定为 1
$index = "1"

# 4. 解锁映像访问权限并挂载 (步骤 3/11)
Write-Host "`n[步骤 3/11] 正在接管 install.wim 物理访问权限并执行挂载..." -ForegroundColor Cyan
attrib.exe -R -S -H "$destWim" 2>&1 | Out-Null
& takeown.exe /F "$destWim" /A 2>&1 | Out-Null
& icacls.exe "$destWim" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
(Get-Item -LiteralPath $destWim).IsReadOnly = $false

# 挂载点初始化与清理 (增强版：强制解除上次遗留的 DISM 挂载锁)
if (Test-Path -LiteralPath $scratchDir) {
    Write-Host "清理历史挂载残留..." -ForegroundColor DarkGray
    
    # 1. 尝试忽略挂载
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    
    # 2. 强制清理所有 DISM 挂载记录 (解决 0xc1420127 错误)
    Write-Host "正在清理 DISM 挂载锁..." -ForegroundColor DarkYellow
    & dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
    & dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
    
    # 3. 如果 DISM 服务被卡死，尝试重启该服务
    $dismService = Get-Service -Name "Dism" -ErrorAction SilentlyContinue
    if ($dismService -and $dismService.Status -eq 'Stopped') {
        Start-Service -Name "Dism" -ErrorAction SilentlyContinue
    }
    
    Start-Sleep -Seconds 2
    Force-NukeFolderOrFile -Target $scratchDir
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载目标映像到 $scratchDir (展示官方挂载进度条)..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] DISM 映像挂载失败，退出码: $LASTEXITCODE！" -ForegroundColor Red
    Write-Host "建议手动重启计算机以释放残留的 WIM 文件句柄后重试。" -ForegroundColor Yellow
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 挂载状态严密自检
$sys32Path = Join-Path $scratchDir "Windows\System32"
if (-not (Test-Path -LiteralPath $sys32Path)) {
    Write-Host "[严重错误] 挂载目录健康自检失败！未检测到 $sys32Path，映像已损坏或挂载不完整。" -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "[完成] 系统主映像挂载成功，运行环境就绪。" -ForegroundColor Green
