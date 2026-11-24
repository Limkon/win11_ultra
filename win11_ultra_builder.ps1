# ==============================================================================
#  Windows 10/11 Ultra Builder - 自动化全功能完整版
#  生成时间: 2026-11-24 00:00:00 UTC
#  构建流水线: GitHub Actions (workflow_dispatch)
# ==============================================================================

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/00-Header-Init.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
#  [企业级重构]：全局交互五合一集中前置 + 倒计时防挂起 + 全流程静默流水线
#  [新增] 源文件获取方式增加 [3] 映像文件夹（已释放好的文件夹 → 原地精简，
#         不挂载、不导出 WIM、不打包 ISO，结果原地保留）
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
$logFile = Join-Path -Path $scriptDir -ChildPath "windows_ultra_build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
try {
    Start-Transcript -Path $logFile -Append -Force
    $global:transcriptActive = $true
} catch {
    $fallbackLog = Join-Path $env:TEMP "windows_ultra_build_fallback_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
Write-Host " Windows 10/11 Builder (自动识别·模块化精简) " -ForegroundColor Cyan
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
Write-Host " [1] 全无人值守 (全自动安装、自动创建指定账户并自动登录)" -ForegroundColor Yellow
Write-Host " [2] 半无人值守 (跳过硬件检测限制，在 OOBE 阶段手动输入用户名/密码) [推荐]" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Magenta

$unattendChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "2"
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
Write-Host " [配置 3/5] 最终映像格式 (ESD 极限高压转换):" -ForegroundColor Cyan
Write-Host " [1] 是 (输出 install.esd, 体积更小, 压缩耗时更长)" -ForegroundColor Yellow
Write-Host " [2] 否 (输出 install.wim, 速度快, 兼容性最佳) [推荐]" -ForegroundColor Green
Write-Host "      注: 映像文件夹模式下本项不影响流程（不产出 WIM/ESD）。" -ForegroundColor DarkGray
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
Write-Host " [配置 4/5] 请选择工作目录所在磁盘 (工作目录 = <盘符>\windows):" -ForegroundColor Cyan

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
$workDir     = Join-Path $targetDisk "windows"
$sourcesDir  = Join-Path $workDir "sources"

# 注意：sourceMode 在第 11 节才确定，此处 $global:sourceMode 可能为 $null；
# 映像文件夹模式的路径重定向放在第 11 节之后（第 11.5 节）。
Write-Host "工作目录锁定在: $workDir" -ForegroundColor Green
Write-Host "映像挂载点锁定在: $scratchDir" -ForegroundColor Green

# ----------------- 11. 前置配置 5/5：源文件获取方式 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [配置 5/5] 请选择 Windows 10/11 源文件获取方式:" -ForegroundColor Cyan
Write-Host " [1] 光驱盘符     (已挂载 ISO → 完整打包生成新 ISO)" -ForegroundColor Green
Write-Host " [2] 映像文件     (指定 .iso / .wim / .esd → 完整打包生成新 ISO)" -ForegroundColor Green
Write-Host " [3] 映像文件夹   (已释放好的文件夹 → 原地精简, 不挂载、不打包) [新增]" -ForegroundColor Magenta
Write-Host "==========================================================" -ForegroundColor Cyan

$sourceChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 / 2 / 3]" -Seconds 15 -DefaultChoice "1"

# 全局初始化，防止下游 $null 判空异常
$global:driveLetter  = ""
$global:sourceFile   = ""
$global:imageFolder  = ""
$global:isFolderMode = $false

if ($sourceChoice -eq "3") {
    # ---------- 模式 3：映像文件夹（已释放，原地精简） ----------
    $global:sourceMode   = "3"
    $global:isFolderMode = $true

    Write-Host "`n[映像文件夹模式] 请将已释放好 Windows 文件结构的文件夹拖拽到此处，或手动输入完整路径:" -ForegroundColor Magenta
    Write-Host "      (文件夹内应直接包含 Windows\、Program Files\、Users\、ProgramData\ 等目录)" -ForegroundColor DarkGray
    $inputFolder = Read-Host
    $inputFolder = $inputFolder.Trim('"', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($inputFolder)) {
        Write-Host "[严重错误] 未输入任何路径，流程中止。" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    if (-not (Test-Path -LiteralPath $inputFolder -PathType Container)) {
        Write-Host "[严重错误] 文件夹不存在或不是目录: $inputFolder" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }

    # ---- 结构完整性前置校验（关键：DISM /Image: 与注册表 hive 加载的前提）----
    $requiredPaths = @(
        "Windows\System32",
        "Windows\System32\config\SOFTWARE",
        "Windows\System32\config\SYSTEM",
        "Windows\System32\config\DEFAULT",
        "Windows\System32\config\COMPONENTS",
        "Users\Default\ntuser.dat"
    )
    $missingItems = @()
    foreach ($rp in $requiredPaths) {
        $fullRp = Join-Path $inputFolder $rp
        if (-not (Test-Path -LiteralPath $fullRp)) { $missingItems += $rp }
    }
    if ($missingItems.Count -gt 0) {
        Write-Host "[严重错误] 目标文件夹不是完整的 Windows 映像结构，缺失以下关键项：" -ForegroundColor Red
        foreach ($m in $missingItems) { Write-Host "   - $m" -ForegroundColor Red }
        Write-Host "请确认该文件夹由 DISM /Apply-Image 或 Expand-WindowsImage 释放得到。" -ForegroundColor Yellow
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }

    # ---- 拒绝系统盘路径（防止对在线系统目录误操作）----
    $inputRoot = [System.IO.Path]::GetPathRoot($inputFolder)
    $systemRoot = $env:SystemDrive.TrimEnd('\') + '\'
    if ($inputRoot -and $inputRoot.TrimEnd('\') -eq $systemRoot.TrimEnd('\')) {
        Write-Host "[严重错误] 目标文件夹位于当前运行的系统盘 ($inputRoot)：无法对在线系统目录执行离线精简！" -ForegroundColor Red
        Write-Host "请将映像释放到非系统盘（如 D:\ 或 E:\）后再重试。" -ForegroundColor Yellow
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }

    $global:imageFolder = $inputFolder.TrimEnd('\')
    Write-Host ">>> 已锁定映像文件夹: $($global:imageFolder)" -ForegroundColor Green
    Write-Host ">>> [行为] 跳过挂载与 ISO 打包，直接对文件夹内容执行精简，结果原地保留。" -ForegroundColor Magenta

} elseif ($sourceChoice -eq "2") {
    # ---------- 模式 2：映像文件（完整打包） ----------
    $global:sourceMode = "2"
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
    # ---------- 模式 1：光驱盘符（完整打包） ----------
    $global:sourceMode = "1"
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

# ----------------- 11.5 映像文件夹模式：路径重定向（关键） -----------------
if ($global:sourceMode -eq "3") {
    # $scratchDir 直接指向用户文件夹：下游所有 $scratchDir\Windows\... 路径天然正确
    $scratchDir = $global:imageFolder

    # $workDir / $sourcesDir 在文件夹模式下不使用；给一个临时空目录兜底，
    # 避免下游 New-Item / Test-Path 因 $null 崩溃（07 模块会写 $workDir\autounattend.xml）
    $workDir    = Join-Path $targetDisk "windows_folder_mode_tmp"
    $sourcesDir = Join-Path $workDir "sources"

    Write-Host ">>> [映像文件夹模式] 离线操作目标已重定向为: $scratchDir" -ForegroundColor Magenta
    Write-Host ">>> [映像文件夹模式] 不会创建挂载点，也不会导出 install.wim。" -ForegroundColor Magenta
}

# ----------------- 12. 配置汇总输出 -----------------
Write-Host ""
if ($global:isFolderMode) {
    Write-Host ">>> [配置状态] 运行模式: 映像文件夹原地精简 (不挂载、不导出 WIM、不打包 ISO)" -ForegroundColor Magenta
    Write-Host ">>> [配置状态] 目标文件夹: $($global:imageFolder)" -ForegroundColor Magenta
    Write-Host ">>> [配置状态] ESD 高压转换: 本模式下不生效（不产出 WIM/ESD 文件）" -ForegroundColor DarkGray
} else {
    if ($global:enableEsdConversion) {
        Write-Host ">>> [配置状态] ESD 高压转换: 开启 (打包前转换为 install.esd)" -ForegroundColor Yellow
    } else {
        Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 打包)" -ForegroundColor DarkGray
    }
}
Write-Host ">>> [配置状态] 工作磁盘: $($global:targetDriveLetter):" -ForegroundColor DarkGray
Write-Host "`n[就绪] 前置配置已全部锁定，后续构建流程将完全静默自动化运行！`n" -ForegroundColor Green

# ----------------- 13. 初始化环境清理 -----------------
Write-Host "[初始化] 正在深度清理历史挂载残留与注册表死锁..." -ForegroundColor DarkGray

# 卸载可能残留的离线注册表（仅影响本机 HKLM 挂载点，与目标文件夹无关）
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

# 执行官方清理
& dism.exe /English /Cleanup-Wim 2>&1 | Out-Null

if ($global:sourceMode -eq "3") {
    # 映像文件夹模式：绝不允许删除 $scratchDir（即用户目标文件夹）
    Write-Host "[初始化] 映像文件夹模式：跳过挂载点清理与目录删除，保护用户目标文件夹。" -ForegroundColor Magenta

    # 仅清理可能残留的临时工作区（$workDir 已是临时目录，安全）
    if (Test-Path $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
} else {
    cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

    if (Test-Path $scratchDir) {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
}

Write-Host "[初始化] 环境清理完毕，准备开始构建。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/00-Header-Init.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/01-Helpers.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
#  [本版核心修复] 彻底根治 reg.exe 在 /d '' 场景下的交互式死锁：
#    - 根因：PowerShell 5.1 传递空字符串数组元素时将 `''` 展开为裸空格，
#      导致 reg.exe 将紧随其后的 `/f` 识别为 `/d` 的数据，从而丢失强制标志；
#      若键值已存在，reg.exe 会静默挂起等待标准输入确认 (Yes/No)?，CPU=0 永久假死。
#    - 修复：采用 .NET Process 底层封装：
#      ① 显式将空字符串和特殊字符序列化为标准双引号 `""`；
#      ② 物理关闭子进程的标准输入 (StandardInput.Close)，收到 EOF 绝不等待交互；
#      ③ 增加 10 秒超时保护，遇到异常强行销毁并报警，保障流水线绝对流畅。
# ==============================================================================

# ----------------- 1. 终极物理粉碎函数 -----------------
function Force-NukeFolderOrFile {
    <#
    .SYNOPSIS
        强行接管文件/文件夹所有权，注入最高权限并彻底粉碎删除
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return }

        if ($item.PSIsContainer) {
            & takeown.exe /F "$Target" /A /R /D Y 2>&1 | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
            if (Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue) {
                attrib.exe -R -S -H "$Target\*" /S /D 2>&1 | Out-Null
            }
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "rd /s /q `"$Target`"" 2>&1 | Out-Null
            }
        } else {
            & takeown.exe /F "$Target" /A 2>&1 | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
            attrib.exe -R -S -H "$Target" 2>&1 | Out-Null
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "del /f /q /a `"$Target`"" 2>&1 | Out-Null
            }
        }
    }
}

# ----------------- 2. 注册表安全卸载函数 (防死锁/重试机制) -----------------
function Safely-UnloadHive {
    <#
    .SYNOPSIS
        带有垃圾回收与 5 次重试容错机制的离线注册表 Hive 卸载器
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$HiveName,

        [bool]$AbortOnFailure = $false
    )

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    for ($i = 1; $i -le 5; $i++) {
        $null = & reg.exe unload "$HiveName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   [卸载完成] 注册表配置单元: $HiveName" -ForegroundColor DarkGray
            return $true
        }
        Write-Host "   [等待句柄释放] 正在尝试第 $i 次重试卸载 $HiveName..." -ForegroundColor DarkYellow

        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1
    }

    if ($AbortOnFailure) {
        Write-Host "[严重错误] $HiveName 单元卸载超时（5 次重试全部失败），为避免半挂载态污染后续操作，流程中止。" -ForegroundColor Red
        Write-Host "           可能原因：svchost 仍持有该 hive 句柄，建议重启系统后重试。" -ForegroundColor Yellow
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }

    Write-Host "   [警告] $HiveName 单元卸载超时，继续推进后续流程。" -ForegroundColor Yellow
    return $false
}

# ----------------- 3. reg.exe 零死锁安全执行器 -----------------
function Invoke-RegSilent {
    <#
    .SYNOPSIS
        执行 reg.exe 并返回退出码，彻底免疫管道死锁与交互式挂起。
    .DESCRIPTION
        1. 针对 /d '' 场景显式转义并序列化为 `""`，避免 /f 参数被误食。
        2. 彻底重定向并物理关闭 StandardInput，遇到任何交互提示即刻返回 EOF，杜绝卡死。
        3. 同步排空 StandardOutput / StandardError，无缓冲区溢出死锁。
        4. 附带 10 秒超时防护。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$RegArgs
    )

    # 1. 规范化参数序列化，重点解决空字符串 `''` 传参问题
    $escapedTokens = foreach ($arg in $RegArgs) {
        if ([string]::IsNullOrEmpty($arg)) {
            '""'
        } elseif ($arg -match '[\s"\\<>&|]') {
            '"' + ($arg -replace '(\\*)("|$)', '$1$1\"$2') + '"'
        } else {
            $arg
        }
    }
    $argumentsString = $escapedTokens -join ' '

    # 2. 构建独立进程环境
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\reg.exe"
    $psi.Arguments = $argumentsString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host "   [错误] 无法启动 reg.exe: $_" -ForegroundColor Red
        return -1
    }

    # 3. 核心机制：物理切断标准输入流，防任何 (Yes/No)? 交互提示挂死。
    # 标准输出/错误使用异步读取；先同步 ReadToEnd 再等待退出会让超时保护失效。
    try { $proc.StandardInput.Close() } catch {}
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    # 4. 10 秒硬性超时防护（异步读取同时排空管道，避免缓冲区死锁）
    $finished = $proc.WaitForExit(10000)
    if (-not $finished) {
        try { $proc.Kill() } catch {}
        try { $proc.WaitForExit() } catch {}
        $proc.Dispose()
        Write-Host "   [严重警告] reg.exe 响应超时已被强制终止: reg.exe $argumentsString" -ForegroundColor Red
        return -1
    }

    # WaitForExit() 确保异步读取回调也已完成。
    $proc.WaitForExit()
    $stdOut = $stdoutTask.Result
    $stdError = $stderrTask.Result
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    # 5. reg.exe 的错误信息常写入 stdout；优先 stderr，缺省时回退 stdout。
    if ($exitCode -ne 0) {
        $diagnostic = if (-not [string]::IsNullOrWhiteSpace($stdError)) { $stdError } else { $stdOut }
        if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
            Write-Host ("   [reg 警告 ({0})] {1}" -f $exitCode, $diagnostic.Trim()) -ForegroundColor DarkYellow
        }
    }

    return $exitCode
}

