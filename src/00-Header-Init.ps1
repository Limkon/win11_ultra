# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
# ==============================================================================

# ----------------- 全局特性静态开关 (后期需要时可直接在此修改) -----------------
# 是否将最终映像转换为 ESD 极限压缩格式 (默认 $false 关闭，直接打包 install.wim；改为 $true 则开启转换)
$enableEsdConversion = $false
# ------------------------------------------------------------------------------

# 1. 确保正确的执行策略
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
}

# 2. 锁定真实脚本目录
if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
Set-Location $scriptDir

# 3. 检查并强制以管理员身份运行
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "正在提升管理员权限..." -ForegroundColor Yellow
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`""
    $newProcess.Verb = "runas"
    $newProcess.WorkingDirectory = $scriptDir
    [System.Diagnostics.Process]::Start($newProcess)
    exit
}

# 4. 内核级关闭控制台快速编辑模式 (彻底解决鼠标误点击黑框导致的线程冻结挂起)
try {
    $consoleHelper = Add-Type -MemberDefinition @"
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@ -Name "Win32ConsoleHelper" -Namespace "Win32Utils" -PassThru -ErrorAction SilentlyContinue

    $stdInHandle = $consoleHelper::GetStdHandle(-10) # STD_INPUT_HANDLE
    $consoleMode = 0
    if ($consoleHelper::GetConsoleMode($stdInHandle, [ref]$consoleMode)) {
        # 移除 ENABLE_QUICK_EDIT_MODE (0x0040), 启用 ENABLE_EXTENDED_FLAGS (0x0080)
        $newMode = ($consoleMode -band -bnot 0x0040) -bor 0x0080
        $null = $consoleHelper::SetConsoleMode($stdInHandle, $newMode)
    }
} catch {}

# 5. 开启全程双重日志
$logFile = Join-Path -Path $scriptDir -ChildPath "win11_ultra_build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
try {
    Start-Transcript -Path $logFile -Append -Force
} catch {
    Write-Host "日志初始化失败: $_" -ForegroundColor Red
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " win11 Builder (全功能模块化·工业级透明稳定版) " -ForegroundColor Cyan
Write-Host " 日志文件: $logFile" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 6. 工作目录配置 (默认定向到 D 盘，若无则回退系统盘)
$targetDisk = "D:\"
if (-not (Test-Path $targetDisk)) {
    Write-Host "[提示] 未检测到 D 盘，工作目录自动回退到系统盘 $($env:SystemDrive)..." -ForegroundColor Yellow
    $targetDisk = "$($env:SystemDrive)\"
}

$scratchDir  = Join-Path $targetDisk "scratchdir"
$workDir     = Join-Path $targetDisk "win11"
$sourcesDir  = Join-Path $workDir "sources"

Write-Host "工作目录锁定在: $workDir" -ForegroundColor Green
Write-Host "映像挂载点锁定在: $scratchDir" -ForegroundColor Green

# 7. 用户模式选择交互
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
Write-Host " [1] 普通精简 (推荐: 极速流畅、稳定平衡、保留组件服务架构)" -ForegroundColor Green
Write-Host " [2] 极限压榨 (全版本自适应 WinSxS 瘦身 + 注册表物理抹杀服务)" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Magenta
$trimModeChoice = Read-Host "请输入对应数字 [1 或 2] (直接回车默认 1)"
if ($trimModeChoice -ne "2") {
    $trimMode = "1"
    Write-Host ">>> 已选择: [1] 普通精简模式 (物理强删文件 + 服务安全停用 + 官方组件清理)" -ForegroundColor Green
} else {
    $trimMode = "2"
    Write-Host ">>> 已选择: [2] 极限压榨模式 (物理强删文件 + 物理抹杀服务 + 自适应组件换头)" -ForegroundColor Red
}

# 输出 ESD 静态开关状态
if ($enableEsdConversion) {
    Write-Host ">>> [配置已启用] ESD 高压转换: 开启 (将在打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置默认值] ESD 高压转换: 关闭 (跳过耗时转换，直接使用 install.wim 打包)" -ForegroundColor DarkGray
}
Write-Host ""

# 8. 初始化清理 (安全预检并卸载残留，彻底杜绝 NativeCommandError 误报红字)
Write-Host "[初始化] 清理历史残留挂载点并重置环境..." -ForegroundColor DarkGray
if (Test-Path "HKLM:\zSOFTWARE") { cmd.exe /c "reg.exe unload HKLM\zSOFTWARE 2>nul" | Out-Null }
if (Test-Path "HKLM:\zSYSTEM")   { cmd.exe /c "reg.exe unload HKLM\zSYSTEM 2>nul" | Out-Null }
if (Test-Path "HKLM:\zNTUSER")   { cmd.exe /c "reg.exe unload HKLM\zNTUSER 2>nul" | Out-Null }

& dism.exe /English /Cleanup-Wim 2>$null | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
