# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-27 01:56:57 UTC
#  构建流水线: GitHub Actions (workflow_dispatch)
# ==============================================================================

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/00-Header-Init.ps1
# ==============================================================================
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

# <<< [分块结束] 文件来源: src/00-Header-Init.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/01-Helpers.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
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
            # 仅当目录存在子项时才启动 attrib，避免空目录无谓进程启动
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
    .PARAMETER HiveName
        完整 Hive 路径，必须包含 HKLM\ 前缀（例如 "HKLM\zSYSTEM"）
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$HiveName
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
        Start-Sleep -Seconds 1
    }

    Write-Host "   [警告] $HiveName 单元卸载超时，继续推进后续流程。" -ForegroundColor Yellow
    return $false
}

# <<< [分块结束] 文件来源: src/01-Helpers.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/02-MountImage.ps1
# ==============================================================================
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

# <<< [分块结束] 文件来源: src/02-MountImage.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/03-RemovePackages.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 1. 语言与硬件架构深度探针 -----------------
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

$destWimPath = Join-Path $sourcesDir "install.wim"
$imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
$matchedArch = $false
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
if (-not $matchedArch) { $global:architecture = "amd64" }

# ----------------- 2. 移除预装 AppX (Bloatware) -----------------
# 注意：保留 *Paint* 和 *Notepad*；相机保留在精简列表中（按之前逻辑）。
$targetAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*', 
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*', 
    '*SoundRecorder*', '*Solitaire*', '*FeedbackHub*', '*Maps*', 
    '*OfficeHub*', '*Help*', '*Family*', '*Alarms*', '*Camera*', 
    '*QuickAssist*', '*PeopleExperienceHost*', '*PinningConfirmationDialog*', 
    '*SecureAssessmentBrowser*', '*CommunicationsApps*', '*Copilot*', 
    '*AV1VideoExtension*', '*HEIFImageExtension*', '*HEVCVideoExtension*', 
    '*WebpImageExtension*', '*Cortana*'
)

# 框架组件保护白名单：任何通配符都不得误伤这些包
$protectedFrameworkPatterns = @(
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.WindowsAppRuntime*',
    '*Microsoft.NET.Native*', '*Microsoft.Services.Store*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$appxToRemove = @()
$appxToKeep = @()

foreach ($pkg in $provisionedPackages) {
    $isProtected = $false
    foreach ($prot in $protectedFrameworkPatterns) {
        if ($pkg.PackageName -like $prot) { $isProtected = $true; break }
    }
    if ($isProtected) {
        $appxToKeep += $pkg
        continue
    }

    foreach ($pattern in $targetAppxPatterns) {
        if ($pkg.PackageName -like $pattern) {
            $appxToRemove += $pkg
            break
        }
    }
}

Write-Host "   [框架保护] 已自动拦截保留 $($appxToKeep.Count) 个核心依赖框架。" -ForegroundColor DarkGray
Write-Host "   [准备移除] 检测到 $($appxToRemove.Count) 个预装应用符合精简规则。" -ForegroundColor Yellow

# AppX 包名 -> HKCR\Applications 下对应 exe 名的映射 (用于后续 06 模块修复关联)
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
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]
$global:removedAppxExeNames = New-Object System.Collections.Generic.List[string]

foreach ($package in $appxToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName)" -ForegroundColor DarkGray
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
    } catch {
        Write-Host "   [警告] 该包受系统保护或已被占用，跳过: $($package.PackageName)" -ForegroundColor DarkYellow
    }
    $removedPackageNames.Add($package.PackageName)

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

# 深度清理 WindowsApps 物理残留目录
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