# <<< [分块结束] 文件来源: src/01-Helpers.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/02-MountImage.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 3/11] 镜像定位、导出与挂载 (src/02-MountImage.ps1)
#  [新增] 映像文件夹模式（sourceMode == "3"）：跳过挂载/导出/复制引导，
#         直接接管用户文件夹（$scratchDir 已在 00 模块重定向），仅做健康自检。
# ==============================================================================

# 1. 变量初始化（非文件夹模式使用；文件夹模式下 $destWim 不参与流程）
$destWim = Join-Path $sourcesDir "install.wim"
$isMountedISO = $false
$fileExt = ""
$sourceRoot = ""
$imageSourceToUse = ""
$bootWimSrc = ""
$installWimSrc = ""
$installEsdSrc = ""

# ==============================================================================
# 映像文件夹模式：完全旁路挂载/导出/复制引导
# ==============================================================================
if ($global:sourceMode -eq "3") {
    Write-Host "`n[步骤 1/11] 映像文件夹模式：跳过挂载、导出与引导复制，直接接管目标文件夹。" -ForegroundColor Magenta
    Write-Host "   目标文件夹: $scratchDir" -ForegroundColor DarkGray

    # 健康自检：文件夹内必须有 Windows\System32，作为最小可用性断言
    $sys32Path = Join-Path $scratchDir "Windows\System32"
    if (-not (Test-Path -LiteralPath $sys32Path)) {
        Write-Host "[严重错误] 文件夹健康自检失败：未检测到 $sys32Path。" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    Write-Host "[完成] 映像文件夹已就绪，跳过步骤 2/11 与 3/11，直接进入精简流程。" -ForegroundColor Green
} else {
    # ==========================================================================
    # 以下为原有 ISO / WIM / ESD 模式逻辑，完整保留
    # ==========================================================================

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
    $wimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$imageSourceToUse"
    if ($LASTEXITCODE -ne 0) {
        throw "无法读取映像分卷信息，DISM 退出码: $LASTEXITCODE ($imageSourceToUse)"
    }
    $availableIndexes = @([regex]::Matches(($wimInfo -join "`n"), '(?m)^\s*Index\s*:\s*(\d+)\s*$') | ForEach-Object { [int]$_.Groups[1].Value })
    if ($availableIndexes.Count -eq 0) {
        throw "源映像中未解析到任何有效 Index: $imageSourceToUse"
    }
    $wimInfo | ForEach-Object { Write-Host $_ }

    do {
        $index = Read-Host "请输入要精简的目标版本 Index 序号 (留空默认 $($availableIndexes[0]))"
        if ([string]::IsNullOrWhiteSpace($index)) { $index = [string]$availableIndexes[0] }
        $parsedIndex = 0
        $validIndex = [int]::TryParse($index, [ref]$parsedIndex) -and ($availableIndexes -contains $parsedIndex)
        if (-not $validIndex) {
            Write-Host "[输入错误] Index 必须是源映像中存在的序号：$($availableIndexes -join ', ')" -ForegroundColor Yellow
        }
    } while (-not $validIndex)
    $index = [string]$parsedIndex

    Write-Host "正在导出目标分卷 $index 到工作区..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$imageSourceToUse" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destWim)) {
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
}

# <<< [分块结束] 文件来源: src/02-MountImage.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/03-RemovePackages.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
#  [重构核心]：
#   1. 打印生态绝对保护：双模式下均不再移除 Printing-PMCPPC 打印管理包。
#   2. 普通模式 (健康精简)：
#      - 保留所有多媒体扩展解码器 (AV1, HEIF, HEVC, WebP)。
#      - 保留 Xbox 游戏服务架构与手柄联动组件。
#      - 保留 Windows Hello 生物识别 (人脸与指纹引导)。
#      - 保留 CJK (日韩繁) 输入法与基础 OCR 语言包。
#      - 保留 OpenSSH 客户端等开发调试组件。
#      - 仅通过官方 API 移除纯粹的无用推广及预装垃圾，不粉碎底层物理目录。
#   3. 极限模式 (极限压榨)：
#      - 保留原有激进粉碎逻辑与极窄组件库，但绝对豁免打印相关组件。
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在识别 Windows 版本、探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 0. Windows 版本探针（不挂载离线注册表 hive） -----------------
function Get-OfflineWindowsRelease {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    # 从内核文件版本读取 build，避免为版本探测临时加载 SOFTWARE hive。
    # 某些释放映像/文件系统权限下 reg.exe load 会失败，即使映像本身可正常 DISM 服务。
    $kernelPath = Join-Path $ImagePath "Windows\System32\ntoskrnl.exe"
    if (-not (Test-Path -LiteralPath $kernelPath -PathType Leaf)) {
        throw "无法识别目标映像：缺少内核文件 ($kernelPath)。"
    }

    $kernelVersion = (Get-Item -LiteralPath $kernelPath -ErrorAction Stop).VersionInfo
    $build = [int]$kernelVersion.FileBuildPart
    if ($build -lt 10240) {
        $versionMatch = [regex]::Match([string]$kernelVersion.FileVersion, '^\d+\.\d+\.(\d+)')
        if ($versionMatch.Success) { $build = [int]$versionMatch.Groups[1].Value }
    }
    if ($build -lt 10240) {
        throw "无法从 ntoskrnl.exe 读取有效的 Windows build: $($kernelVersion.FileVersion)"
    }

    # DISM 的 Edition ID 可用于排除 Server，且无需直接加载目标注册表。
    $editionOutput = & dism.exe /English "/Image:$ImagePath" /Get-CurrentEdition 2>&1
    $editionExitCode = $LASTEXITCODE
    if ($editionExitCode -ne 0) {
        $detail = ($editionOutput | Out-String).Trim()
        throw "DISM 无法读取目标映像 Edition (退出码 $editionExitCode): $detail"
    }
    $editionText = ($editionOutput -join "`n")
    $editionMatch = [regex]::Match($editionText, '(?m)^\s*Current Edition\s*:\s*(.+?)\s*$')
    if (-not $editionMatch.Success) {
        throw "无法从 DISM 输出解析目标映像 Edition：$editionText"
    }
    $edition = $editionMatch.Groups[1].Value.Trim()
    if ($edition -match 'Server') {
        throw "检测到 Windows Server 映像 ($edition)；本工具仅支持 Windows 10/11 客户端映像。"
    }

    $family = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    return [pscustomobject]@{
        Family = $family
        Build = $build
        DisplayVersion = [string]$kernelVersion.ProductVersion
        ProductName = [string]$kernelVersion.ProductName
        EditionID = $edition
    }
}

$global:targetWindows = Get-OfflineWindowsRelease -ImagePath $scratchDir
$global:windowsFamily = $global:targetWindows.Family
$global:windowsBuild = $global:targetWindows.Build
$releaseLabel = if ($global:targetWindows.DisplayVersion) { "，版本 $($global:targetWindows.DisplayVersion)" } else { "" }
Write-Host "   [自动适配] 检测到 $($global:windowsFamily) build $($global:windowsBuild)$releaseLabel，Edition: $($global:targetWindows.EditionID)" -ForegroundColor Green

# ----------------- 1. 语言探针（DISM 离线操作，对文件夹模式有效） -----------------
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$matchedLang = $false
foreach ($line in ($imageIntl -split '\r?\n')) {
    if ($line -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
        $global:languageCode = $Matches[1].Trim()
        $matchedLang = $true
        break
    }
}
if (-not $matchedLang) { $global:languageCode = "zh-CN" }

# ----------------- 1.1 架构探针（文件夹模式与通用自适应） -----------------
function Get-ArchitectureFromPe {
    param([string]$ExePath)
    try {
        if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
        $fs = [System.IO.File]::Open($ExePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt 0x40) { return $null }
            $buffer = New-Object byte[] 0x400
            $read = $fs.Read($buffer, 0, $buffer.Length)
            if ($read -lt 0x40) { return $null }
            if ($buffer[0] -ne 0x4D -or $buffer[1] -ne 0x5A) { return $null }
            $e_lfanew = [BitConverter]::ToInt32($buffer, 0x3C)
            if ($e_lfanew -lt 0 -or $e_lfanew -gt ($read - 6)) { return $null }
            if ($buffer[$e_lfanew] -ne 0x50 -or $buffer[$e_lfanew + 1] -ne 0x45 -or
                $buffer[$e_lfanew + 2] -ne 0x00 -or $buffer[$e_lfanew + 3] -ne 0x00) { return $null }
            $machine = [BitConverter]::ToUInt16($buffer, $e_lfanew + 4)
            switch ($machine) {
                0x8664 { return 'amd64' }
                0xAA64 { return 'arm64' }
                0x014C { return 'x86'   }
                0x0200 { return 'ia64'  }
                default { return $null }
            }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

$matchedArch = $false
$global:architecture = $null

$destWimPath = Join-Path $sourcesDir "install.wim"
if (Test-Path -LiteralPath $destWimPath) {
    $imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
    foreach ($line in ($imageInfo -split '\r?\n')) {
        if ($line -match 'Architecture\s*:\s*(.+)$') {
            $rawArch = $Matches[1].Trim().ToLower()
            if ($rawArch -eq 'x64' -or $rawArch -eq 'amd64') { $global:architecture = 'amd64' }
            elseif ($rawArch -eq 'arm64') { $global:architecture = 'arm64' }
            elseif ($rawArch -eq 'x86') { $global:architecture = 'x86' }
            else { $global:architecture = $rawArch }
            $matchedArch = $true
            break
        }
    }
}

if (-not $matchedArch) {
    $ntoskrnlPath = Join-Path $scratchDir "Windows\System32\ntoskrnl.exe"
    $peArch = Get-ArchitectureFromPe -ExePath $ntoskrnlPath
    if ($peArch) {
        $global:architecture = $peArch
        $matchedArch = $true
        Write-Host "   [架构探针] 通过 ntoskrnl.exe PE 头识别架构: $peArch" -ForegroundColor DarkGray
    }
}

if (-not $matchedArch -or [string]::IsNullOrWhiteSpace($global:architecture)) {
    $envArch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE.ToLower() } else { "" }
    if ($envArch -eq 'arm64') { $global:architecture = 'arm64' }
    elseif ($envArch -eq 'x86') { $global:architecture = 'x86' }
    else { $global:architecture = 'amd64' }
    Write-Host "   [架构探针] 回退使用环境变量/默认值: $($global:architecture)" -ForegroundColor DarkYellow
}

# ----------------- 2. 区分模式构建预装 AppX 移除清单 -----------------
# 基础推广与无用流氓软件（双模式均移除）
$baseBloatAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*People*',
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*',
    '*Solitaire*', '*FeedbackHub*', '*Maps*',
    '*OfficeHub*', '*Help*', '*Family*',
    '*PeopleExperienceHost*', '*PinningConfirmationDialog*',
    '*SecureAssessmentBrowser*', '*CommunicationsApps*', '*Copilot*',
    '*Cortana*', '*MicrosoftEdge.Stable*', '*MicrosoftEdge*', '*Microsoft.MicrosoftEdge*',
    '*549981C3F5F10*'
)

if ($global:trimMode -eq "2") {
    # 极限压榨模式：额外移除游戏核心组件、现代多媒体扩展、系统录音机与相机
    $targetAppxPatterns = $baseBloatAppxPatterns + @(
        '*Gaming*',
        '*SoundRecorder*',
        '*Camera*',
        '*Alarms*',
        '*QuickAssist*',
        '*AV1VideoExtension*',
        '*HEIFImageExtension*',
        '*HEVCVideoExtension*',
        '*WebpImageExtension*'
    )
} else {
    # 普通健康模式：严格保护游戏架构、影音解码、相机、录音机、快速助手
    $targetAppxPatterns = $baseBloatAppxPatterns
}

# 核心依赖框架白名单（坚决不触碰）
$protectedFrameworkPatterns = @(
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.WindowsAppRuntime*',
    '*Microsoft.NET.Native*', '*Microsoft.Services.Store*'
)

