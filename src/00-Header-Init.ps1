# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
#  [企业级重构]：全局交互三合一集中前置 + 倒计时防挂起 + 全流程静默流水线
# ==============================================================================

# ----------------- 全局特性静态开关 -----------------
# 是否将最终映像转换为 ESD 极限压缩格式 (默认 $false 关闭，直接打包 install.wim)
$global:enableEsdConversion = $false
# ----------------------------------------------------

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
    $scriptFullPath = $MyInvocation.MyCommand.Definition
    if (-not [System.IO.Path]::IsPathRooted($scriptFullPath)) {
        $scriptFullPath = Join-Path $scriptDir $scriptFullPath
    }
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFullPath`""
    $newProcess.Verb = "runas"
    $newProcess.WorkingDirectory = $scriptDir
    [System.Diagnostics.Process]::Start($newProcess)
    exit
}

# 4. 内核级关闭控制台快速编辑模式 (防误触黑框导致线程挂起)
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
        $newMode = ($consoleMode -band -bnot 0x0040) -bor 0x0080
        $null = $consoleHelper::SetConsoleMode($stdInHandle, $newMode)
    }
} catch {}

# 5. 开启全程双重日志 (失败时设状态标志并 fallback 到 TEMP)
$global:transcriptActive = $false
$logFile = Join-Path -Path $scriptDir -ChildPath "win11_ultra_build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
try {
    Start-Transcript -Path $logFile -Append -Force
    $global:transcriptActive = $true
} catch {
    $fallbackLog = Join-Path $env:TEMP "win11_ultra_build_fallback_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Host "日志初始化失败: $_" -ForegroundColor Red
    Write-Host "已回退到临时日志: $fallbackLog" -ForegroundColor Yellow
    $logFile = $fallbackLog
    try {
        Start-Transcript -Path $logFile -Append -Force
        $global:transcriptActive = $true
    } catch {
        Write-Host "[警告] 临时日志亦初始化失败，后续输出仅显示在控制台。" -ForegroundColor Red
    }
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

# ----------------- 7. 前置倒计时交互引擎函数 -----------------
function Read-ChoiceWithTimeout {
    param (
        [string]$PromptText = "请输入选项",
        [int]$Seconds = 15,
        [string]$DefaultChoice = "1"
    )

    try {
        $null = [Console]::KeyAvailable
    } catch {
        $fallback = Read-Host "$PromptText (回车默认: $DefaultChoice)"
        if ([string]::IsNullOrWhiteSpace($fallback)) { return $DefaultChoice }
        return $fallback.Trim()
    }

    $startTime = [DateTime]::Now
    $lastPrinted = -1

    while ($true) {
        $remaining = $Seconds - [int]([DateTime]::Now - $startTime).TotalSeconds
        if ($remaining -le 0) {
            Write-Host "`n>>> [超时] 倒计时结束，自动采用默认项: [$DefaultChoice]" -ForegroundColor Yellow
            return $DefaultChoice
        }

        if ($remaining -ne $lastPrinted) {
            $lastPrinted = $remaining
            $statusLine = "`r$PromptText (默认: $DefaultChoice) [倒计时 $remaining 秒]: "
            Write-Host -NoNewline ($statusLine.PadRight(70)) -ForegroundColor Cyan
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                return $DefaultChoice
            } elseif ($key.KeyChar -ge 49 -and $key.KeyChar -le 57) {
                Write-Host $key.KeyChar
                return ([string]$key.KeyChar)
            }
        }
        Start-Sleep -Milliseconds 50
    }
}