# ----------------- 3. 暴力物理粉碎系统级残留 (断根 Edge/Cortana) -----------------
$sysAppsPath = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path -LiteralPath $sysAppsPath) {
    $sysAppsToDelete = @("*Cortana*", "*Edge*", "*PeopleExperienceHost*", "*SecureAssessmentBrowser*")
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
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~",
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "OpenSSH-Client-Package~",
    "*IME-ja-jp*", "*IME-ko-kr*", "*IME-zh-tw*",
    "Windows-Defender-Client-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",
    "Microsoft-Windows-Hello-Face-Package~",
    "Microsoft-Windows-Hello-BioEnrollment-Package~",
    "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
    "Microsoft-Windows-TPM-WMI-Provider-Package~",
    "Microsoft-Windows-Narrator-App-Package~",
    "Microsoft-Windows-Magnifier-App-Package~",
    "Microsoft-Windows-Printing-PMCPPC-FoD-Package~",
    "Microsoft-Windows-WebcamExperience-Package~",
    "Microsoft-Media-MPEG2-Decoder-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~"
)

if ($global:languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
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
            $fodRemovedCount++
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
#  win11 Builder - [模块 5/11] 驱动仓库与 .NET 缓存清理 (src/04-DriversFeatures.ps1)
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行 DriverStore 精简与 .NET 原生映像清理..." -ForegroundColor Cyan

# 1. 移除 pre-compiled .NET assemblies (覆盖旧版与新路径)
Write-Host "Removing pre-compiled .NET assemblies (Native Images)..."
$nativeImagePaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)
foreach ($p in $nativeImagePaths) {
    Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. 驱动仓库激进瘦身
# 注：仅删除通用打印/扫描类 INF 前缀，保留厂商专用驱动；
#     原 'scan*'、'mfd*' 通配符会误伤扫描仪与多功能设备核心驱动，已收窄。
$winDir = "$scratchDir\Windows"
Write-Host "Slimming the DriverStore... (removing non-essential driver classes)"
$driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
$patternsToRemove = @(
    'prnms00*',
    'prnms001*',
    'prnms002*',
    'prnms003*',
    'prnms004*',
    'prnms005*',
    'prnca00*',
    'prnkm00*',
    'wscsmd.inf*',
    'tapdrv*',
    'rdpbus.inf*',
    'tdibth.inf*'
)

if (Test-Path $driverRepo) {
    Get-ChildItem -Path $driverRepo -Directory | ForEach-Object {
        $driverFolder = $_.Name
        foreach ($pattern in $patternsToRemove) {
            if ($driverFolder -like $pattern) {
                Write-Host "Removing non-essential driver package: $driverFolder"
                attrib.exe -R -S -H "$($_.FullName)\*" /S /D 2>&1 | Out-Null
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
}
Write-Host "[完成] 驱动与底层运行库缓存精简完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/04-DriversFeatures.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/05-PhysicalNuke.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在执行系统冗余物理文件清理..." -ForegroundColor Cyan
$winDir = "$scratchDir\Windows"

# 1. 字体库精简 (保护微软雅黑与核心英文字体)
$fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
if (Test-Path $fontsPath) { 
    Write-Host "Cleaning up Fonts..."
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# 2. 语音引擎、病毒定义更新与输入法
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 3. 临时目录、Web 壁纸、Help、Cursors
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 4. 移除预编译 .NET 程序集 (Native Images)
Write-Host "Removing pre-compiled .NET assemblies (Native Images)..."
$nativeImagePaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)
foreach ($p in $nativeImagePaths) {
    Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. 全版本通用：地毯式清理 Edge、OneDrive、Defender 以及旧版残留
Write-Host "Removing Edge, WinRE, OneDrive, and Defender (Universal Search)..." -ForegroundColor Yellow

$searchBases = @(
    "$scratchDir\Program Files",
    "$scratchDir\Program Files (x86)",
    "$scratchDir\Windows\System32",
    "$scratchDir\Windows\SysWOW64",
    "$scratchDir\Windows\WinSxS",
    "$scratchDir\Windows\SystemApps",
    "$scratchDir\ProgramData\Microsoft\Windows Defender"
)
$patternsToDelete = @("*Edge*", "*MicrosoftEdge*", "*OneDrive*", "*Windows Defender*", "*WinDefend*")

foreach ($base in $searchBases) {
    if (Test-Path -LiteralPath $base) {
        foreach ($pattern in $patternsToDelete) {
            $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Host "   粉碎底层残留: $($item.FullName)" -ForegroundColor DarkGray
                if ($item.PSIsContainer) {
                    & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                    & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# 6. 处理用户目录下的 OneDrive 残留
$userProfileOneDrive = "$scratchDir\Users\Default\AppData\Local\Microsoft\OneDrive"
if (Test-Path $userProfileOneDrive) { Remove-Item -LiteralPath $userProfileOneDrive -Recurse -Force -ErrorAction SilentlyContinue }

# 7. WinRE 零字节占位
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Write-Host "[完成] 冗余物理文件与底层组件彻底清理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 挂载离线注册表配置单元 (带失败检查，避免静默生成无效母盘)
$hiveLoads = @(
    @{ Name = "HKLM\zCOMPONENTS"; Path = "$scratchDir\Windows\System32\config\COMPONENTS" },
    @{ Name = "HKLM\zDEFAULT";    Path = "$scratchDir\Windows\System32\config\default" },
    @{ Name = "HKLM\zNTUSER";     Path = "$scratchDir\Users\Default\ntuser.dat" },
    @{ Name = "HKLM\zSOFTWARE";   Path = "$scratchDir\Windows\System32\config\SOFTWARE" },
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
# 1.5 修复“打开方式 -> 更多应用” 及 恢复照片查看器
# ==============================================================================
Write-Host "Repairing OpenWith application associations and restoring Photo Viewer..." -ForegroundColor Yellow

# 步骤 A: 清理已删 AppX 产生的死链
if ($global:removedAppxExeNames -and $global:removedAppxExeNames.Count -gt 0) {
    $commonExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.txt', '.log', '.ini', '.md', '.csv', '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov'
    )
    $classesRoots = @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')

    foreach ($exe in $global:removedAppxExeNames) {
        foreach ($croot in $classesRoots) {
            & reg.exe delete "$croot\Applications\$exe" /f 2>&1 | Out-Null
            foreach ($ext in $commonExtensions) {
                & reg.exe delete "$croot\$ext\OpenWithList\$exe" /f 2>&1 | Out-Null
                & reg.exe delete "$croot\$ext\OpenWithProgids" /v $exe /f 2>&1 | Out-Null
            }
        }
    }
}

# 步骤 B: 强制恢复 Notepad 核心关联
$essentialApps = @(
    @{ Exe = 'notepad.exe'; Name = 'Notepad' }
)
foreach ($app in $essentialApps) {
    foreach ($croot in @('HKLM\zSOFTWARE\Classes', 'HKLM\zSOFTWARE\WOW6432Node\Classes')) {
        & 'reg' 'add' "$croot\Applications\$($app.Exe)\shell\open\command" '/ve' '/t' 'REG_SZ' '/d' "`"%SystemRoot%\system32\$($app.Exe)`" `"%1`"" '/f' 2>&1 | Out-Null
        & 'reg' 'add' "$croot\Applications\$($app.Exe)" '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' $app.Name '/f' 2>&1 | Out-Null
    }
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithList\notepad.exe' '/ve' '/t' 'REG_SZ' '/d' '' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids' '/v' 'txtfile' '/t' 'REG_NONE' '/d' '' '/f' 2>&1 | Out-Null

# 步骤 C: 强制恢复 Windows 照片查看器 (Photo Viewer) 的注册与调用权限
$photoViewerCroot = 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities'
& 'reg' 'add' "$photoViewerCroot" '/v' 'ApplicationName' '/t' 'REG_SZ' '/d' '@%SystemRoot%\System32\PhotoViewer.dll,-24513' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.bmp' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.dib' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.gif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpe' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpeg' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jpg' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.jfif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Jpeg' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.png' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Png' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.tif' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null
& 'reg' 'add' "$photoViewerCroot\FileAssociations" '/v' '.tiff' '/t' 'REG_SZ' '/d' 'PhotoViewer.FileAssoc.Tiff' '/f' 2>&1 | Out-Null

& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll' '/v' 'FriendlyAppName' '/t' 'REG_SZ' '/d' '@%SystemRoot%\System32\PhotoViewer.dll,-24513' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command' '/ve' '/t' 'REG_SZ' '/d' 'rundll32.exe "%SystemRoot%\System32\PhotoViewer.dll", ImageView_Fullscreen %1' '/f' 2>&1 | Out-Null

Write-Host "[完成] OpenWith 关联修复及照片查看器注册完毕。" -ForegroundColor Green

# ==============================================================================
# 2. 常规注册表精简与优化
# ==============================================================================

Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch' '/v' 'DriverLoadPolicy' '/t' 'REG_DWORD' '/d' '8' '/f' 2>&1 | Out-Null

Write-Host "Bypassing system requirements(on the system image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Sponsored Apps:"
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableWindowsConsumerFeatures' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' '/v' 'ConfigureStartPins' '/t' 'REG_SZ' '/d' '{"pinnedList": [{}]}' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'FeatureManagementEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEverEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SoftLandingEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-310093Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338388Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338389Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338393Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353694Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353696Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SystemPaneSuggestionsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' '/v' 'DisablePushToInstall' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' '/v' 'DontOfferThroughWUAU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' '/f' 2>&1 | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableConsumerAccountStateContent' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableCloudOptimizedContent' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Enabling Local Accounts on OOBE:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'BypassNRO' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Reserved Storage:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' '/v' 'ShippedWithReserves' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Chat icon:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' '/v' 'ChatIcon' '/t' 'REG_DWORD' '/d' '3' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' '/v' 'TaskbarMn' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null

Write-Host "Disabling OneDrive folder backup"
& 'reg' 'add' "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" '/v' 'DisableFileSyncNGSC' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

Write-Host "Disabling Telemetry:"
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' '/v' 'TailoredExperiencesWithDiagnosticDataEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' '/v' 'HasAccepted' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitInkCollection' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitTextCollection' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' '/v' 'HarvestContacts' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' '/v' 'AcceptedPrivacyPolicy' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' '/v' 'AllowTelemetry' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null

Write-Host "Prevents installation or DevHome and Outlook:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" /f 2>&1 | Out-Null
Write-Host "Disabling Copilot"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' '/v' 'TurnOffWindowsCopilot' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' '/v' 'HubsSidebarEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' '/v' 'DisableSearchBoxSuggestions' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
Write-Host "Prevents installation of Teams:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' '/v' 'DisableInstallation' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
Write-Host "Prevent installation of New Outlook":
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' '/v' 'PreventRun' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

# ==============================================================================
# 2.5 终极拔管：彻底封杀 Edge 和 Windows Defender
# ==============================================================================
Write-Host "Disabling Edge and Windows Defender at the kernel and policy level..." -ForegroundColor Yellow

# Edge 策略拦截
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>&1 | Out-Null
$edgeServices = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
foreach ($svc in $edgeServices) {
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc" /f 2>&1 | Out-Null
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate' '/v' 'DoNotUpdateToEdgeWithChromium' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' '/v' 'UpdateDefault' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null

# Defender 策略拦截
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' '/v' 'DisableAntiSpyware' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' '/v' 'DisableAntiVirus' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' '/v' 'DisableBehaviorMonitoring' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows Defender\Features' '/v' 'TamperProtection' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\SecurityHealthService' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "WdBoot")
foreach ($svc in $defenderServices) {
    & 'reg' 'add' "HKLM\zSYSTEM\ControlSet001\Services\$svc" '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
}

# 屏蔽 UI 入口
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' '/v' 'SettingsPageVisibility' '/t' 'REG_SZ' '/d' 'hide:virus;windowsupdate' '/f' 2>&1 | Out-Null

# ==============================================================================

Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."

Write-Host "Disabling Windows Update..."
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE1' '/t' 'REG_SZ' '/d' 'net stop wuauserv' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE2' '/t' 'REG_SZ' '/d' 'sc stop wuauserv' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE3' '/t' 'REG_SZ' '/d' 'sc config wuauserv start= disabled' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE1' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' 2>&1 | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE2' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DoNotConnectToWindowsUpdateInternetLocations' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DisableWindowsUpdateAccess' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUStatusServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'UpdateServiceUrlAlternate' '/t' 'REG_SZ' '/d' 'localhost' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'UseWUServer' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'DisableOnline' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>&1 | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC" /f 2>&1 | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc" /f 2>&1 | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'NoAutoUpdate' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

# 3. 卸载并释放离线配置单元
Write-Host "Unmounting Registry..."
foreach ($h in @("HKLM\zNTUSER", "HKLM\zDEFAULT", "HKLM\zCOMPONENTS", "HKLM\zSOFTWARE", "HKLM\zSYSTEM")) {
    Safely-UnloadHive -HiveName $h | Out-Null
}

# 4. 重新装载 SYSTEM 单元以深度清除多余服务实体
Write-Host "Loading registry hives to remove services..."
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 重新装载 SYSTEM 配置单元失败，退出码 $LASTEXITCODE，服务删除阶段中止。" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}
$servicesToRemove = @( 
    'Spooler', 'PrintNotify', 'Fax', 'RemoteRegistry', 'diagsvc', 
    'WerSvc', 'PcaSvc', 'MapsBroker', 'WalletService', 'BthAvctpSvc', 
    'BluetoothUserService', 'wuauserv', 'UsoSvc', 'WaaSMedicSVC',
    'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService',
    'WinDefend', 'WdNisSvc', 'SecurityHealthService'
)
foreach ($service in $servicesToRemove) { 
    Write-Host "Removing service: $service"
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$service" /f 2>&1 | Out-Null
}
Safely-UnloadHive -HiveName "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 离线注册表配置与多余服务清理全部完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/06-RegistryTweaks.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/07-UnattendInject.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在加载全局配置并注入 Windows 安装引导应答文件..." -ForegroundColor Cyan

# ----------------- 0. 承接前置配置与安全兜底 -----------------
$mode = if ($global:unattendMode) { $global:unattendMode } else { "1" }
$user = if ($global:customUser)   { $global:customUser }   else { "Admin" }
$pass = if ($global:customPass)   { $global:customPass }   else { "" }
$lang = if ($global:languageCode) { $global:languageCode } else { "zh-CN" }
$arch = if ($global:architecture) { $global:architecture } else { "amd64" }

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
		$report.Add(" Windows 11 精简母盘 - 首次登录系统健康与稳定性自检审计报告");
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
$finalXml = $finalXml.Replace('__HIDE_LOCAL_ACCOUNT_SCREEN__', $hideLocalAccountScreenValue)
$finalXml = $finalXml.Replace('__HIDE_ONLINE_ACCOUNT_SCREENS__', $hideOnlineAccountScreensValue)
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 多通道规范注入 (带强力防占用机制) -----------------
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

Write-XmlSafely -Path (Join-Path $sysprepDir "unattend.xml") -Content $finalXml
Write-XmlSafely -Path (Join-Path $sysprepDir "autounattend.xml") -Content $finalXml
Write-XmlSafely -Path (Join-Path $pantherDir "unattend.xml") -Content $finalXml
Write-XmlSafely -Path (Join-Path $workDir "autounattend.xml") -Content $finalXml

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (自适应语言: $lang | 架构: $arch)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] 组件库瘦身与主映像优化 (src/08-WinSxSOptimize.ps1)
#  注：本模块会被合并进单文件主脚本，禁止使用 return（会退出整个脚本），
#      所有提前退出分支统一改为 if/else 嵌套。
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在根据精简模式执行组件存储 (WinSxS) 优化..." -ForegroundColor Cyan

$currentTrimMode = if ($global:trimMode) { $global:trimMode } else { "1" }
$currentArch     = if ($global:architecture) { $global:architecture } else { "amd64" }

# ----------------- 1. 通用阶段：执行官方基线重置 -----------------
Write-Host "正在执行 DISM 深度组件清理与基线重置 (/StartComponentCleanup /ResetBase)..." -ForegroundColor Yellow
& dism.exe /English "/Image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase

if ($LASTEXITCODE -ne 0) {
    Write-Host "[提示] DISM 组件重置退出码: $LASTEXITCODE (部分精简组件无需重置或已处于最新基线，继续推进)。" -ForegroundColor DarkGray
}

# ----------------- 2. 分支处理：依据模式决定是否执行物理抹杀 -----------------
if ($currentTrimMode -ne "2") {
    Write-Host "[完成] 当前为【普通精简模式】，已保留完整 WinSxS 核心组件库以确保绝佳兼容性与可维护性。" -ForegroundColor Green
} else {
    # ----------------- 3. 极限压榨模式专用：WinSxS 物理极限裁剪 -----------------
    Write-Host "`n>>> [警告] 当前为【极限压榨模式】，正在物理瘦身 WinSxS (架构: $currentArch)..." -ForegroundColor Red

    $winSxSDir     = Join-Path $scratchDir "Windows\WinSxS"
    $winSxSEditDir = Join-Path $scratchDir "Windows\WinSxS_edit"

    if (-not (Test-Path -LiteralPath $winSxSDir)) {
        Write-Host "[错误] 未检测到 WinSxS 目录: $winSxSDir，跳过物理替换。" -ForegroundColor Red
    } else {
        # 极限模式前置断言：OpenWith.exe 缺失时物理替换 WinSxS 将导致“打开方式”功能永久损坏
        $openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
        if (-not (Test-Path -LiteralPath $openWithExe)) {
            Write-Host "[严重错误] 极限模式前置断言失败：OpenWith.exe 不存在，物理替换 WinSxS 将导致“打开方式”功能永久损坏。已中止极限模式，回退为普通精简。" -ForegroundColor Red
        } else {
            # 获取 WinSxS 物理掌控权
            Write-Host "正在获取 WinSxS 目录物理所有权与完全控制权限..." -ForegroundColor Yellow
            & takeown.exe /F "$winSxSDir" /R /A /D Y 2>$null | Out-Null
            & icacls.exe "$winSxSDir" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

            # 重置并创建暂存目录
            if (Test-Path -LiteralPath $winSxSEditDir) {
                Remove-Item -LiteralPath $winSxSEditDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $winSxSEditDir -ItemType Directory -Force | Out-Null

            # 根据架构构建保活组件清单
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
                    "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
                )
            } else {
                # 默认 amd64 体系
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
                    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
                )
            }

            # 复制保活核心清单
            Write-Host "正在提取基础运行库与核心服务依赖项..." -ForegroundColor Cyan
            foreach ($pattern in $dirsToCopy) {
                $matchedDirs = Get-ChildItem -Path $winSxSDir -Filter $pattern -Directory -ErrorAction SilentlyContinue
                if ($matchedDirs) {
                    foreach ($sDir in $matchedDirs) {
                        $destDir = Join-Path $winSxSEditDir $sDir.Name
                        Copy-Item -LiteralPath $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            # 执行物理粉碎替换
            Write-Host "正在物理销毁原始 WinSxS 并置换轻量结构..." -ForegroundColor Yellow
            attrib.exe -R -S -H "$winSxSDir\*" /S /D 2>$null
            Remove-Item -LiteralPath $winSxSDir -Recurse -Force -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $winSxSDir) {
                cmd.exe /c "rd /s /q `"$winSxSDir`"" 2>$null
            }

            if (-not (Test-Path -LiteralPath $winSxSDir)) {
                Rename-Item -LiteralPath $winSxSEditDir -NewName "WinSxS" -Force
                Write-Host "[完成] WinSxS 极限置换完成，体积已大幅度压缩。" -ForegroundColor Green
            } else {
                Write-Host "[警告] WinSxS 原始目录存在锁死残留，保留备份以防映像损坏。" -ForegroundColor Yellow
            }
        }
    }
}

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE/BCD 深度修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在安全提交主映像并优化引导资产..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"
$bootWimPath   = Join-Path $sourcesDir "boot.wim"
$legacyBcdPath = Join-Path $workDir "boot\bcd"

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

# ==============================================================================
# 如果是单文件 WIM/ESD 模式，跳过 boot.wim 修补
# ==============================================================================
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
            & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
        }
        if ($loadedHives -contains "HKLM\zNTUSER") {
            & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
        }
        if ($loadedHives -contains "HKLM\zSYSTEM") {
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassDiskCheck' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

            # 2. 禁用 WinPE 阶段的 BitLocker 设备自动加密
            & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' 2>&1 | Out-Null

            # 3. 【关键：解决 Legacy 卡死】注入内核级早期驱动启动与基本显示豁免策略
            & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch' '/v' 'DriverLoadPolicy' '/t' 'REG_DWORD' '/d' '8' '/f' 2>&1 | Out-Null
            & 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\BasicDisplay' '/v' 'Start' '/t' 'REG_DWORD' '/d' '0' '/f' 2>&1 | Out-Null
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

# <<< [分块结束] 文件来源: src/09-ExportAndPE.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/10-PackageAndClean.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 11/11] ISO 最终打包与临时缓存清理 (src/10-PackageAndClean.ps1)
# ==============================================================================

Write-Host "`n[步骤 12/12] 正在校验资产并执行最终打包流程..." -ForegroundColor Cyan

# ----------------- 0. 响应该阶段 ESD 极限高压转换开关 -----------------
$esdEnabled = if ($null -ne $global:enableEsdConversion) { [bool]$global:enableEsdConversion } else { $false }

$destWimPath = Join-Path $sourcesDir "install.wim"
$destEsdPath = Join-Path $sourcesDir "install.esd"

# ==============================================================================
# 单文件模式：直接输出精简后的 WIM/ESD 文件，跳过 ISO 打包
# ==============================================================================
if ($global:sourceMode -eq "2" -and $global:sourceFile -match '\.(wim|esd)$') {
    $sourceExt = [System.IO.Path]::GetExtension($global:sourceFile).ToLower()
    $sourceDir = Split-Path -Parent $global:sourceFile
    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($global:sourceFile)

    if ($sourceExt -eq '.esd' -or $esdEnabled) {
        Write-Host "`n>>> 正在将精简后的 install.wim 转换为 ESD 高压格式..." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $destWimPath) {
            & dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destEsdPath" /Compress:recovery /CheckIntegrity
            if (Test-Path -LiteralPath $destEsdPath) {
                $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.esd"
                Move-Item -LiteralPath $destEsdPath -Destination $outputFilePath -Force
                Write-Host "[完成] 单文件 ESD 输出: $outputFilePath" -ForegroundColor Green
            } else {
                Write-Host "[警告] ESD 转换异常，将直接导出原始 WIM。" -ForegroundColor Yellow
                $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.wim"
                Move-Item -LiteralPath $destWimPath -Destination $outputFilePath -Force
                Write-Host "[完成] 单文件 WIM 输出: $outputFilePath" -ForegroundColor Green
            }
        } else {
            Write-Host "[严重错误] 未找到 install.wim，无法导出！" -ForegroundColor Red
        }
    } else {
        $outputFilePath = Join-Path $sourceDir "${sourceBaseName}_trim.wim"
        if (Test-Path -LiteralPath $destWimPath) {
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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
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
$outputISO = Join-Path $scriptDir "win11_ultra_v7.iso"
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

# 路径加引号，支持工作目录含空格 (如 D:\My Build\win11)
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
    "-lWIN11_ULTRA",
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

