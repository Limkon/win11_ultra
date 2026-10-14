# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
#  [企业级重构]：全局交互三合一集中前置 + 倒计时防挂起 + 全流程静默流水线
# ==============================================================================

# ----------------- 全局特性静态开关 -----------------
# 是否将最终映像转换为 ESD 极限压缩格式 (默认 $false 关闭，直接打包 install.wim)
$enableEsdConversion = $false
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
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`""
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
Write-Host " [配置 1/2] 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
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
Write-Host " [配置 2/2] 请选择 Windows 安装引导模式 (Unattend Mode):" -ForegroundColor Magenta
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

# 输出 ESD 开关状态与就绪提示
Write-Host ""
if ($enableEsdConversion) {
    Write-Host ">>> [配置状态] ESD 高压转换: 开启 (打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 打包)" -ForegroundColor DarkGray
}
Write-Host "`n[就绪] 前置配置已全部锁定，流水线启动！`n" -ForegroundColor Green

# ----------------- 10. 初始化清理 (安全预检并卸载残留) -----------------
Write-Host "[初始化] 清理历史残留挂载点并重置环境..." -ForegroundColor DarkGray
if (Test-Path "HKLM:\zSOFTWARE") { cmd.exe /c "reg.exe unload HKLM\zSOFTWARE 2>nul" | Out-Null }
if (Test-Path "HKLM:\zSYSTEM")   { cmd.exe /c "reg.exe unload HKLM\zSYSTEM 2>nul" | Out-Null }
if (Test-Path "HKLM:\zNTUSER")   { cmd.exe /c "reg.exe unload HKLM\zNTUSER 2>nul" | Out-Null }

& dism.exe /English /Cleanup-Wim 2>$null | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