function Read-StringWithTimeout {
    param (
        [string]$Prompt = "请输入自定义用户名",
        [int]$Seconds = 15,
        [string]$Default = "Admin"
    )

    try {
        $null = [Console]::KeyAvailable
    } catch {
        $fallback = Read-Host "$Prompt (回车默认: $Default)"
        if ([string]::IsNullOrWhiteSpace($fallback)) { return @{ TimedOut = $false; Value = $Default } }
        return @{ TimedOut = $false; Value = $fallback.Trim() }
    }

    $inputStr = New-Object System.Text.StringBuilder
    $startTime = [DateTime]::Now
    $lastPrinted = -1

    while ($true) {
        $remaining = $Seconds - [int]([DateTime]::Now - $startTime).TotalSeconds
        if ($remaining -le 0 -and $inputStr.Length -eq 0) {
            Write-Host "`n>>> [超时] 未输入，已自动采用默认用户名: $Default (密码自动留空)" -ForegroundColor Yellow
            return @{ TimedOut = $true; Value = $Default }
        }

        if ($inputStr.Length -eq 0 -and $remaining -ne $lastPrinted) {
            $lastPrinted = $remaining
            $statusLine = "`r$Prompt (默认: $Default) [剩余 $remaining 秒]: "
            Write-Host -NoNewline ($statusLine.PadRight(70)) -ForegroundColor Cyan
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                $finalText = $inputStr.ToString().Trim()
                if ([string]::IsNullOrWhiteSpace($finalText)) {
                    return @{ TimedOut = $false; Value = $Default }
                }
                return @{ TimedOut = $false; Value = $finalText }
            }
            elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($inputStr.Length -gt 0) {
                    $inputStr.Remove($inputStr.Length - 1, 1) | Out-Null
                    Write-Host -NoNewline "`b `b"
                }
            }
            elseif ($key.KeyChar -ge 32) {
                if ($inputStr.Length -eq 0) {
                    Write-Host -NoNewline ("`r" + (" " * 75) + "`r")
                    Write-Host -NoNewline "${Prompt}: " -ForegroundColor Cyan
                }
                $inputStr.Append($key.KeyChar) | Out-Null
                Write-Host -NoNewline $key.KeyChar
            }
        }
        Start-Sleep -Milliseconds 50
    }
}

# ----------------- 8. 前置配置 1：选择精简制作模式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 1/3] 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
Write-Host " [1] 普通精简 (推荐: 极速流畅、稳定平衡、保留组件服务架构)" -ForegroundColor Green
Write-Host " [2] 极限压榨 (全版本自适应 WinSxS 瘦身 + 注册表物理抹杀服务)" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Magenta

$trimChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "1"
if ($trimChoice -eq "2") {
    $global:trimMode = "2"
    Write-Host ">>> 已确认: [2] 极限压榨模式" -ForegroundColor Red
} else {
    $global:trimMode = "1"
    Write-Host ">>> 已确认: [1] 普通精简模式" -ForegroundColor Green
}

# ----------------- 9. 前置配置 2：选择无人值守引导模式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 2/3] 请选择 Windows 安装引导模式 (Unattend Mode):" -ForegroundColor Magenta
Write-Host " [1] 全无人值守 (全自动安装、自动创建指定账户并自动登录)" -ForegroundColor Green
Write-Host " [2] 半无人值守 (跳过硬件检测限制，在 OOBE 阶段手动输入用户名/密码)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Magenta

$unattendChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "1"
if ($unattendChoice -eq "2") {
    $global:unattendMode = "2"
    $global:customUser   = ""
    $global:customPass   = ""
    Write-Host ">>> 已确认: [2] 半无人值守模式 (保留原生手动设置用户名/密码向导)" -ForegroundColor Yellow
} else {
    $global:unattendMode = "1"
    Write-Host ">>> 已确认: [1] 全无人值守模式" -ForegroundColor Green

    $userResult = Read-StringWithTimeout -Prompt "请输入自动登录用户名" -Seconds 15 -Default "Admin"
    $inputUser = $userResult.Value
    if ($inputUser -match "^(Administrator|Guest)$") {
        Write-Host "[警告] 输入了系统保留账户名 $inputUser，自动重置为 Admin！" -ForegroundColor Yellow
        $inputUser = "Admin"
    }

    if ($userResult.TimedOut) {
        $inputPass = ""
    } else {
        $inputPass = Read-Host "请输入登录密码 (直接回车表示留空无密码)"
    }

    $global:customUser = $inputUser
    $global:customPass = $inputPass
    Write-Host ">>> [账户锁定] 用户名: $global:customUser | 密码: $(if ([string]::IsNullOrEmpty($global:customPass)) { '(留空)' } else { '******' })" -ForegroundColor DarkGray
}

