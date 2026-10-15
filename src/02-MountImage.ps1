# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像挂载与权限接管 (1:1 对齐 nano11)
# ==============================================================================

# 1. 输入与校验 ISO 光驱盘符
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 镜像文件不存在！" -ForegroundColor Red
    exit
}

# 2. 复制基础镜像架构 (nano11 原生)
Write-Host "正在复制 Windows 镜像架构..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination "$workDir" -Recurse -Force > $null
Remove-Item "$sourcesDir\install.esd" -ErrorAction SilentlyContinue 

# 3. 获取分卷并挂载 (nano11 原生)
& dism.exe /English /Get-WimInfo "/wimfile:$sourcesDir\install.wim"
$index = Read-Host "请输入要精简的目标版本 Index 序号"

$wimFilePath = "$sourcesDir\install.wim"
& takeown.exe /F "$wimFilePath" > $null
& icacls.exe "$wimFilePath" /grant "*S-1-5-32-544:F" > $null
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

if (Test-Path $scratchDir) { Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载映像..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$wimFilePath" "/Index:$index" "/MountDir:$scratchDir"

# 4. nano11 原版预夺权 (完全对齐 nano11 原始语法，不走子进程，秒过不卡顿)
Write-Host "正在接管核心目录权限 (nano11 原版)..." -ForegroundColor DarkGray
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
        & takeown.exe /F "$folder" /R /D Y > $null 2>&1
        & icacls.exe "$folder" /grant "*S-1-5-32-544:F" /T /C > $null 2>&1
    } 
}
foreach ($file in $filesToOwn) { 
    if (Test-Path $file) { 
        & takeown.exe /F "$file" /D Y > $null 2>&1
        & icacls.exe "$file" /grant "*S-1-5-32-544:F" /C > $null 2>&1
    } 
}
Write-Host "[完成] 映像挂载与权限接管完毕。" -ForegroundColor Green