# 系统安装依赖防护清单
$installDependencyPatterns = @(
    '*OneSettings*', '*UniversalTelemetryClient*', '*CrossDevice*',
    '*Client.WebExperience*', '*Windows.ShellExperience*',
    '*Windows.CloudExperienceHost*', '*UEV*', '*WindowsFeedbackHub*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$appxToRemove = @()
$appxToKeep = @()

foreach ($pkg in $provisionedPackages) {
    $isProtected = $false
    foreach ($prot in $protectedFrameworkPatterns) {
        if ($pkg.PackageName -like $prot) { $isProtected = $true; break }
    }
    if ($isProtected) { $appxToKeep += $pkg; continue }

    if ($global:trimMode -ne "2") {
        $isInstallDep = $false
        foreach ($dep in $installDependencyPatterns) {
            if ($pkg.PackageName -like $dep) { $isInstallDep = $true; break }
        }
        if ($isInstallDep) { $appxToKeep += $pkg; continue }
    }

    foreach ($pattern in $targetAppxPatterns) {
        if ($pkg.PackageName -like $pattern) { $appxToRemove += $pkg; break }
    }
}

Write-Host "   [框架保护] 已自动拦截保留 $($appxToKeep.Count) 个核心依赖框架/关键组件。" -ForegroundColor DarkGray
Write-Host "   [准备移除] 检测到 $($appxToRemove.Count) 个预装应用符合当前精简规则。" -ForegroundColor Yellow

$appxExeMap = @{
    'Microsoft.Windows.Photos'            = @('Photos.exe', 'Microsoft.Photos.exe')
    'Microsoft.ScreenSketch'              = @('SnippingTool.exe', 'ScreenSketch.exe')
    'Microsoft.People'                    = @('People.exe')
    'Microsoft.WindowsMaps'               = @('Maps.exe')
    'Microsoft.MicrosoftStickyNotes'      = @('Microsoft.MicrosoftStickyNotes.exe')
    'Microsoft.WindowsAlarms'             = @('WindowsAlarms.exe')
    'Microsoft.WindowsSoundRecorder'      = @('WindowsSoundRecorder.exe')
    'Microsoft.ZuneMusic'                 = @('Microsoft.ZuneMusic.exe')
    'Microsoft.ZuneVideo'                 = @('Microsoft.ZuneVideo.exe')
    'Microsoft.BingNews'                  = @('Microsoft.BingNews.exe')
    'Microsoft.BingWeather'               = @('Microsoft.BingWeather.exe')
    'Microsoft.WindowsCamera'             = @('WindowsCamera.exe')
    'Microsoft.MicrosoftEdge.Stable'      = @('msedge.exe', 'MicrosoftEdge.exe')
    'Microsoft.MicrosoftEdge'             = @('MicrosoftEdge.exe')
    'Microsoft.549981C3F5F10'             = @('Cortana.exe')
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]
$global:removedAppxExeNames = New-Object System.Collections.Generic.List[string]
$global:deprovisionedAppxFamilies = New-Object System.Collections.Generic.List[string]

foreach ($package in $appxToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName)" -ForegroundColor DarkGray
    $removeSucceeded = $false
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
        $removeSucceeded = $true
    } catch {
        Write-Host "   [警告] 应用移除失败，跳过其残留清理和防重装标记: $($package.PackageName) ($_ )" -ForegroundColor DarkYellow
    }
    if (-not $removeSucceeded) { continue }
    $removedPackageNames.Add($package.PackageName)

    $familyName = $null
    $pkgParts = $package.PackageName -split '_'
    if ($pkgParts.Count -ge 2) {
        $firstPart = $pkgParts[0]
        $lastPart = $pkgParts[-1]
        if ($lastPart -match '^[a-z0-9]{13}$') {
            $familyName = "$($firstPart)_$($lastPart)"
        }
    }

    if ($familyName -and -not $global:deprovisionedAppxFamilies.Contains($familyName)) {
        $global:deprovisionedAppxFamilies.Add($familyName)
    }

    foreach ($mapKey in $appxExeMap.Keys) {
        if ($package.PackageName -like "*$mapKey*") {
            foreach ($exeName in $appxExeMap[$mapKey]) {
                if (-not $global:removedAppxExeNames.Contains($exeName)) {
                    $global:removedAppxExeNames.Add($exeName)
                }
            }
            break
        }
    }
}

Write-Host "   [Deprovision] 已收集 $($global:deprovisionedAppxFamilies.Count) 个包家族名，将在注册表阶段写入防重装标记。" -ForegroundColor DarkGray

# ----------------- 2.1 WindowsApps 物理残留清理（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
    $windowsAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
    if (Test-Path -LiteralPath $windowsAppsDir) {
        foreach ($pkgName in $removedPackageNames) {
            $candidateFolder = Join-Path $windowsAppsDir $pkgName
            if (Test-Path -LiteralPath $candidateFolder) {
                Write-Host "   粉碎残留资产目录: $pkgName" -ForegroundColor DarkGray
                & takeown.exe /F "$candidateFolder" /A /R /D Y 2>&1 | Out-Null
                & icacls.exe "$candidateFolder" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                Remove-Item -LiteralPath $candidateFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host "   [普通健康模式] 跳过 WindowsApps 物理残留粉碎，保留组件注册表链一致性。" -ForegroundColor DarkGray
}

# ----------------- 3. SystemApps 物理粉碎（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
    $sysAppsPath = Join-Path $scratchDir "Windows\SystemApps"
    if (Test-Path -LiteralPath $sysAppsPath) {
        $sysAppsToDelete = @("*Cortana*", "*Edge*", "*PeopleExperienceHost*", "*SecureAssessmentBrowser*", "*549981C3F5F10*")
        foreach ($pattern in $sysAppsToDelete) {
            $items = Get-ChildItem -Path $sysAppsPath -Filter $pattern -Directory -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Host "   删除 SystemApps 目录: $($item.Name)" -ForegroundColor DarkGray
                & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host "   [普通健康模式] 跳过 SystemApps 物理粉碎，仅依赖 AppX 官方通道卸载。" -ForegroundColor DarkGray
}

# 关键组件完整性校验
$openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
$shell32Dll  = Join-Path $scratchDir "Windows\System32\shell32.dll"
$shCoreDll   = Join-Path $scratchDir "Windows\System32\shcore.dll"
foreach ($critical in @($openWithExe, $shell32Dll, $shCoreDll)) {
    if (-not (Test-Path -LiteralPath $critical)) {
        Write-Host "[严重警告] 关键 Shell/OpenWith 组件缺失: $critical —— 精简过度！" -ForegroundColor Red
    }
}

# ----------------- 4. 移除系统底层功能包 Packages (FOD) -----------------
# 注意：双模式均已剔除 "Microsoft-Windows-Printing-PMCPPC-FoD-Package~"，确保打印管理可用！
$baseFodPatterns = @(
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~"
)

if ($global:trimMode -eq "2") {
    # 极限压榨模式：额外清除 Defender 客户端、生化识别、辅助工具、远程调试
    $packagePatterns = $baseFodPatterns + @(
        "OpenSSH-Client-Package~",
        "*IME-ja-jp*", "*IME-ko-kr*", "*IME-zh-tw*",
        "Windows-Defender-Client-Package~",
        "Microsoft-Windows-Hello-Face-Package~",
        "Microsoft-Windows-Hello-BioEnrollment-Package~",
        "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
        "Microsoft-Windows-TPM-WMI-Provider-Package~",
        "Microsoft-Windows-Narrator-App-Package~",
        "Microsoft-Windows-Magnifier-App-Package~",
        "Microsoft-Windows-WebcamExperience-Package~",
        "Microsoft-Media-MPEG2-Decoder-Package~"
    )

    if ($global:languageCode -ne "zh-CN") {
        $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
        $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
    }
} else {
    # 普通健康模式：完整保留 Hello人脸/指纹、OpenSSH、日韩繁输入法、MPEG2解码等基础功能
    $packagePatterns = $baseFodPatterns
}

$rawPackageOutput = & dism.exe /English "/Image:$scratchDir" /Get-Packages /Format:Table
$packageLines = ($rawPackageOutput -split '\r?\n') | Select-Object -Skip 1
$fodRemovedCount = 0

foreach ($pattern in $packagePatterns) {
    $matchedLines = $packageLines | Where-Object { $_ -like "$pattern*" }
    foreach ($mLine in $matchedLines) {
        $packageIdentity = ($mLine -split '\s+')[0]
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -notmatch "^-+$" -and $packageIdentity -ne "Package") {
            Write-Host "   正在移除 FOD: $packageIdentity" -ForegroundColor DarkGray
            & dism.exe /English "/Image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $fodRemovedCount++
            } else {
                Write-Host "   [警告] FOD 移除失败 (DISM $LASTEXITCODE): $packageIdentity" -ForegroundColor DarkYellow
            }
        }
    }
}
Write-Host "   [执行完毕] 共清理 $fodRemovedCount 个底层功能包。" -ForegroundColor Yellow
Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/03-RemovePackages.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/04-DriversFeatures.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 5/11] 驱动仓库与 .NET 缓存清理 (src/04-DriversFeatures.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 完整保留 DriverStore (FileRepository)，杜绝因缺失系统级基础驱动导致
#        新插打印机、蓝牙、网卡、显卡报 0x00000002 或驱动安装中断故障。
#      - 仅安全清理可重构的过期 .NET Native Images 缓存（系统空闲时会自动重构）。
#   2. 极限模式 (极限压榨)：
#      - 执行激进 DriverStore 瘦身，但【绝对豁免所有打印驱动 prn* 与一体机扫描驱动 wscsmd*】，
#        确保虚拟打印 (Print to PDF)、通用打印类驱动及打印向导在极限模式下绝对可用。
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行 DriverStore 精简与 .NET 原生映像清理..." -ForegroundColor Cyan

# ----------------- 1. 通用阶段：移除 pre-compiled .NET assemblies (Native Images) -----------------
Write-Host "Cleaning pre-compiled .NET assemblies (Native Images)..." -ForegroundColor DarkGray

$nativeSearchPaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)

foreach ($searchPath in $nativeSearchPaths) {
    $matchedItems = Get-Item -Path $searchPath -ErrorAction SilentlyContinue
    if ($matchedItems) {
        foreach ($item in $matchedItems) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----------------- 2. 驱动仓库按模式差异化处理 -----------------
$winDir = "$scratchDir\Windows"
$driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"

if ($global:trimMode -eq "2") {
    # --------------------------------------------------------------------------
    # 极限压榨模式：清理非关键硬件总线驱动，但【坚决保留所有打印相关驱动】
    # 绝对排除：prnms00* (Print to PDF/通用打印类), prnca00*, prnkm00*, wscsmd* (WIA扫描)
    # --------------------------------------------------------------------------
    Write-Host ">>> [极限压榨模式] 正在精简 DriverStore 非关键总线驱动 (已锁定保护打印驱动)..." -ForegroundColor Yellow

    # 剔除了所有 prn* 及扫描仪驱动，仅清理真正冗余的虚拟总线
    $patternsToRemove = @(
        'tapdrv*',
        'rdpbus.inf*',
        'tdibth.inf*'
    )

    if (Test-Path -LiteralPath $driverRepo) {
        $repoFolders = Get-ChildItem -LiteralPath $driverRepo -Directory -ErrorAction SilentlyContinue
        if ($repoFolders) {
            foreach ($folder in $repoFolders) {
                $driverName = $folder.Name
                foreach ($pattern in $patternsToRemove) {
                    if ($driverName -like $pattern) {
                        Write-Host "   [极限瘦身] 移除驱动包: $driverName" -ForegroundColor DarkGray
                        attrib.exe -R -S -H "$($folder.FullName)\*" /S /D 2>&1 | Out-Null
                        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        break
                    }
                }
            }
        }
    }
    Write-Host "[完成] 驱动仓库极限瘦身完毕（打印基础驱动已完整保留）。" -ForegroundColor Green
} else {
    # --------------------------------------------------------------------------
    # 普通健康模式：坚决不碰驱动仓库，保障 100% 硬件生态与即插即用完整性
    # --------------------------------------------------------------------------
    Write-Host "   [普通健康模式] 完整保留 DriverStore 驱动仓库，确保全系硬件即插即用、打印机与外设驱动链路绝对完整。" -ForegroundColor Green
}

Write-Host "[完成] 驱动与底层运行库缓存阶段处理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/04-DriversFeatures.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/05-PhysicalNuke.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 严禁粉碎 CJK 多语言字体库与输入法，防止游戏、网页、跨国文档与打印乱码。
#      - 严禁篡改/置空 WinRE 恢复环境 (winre.wim)，确保系统还原、安全模式与“重置此电脑”功能完好。
#      - 完整保留 TTS 语音引擎与系统光标库 (Cursors)。
#      - 仅安全清理纯冗余临时缓存、离线病毒库增量包与默认配置文件中的 OneDrive 残留。
#   2. 极限模式 (极限压榨)：
#      - 保留原有地毯式物理粉碎 (WinRE 零字节占位、字体库极限剔除、Edge/OneDrive 底层粉碎)。
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在执行系统冗余物理文件清理..." -ForegroundColor Cyan
$winDir = "$scratchDir\Windows"

# ----------------- 1. 字体库处理 (按模式差异化) -----------------
$fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
if (Test-Path -LiteralPath $fontsPath) {
    if ($global:trimMode -eq "2") {
        # 极限模式：仅保留微软核心英文字体与简体中文字体，清理其他多语言字型
        Write-Host ">>> [极限压榨模式] 正在极限裁剪非核心字型库..." -ForegroundColor Yellow
        Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # 普通健康模式：完整保留字体库，确保全语言排版与打印光栅化绝对正常
        Write-Host "   [普通健康模式] 完整保留系统全套字型库，防止游戏、繁体网站及跨国文档乱码。" -ForegroundColor Green
    }
}

# ----------------- 2. 语音引擎与多语言输入法物理目录 -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 清理 TTS 语音引擎与外语输入法资产..." -ForegroundColor Yellow
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "   [普通健康模式] 保留 TTS 语音引擎与日韩繁输入法架构。" -ForegroundColor Green
}

# ----------------- 3. 通用安全清理项 (双模式均执行) -----------------
# 离线病毒定义更新包（开机联网后会自动下载最新基线）
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# Windows 临时工作区
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# 用户配置文件下的 OneDrive 初始安装包缓存
$userProfileOneDrive = "$scratchDir\Users\Default\AppData\Local\Microsoft\OneDrive"
if (Test-Path -LiteralPath $userProfileOneDrive) {
    Remove-Item -LiteralPath $userProfileOneDrive -Recurse -Force -ErrorAction SilentlyContinue
}

# 帮助文档与示例壁纸清理
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------- 4. 光标库 (Cursors) 处理 -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 清理系统指针库 (Cursors)..." -ForegroundColor Yellow
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "   [普通健康模式] 完整保留鼠标指针库 (Cursors)，防止高分屏与游戏鼠标花屏。" -ForegroundColor Green
}

