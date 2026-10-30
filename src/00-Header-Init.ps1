# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
#  [企业级重构]：全局交互五合一集中前置 + 倒计时防挂起 + 全流程静默流水线
# ==============================================================================

# ----------------- 全局特性静态开关 (作为交互默认值来源) -----------------
# 是否将最终映像转换为 ESD 极限压缩格式 (默认 $false 关闭，交互中可临时开启)
$global:enableEsdConversion = $false
# ------------------------------------------------------------------------

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

# ----------------- 6. 前置倒计时交互引擎函数 -----------------
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

# ----------------- 7. 前置配置 1/5：选择精简制作模式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 1/5] 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
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

# ----------------- 8. 前置配置 2/5：选择无人值守引导模式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 2/5] 请选择 Windows 安装引导模式 (Unattend Mode):" -ForegroundColor Magenta
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

# ----------------- 9. 前置配置 3/5：ESD 极限高压转换开关 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [配置 3/5] 是否启用 ESD 极限高压转换 (最终映像格式):" -ForegroundColor Cyan
Write-Host " [1] 是 (转换为 install.esd, 体积更小, 压缩耗时更长)" -ForegroundColor Yellow
Write-Host " [2] 否 (直接打包 install.wim, 速度快, 兼容性最佳) [推荐]" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

# 静态开关作为交互默认值：$true -> 默认1(是)，$false -> 默认2(否)
$esdDefaultChoice = if ($global:enableEsdConversion) { "1" } else { "2" }
$esdChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2] (倒计时结束默认: 否)" -Seconds 15 -DefaultChoice $esdDefaultChoice

if ($esdChoice -eq "1") {
    $global:enableEsdConversion = $true
    Write-Host ">>> 已确认: [是] 启用 ESD 极限高压转换" -ForegroundColor Yellow
} else {
    $global:enableEsdConversion = $false
    Write-Host ">>> 已确认: [否] 直接输出 install.wim" -ForegroundColor Green
}

# ----------------- 10. 前置配置 4/5：工作目录盘符选择 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [配置 4/5] 请选择工作目录所在磁盘 (工作目录 = <盘符>\win11):" -ForegroundColor Cyan

# 自动枚举本机可用固定磁盘盘符 (排除系统保留/A/B/光驱/网络/可移动)
$availableDrives = @()
try {
    $availableDrives = @(
        Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object {
                $_.DriveType -eq 3 -and
                $_.DeviceID -match '^[A-Z]:$' -and
                $_.DeviceID -notin @('A:', 'B:') -and
                $_.Size -gt 0
            } |
            ForEach-Object { $_.DeviceID.TrimEnd(':') } |
            Sort-Object
    )
} catch {
    Write-Host "[警告] 盘符枚举失败，回退到 C/D 探测: $_" -ForegroundColor Yellow
    $availableDrives = @('C', 'D') | Where-Object { Test-Path "${_}:\" }
}

if ($availableDrives.Count -eq 0) {
    Write-Host "[警告] 未检测到任何可用固定磁盘，回退到系统盘 $($env:SystemDrive)" -ForegroundColor Yellow
    $global:targetDriveLetter = $env:SystemDrive.TrimEnd('\').TrimEnd(':')
} else {
    # 排序后：第 1 个为“首选”，第 2 个为“倒计时默认”；不足 2 个则回退第 1 个
    $defaultDrive = if ($availableDrives.Count -ge 2) { $availableDrives[1] } else { $availableDrives[0] }

    Write-Host " 检测到以下可用磁盘盘符 (按字母升序):" -ForegroundColor Gray
    for ($i = 0; $i -lt $availableDrives.Count; $i++) {
        $d = $availableDrives[$i]
        $marker = if ($d -eq $defaultDrive) { " [倒计时默认]" } else { "" }
        $sizeInfo = ""
        try {
            $vol = Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue
            if ($vol -and $vol.Size) {
                $sizeGB = [math]::Round($vol.Size / 1GB, 1)
                $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
                $sizeInfo = " (总 $sizeGB GB / 空闲 $freeGB GB)"
            }
        } catch {}
        Write-Host (" [{0}] {1}:{2}{3}" -f ($i + 1), $d, $sizeInfo, $marker) -ForegroundColor White
    }
    Write-Host "==========================================================" -ForegroundColor Cyan

    $driveChoicePrompt = "请输入盘符前的序号 [1-$($availableDrives.Count)]"
    $driveChoice = Read-ChoiceWithTimeout -PromptText $driveChoicePrompt -Seconds 15 -DefaultChoice "0"

    # 超时/回车: 直接选 $defaultDrive (即排序第二)；手动输入则按序号取
    if ($driveChoice -eq "0") {
        $global:targetDriveLetter = $defaultDrive
        Write-Host ">>> [超时] 已自动选择排序第 2 的盘符: $($global:targetDriveLetter):" -ForegroundColor Yellow
    } else {
        $idx = [int]$driveChoice - 1
        if ($idx -ge 0 -and $idx -lt $availableDrives.Count) {
            $global:targetDriveLetter = $availableDrives[$idx]
            Write-Host ">>> 已确认工作磁盘: $($global:targetDriveLetter):" -ForegroundColor Green
        } else {
            $global:targetDriveLetter = $defaultDrive
            Write-Host ">>> [非法序号] 已回退到排序第 2 的盘符: $($global:targetDriveLetter):" -ForegroundColor Yellow
        }
    }
}

$targetDisk = "$($global:targetDriveLetter):\"
$scratchDir  = Join-Path $targetDisk "scratchdir"
$workDir     = Join-Path $targetDisk "win11"
$sourcesDir  = Join-Path $workDir "sources"

Write-Host "工作目录锁定在: $workDir" -ForegroundColor Green
Write-Host "映像挂载点锁定在: $scratchDir" -ForegroundColor Green

# ----------------- 11. 前置配置 5/5：源文件获取方式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [配置 5/5] 请选择 Windows 11 源文件获取方式:" -ForegroundColor Cyan
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

# ----------------- 12. 配置汇总输出 -----------------
Write-Host ""
if ($global:enableEsdConversion) {
    Write-Host ">>> [配置状态] ESD 高压转换: 开启 (打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 打包)" -ForegroundColor DarkGray
}
Write-Host ">>> [配置状态] 工作磁盘: $($global:targetDriveLetter):" -ForegroundColor DarkGray
Write-Host "`n[就绪] 前置配置已全部锁定，后续构建流程将完全静默自动化运行！`n" -ForegroundColor Green

# ----------------- 13. 初始化环境清理 -----------------
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
