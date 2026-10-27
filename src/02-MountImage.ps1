# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像定位、导出与挂载 (src/02-MountImage.ps1)
# ==============================================================================

# 1. 变量初始化
$destWim = Join-Path $sourcesDir "install.wim"
$isMountedISO = $false
$fileExt = ""
$sourceRoot = ""
$imageSourceToUse = ""
$bootWimSrc = ""
$installWimSrc = ""
$installEsdSrc = ""

# 2. 详细源文件定位与盘符校验 (双模式)
if ($global:sourceMode -eq "2") {
    $sourceFile = $global:sourceFile
    $fileExt = [System.IO.Path]::GetExtension($sourceFile).ToLower()
    
    if ($fileExt -eq '.iso') {
        Write-Host "`n[步骤 1/11] 正在挂载 ISO 虚拟镜像..." -ForegroundColor Cyan
        $isoMount = Mount-DiskImage -ImagePath $sourceFile -PassThru -ErrorAction SilentlyContinue
        if (-not $isoMount) {
            Write-Host "[严重错误] 无法挂载 ISO 文件！可能文件损坏或被占用。" -ForegroundColor Red
            if ($global:transcriptActive) { Stop-Transcript }
            pause
            exit 1
        }
        
        Write-Host "   等待系统分配光驱盘符..." -ForegroundColor DarkGray
        $driveLetter = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $driveLetter = ($isoMount | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
            if ($driveLetter) { break }
        }
        if (-not $driveLetter) {
            Write-Host "[严重错误] ISO 挂载后未能获取到有效的盘符，请检查虚拟光驱驱动是否正常。" -ForegroundColor Red
            Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null
            if ($global:transcriptActive) { Stop-Transcript }
            pause
            exit 1
        }
        $sourceRoot = "$($driveLetter):"
        $isMountedISO = $true
        Write-Host "   ISO 成功挂载到: $sourceRoot" -ForegroundColor Green
    } else {
        Write-Host "`n[步骤 1/11] 单文件处理模式: 准备直接精简..." -ForegroundColor Cyan
        $imageSourceToUse = $sourceFile
        $sourceRoot = Split-Path -Parent $sourceFile
    }
} else {
    $sourceRoot = $global:driveLetter
    $fileExt = ".iso"
    Write-Host "`n[步骤 1/11] 正在读取虚拟光驱盘符 $sourceRoot..." -ForegroundColor Cyan
}

# 3. 统一构建 ISO 源路径变量与深度校验
if ($fileExt -eq ".iso") {
    $bootWimSrc    = "$sourceRoot\sources\boot.wim"
    $installWimSrc = "$sourceRoot\sources\install.wim"
    $installEsdSrc = "$sourceRoot\sources\install.esd"
    $imageSourceToUse = if (Test-Path -LiteralPath $installWimSrc) { $installWimSrc } else { $installEsdSrc }

    # 校验基础引导文件是否存在
    if (-not (Test-Path -LiteralPath $bootWimSrc)) {
        Write-Host "[严重错误] 在源 $sourceRoot 中未检测到 boot.wim！" -ForegroundColor Red
        if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    # 校验主镜像文件是否存在
    if (-not (Test-Path -LiteralPath $installWimSrc) -and -not (Test-Path -LiteralPath $installEsdSrc)) {
        Write-Host "[严重错误] 在源 $sourceRoot 中未检测到 install.wim 或 install.esd！" -ForegroundColor Red
        if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
}

# 4. 复制 ISO 引导架构文件 (步骤 1/11)
Write-Host "`n[步骤 1/11] 正在复制 ISO 核心引导架构到工作区..." -ForegroundColor Cyan
$sourceRoot = $sourceRoot.TrimEnd('\')

# Robocopy 返回码 0-7 均代表正常/成功，8 及以上代表严重异常
$null = & robocopy.exe "$sourceRoot" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NC /NS /NP
if ($LASTEXITCODE -ge 8) {
    $rcMsg = switch ($LASTEXITCODE) {
        8  { "部分文件复制失败（可能被占用）" }
        16 { "严重错误，未复制任何文件" }
        default { "未知严重错误" }
    }
    Write-Host "[严重错误] 基础引导结构复制失败！Robocopy 退出码: $LASTEXITCODE ($rcMsg)" -ForegroundColor Red
    if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 校验关键引导链文件完整性
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

if ($missingBootFile -and $fileExt -eq ".iso") {
    Write-Host "[严重错误] 核心引导结构未能完整复制到工作区，无法支持后续引导生成！" -ForegroundColor Red
    if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}
Write-Host "[完成] 引导架构准备完毕。" -ForegroundColor Green

# 5. 定位源映像文件并导出目标分卷 (步骤 2/11)
if ($fileExt -eq ".iso") {
    $imageSourceToUse = if (Test-Path -LiteralPath $installWimSrc) { $installWimSrc } else { $installEsdSrc }
}

Write-Host "`n[步骤 2/11] 正在解析源映像分卷列表..." -ForegroundColor Cyan
& dism.exe /English /Get-WimInfo "/WimFile:$imageSourceToUse"
$index = Read-Host "请输入要精简的目标版本 Index 序号 (留空默认1)"
if ([string]::IsNullOrWhiteSpace($index)) { $index = "1" }

Write-Host "正在导出目标分卷 $index 到工作区..." -ForegroundColor Green
& dism.exe /English /Export-Image "/SourceImageFile:$imageSourceToUse" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity

if (-not (Test-Path -LiteralPath $destWim)) {
    Write-Host "[严重错误] install.wim 导出生成失败！流程终止。" -ForegroundColor Red
    if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

if ($isMountedISO) { Dismount-DiskImage -ImagePath $sourceFile -ErrorAction SilentlyContinue | Out-Null }
$index = "1"

# 6. 解锁映像访问权限并挂载 (步骤 3/11)
Write-Host "`n[步骤 3/11] 正在接管 install.wim 物理访问权限并执行挂载..." -ForegroundColor Cyan
attrib.exe -R -S -H "$destWim" 2>&1 | Out-Null
& takeown.exe /F "$destWim" /A 2>&1 | Out-Null
& icacls.exe "$destWim" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
(Get-Item -LiteralPath $destWim).IsReadOnly = $false

# 清理挂载死锁
if (Test-Path -LiteralPath $scratchDir) {
    Write-Host "清理历史挂载残留..." -ForegroundColor DarkGray
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    & dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
    & dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
    
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

# 挂载健康状态自检
$sys32Path = Join-Path $scratchDir "Windows\System32"
if (-not (Test-Path -LiteralPath $sys32Path)) {
    Write-Host "[严重错误] 挂载目录健康自检失败！未检测到 $sys32Path，映像已损坏或挂载不完整。" -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "[完成] 系统主映像挂载成功，运行环境就绪。" -ForegroundColor Green