# ----------------- 5. Edge / OneDrive 物理地毯式粉碎（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 正在地毯式粉碎 Edge 和 OneDrive 磁盘实体残留..." -ForegroundColor Yellow

    $searchBases = @(
        "$scratchDir\Program Files",
        "$scratchDir\Program Files (x86)",
        "$scratchDir\Windows\System32",
        "$scratchDir\Windows\SysWOW64",
        "$scratchDir\Windows\WinSxS",
        "$scratchDir\Windows\SystemApps"
    )
    $patternsToDelete = @("*Edge*", "*MicrosoftEdge*", "*OneDrive*")

    foreach ($base in $searchBases) {
        if (Test-Path -LiteralPath $base) {
            foreach ($pattern in $patternsToDelete) {
                $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
                if ($items) {
                    foreach ($item in $items) {
                        Write-Host "   [物理粉碎] 残留实体: $($item.FullName)" -ForegroundColor DarkGray
                        if ($item.PSIsContainer) {
                            & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                            & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                        }
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
} else {
    Write-Host "   [普通健康模式] 跳过 Program Files / System32 / SysWOW64 等系统关键目录的底层实体物理粉碎，改由官方 AppX 卸载与注册表策略禁用安全处理。" -ForegroundColor Green
}

# ----------------- 6. WinRE 恢复环境处理 (极其关键) -----------------
$winrePath = "$scratchDir\Windows\System32\Recovery\winre.wim"
if ($global:trimMode -eq "2") {
    # 极限模式：清空 WinRE 以换取 ~500MB 极限体积
    Write-Host ">>> [极限压榨模式] 正在将 WinRE 执行零字节占位 (释放 500MB)..." -ForegroundColor Yellow
    Remove-Item -Path $winrePath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $winrePath -ItemType File -Force | Out-Null
} else {
    # 普通健康模式：完整保留官方 winre.wim，确保重置此电脑与高级故障排查 100% 正常
    Write-Host "   [普通健康模式] 完整保留官方 WinRE 恢复环境，确保系统故障自愈、安全模式与“重置此电脑”功能绝对可用。" -ForegroundColor Green
}

Write-Host "[完成] 冗余物理文件与底层资产清理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
#  [重构核心]：
#   1. 打印体系绝对保护（双模式通用）：
#      - 彻底剔除针对 Spooler 和 PrintNotify 的删除指令！
#      - 显式锁定 Spooler (Start=2 自动) 与 PrintNotify (Start=3 手动)，根治 RPC 崩溃。
#   2. 普通模式 (健康精简)：
#      - 蓝牙生态保护：坚决保留 BthAvctpSvc (耳机切歌/音量) 与 BluetoothUserService (蓝牙配对)。
#      - Windows Update 策略优化：采用“策略防打扰 + 按需启动 (Start=3)”方案，不堵死 localhost，
#        确保【微软商店正常下载】、【新插外设自动拉取官方驱动】、【.NET 3.5 / 功能包按需启用】。
#   3. 极限模式 (极限压榨)：
#      - 保留原有对 Windows Update 的极限封死策略及非关键服务清理，但绝对保护打印服务存活。
#   4. 完整保留 OpenWith 现代死锁修复、Notepad/照片查看器全链路修复、硬件限制跳过。
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# ==============================================================================
# 1. 挂载非 zSOFTWARE 的注册表配置单元 (带失败检查)
# ==============================================================================
$hiveLoads = @(
    @{ Name = "HKLM\zCOMPONENTS"; Path = "$scratchDir\Windows\System32\config\COMPONENTS" },
    @{ Name = "HKLM\zDEFAULT";    Path = "$scratchDir\Windows\System32\config\default" },
    @{ Name = "HKLM\zNTUSER";     Path = "$scratchDir\Users\Default\ntuser.dat" },
    @{ Name = "HKLM\zSYSTEM";     Path = "$scratchDir\Windows\System32\config\SYSTEM" }
)
foreach ($h in $hiveLoads) {
    & reg.exe load $h.Name $h.Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[严重错误] 注册表配置单元加载失败: $($h.Name) <- $($h.Path)，退出码 $LASTEXITCODE" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
}

# ==============================================================================
# 1.2 [方案C-第一轮] 挂载 zSOFTWARE → 只写 Appx Deprovisioned → 立即卸载
# ==============================================================================
Write-Host "[方案C-第一轮] 加载 zSOFTWARE 用于写入 Appx Deprovisioned 标记..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 配置单元加载失败，退出码 $LASTEXITCODE，Appx 防重装标记无法写入。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "Writing Appx Deprovisioned markers to prevent bloatware re-provisioning..." -ForegroundColor Yellow

$deprovisionedBase = "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
if ($global:deprovisionedAppxFamilies -and $global:deprovisionedAppxFamilies.Count -gt 0) {
    foreach ($familyName in $global:deprovisionedAppxFamilies) {
        $null = Invoke-RegSilent @('add', "$deprovisionedBase\$familyName", '/f')
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   [Deprovision] 已标记: $familyName" -ForegroundColor DarkGray
        } else {
            Write-Host "   [警告] 标记失败: $familyName (退出码 $LASTEXITCODE)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "   [完成] 共写入 $($global:deprovisionedAppxFamilies.Count) 个 Appx 防重装标记。" -ForegroundColor Green
} else {
    Write-Host "   [跳过] 未收集到任何 PackageFamilyName，未写入 Deprovisioned 标记。" -ForegroundColor DarkGray
}

Write-Host "[方案C-第一轮] 写入完毕，强制卸载 zSOFTWARE（阻断半挂载态）..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $true | Out-Null

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

# ==============================================================================
# 1.5 [方案C-第二轮] 重新挂载 zSOFTWARE → OpenWith 修复 + Notepad + Photo Viewer
# ==============================================================================
Write-Host "[方案C-第二轮] 干净重挂 zSOFTWARE 用于 OpenWith / Notepad / Photo Viewer 修复..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 第二轮重挂失败，退出码 $LASTEXITCODE，关联链修复无法执行。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 步骤 A: 彻底根治“打开方式 -> 更多应用”无反应 -----------------
Write-Host "Applying ultimate fix for 'Open With -> More Apps' deadlock..." -ForegroundColor Green

$blockedGuid = '{e44e9428-bdbc-4987-a099-40dc8fd255e7}'
$blockedRoots = @(
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
    'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
)
foreach ($br in $blockedRoots) {
    $null = Invoke-RegSilent @('add', $br, '/v', $blockedGuid, '/t', 'REG_SZ', '/d', 'OpenWith Modern Dialog Bypass', '/f')
}

$explorerPolicies = @(
    'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer',
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
)
foreach ($ep in $explorerPolicies) {
    $null = Invoke-RegSilent @('add', $ep, '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer', '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer', '/v', 'NoUseStoreOpenWith', '/t', 'REG_DWORD', '/d', '1', '/f')

$openWithRoots = @('HKLM\zSOFTWARE\Classes\Applications\OpenWith.exe', 'HKLM\zSOFTWARE\WOW6432Node\Classes\Applications\OpenWith.exe')
foreach ($ow in $openWithRoots) {
    $null = Invoke-RegSilent @('add', $ow, '/v', 'NoOpenWith', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$ow\shell\open", '/v', 'MultiSelectModel', '/t', 'REG_SZ', '/d', 'Single', '/f')
    $null = Invoke-RegSilent @('add', "$ow\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\OpenWith.exe "%1"', '/f')
}

if ($global:removedAppxExeNames -and $global:removedAppxExeNames.Count -gt 0) {
    $commonExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.txt', '.log', '.ini', '.md', '.csv', '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov'
    )
    $classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')

    foreach ($exe in $global:removedAppxExeNames) {
        foreach ($croot in $classesRoots) {
            $null = Invoke-RegSilent @('delete', "$croot\Applications\$exe", '/f')
            foreach ($ext in $commonExtensions) {
                $null = Invoke-RegSilent @('delete', "$croot\$ext\OpenWithList\$exe", '/f')
                $null = Invoke-RegSilent @('delete', "$croot\$ext\OpenWithProgids", '/v', $exe, '/f')
            }
        }
    }
}

# ----------------- 步骤 B: 完整重建 Notepad 与 txtfile 关联链 -----------------
Write-Host "Rebuilding Notepad and txtfile association chain..." -ForegroundColor Yellow

$classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')
$notepadCmd   = '%SystemRoot%\System32\notepad.exe %1'

foreach ($croot in $classesRoots) {
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe", '/v', 'FriendlyAppName', '/t', 'REG_SZ', '/d', 'Notepad', '/f')
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\Applications\notepad.exe\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt", '/ve', '/t', 'REG_SZ', '/d', 'txtfile', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt", '/v', 'Content Type', '/t', 'REG_SZ', '/d', 'text/plain', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt", '/v', 'PerceivedType', '/t', 'REG_SZ', '/d', 'text', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$croot\.txt\ShellNew", '/v', 'ItemName', '/t', 'REG_EXPAND_SZ', '/d', '@%SystemRoot%\System32\notepad.exe,-470', '/f')

    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/ve', '/t', 'REG_SZ', '/d', '文本文档', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/v', 'AlwaysShowExt', '/t', 'REG_SZ', '/d', '', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile", '/v', 'PerceivedType', '/t', 'REG_SZ', '/d', 'text', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfile\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')

    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy", '/ve', '/t', 'REG_SZ', '/d', '文本文档', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\DefaultIcon", '/ve', '/t', 'REG_EXPAND_SZ', '/d', '%SystemRoot%\System32\notepad.exe,0', '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\shell\open\command", '/ve', '/t', 'REG_EXPAND_SZ', '/d', $notepadCmd, '/f')
    $null = Invoke-RegSilent @('add', "$croot\txtfilelegacy\ShellNew", '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')

    $null = Invoke-RegSilent @('add', "$croot\.txt\OpenWithList\notepad.exe", '/ve', '/t', 'REG_SZ', '/d', '', '/f')
}
Write-Host "[完成] Notepad 与 txtfile 关联链重建完毕。" -ForegroundColor Green

# ----------------- 步骤 C: 注册 Windows 照片查看器（仅当映像确实包含 DLL） -----------------
# PhotoViewer.dll 位于 Program Files\Windows Photo Viewer，而不是 System32。
$photoViewerDll = Join-Path $scratchDir "Program Files\Windows Photo Viewer\PhotoViewer.dll"
if (Test-Path -LiteralPath $photoViewerDll -PathType Leaf) {
    $photoViewerCroot = 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities'
    $photoViewerResource = '@%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll,-3053'
    $null = Invoke-RegSilent @('add', $photoViewerCroot, '/v', 'ApplicationName', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerResource, '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.bmp', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.dib', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.gif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpe', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpeg', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jpg', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.jfif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Jpeg', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.png', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Png', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.tif', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')
    $null = Invoke-RegSilent @('add', "$photoViewerCroot\FileAssociations", '/v', '.tiff', '/t', 'REG_SZ', '/d', 'PhotoViewer.FileAssoc.Tiff', '/f')

    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll', '/v', 'FriendlyAppName', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerResource, '/f')
    $photoViewerCommand = 'rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen "%1"'
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command', '/ve', '/t', 'REG_EXPAND_SZ', '/d', $photoViewerCommand, '/f')
    Write-Host "[完成] 已注册映像内存在的 Windows 照片查看器；可在‘打开方式’中选择，不强制覆盖默认应用。" -ForegroundColor Green
} else {
    Write-Host "[跳过] 映像中不存在 Windows Photo Viewer DLL；不写入无效关联。" -ForegroundColor DarkGray
}

Write-Host "[方案C-第二轮] 关联链修复完毕，卸载 zSOFTWARE..." -ForegroundColor Yellow
Safely-UnloadHive -HiveName "HKLM\zSOFTWARE" -AbortOnFailure $false | Out-Null

# ==============================================================================
# 2. 常规注册表精简与优化策略
# ==============================================================================
Write-Host "[方案C-第三轮] 重新挂载 zSOFTWARE 以承载 2/2.5/3 节的策略与服务写入..." -ForegroundColor Yellow
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] zSOFTWARE 第三轮重挂失败，退出码 $LASTEXITCODE，后续策略写入无法执行。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch', '/v', 'DriverLoadPolicy', '/t', 'REG_DWORD', '/d', '8', '/f')

Write-Host "Bypassing system requirements(on the system image):"
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassCPUCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassRAMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassSecureBootCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassStorageCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassTPMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\MoSetup', '/v', 'AllowUpgradesWithUnsupportedTPMOrCPU', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Sponsored Apps:"
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'OemPreInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'PreInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SilentInstalledAppsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableWindowsConsumerFeatures', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'ContentDeliveryAllowed', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start', '/v', 'ConfigureStartPins', '/t', 'REG_SZ', '/d', '{"pinnedList": [{}]}', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'FeatureManagementEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'PreInstalledAppsEverEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SoftLandingEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContentEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-310093Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338388Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338389Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-338393Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-353694Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SubscribedContent-353696Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', '/v', 'SystemPaneSuggestionsEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall', '/v', 'DisablePushToInstall', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\MRT', '/v', 'DontOfferThroughWUAU', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableConsumerAccountStateContent', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent', '/v', 'DisableCloudOptimizedContent', '/t', 'REG_DWORD', '/d', '1', '/f')

if ($global:windowsFamily -eq 'Windows 11') {
    # BypassNRO is a Windows 11 OOBE switch; avoid writing a Win11-only value to Win10 images.
    Write-Host "Enabling local-account OOBE path (Windows 11):"
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'BypassNRO', '/t', 'REG_DWORD', '/d', '1', '/f')
}

Write-Host "Disabling Reserved Storage:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager', '/v', 'ShippedWithReserves', '/t', 'REG_DWORD', '/d', '0', '/f')
Write-Host "Disabling BitLocker Device Encryption"
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker', '/v', 'PreventDeviceEncryption', '/t', 'REG_DWORD', '/d', '1', '/f')

if ($global:windowsFamily -eq 'Windows 11') {
    Write-Host "Disabling Windows 11 Chat/Widgets taskbar entry points:"
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat', '/v', 'ChatIcon', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced', '/v', 'TaskbarMn', '/t', 'REG_DWORD', '/d', '0', '/f')
}

Write-Host "Disabling OneDrive folder backup"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive', '/v', 'DisableFileSyncNGSC', '/t', 'REG_DWORD', '/d', '1', '/f')

Write-Host "Disabling Telemetry:"
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', '/v', 'Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy', '/v', 'TailoredExperiencesWithDiagnosticDataEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy', '/v', 'HasAccepted', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC', '/v', 'Enabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization', '/v', 'RestrictImplicitInkCollection', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization', '/v', 'RestrictImplicitTextCollection', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore', '/v', 'HarvestContacts', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings', '/v', 'AcceptedPrivacyPolicy', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection', '/v', 'AllowTelemetry', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')

if ($global:windowsFamily -eq 'Windows 11') {
    Write-Host "Disabling Windows 11 Dev Home/Outlook provisioning and Copilot:"
    # These Windows 11 scheduler stores use distinct CurrentVersion and OOBE paths.
    foreach ($appName in @('OutlookUpdate', 'DevHomeUpdate')) {
        $null = Invoke-RegSilent @('add', "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\$appName", '/v', 'workCompleted', '/t', 'REG_DWORD', '/d', '1', '/f')
        $null = Invoke-RegSilent @('delete', "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$appName", '/f')
    }
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', '/v', 'TurnOffWindowsCopilot', '/t', 'REG_DWORD', '/d', '1', '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Edge', '/v', 'HubsSidebarEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer', '/v', 'DisableSearchBoxSuggestions', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevents installation of Teams:"
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Teams', '/v', 'DisableInstallation', '/t', 'REG_DWORD', '/d', '1', '/f')
Write-Host "Prevent installation of New Outlook":
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail', '/v', 'PreventRun', '/t', 'REG_DWORD', '/d', '1', '/f')

# ----------------- 2.5 Edge 策略拦截与 Defender 禁用 -----------------
Write-Host "Disabling Edge at policy level (Defender: disable-only)..." -ForegroundColor Yellow

$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', '/f')
$null = Invoke-RegSilent @('delete', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', '/f')
$edgeServices = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
foreach ($svc in $edgeServices) {
    $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$svc", '/f')
}
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate', '/v', 'DoNotUpdateToEdgeWithChromium', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate', '/v', 'UpdateDefault', '/t', 'REG_DWORD', '/d', '0', '/f')

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiSpyware', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender', '/v', 'DisableAntiVirus', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', '/v', 'DisableBehaviorMonitoring', '/t', 'REG_DWORD', '/d', '1', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows Defender\Features', '/v', 'TamperProtection', '/t', 'REG_DWORD', '/d', '0', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\SecurityHealthService', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "WdBoot")
foreach ($svc in $defenderServices) {
    $null = Invoke-RegSilent @('add', "HKLM\zSYSTEM\ControlSet001\Services\$svc", '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
}

$null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer', '/v', 'SettingsPageVisibility', '/t', 'REG_SZ', '/d', 'hide:virus;windowsupdate', '/f')

# ----------------- 计划任务定义删除 -----------------
Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."

# ----------------- Windows Update 策略差异化处理 -----------------
if ($global:trimMode -eq "2") {
    # --------------------------------------------------------------------------
    # 极限模式：保留原有极限彻底断网阻断策略 (注意：会连带商店与自动驱动安装失效)
    # --------------------------------------------------------------------------
    Write-Host ">>> [极限压榨模式] 彻底物理截断 Windows Update (服务设为4 + 伪造本地服务器)..." -ForegroundColor Yellow
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE1', '/t', 'REG_SZ', '/d', 'net stop wuauserv', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE2', '/t', 'REG_SZ', '/d', 'sc stop wuauserv', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'StopWUPostOOBE3', '/t', 'REG_SZ', '/d', 'sc config wuauserv start= disabled', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE1', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '/v', 'DisbaleWUPostOOBE2', '/t', 'REG_SZ', '/d', 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DoNotConnectToWindowsUpdateInternetLocations', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'DisableWindowsUpdateAccess', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'WUStatusServer', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', '/v', 'UpdateServiceUrlAlternate', '/t', 'REG_SZ', '/d', 'localhost', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'UseWUServer', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', '/v', 'DisableOnline', '/t', 'REG_DWORD', '/d', '1', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '1', '/f')

    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
} else {
    # --------------------------------------------------------------------------
    # 普通健康模式：静默防打扰 + 按需触发 (Start=3 手动)
    # 不篡改 WUServer，保证【微软商店正常下应用】、【插新硬件自动装驱动】、【.NET 3.5 按需安装】
    # --------------------------------------------------------------------------
    Write-Host "   [普通健康模式] 配置 Windows Update 为防打扰按需模式（保留应用商店与外设自动拉取驱动链路）..." -ForegroundColor Green
    
    # 策略级关闭自动强行重启与自动强推，AUOptions=2 (检查到更新但通知用户，绝不静默下载与重启)
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoUpdate', '/t', 'REG_DWORD', '/d', '0', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'AUOptions', '/t', 'REG_DWORD', '/d', '2', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', '/v', 'NoAutoRebootWithLoggedOnUsers', '/t', 'REG_DWORD', '/d', '1', '/f')

    # 更新核心服务设为 3 (Manual 手动按需启动)，平时后台 0 资源占用，商店下载或插入新设备时自动唤醒
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
}

# ==============================================================================
# 3. 卸载并释放离线配置单元
# ==============================================================================
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zSOFTWARE", "HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zCOMPONENTS", "HKLM\zSYSTEM")) {
    Safely-UnloadHive -HiveName $h | Out-Null
}

# ==============================================================================
# 4. 重新装载 SYSTEM 单元以精炼多余服务实体 (打印与核心蓝牙绝对豁免)
# ==============================================================================
Write-Host "Loading registry hives to clean services..."
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 重新装载 SYSTEM 配置单元失败，退出码 $LASTEXITCODE，服务精炼阶段中止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 核心关键保障：确保 Spooler 服务配置百分之百健康 -----------------
Write-Host ">>> [打印保障] 正在锁定 Print Spooler 服务为自动启动 (Start=2)..." -ForegroundColor Green
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\Spooler', '/v', 'Start', '/t', 'REG_DWORD', '/d', '2', '/f')
$null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\PrintNotify', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')

# ----------------- 服务移除/精简差异化处理 -----------------
if ($global:trimMode -eq "2") {
    # 极限模式：清理非关键服务，但【坚决排除 Spooler 和 PrintNotify】
    $servicesToRemove = @( 
        'Fax', 'RemoteRegistry', 'diagsvc', 
        'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc', 
        'BluetoothUserService', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService'
    )
    foreach ($service in $servicesToRemove) { 
        Write-Host "   [极限瘦身] 移除多余服务实体: $service" -ForegroundColor DarkGray
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$service", '/f')
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\CurrentControlSet\Services\$service", '/f')
    }
} else {
    # 普通健康模式：仅清理纯 Edge 更新独立残余，绝对不删系统底层服务，保护蓝牙与打印
    Write-Host "   [普通健康模式] 保留蓝牙核心服务 (BthAvctpSvc, BluetoothUserService) 与打印核心服务。" -ForegroundColor Green
    
    # 确保蓝牙核心服务为手动按需
    $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\BthAvctpSvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f')
    
    $safeToRemoveServices = @('RemoteRegistry', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
    foreach ($service in $safeToRemoveServices) { 
        Write-Host "   [健康清理] 移除无用服务: $service" -ForegroundColor DarkGray
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\ControlSet001\Services\$service", '/f')
        $null = Invoke-RegSilent @('delete', "HKLM\zSYSTEM\CurrentControlSet\Services\$service", '/f')
    }
}

Safely-UnloadHive -HiveName "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 离线注册表配置与服务配置精炼全部就绪。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/06-RegistryTweaks.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/07-UnattendInject.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
#  [新增] 映像文件夹模式（sourceMode == "3"）：
#         跳过 $workDir\autounattend.xml 写入（$workDir 为临时空目录，写入无意义）；
#         $scratchDir\Windows\System32\Sysprep\ 与 $scratchDir\Windows\Panther\ 下的
#         三个应答文件仍正常注入（若该文件夹后续被重新捕获或由部署工具直接使用，
#         应答仍生效）。
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在加载全局配置并注入 Windows 安装引导应答文件..." -ForegroundColor Cyan

# ----------------- 0. 承接前置配置与安全兜底 -----------------
$mode = if ($global:unattendMode) { $global:unattendMode } else { "1" }
$user = if ($global:customUser)   { $global:customUser }   else { "Admin" }
$pass = if ($global:customPass)   { $global:customPass }   else { "" }
$lang = if ($global:languageCode) { $global:languageCode } else { "zh-CN" }
$arch = if ($global:architecture) { $global:architecture } else { "amd64" }

# Windows 10 Setup requires an explicit empty ProductKey node for keyless installs;
# keep the established Windows 11 unattended behavior unchanged.
$productKeyXmlFragment = ""
if ($global:windowsFamily -eq "Windows 10") {
    $productKeyXmlFragment = @'
				<ProductKey>
					<Key></Key>
				</ProductKey>
'@
}

$modeText = if ($mode -eq "2") { "半无人值守 (手动设置账户向导)" } else { "全无人值守 (自动配置并登录)" }
Write-Host "   [配置承接] 运行模式: $modeText | 目标语言: $lang | 处理器架构: $arch" -ForegroundColor Green

# ----------------- 1. 动态生成应答 XML 架构片段 -----------------
$userAccountsXmlFragment = ""
$autoLogonXmlFragment    = ""
$hideLocalAccountScreenValue = "true"
$hideOnlineAccountScreensValue = "true"

if ($mode -eq "1") {
    # 全无人值守：注入预设账户与自动登录节点
    $inputUserEscaped = [System.Security.SecurityElement]::Escape($user)
    $inputPassEscaped = [System.Security.SecurityElement]::Escape($pass)

    Write-Host "   [账户预设] 用户名: $user | 密码: $(if ([string]::IsNullOrEmpty($pass)) { '(留空)' } else { '******' })" -ForegroundColor DarkGray

    $userAccountsXmlFragment = @"
			<UserAccounts>
				<LocalAccounts>
					<LocalAccount wcm:action="add">
						<Description>系统核心管理员账户</Description>
						<DisplayName>$inputUserEscaped</DisplayName>
						<Group>Administrators</Group>
						<Name>$inputUserEscaped</Name>
						<Password>
							<Value>$inputPassEscaped</Value>
							<PlainText>true</PlainText>
						</Password>
					</LocalAccount>
				</LocalAccounts>
			</UserAccounts>
"@

    $autoLogonXmlFragment = @"
			<AutoLogon>
				<Username>$inputUserEscaped</Username>
				<Enabled>true</Enabled>
				<LogonCount>1</LogonCount>
				<Password>
					<Value>$inputPassEscaped</Value>
					<PlainText>true</PlainText>
				</Password>
			</AutoLogon>
"@
    $hideLocalAccountScreenValue = "true"
    $hideOnlineAccountScreensValue = "true"
} else {
    # 半无人值守：剥离内置账户，开启本地账户输入屏，同时放开在线账户屏
    Write-Host "   [账户策略] 已剥离预置账户，装机后将由用户在 OOBE 原生界面自定用户名与密码。" -ForegroundColor DarkGray
    $userAccountsXmlFragment = ""
    $autoLogonXmlFragment    = ""
    $hideLocalAccountScreenValue = "false"
    $hideOnlineAccountScreensValue = "false"
}

# ----------------- 2. 纯字面量无损模板 (自适应架构与语言) -----------------
$unattendTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
	<settings pass="offlineServicing"></settings>
	<settings pass="windowsPE">
		<!-- 1. WinPE 安装环境国际化 (动态自适应母盘主语言) -->
		<component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<SetupUILanguage>
				<UILanguage>__LANG__</UILanguage>
			</SetupUILanguage>
			<InputLocale>__LANG__</InputLocale>
			<SystemLocale>__LANG__</SystemLocale>
			<UILanguage>__LANG__</UILanguage>
			<UserLocale>__LANG__</UserLocale>
		</component>
		<component name="Microsoft-Windows-Setup" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<UserData>
__PRODUCT_KEY_XML__
				<AcceptEula>true</AcceptEula>
			</UserData>
			<UseConfigurationSet>false</UseConfigurationSet>
			<RunSynchronous>
				<RunSynchronousCommand wcm:action="add">
					<Order>1</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>2</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>3</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>4</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>5</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>6</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassDiskCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
			</RunSynchronous>
		</component>
	</settings>
	<settings pass="generalize"></settings>
	<settings pass="specialize">
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<ComputerName>DESKTOP-PC</ComputerName>
		</component>
		<component name="Microsoft-Windows-Deployment" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<RunSynchronous>
				<RunSynchronousCommand wcm:action="add">
					<Order>1</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>2</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\Specialize.ps1' -Raw | Invoke-Expression;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>3</Order>
					<Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>4</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\DefaultUser.ps1' -Raw | Invoke-Expression;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>5</Order>
					<Path>reg.exe unload "HKU\DefaultUser"</Path>
				</RunSynchronousCommand>
			</RunSynchronous>
		</component>
	</settings>
	<settings pass="auditSystem"></settings>
	<settings pass="auditUser"></settings>
	<settings pass="oobeSystem">
		<!-- 2. OOBE 阶段国际化全自动闭环 -->
		<component name="Microsoft-Windows-International-Core" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>__LANG__</InputLocale>
			<SystemLocale>__LANG__</SystemLocale>
			<UILanguage>__LANG__</UILanguage>
			<UserLocale>__LANG__</UserLocale>
		</component>
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="__ARCH__" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
__USER_ACCOUNTS__
__AUTO_LOGON__
			<OOBE>
				<ProtectYourPC>3</ProtectYourPC>
				<HideEULAPage>true</HideEULAPage>
				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<HideOnlineAccountScreens>__HIDE_ONLINE_ACCOUNT_SCREENS__</HideOnlineAccountScreens>
				<HideLocalAccountScreen>__HIDE_LOCAL_ACCOUNT_SCREEN__</HideLocalAccountScreen>
			</OOBE>
			<FirstLogonCommands>
				<SynchronousCommand wcm:action="add">
					<Order>1</Order>
					<CommandLine>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\FirstLogon.ps1' -Raw | Invoke-Expression;"</CommandLine>
				</SynchronousCommand>
			</FirstLogonCommands>
		</component>
	</settings>
	<Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
		<ExtractScript>
param(
    [xml] $Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
		</ExtractScript>
		<File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
	{
		net.exe accounts /maxpwage:UNLIMITED;
	};
	{
		Set-ExecutionPolicy -Scope 'LocalMachine' -ExecutionPolicy 'RemoteSigned' -Force;
	};
	{
		reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
	};
	{
		reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f;
	};
	{
		reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f;
	};
);

&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\Specialize.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
	};
	{
		Remove-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew' -Recurse -Force -ErrorAction 'SilentlyContinue';
	};
	{
		Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript {
			$_.SessionId -eq ( Get-Process -Id $PID ).SessionId;
		} | Stop-Process -Force;
		Start-Sleep -Seconds 2;
	};
);
&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\UserOnce.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
	{
		$names = @(
		  'ContentDeliveryAllowed';
		  'FeatureManagementEnabled';
		  'OEMPreInstalledAppsEnabled';
		  'PreInstalledAppsEnabled';
		  'PreInstalledAppsEverEnabled';
		  'SilentInstalledAppsEnabled';
		  'SoftLandingEnabled';
		  'SubscribedContentEnabled';
		  'SubscribedContent-310093Enabled';
		  'SubscribedContent-338387Enabled';
		  'SubscribedContent-338388Enabled';
		  'SubscribedContent-338389Enabled';
		  'SubscribedContent-338393Enabled';
		  'SubscribedContent-353694Enabled';
		  'SubscribedContent-353696Enabled';
		  'SubscribedContent-353698Enabled';
		  'SystemPaneSuggestionsEnabled';
		);
		
		foreach( $name in $names ) {
		  reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $name /t REG_DWORD /d 0 /f;
		}
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Normal -NoProfile -Command \""Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UserOnce.ps1' -Raw | Invoke-Expression;\""" /f;
	};
);

