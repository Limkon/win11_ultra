# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像挂载与底层权限接管 (src/02-MountImage.ps1)
#  [企业级重构]：恢复原有原生提权清单 (坚决不碰 SystemApps) + Index 全局持久化
# ==============================================================================

# ----------------- 1. 输入与校验 ISO 光驱盘符 -----------------
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[严重错误] 镜像文件不存在！" -ForegroundColor Red
    pause
    exit
}

# ----------------- 2. 复制基础镜像架构 -----------------
Write-Host "正在复制 Windows 镜像架构..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination "$workDir" -Recurse -Force > $null
Remove-Item "$sourcesDir\install.esd" -ErrorAction SilentlyContinue 

# ----------------- 3. 获取分卷并挂载 -----------------
$wimFilePath = "$sourcesDir\install.wim"
& dism.exe /English /Get-WimInfo "/wimfile:$wimFilePath"

$inputIndex = Read-Host "请输入要精简的目标版本 Index 序号"
$inputIndex = $inputIndex.Trim()

# 校验并全局锁定目标版本，彻底修复单卷导出硬编码错位
if ([string]::IsNullOrWhiteSpace($inputIndex) -or ($inputIndex -notmatch '^\d+$')) {
    Write-Host "[提示] 输入无效，默认锁定 Index 序号: 1" -ForegroundColor Yellow
    $global:targetIndex = "1"
} else {
    $global:targetIndex = $inputIndex
    Write-Host ">>> 已全局锁定精简目标版本 Index: $global:targetIndex" -ForegroundColor Green
}

& takeown.exe /F "$wimFilePath" > $null 2>&1
& icacls.exe "$wimFilePath" /grant "*S-1-5-32-544:F" > $null 2>&1
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $scratchDir) { 
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue 
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载映像分卷 [$global:targetIndex]..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$wimFilePath" "/Index:$global:targetIndex" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 映像挂载失败！" -ForegroundColor Red
    pause
    exit
}

# ----------------- 4. 恢复原有预夺权白名单 (坚决不碰 SystemApps，确保打开方式完好) -----------------
Write-Host "正在接管核心目录权限 (严格遵照原生安全架构)..." -ForegroundColor DarkGray
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
$filesToOwn = @( 
    "$scratchDir\Windows\System32\OneDriveSetup.exe" 
)

foreach ($folder in $foldersToOwn) { 
    if (Test-Path -LiteralPath $folder) { 
        & takeown.exe /F "$folder" /R /D Y > $null 2>&1
        & icacls.exe "$folder" /grant "*S-1-5-32-544:F" /T /C > $null 2>&1
    } 
}

foreach ($file in $filesToOwn) { 
    if (Test-Path -LiteralPath $file) { 
        & takeown.exe /F "$file" /D Y > $null 2>&1
        & icacls.exe "$file" /grant "*S-1-5-32-544:F" /C > $null 2>&1
    } 
}

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Write-Host "[完成] 映像挂载与权限接管完毕。" -ForegroundColor Green
