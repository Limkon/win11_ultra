# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像定位、导出与挂载 (src/02-MountImage.ps1)
# ==============================================================================

# 1. 输入与校验 ISO 光驱盘符
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 在 $DriveLetter 中未找到有效的 Windows 安装镜像源 (缺少 boot.wim 或 install.wim/esd)！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 2. 复制 ISO 引导架构文件 (步骤 1/11)
Write-Host "`n[步骤 1/11] 正在复制 ISO 核心引导结构到工作区..." -ForegroundColor Cyan
& robocopy.exe "$DriveLetter\\" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NC /NS /NP | Out-Null
Write-Host "[完成] 基础架构复制完毕。" -ForegroundColor Green

# 3. 定位源映像文件并导出目标分卷 (步骤 2/11)
$srcWim = "$DriveLetter\sources\install.wim"
$srcEsd = "$DriveLetter\sources\install.esd"
$destWim = "$sourcesDir\install.wim"

if (Test-Path $srcWim) {
    Write-Host "`n[步骤 2/11] 检测到 install.wim，获取映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$srcWim"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在导出目标分卷 (展示官方原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcWim" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
} else {
    Write-Host "`n[步骤 2/11] 检测到 install.esd，获取映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$srcEsd"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在将目标分卷从 ESD 转换导出为 install.wim (展示官方原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcEsd" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
}

if (-not (Test-Path $destWim)) {
    Write-Host "[严重错误] install.wim 导出失败！终止流程。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 导出后独立单一镜像的 Index 固定为 1
$index = "1"

# 4. 解锁映像访问权限并正式挂载 (步骤 3/11)
Write-Host "`n[步骤 3/11] 解锁 install.wim 访问权限并挂载..." -ForegroundColor Cyan
attrib.exe -R -S -H "$destWim" 2>$null
Start-Process -FilePath "takeown.exe" -ArgumentList "/F `"$destWim`"" -NoNewWindow -Wait
Start-Process -FilePath "icacls.exe" -ArgumentList "`"$destWim`" /grant *S-1-5-32-544:F /C /Q" -NoNewWindow -Wait
(Get-Item $destWim).IsReadOnly = $false

if (Test-Path $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载 install.wim 到 $scratchDir (展示官方挂载进度条)..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"

# 挂载状态校验
if (-not (Test-Path "$scratchDir\Windows\System32")) {
    Write-Host "[严重错误] 映像挂载失败！System32 目录不存在，终止运行。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}
Write-Host "[完成] 系统映像挂载成功。" -ForegroundColor Green

# 挂载状态校验
if (-not (Test-Path "$scratchDir\Windows\System32")) {
    Write-Host "[严重错误] 映像挂载失败！System32 目录不存在，终止运行。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}
Write-Host "[完成] 系统映像挂载成功。" -ForegroundColor Green

Write-Host "   -> [对齐] 正在接管目标核心目录物理权限 (防止静默删除失败)..." -ForegroundColor DarkGray
$foldersToOwn = @( 
    "$scratchDir\Windows\System32\DriverStore\FileRepository", 
    "$scratchDir\Windows\Fonts", 
    "$scratchDir\Windows\Web", 
    "$scratchDir\Windows\Help", 
    "$scratchDir\Windows\Cursors", 
    "$scratchDir\Program Files (x86)\Microsoft", 
    "$scratchDir\Program Files\WindowsApps", 
    "$scratchDir\Windows\System32\Microsoft-Edge-Webview", 
    "$scratchDir\Windows\System32\Recovery", 
    "$scratchDir\Windows\WinSxS", 
    "$scratchDir\Windows\assembly", 
    "$scratchDir\ProgramData\Microsoft\Windows Defender", 
    "$scratchDir\Windows\System32\InputMethod", 
    "$scratchDir\Windows\Speech", 
    "$scratchDir\Windows\Temp" 
)
$filesToOwn = @( "$scratchDir\Windows\System32\OneDriveSetup.exe" )

foreach ($folder in $foldersToOwn) { 
    if (Test-Path $folder) { 
        & takeown.exe /F $folder /R /D Y 2>$null | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
    } 
}
foreach ($file in $filesToOwn) { 
    if (Test-Path $file) { 
        & takeown.exe /F $file /D Y 2>$null | Out-Null
        & icacls.exe $file /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
    } 
}
Write-Host "   [就绪] 目标目录物理权限已全部解锁完毕。" -ForegroundColor Green