# ----------------- 10. 前置配置 3：源文件获取方式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [配置 3/3] 请选择 Windows 11 源文件获取方式:" -ForegroundColor Cyan
Write-Host " [1] 输入光驱盘符 (适用于已挂载 ISO 的用户)" -ForegroundColor Green
Write-Host " [2] 输入文件路径 (直接指定 .iso / .wim / .esd，支持拖拽)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

$sourceChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "1"
$global:sourceMode = $sourceChoice
$global:driveLetter = ""
$global:sourceFile = ""

if ($sourceChoice -eq "2") {
    Write-Host "`n请将 .iso / .wim / .esd 文件拖拽到此处，或手动输入完整路径:" -ForegroundColor Yellow
    $inputPath = Read-Host
    $inputPath = $inputPath.Trim('"', ' ').Trim()
    if (-not (Test-Path -LiteralPath $inputPath)) {
        Write-Host "[严重错误] 文件不存在: $inputPath" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    $ext = [System.IO.Path]::GetExtension($inputPath).ToLower()
    if ($ext -notin '.iso', '.wim', '.esd') {
        Write-Host "[严重错误] 不支持的文件格式 ($ext)，仅限 .iso / .wim / .esd。" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    $global:sourceFile = $inputPath
    Write-Host ">>> 已锁定源文件: $($global:sourceFile)" -ForegroundColor Green
} else {
    Write-Host "`n请输入 ISO 虚拟光驱盘符 (例如 E):" -ForegroundColor Yellow
    $inputDrive = Read-Host
    $normalized = $inputDrive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
    if ($normalized -notmatch '^[A-Z]$') {
        Write-Host "[严重错误] 盘符格式非法，请输入单个字母（如 E）！" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    $global:driveLetter = "$normalized`:"
    Write-Host ">>> 已锁定挂载盘符: $($global:driveLetter)" -ForegroundColor Green
}

# 输出 ESD 开关状态
Write-Host ""
if ($global:enableEsdConversion) {
    Write-Host ">>> [配置状态] ESD 高压转换: 开启 (打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 打包)" -ForegroundColor DarkGray
}
Write-Host "`n[就绪] 前置配置已全部锁定，后续构建流程将完全静默自动化运行！`n" -ForegroundColor Green

# ----------------- 11. 初始化环境清理 -----------------
Write-Host "[初始化] 正在深度清理历史挂载残留与注册表死锁..." -ForegroundColor DarkGray

# 卸载可能残留的离线注册表
foreach ($hive in @("zCOMPONENTS", "zDEFAULT", "zNTUSER", "zSOFTWARE", "zSYSTEM")) {
    if (Test-Path "HKLM:\$hive") { 
        cmd.exe /c "reg.exe unload HKLM\$hive 2>nul" | Out-Null 
    }
}

# 强制终结卡死的 DISM 进程
Get-Process -Name "dism", "dismhost" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 强制清理注册表中的 WIM 幽灵挂载记录
try {
    $wimMountKey = "HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images"
    if (Test-Path $wimMountKey) {
        Get-ChildItem -Path $wimMountKey -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

# 执行官方清理并处理挂载目录
& dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path $scratchDir) { 
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue 
}

if (Test-Path $workDir) { 
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue 
}
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

Write-Host "[初始化] 环境清理完毕，准备开始构建。" -ForegroundColor Green