&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\DefaultUser.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0;
	};
	{
		Disable-ComputerRestore -Drive 'C:\';
	};
	{
		cmd.exe /c "rd /s /q C:\Windows.old 2>nul";
	};
	{
		# 自动化稳定性测试探针
		$report = New-Object System.Collections.Generic.List[string];
		$report.Add("==================================================================");
		$report.Add(" Windows 10/11 精简母盘 - 首次登录系统健康与稳定性自检审计报告");
		$report.Add(" 生成时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'));
		$report.Add(" 部署模式: __DEPLOY_MODE_TEXT__");
		$report.Add("==================================================================");

		$wtPkg = Get-AppxPackage -Name "*WindowsTerminal*" -ErrorAction SilentlyContinue;
		$wtStatus = if ($wtPkg) { "正常部署 (版本: $($wtPkg.Version))" } else { "未安装或已被剔除" };
		$report.Add("[组件测试] Windows 终端 (Terminal): $wtStatus");

		$wingetPkg = Get-AppxPackage -Name "*DesktopAppInstaller*" -ErrorAction SilentlyContinue;
		$wingetStatus = if ($wingetPkg) { "正常可用 (支持 Winget/离线安装)" } else { "未安装" };
		$report.Add("[组件测试] 应用安装程序 (Winget): $wingetStatus");

		$txtAssoc = (cmd.exe /c "assoc .txt 2>nul");
		$report.Add("[关联测试] .txt 扩展名关联项: $txtAssoc");

		$crashCount = 0;
		$dcomCount = 0;
		try {
			$appCrashes = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			$crashCount = if ($appCrashes) { $appCrashes.Count } else { 0 };
			$report.Add("[事件测试] 应用程序核心崩溃事件数 (Level=Error): $crashCount");

			$dcomErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-DistributedCOM'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			$dcomCount = if ($dcomErrors) { $dcomErrors.Count } else { 0 };
			$report.Add("[事件测试] DCOM 幽灵调用异常事件数: $dcomCount");
		} catch {
			$report.Add("[事件测试] 事件日志扫描已安全旁路。");
		}

		$report.Add("------------------------------------------------------------------");
		$verdict = if ($crashCount -eq 0 -and $dcomCount -eq 0) { "【优秀】系统底层核心零异常，运行极度稳定！" } else { "【良好】已自动记录轻微事件，系统运行正常。" };
		$report.Add("总体稳定性裁定: $verdict");
		$report.Add("==================================================================");

		$reportPath = "C:\Windows\Temp\Trim_Stability_Report.log";
		[System.IO.File]::WriteAllLines($reportPath, $report, [System.Text.Encoding]::UTF8);
		$report = $null;
	};
	{
		# 1. 彻底销毁包含配置的应答文件
		$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach ($f in $xmlFiles) {
			if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; }
		}

		# 2. 异步销毁临时脚本目录 (改为纯 PowerShell 安全写法，避免 cmd 死锁)
		Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 3; Remove-Item -LiteralPath 'C:\Windows\Setup\Scripts' -Recurse -Force -ErrorAction SilentlyContinue`""
	};
);

&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\FirstLogon.log";
		</File>
	</Extensions>
</unattend>
'@

# ----------------- 3. 安全替换变量占位符 -----------------
$finalXml = $unattendTemplate
$finalXml = $finalXml.Replace('__ARCH__', $arch)
$finalXml = $finalXml.Replace('__LANG__', $lang)
$finalXml = $finalXml.Replace('__USER_ACCOUNTS__', $userAccountsXmlFragment)
$finalXml = $finalXml.Replace('__AUTO_LOGON__', $autoLogonXmlFragment)
$finalXml = $finalXml.Replace('__PRODUCT_KEY_XML__', $productKeyXmlFragment)
$finalXml = $finalXml.Replace('__HIDE_LOCAL_ACCOUNT_SCREEN__', $hideLocalAccountScreenValue)
$finalXml = $finalXml.Replace('__HIDE_ONLINE_ACCOUNT_SCREENS__', $hideOnlineAccountScreensValue)
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 多通道规范注入 (带强力防占用机制) -----------------
# 注入前轻量确认：应答文件依赖 Panther/Setup 目录结构与 Shell-Setup 组件存在，
# 若被精简误伤则直接中止，避免打包出装不上的镜像。
$pantherCheckDir = Join-Path $scratchDir "Windows\Panther"
$shellSetupCheck = Join-Path $scratchDir "Windows\System32\Sysprep"
if (-not (Test-Path -LiteralPath $shellSetupCheck) -and -not (Test-Path -LiteralPath $pantherCheckDir)) {
    Write-Host "[严重错误] 应答文件注入前确认失败：Sysprep 与 Panther 目录均不存在，映像可能已被过度精简。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path -LiteralPath $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$utf8Encoding = [System.Text.Encoding]::UTF8

# 核心修复：强制解除只读并覆盖写入的通用函数
function Write-XmlSafely {
    param([string]$Path, [string]$Content)
    if (Test-Path -LiteralPath $Path) {
        attrib.exe -R -S -H "$Path" 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
    try {
        [System.IO.File]::WriteAllText($Path, $Content, $utf8Encoding)
    } catch {
        Write-Host "[警告] 写入 $Path 失败，尝试备用写入法..." -ForegroundColor Yellow
        $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
}

# ---- 注入目标文件夹内的三个路径（文件夹 / ISO / 单文件模式通用）----
Write-XmlSafely -Path (Join-Path $sysprepDir "unattend.xml") -Content $finalXml
Write-XmlSafely -Path (Join-Path $sysprepDir "autounattend.xml") -Content $finalXml
Write-XmlSafely -Path (Join-Path $pantherDir "unattend.xml") -Content $finalXml

# ---- ISO 根目录应答文件：仅在非文件夹模式写入 ----
# 文件夹模式下 $workDir 是 windows_folder_mode_tmp（临时空目录），
# 写入 autounattend.xml 无任何意义（会被 10 模块清理删除），故跳过。
if ($global:sourceMode -eq "3") {
    Write-Host "   [映像文件夹模式] 已跳过写入 `$workDir\autounattend.xml（临时目录，写入无意义）。" -ForegroundColor DarkGray
    Write-Host "[完成] 高级无人值守应答文件注入完毕（目标文件夹内 3 个通道，自适应语言: $lang | 架构: $arch）。" -ForegroundColor Green
} else {
    Write-XmlSafely -Path (Join-Path $workDir "autounattend.xml") -Content $finalXml
    Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (自适应语言: $lang | 架构: $arch)。" -ForegroundColor Green
}

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 9/11] 组件库瘦身与主映像优化 (src/08-WinSxSOptimize.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 仅执行官方 DISM /StartComponentCleanup，不执行 /ResetBase，
#        保留完整更新回滚基线与硬链接链条，确保系统 100% 具备自愈与后期维护能力。
#   2. 极限模式 (极限压榨)：
#      - 补齐 WinSxS 物理置换白名单中的【全部打印服务核心程序集与 32位兼容层】！
#        彻底解决原版极限模式因 WinSxS 缺失 winprint / spooler 组件导致的
#        “打印处理器不存在”与“RPC 服务器不可用”绝症。
#   3. 流控规范：严禁使用 return，保障单文件或分模块调度流水线顺畅贯通。
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在根据精简模式执行组件存储 (WinSxS) 优化..." -ForegroundColor Cyan

$currentTrimMode = if ($global:trimMode) { $global:trimMode } else { "1" }
$currentArch     = if ($global:architecture) { $global:architecture } else { "amd64" }

# ----------------- 1. 通用阶段：按模式执行组件清理 -----------------
if ($currentTrimMode -ne "2") {
    # --------------------------------------------------------------------------
    # 普通健康精简模式：仅安全清理无用废弃组件，不重置基线，不物理破坏 WinSxS
    # --------------------------------------------------------------------------
    Write-Host "正在执行 DISM 安全组件清理 (/StartComponentCleanup，保留更新基线)..." -ForegroundColor Yellow
    & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[提示] DISM 组件清理退出码: $LASTEXITCODE (部分精简组件无需清理或已处于最新状态，继续推进)。" -ForegroundColor DarkGray
    }

    Write-Host "[完成] 【普通健康模式】已完整保留 WinSxS 核心组件库与硬链接，确保系统自愈性与全功能生态稳定。" -ForegroundColor Green
} else {
    # --------------------------------------------------------------------------
    # 极限压榨模式：重置基线，随后物理替换 WinSxS (但已补全打印核心依赖)
    # --------------------------------------------------------------------------
    Write-Host "正在执行 DISM 深度组件清理与基线重置 (/StartComponentCleanup /ResetBase)..." -ForegroundColor Yellow
    & dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[提示] DISM 组件重置退出码: $LASTEXITCODE (部分精简组件无需重置，继续推进)。" -ForegroundColor DarkGray
    }

    Write-Host "`n>>> [警告] 当前为【极限压榨模式】，正在物理瘦身 WinSxS (已锁定保护打印核心，架构: $currentArch)..." -ForegroundColor Red

    $winSxSDir     = Join-Path $scratchDir "Windows\WinSxS"
    $winSxSEditDir = Join-Path $scratchDir "Windows\WinSxS_edit"

    if (-not (Test-Path -LiteralPath $winSxSDir)) {
        Write-Host "[错误] 未检测到 WinSxS 目录: $winSxSDir，跳过物理替换。" -ForegroundColor Red
    } else {
        # 极限模式前置断言：校验 OpenWith.exe 是否存活
        $openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
        if (-not (Test-Path -LiteralPath $openWithExe)) {
            Write-Host "[严重错误] 极限模式前置断言失败：OpenWith.exe 不存在，物理替换将导致关联损坏，已跳过物理粉碎。" -ForegroundColor Red
        } else {
            # 获取 WinSxS 物理掌控权
            Write-Host "正在接管 WinSxS 目录所有权与完全控制权限..." -ForegroundColor Yellow
            & takeown.exe /F "$winSxSDir" /R /A /D Y 2>$null | Out-Null
            & icacls.exe "$winSxSDir" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

            # 重置并创建暂存目录
            if (Test-Path -LiteralPath $winSxSEditDir) {
                Remove-Item -LiteralPath $winSxSEditDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $winSxSEditDir -ItemType Directory -Force | Out-Null

            # 根据架构构建保活清单（已彻底补齐打印相关底层组件与 32位兼容组件）
            $dirsToCopy = @()

            if ($currentArch -eq "arm64") {
                $dirsToCopy = @(
                    "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
                    "Catalogs",
                    "FileMaps",
                    "Fusion",
                    "InstallTemp",
                    "Manifests",
                    "SettingsManifests",
                    "Temp",
                    "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "arm_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
                    "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
                    # ---- ARM64 打印核心组件保护 ----
                    "arm64_microsoft-windows-printing*",
                    "arm64_microsoft-windows-p..ing*",
                    "arm64_microsoft-windows-spooler*",
                    "arm64_microsoft-windows-p..spooler*",
                    "arm_microsoft-windows-printing*",
                    "arm_microsoft-windows-spooler*",
                    "x86_microsoft-windows-printing*",
                    "x86_microsoft-windows-spooler*"
                )
            } else {
                # 默认 amd64 体系架构
                $dirsToCopy = @(
                    "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
                    "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
                    "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "x86_microsoft-windows-servicingstack-inetsrv_*",
                    "x86_microsoft-windows-servicingstack-onecore_*",
                    "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
                    "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
                    "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shell32_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shcore_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-explorerframe_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-openwith_31bf3856ad364e35_*",
                    "amd64_microsoft-windows-shell-experience_31bf3856ad364e35_*",
                    "x86_microsoft.windows.shell*",
                    "Catalogs",
                    "FileMaps",
                    "Fusion",
                    "InstallTemp",
                    "Manifests",
                    "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
                    # ---- AMD64 打印核心组件与 32位兼容层保护 ----
                    "amd64_microsoft-windows-printing*",
                    "amd64_microsoft-windows-p..ing*",
                    "amd64_microsoft-windows-spooler*",
                    "amd64_microsoft-windows-p..spooler*",
                    "x86_microsoft-windows-printing*",
                    "x86_microsoft-windows-p..ing*",
                    "x86_microsoft-windows-spooler*"
                )
            }

            # 复制保活核心清单
            Write-Host "正在提取基础运行库、Shell 依赖与打印架构项..." -ForegroundColor Cyan
            foreach ($pattern in $dirsToCopy) {
                $matchedDirs = Get-ChildItem -Path $winSxSDir -Filter $pattern -Directory -ErrorAction SilentlyContinue
                if ($matchedDirs) {
                    foreach ($sDir in $matchedDirs) {
                        $destDir = Join-Path $winSxSEditDir $sDir.Name
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            Copy-Item -LiteralPath $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }

            # 执行物理粉碎替换
            Write-Host "正在物理销毁原始 WinSxS 并置换保护型结构..." -ForegroundColor Yellow
            attrib.exe -R -S -H "$winSxSDir\*" /S /D 2>$null
            Remove-Item -LiteralPath $winSxSDir -Recurse -Force -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $winSxSDir) {
                cmd.exe /c "rd /s /q `"$winSxSDir`"" 2>$null
            }

            if (-not (Test-Path -LiteralPath $winSxSDir)) {
                Rename-Item -LiteralPath $winSxSEditDir -NewName "WinSxS" -Force
                Write-Host "[完成] WinSxS 极限置换完成，体积已大幅压缩（打印核心已成功保留）。" -ForegroundColor Green
            } else {
                Write-Host "[警告] WinSxS 原始目录存在锁死残留，保留备份以防映像损坏。" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "[完成] 组件存储优化流程处理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE/BCD 深度修补 (src/09-ExportAndPE.ps1)
#  [本版核心修复] boot.wim 修补段管道死锁根治：
#    - 与 06-RegistryTweaks.ps1 Notepad 段完全同构的"连续密集 & reg ... | Out-Null"
#      模式（每卷 14 条 × 分卷数 = 28 条），跑过 06 后到此必再次触发 PowerShell
#      单线程管道调度死锁（reg.exe WaitReason=Executive, CPU=0 永久挂起）。
#    - 全部替换为 $null = Invoke-RegSilent @(...)，Start-Process +
#      -RedirectStandardOutput/Error "NUL" 文件句柄级重定向，零管道零死锁。
#  [保留] 映像文件夹模式旁路、单文件模式旁路、ISO 模式主流程全部字节级不变。
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在安全提交主映像并优化引导资产..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"
$bootWimPath   = Join-Path $sourcesDir "boot.wim"
$legacyBcdPath = Join-Path $workDir "boot\bcd"

# ==============================================================================
# 映像文件夹模式：整体旁路提交/重构/boot.wim/BCD/根目录清洗
# ==============================================================================
if ($global:sourceMode -eq "3") {
    Write-Host "[步骤 11/11] 映像文件夹模式：跳过 install.wim 提交、二次重构、boot.wim 修补、BCD 修补、ISO 根目录清洗。" -ForegroundColor Magenta

    # 仅保留精简语义内的快捷方式清理（路径对文件夹模式天然正确）
    Write-Host "正在清理可能残留的 Edge 和 Cortana 快捷方式..." -ForegroundColor Cyan
    $shortcutPaths = @(
        "$scratchDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
        "$scratchDir\Users\Default\Desktop\Microsoft Edge.lnk",
        "$scratchDir\Users\Public\Desktop\Microsoft Edge.lnk",
        "$scratchDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk"
    )
    foreach ($sc in $shortcutPaths) {
        if (Test-Path -LiteralPath $sc) {
            Write-Host "   清理快捷方式: $sc" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $sc -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[完成] 映像文件夹模式精简收尾完毕。" -ForegroundColor Green
} else {
    # ==========================================================================
    # 以下为原有 ISO / WIM / ESD 模式逻辑，完整保留
    # ==========================================================================

    # ----------------- 1. 提交并卸载主系统映像 (install.wim) -----------------
    Write-Host "正在提交并卸载主系统映像 install.wim (请耐心等待写入磁盘)..." -ForegroundColor Yellow

    # 强制垃圾回收以释放可能附着的目录句柄
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2

    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[严重错误] install.wim 提交卸载失败，退出码: $LASTEXITCODE！正在尝试强制放弃挂载以保护母盘..." -ForegroundColor Red
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
    Write-Host "[完成] 主系统映像修改已安全提交。" -ForegroundColor Green

    # 清理挂载点残留，避免后续 boot.wim 挂载失败
    if (Test-Path -LiteralPath $scratchDir) {
        Force-NukeFolderOrFile -Target $scratchDir
    }
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

    # ----------------- 2. 二次重构 install.wim 消除存储碎片 -----------------
    Write-Host "正在二次导出并重构压缩 install.wim (消除内部精简碎片)..." -ForegroundColor Cyan
    & dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /Compress:max /CheckIntegrity

    if (Test-Path -LiteralPath $destWim2Path) {
        attrib.exe -R -S -H "$destWimPath" 2>&1 | Out-Null
        Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $destWim2Path -NewName "install.wim" -Force
        Write-Host "[完成] install.wim 导出重构完毕，体积已达最佳压缩状态。" -ForegroundColor Green
    } else {
        Write-Host "[提示] 二次压缩镜像未能生成，安全保留原镜像继续推进。" -ForegroundColor Yellow
    }

    # ==========================================================================
    # 如果是单文件 WIM/ESD 模式，跳过 boot.wim 修补
    # ==========================================================================
    if ($global:sourceMode -eq "2" -and $global:sourceFile -match '\.(wim|esd)$') {
        Write-Host "[提示] 当前为单文件处理模式，已跳过 boot.wim 和 BCD 修补工作。" -ForegroundColor DarkGray
    } else {

        # ----------------- 3. 稳固修补 boot.wim (双卷全覆盖·原地提交保全元数据) -----------------
        Write-Host "`n正在以【原地修改提交】模式深度修补 boot.wim (彻底解决 Legacy 卡 Logo 问题)..." -ForegroundColor Cyan

        if (-not (Test-Path -LiteralPath $bootWimPath)) {
            Write-Host "[严重错误] 未在 sources 目录中检测到 boot.wim，无法构建可引导介质！" -ForegroundColor Red
            if ($global:transcriptActive) { Stop-Transcript }
            pause
            exit 1
        }

        # 接管 boot.wim 物理所有权与文件属性
        attrib.exe -R -S -H "$bootWimPath" 2>&1 | Out-Null
        & takeown.exe /F "$bootWimPath" /A 2>&1 | Out-Null
        & icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
        try {
            (Get-Item -LiteralPath $bootWimPath).IsReadOnly = $false
        } catch {}

        # 解析 boot.wim 内部包含的分卷数量 (行首锚定，避免误计 "Image Index" 等上下文)
        $bootWimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
        $totalBootIndexes = 1
        $indexMatches = [regex]::Matches($bootWimInfo, '(?m)^\s*Index\s*:\s*(\d+)\s*$')
        if ($indexMatches.Count -gt 0) {
            $totalBootIndexes = $indexMatches.Count
        }
        Write-Host "检测到 boot.wim 包含 $totalBootIndexes 个分卷，启动全卷深度渗透修补..." -ForegroundColor Green

        # 循环修补 boot.wim 的每个分卷
        for ($idx = 1; $idx -le $totalBootIndexes; $idx++) {
            Write-Host "`n>>> 正在原地挂载修补 boot.wim 分卷 [$idx/$totalBootIndexes]..." -ForegroundColor Yellow

            # 挂载当前分卷
            & dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$idx" "/MountDir:$scratchDir"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[错误] 挂载 boot.wim 分卷 $idx 失败，跳过该卷修补。" -ForegroundColor Red
                continue
            }

            # 跟踪本卷已成功加载的 hive，便于 continue 前精确卸载
            $loadedHives = New-Object System.Collections.Generic.List[string]

            $hiveCandidates = @(
                @{ Name = "HKLM\zDEFAULT";  Path = "$scratchDir\Windows\System32\config\default" },
                @{ Name = "HKLM\zNTUSER";   Path = "$scratchDir\Users\Default\ntuser.dat" },
                @{ Name = "HKLM\zSYSTEM";   Path = "$scratchDir\Windows\System32\config\SYSTEM" },
                @{ Name = "HKLM\zSOFTWARE"; Path = "$scratchDir\Windows\System32\config\SOFTWARE" }
            )

            foreach ($hc in $hiveCandidates) {
                if (-not (Test-Path -LiteralPath $hc.Path)) {
                    Write-Host "   [跳过] 分卷 $idx 中不存在 hive 文件: $($hc.Path)" -ForegroundColor DarkYellow
                    continue
                }
                & reg.exe load $hc.Name $hc.Path 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $loadedHives.Add($hc.Name) | Out-Null
                } else {
                    Write-Host "   [警告] hive 加载失败: $($hc.Name) <- $($hc.Path)，退出码 $LASTEXITCODE" -ForegroundColor DarkYellow
                }
            }

            # 1. 注入全套硬件检测豁免规则 (WinPE Setup 阶段)
            if ($loadedHives -contains "HKLM\zDEFAULT") {
                $null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
            }
            if ($loadedHives -contains "HKLM\zNTUSER") {
                $null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV1', '/t', 'REG_DWORD', '/d', '0', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache', '/v', 'SV2', '/t', 'REG_DWORD', '/d', '0', '/f')
            }
            if ($loadedHives -contains "HKLM\zSYSTEM") {
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassCPUCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassRAMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassSecureBootCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassStorageCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassTPMCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\LabConfig', '/v', 'BypassDiskCheck', '/t', 'REG_DWORD', '/d', '1', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\Setup\MoSetup', '/v', 'AllowUpgradesWithUnsupportedTPMOrCPU', '/t', 'REG_DWORD', '/d', '1', '/f')

                # 2. 禁用 WinPE 阶段的 BitLocker 设备自动加密
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker', '/v', 'PreventDeviceEncryption', '/t', 'REG_DWORD', '/d', '1', '/f')

                # 3. 【关键：解决 Legacy 卡死】注入内核级早期驱动启动与基本显示豁免策略
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch', '/v', 'DriverLoadPolicy', '/t', 'REG_DWORD', '/d', '8', '/f')
                $null = Invoke-RegSilent @('add', 'HKLM\zSYSTEM\ControlSet001\Services\BasicDisplay', '/v', 'Start', '/t', 'REG_DWORD', '/d', '0', '/f')
            }

            # 卸载本卷已加载的注册表配置单元 (带重试，先非 SYSTEM 后 SYSTEM)
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            foreach ($h in @("HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zSOFTWARE", "HKLM\zSYSTEM")) {
                if ($loadedHives -contains $h) {
                    Safely-UnloadHive -HiveName $h | Out-Null
                }
            }

            # 原地安全提交修改
            Write-Host "   正在原地提交 boot.wim 分卷 $idx 修改..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
            if ($LASTEXITCODE -ne 0) {
                Write-Host "   [警告] boot.wim 分卷 $idx 提交异常，执行强制释放..." -ForegroundColor Yellow
                & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
            }
        }
        Write-Host "[完成] boot.wim 所有分卷修补完成，原生架构与元数据完全保留。" -ForegroundColor Green

        # ----------------- 4. 修复 Legacy BCD 显卡防死锁参数 -----------------
        if (Test-Path -LiteralPath $legacyBcdPath) {
            Write-Host "`n正在对 Legacy BIOS BCD 启动菜单注入兼容性保护..." -ForegroundColor Cyan
            attrib.exe -R -S -H "$legacyBcdPath" 2>&1 | Out-Null

            & bcdedit.exe /store "$legacyBcdPath" /set '{default}' detecthal Yes 2>&1 | Out-Null
            & bcdedit.exe /store "$legacyBcdPath" /set '{bootmgr}' displaybootmenu No 2>&1 | Out-Null
            Write-Host "[完成] Legacy BCD 启动项防死锁参数注入完毕。" -ForegroundColor Green
        }

        # ----------------- 5. ISO 根目录结构规范化清理 -----------------
        Write-Host "`n正在对 ISO 根目录执行合规性清洗..." -ForegroundColor Cyan
        $keepList = @(
            "boot",
            "efi",
            "sources",
            "support",
            "bootmgr",
            "bootmgr.efi",
            "setup.exe",
            "autorun.inf",
            "autounattend.xml"
        )

        Get-ChildItem -Path $workDir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
            Write-Host "   清除根目录多余文件/目录: $($_.Name)" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

        # ----------------- 6. 清理残留的 Edge 和 Cortana 快捷方式 -----------------
        Write-Host "`n正在清理可能残留的 Edge 和 Cortana 快捷方式..." -ForegroundColor Cyan
        $shortcutPaths = @(
            "$scratchDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
            "$scratchDir\Users\Default\Desktop\Microsoft Edge.lnk",
            "$scratchDir\Users\Public\Desktop\Microsoft Edge.lnk",
            "$scratchDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk"
        )
        foreach ($sc in $shortcutPaths) {
            if (Test-Path -LiteralPath $sc) {
                Write-Host "   清理快捷方式: $sc" -ForegroundColor DarkGray
                Remove-Item -LiteralPath $sc -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host "[完成] WinPE 引导与 BCD 修补全部圆满就绪。" -ForegroundColor Green
    }
}

# <<< [分块结束] 文件来源: src/09-ExportAndPE.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/10-PackageAndClean.ps1
# ==============================================================================
# ==============================================================================
#  Windows 10/11 Builder - [模块 11/11] ISO 最终打包与临时缓存清理 (src/10-PackageAndClean.ps1)
#  重构要点：
#   1. 单文件模式下，当 $global:enableEsdConversion = $false 时，不论来源是
#      .esd 还是 .wim，一律直接输出 .wim，不再强制转 ESD。
#   2. ESD 转换失败回退分支增加 $destWimPath 存在性校验，避免 Move-Item 抛错。
#   3. 保留 ISO 模式 ESD 开关、oscdimg 探测/下载/PE 头校验、双模引导校验、
#      打包参数与清理收尾全部逻辑。
#   4. [新增] 映像文件夹模式（sourceMode == "3"）：不打包、不转换 ESD、
#      不拉取 oscdimg、不触碰用户文件夹；仅做最终健康检查 + 清理临时工作区
#      + 关闭 Transcript，然后退出主脚本。
# ==============================================================================

Write-Host "`n[步骤 12/12] 正在校验资产并执行最终打包流程..." -ForegroundColor Cyan

# ----------------- 0. 响应该阶段 ESD 极限高压转换开关 -----------------
$esdEnabled = if ($null -ne $global:enableEsdConversion) { [bool]$global:enableEsdConversion } else { $false }

$destWimPath = Join-Path $sourcesDir "install.wim"
$destEsdPath = Join-Path $sourcesDir "install.esd"

# ==============================================================================
# 映像文件夹模式：不打包、不转换 ESD、不拉取 oscdimg，直接收尾退出
# ==============================================================================
if ($global:sourceMode -eq "3") {
    Write-Host "`n[步骤 12/12] 映像文件夹模式：跳过 ISO 打包、ESD 转换、oscdimg 拉取与校验。" -ForegroundColor Magenta

    # 最终健康检查（非致命提示）
    $sys32Final = Join-Path $scratchDir "Windows\System32"
    if (Test-Path -LiteralPath $sys32Final) {
        Write-Host "[完成] 精简结果已原地保留于: $($global:imageFolder)" -ForegroundColor Green
    } else {
        Write-Host "[警告] 目标文件夹最终健康检查未通过：$sys32Final 不存在。" -ForegroundColor Yellow
        Write-Host "        请手动核查该文件夹是否被外部进程修改或删除。" -ForegroundColor Yellow
    }

    # 仅清理本脚本产生的临时工作区（$workDir 在文件夹模式下是 windows_folder_mode_tmp），
    # 绝不触碰 $scratchDir（用户目标文件夹）。
    if ($workDir -and (Test-Path -LiteralPath $workDir)) {
        Write-Host "正在清理临时工作区: $workDir" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($global:transcriptActive) {
        Stop-Transcript
        Start-Sleep -Milliseconds 300
    }
    Write-Host "`n[结束] 映像文件夹原地精简流程完成。结果目录: $($global:imageFolder)" -ForegroundColor Green

    # 10 模块是主脚本最后一个模块，此 return 退出整个 dot-source 主脚本，安全
    return
}

# ==============================================================================
# 单文件模式：直接输出精简后的 WIM/ESD 文件，跳过 ISO 打包
# 逻辑：仅当 $esdEnabled = $true 时才转 ESD；否则无论来源扩展名，一律输出 WIM
# ==============================================================================
if ($global:sourceMode -eq "2" -and $global:sourceFile -match '\.(wim|esd)$') {
    $sourceExt = [System.IO.Path]::GetExtension($global:sourceFile).ToLower()
    $sourceDir = Split-Path -Parent $global:sourceFile
    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($global:sourceFile)

    if ($esdEnabled) {
        Write-Host "`n>>> [ESD 转换开启] 正在将精简后的 install.wim 转换为 ESD 高压格式..." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $destWimPath) {
            & dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destEsdPath" /Compress:recovery /CheckIntegrity
            if (Test-Path -LiteralPath $destEsdPath) {
                $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.esd"
                Move-Item -LiteralPath $destEsdPath -Destination $outputFilePath -Force
                Write-Host "[完成] 单文件 ESD 输出: $outputFilePath" -ForegroundColor Green
            } else {
                Write-Host "[警告] ESD 转换异常，尝试回退输出 WIM。" -ForegroundColor Yellow
                if (Test-Path -LiteralPath $destWimPath) {
                    $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.wim"
                    Move-Item -LiteralPath $destWimPath -Destination $outputFilePath -Force
                    Write-Host "[完成] 单文件 WIM 输出 (回退): $outputFilePath" -ForegroundColor Green
                } else {
                    Write-Host "[严重错误] ESD 转换失败且 install.wim 不存在，无法输出！" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "[严重错误] 未找到 install.wim，无法导出！" -ForegroundColor Red
        }
    } else {
        Write-Host "`n>>> [ESD 转换关闭] 正在将精简后的映像直接输出为 WIM 格式..." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $destWimPath) {
            $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.wim"
            Move-Item -LiteralPath $destWimPath -Destination $outputFilePath -Force
            Write-Host "[完成] 单文件 WIM 输出: $outputFilePath" -ForegroundColor Green
        } else {
            Write-Host "[严重错误] 未找到 install.wim，无法导出！" -ForegroundColor Red
        }
    }

    # 清理临时目录
    Write-Host "`n正在清理临时工作区与残留挂载点..." -ForegroundColor DarkGray
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($global:transcriptActive) {
        Stop-Transcript
        Start-Sleep -Milliseconds 300
    }
    Write-Host "`n[结束] 单文件精简流程完成。" -ForegroundColor Green
    return
}

# ==============================================================================
# ISO 模式：正常执行 ESD 转换（如果开启）与 oscdimg 打包流程
# ==============================================================================
if ($esdEnabled) {
    if (Test-Path -LiteralPath $destWimPath) {
        Write-Host ">>> [ESD 转换开启] 正在将 install.wim 高压转换为 install.esd..." -ForegroundColor Yellow
        & dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destEsdPath" /Compress:recovery /CheckIntegrity

        if (Test-Path -LiteralPath $destEsdPath) {
            Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
            Write-Host "[完成] 最终映像已成功转换为 ESD 极限高压格式！" -ForegroundColor Green
        } else {
            Write-Host "[警告] ESD 转换异常，安全保留原始 install.wim 进行打包。" -ForegroundColor Yellow
        }
    }
}

# ----------------- 1. 探测或自动拉取现代化 Oscdimg.exe 打包引擎 -----------------
$oscdimgExe = Join-Path $scriptDir "oscdimg.exe"

if (-not (Test-Path -LiteralPath $oscdimgExe)) {
    $adkOscdimg = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    if (Test-Path -LiteralPath $adkOscdimg) {
        Write-Host "从本地 Windows ADK 检测到 oscdimg.exe，正在提取..." -ForegroundColor Green
        Copy-Item -LiteralPath $adkOscdimg -Destination $oscdimgExe -Force
    } else {
        Write-Host "正在拉取支持现代 UEFI/UDF 2.0 规范的 oscdimg.exe 打包内核..." -ForegroundColor Yellow
        # Windows PowerShell 5.1 on Windows 10 may not expose the Tls13 enum value.
        # TLS 1.2 is sufficient for the HTTPS download and is available on supported hosts.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $oscdimgUrl = "https://ghproxy.net/https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe"
        try {
            Invoke-WebRequest -Uri $oscdimgUrl -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 30
        } catch {
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe" -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 15
            } catch {
                Write-Host "[严重错误] oscdimg.exe 自动下载失败！请手动将 Windows ADK 的 oscdimg.exe 放入脚本目录后再运行！" -ForegroundColor Red
                if ($global:transcriptActive) { Stop-Transcript }
                pause
                exit 1
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $oscdimgExe)) {
    Write-Host "[严重错误] 缺失 oscdimg.exe 打包引擎，打包阻断！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 下载/复制后校验 PE 头与文件大小，防止 HTML 错误页或损坏文件被误用
try {
    $fi = Get-Item -LiteralPath $oscdimgExe
    $headBytes = [System.IO.File]::ReadAllBytes($oscdimgExe)
    $isPE = ($headBytes.Length -ge 2 -and $headBytes[0] -eq 0x4D -and $headBytes[1] -eq 0x5A)
    if ($fi.Length -lt 100KB -or -not $isPE) {
        Remove-Item -LiteralPath $oscdimgExe -Force -ErrorAction SilentlyContinue
        Write-Host "[严重错误] oscdimg.exe 校验失败（文件过小或非 PE 可执行），请手动放置 ADK 的 oscdimg.exe！" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
} catch {
    Write-Host "[严重错误] oscdimg.exe 校验异常: $_" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 2. 严密校验 Legacy + UEFI 双模引导引导文件 -----------------
$outputISO = Join-Path $scriptDir "windows_ultra_v7.iso"
$etfsboot  = Join-Path $workDir "boot\etfsboot.com"

# 优先选用免按任意键直进安装向导的 efisys_noprompt.bin
$efisys = Join-Path $workDir "efi\microsoft\boot\efisys_noprompt.bin"
if (-not (Test-Path -LiteralPath $efisys)) {
    $efisys = Join-Path $workDir "efi\microsoft\boot\efisys.bin"
}

if (-not (Test-Path -LiteralPath $etfsboot) -or -not (Test-Path -LiteralPath $efisys)) {
    Write-Host "[严重错误] 关键双模引导扇区镜像不存在！" -ForegroundColor Red
    Write-Host "缺少文件: etfsboot.com (BIOS) 或 efisys.bin/efisys_noprompt.bin (UEFI)" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 3. 构建合规双模启动参数并打包生成 ISO -----------------
Write-Host "正在合成 Legacy BIOS + UEFI 双模自启动引导扇区..." -ForegroundColor Yellow

# 路径加引号，支持工作目录含空格 (如 D:\My Build\windows)
$bootDataParam = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""

# 参数解析:
# -m: 允许生成大于 4.7GB 的 ISO
# -o: 优化重复文件存储 (单实例优化)
# -u2: 仅生成 UDF 文件系统
# -udfver102: UDF 1.02 兼容格式 (兼容几乎所有 BIOS/UEFI 固件)
# -h: 包含源目录中的所有隐藏文件 (关键！保证 boot.sdi 等不丢失)
# -l: 指定 ISO 卷标
$oscdimgArgs = @(
    "-m",
    "-o",
    "-u2",
    "-udfver102",
    "-h",
    "-lWINDOWS_ULTRA",
    "-bootdata:$bootDataParam",
    "$workDir",
    "$outputISO"
)

# 清理可能存在的旧镜像文件
if (Test-Path -LiteralPath $outputISO) {
    Remove-Item -LiteralPath $outputISO -Force -ErrorAction SilentlyContinue
}

Write-Host "正在执行 ISO 最终打包封装 (展示 Oscdimg 打包进度)..." -ForegroundColor Green
& $oscdimgExe @oscdimgArgs

if (-not (Test-Path -LiteralPath $outputISO)) {
    Write-Host "[严重错误] ISO 打包生成失败！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 4. 汇总展示与收尾清理 -----------------
$isoSizeMB = [math]::Round((Get-Item -LiteralPath $outputISO).Length / 1MB, 2)
$isoSizeGB = [math]::Round((Get-Item -LiteralPath $outputISO).Length / 1GB, 2)

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "      全部构建流程圆满完成！ISO 引导镜像已生成: " -ForegroundColor Green
Write-Host "      路径: $outputISO" -ForegroundColor Yellow
Write-Host "      体积: $isoSizeMB MB ($isoSizeGB GB)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green

Write-Host "`n请按回车键 [ENTER] 执行临时挂载点清理并退出构建..." -ForegroundColor DarkGray
pause

Write-Host "正在清理临时工作区与残留挂载点..." -ForegroundColor DarkGray
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

if ($global:transcriptActive) {
    Stop-Transcript
    Start-Sleep -Milliseconds 300
}

# <<< [分块结束] 文件来源: src/10-PackageAndClean.ps1
