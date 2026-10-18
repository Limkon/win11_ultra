# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像挂载与底层权限接管 (src/02-MountImage.ps1)
#  [企业级重构]：Index 全局持久化锁定 + 核心与 Edge 目录底层穿透夺权
# ==============================================================================

# ----------------- 1. 输入与校验 ISO 光驱盘符 -----------------
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[严重错误] 指定驱动器中未找到有效的 Windows 安装镜像文件！" -ForegroundColor Red
    pause
    exit
}

# ----------------- 2. 复制基础安装介质架构 -----------------
Write-Host "正在复制 Windows 原始安装介质架构..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination "$workDir" -Recurse -Force > $null
Remove-Item "$sourcesDir\install.esd" -ErrorAction SilentlyContinue 

# ----------------- 3. 动态获取分卷并全局锁定选定版本 -----------------
$wimFilePath = "$sourcesDir\install.wim"
& dism.exe /English /Get-WimInfo "/wimfile:$wimFilePath"

$inputIndex = Read-Host "请输入要精简的目标版本 Index 序号"
$inputIndex = $inputIndex.Trim()

# 校验并全局锁定目标分卷序号，杜绝后续单卷导出时硬编码错位
if ([string]::IsNullOrWhiteSpace($inputIndex) -or ($inputIndex -notmatch '^\d+$')) {
    Write-Host "[提示] 输入无效，默认锁定 Index 序号: 1" -ForegroundColor Yellow
    $global:targetIndex = "1"
} else {
    $global:targetIndex = $inputIndex
    Write-Host ">>> 已全局锁定精简目标版本 Index: $global:targetIndex" -ForegroundColor Green
}

# 接管 install.wim 实体文件所有权
& takeown.exe /F "$wimFilePath" > $null 2>&1
& icacls.exe "$wimFilePath" /grant "*S-1-5-32-544:F" > $null 2>&1
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

# 重置并创建挂载工作目录
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

# ----------------- 4. 脱机核心系统目录提权预处理 -----------------
Write-Host "正在接管核心系统目录控制权 (注入 Administrators 完全控制权限)..." -ForegroundColor DarkGray
$foldersToOwn = @( 
    "$scratchDir\Windows\System32\DriverStore\FileRepository", 
    "$scratchDir\Windows\Fonts", 
    "$scratchDir\Windows\Web", 
    "$scratchDir\Windows\Help", 
    "$scratchDir\Windows\Cursors", 
    "$scratchDir\Program Files (x86)\Microsoft", 
    "$scratchDir\Program Files (x86)\Microsoft\Edge", 
    "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate", 
    "$scratchDir\Program Files (x86)\Microsoft\EdgeCore", 
    "$scratchDir\Program Files (x86)\Microsoft\EdgeWebView", 
    "$scratchDir\Program Files\WindowsApps", 
    "$scratchDir\Windows\SystemApps", 
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
        & icacls.exe "$folder" /grant "*S-1-5-32-544:F" /T /C /Q > $null 2>&1
    } 
}

foreach ($file in $filesToOwn) { 
    if (Test-Path -LiteralPath $file) { 
        & takeown.exe /F "$file" /D Y > $null 2>&1
        & icacls.exe "$file" /grant "*S-1-5-32-544:F" /C /Q > $null 2>&1
    } 
}

# 释放临时句柄保证稳定性
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Write-Host "[完成] 目标分卷 [$global:targetIndex] 挂载与全量权限预接管完毕。" -ForegroundColor Green
