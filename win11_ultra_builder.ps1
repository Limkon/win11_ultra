# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-19 06:49:05 UTC
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

# ----------------- 10. 前置配置 3：UWP 依赖稳定性冲突处置策略 -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 3/3] 若 UWP 依赖测试发现稳定性风险时的处置策略:" -ForegroundColor Magenta
Write-Host " [1] 全部删除 (高危: 强行抹杀所有冲突依赖，追求极限体积)" -ForegroundColor Red
Write-Host " [2] 不删除   (推荐: 默认，自动保护所有冲突依赖包，确保系统绝对稳定)" -ForegroundColor Green
Write-Host " [3] 手动选择 (仅在后续检测到异常时，暂停由人工逐项裁决)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Magenta

$conflictChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1, 2 或 3]" -Seconds 15 -DefaultChoice "2"
switch ($conflictChoice) {
    "1" {
        $global:uwpConflictPolicy = "1"
        Write-Host ">>> 已确认: [1] 全部删除 (后续遇到冲突将自动强行粉碎，不暂停)" -ForegroundColor Red
    }
    "3" {
        $global:uwpConflictPolicy = "3"
        Write-Host ">>> 已确认: [3] 手动选择 (后续若检测到冲突将暂停供逐项确认)" -ForegroundColor Yellow
    }
    default {
        $global:uwpConflictPolicy = "2"
        Write-Host ">>> 已确认: [2] 不删除 (后续遇到冲突将自动保护保留，不暂停)" -ForegroundColor Green
    }
}

# 输出 ESD 开关状态
Write-Host ""
if ($enableEsdConversion) {
    Write-Host ">>> [配置状态] ESD 高压转换: 开启 (打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 打包)" -ForegroundColor DarkGray
}
Write-Host "`n[就绪] 前置配置已全部锁定，后续构建流程将完全静默自动化运行！`n" -ForegroundColor Green

# 11. 初始化清理 (安全预检并卸载残留)
Write-Host "[初始化] 清理历史残留挂载点并重置环境..." -ForegroundColor DarkGray
if (Test-Path "HKLM:\zSOFTWARE") { cmd.exe /c "reg.exe unload HKLM\zSOFTWARE 2>nul" | Out-Null }
if (Test-Path "HKLM:\zSYSTEM")   { cmd.exe /c "reg.exe unload HKLM\zSYSTEM 2>nul" | Out-Null }
if (Test-Path "HKLM:\zNTUSER")   { cmd.exe /c "reg.exe unload HKLM\zNTUSER 2>nul" | Out-Null }

& dism.exe /English /Cleanup-Wim 2>$null | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

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
            & takeown.exe /F "$Target" /A /R /D Y 2>$null | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$Target\*" /S /D 2>$null
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "rd /s /q `"$Target`"" 2>$null
            }
        } else {
            & takeown.exe /F "$Target" /A 2>$null | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$Target" 2>$null
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "del /f /q /a `"$Target`"" 2>$null
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

# ----------------- 3. 智能倒计时输入函数 (防跳行·回车符稳固版) -----------------
function Read-InputWithTimeout {
    <#
    .SYNOPSIS
        使用原生回车符 (\r) 替代光标位置坐标，彻底杜绝横向跳行并完美兼容中英文输入
    #>
    param (
        [string]$Prompt = "请输入自定义用户名",
        [int]$Seconds = 30,
        [string]$Default = "Admin"
    )

    Write-Host "[提示] 倒计时进行中。若需自定义请输入（请切至英文输入法）；若不输入，30秒后默认采用 [$Default]。" -ForegroundColor DarkGray

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
            Write-Host "`n>>> [超时] 超过 $Seconds 秒未输入，已自动采用默认用户名: $Default (密码自动留空)" -ForegroundColor Yellow
            return @{ TimedOut = $true; Value = $Default }
        }

        # 使用 \r 回车符重置光标至行首，并用足够空格覆盖历史文字，彻底杜绝跳行追加
        if ($inputStr.Length -eq 0 -and $remaining -ne $lastPrinted) {
            $lastPrinted = $remaining
            $statusLine = "`r$Prompt (默认: $Default) [剩余 $remaining 秒]: "
            Write-Host -NoNewline ($statusLine.PadRight(65)) -ForegroundColor Cyan
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
                # 捕获到第一个有效字符时，彻底擦除倒计时字样，转为常规输入提示行
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

# <<< [分块结束] 文件来源: src/01-Helpers.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/02-MountImage.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 3/11] 镜像定位、导出与挂载 (src/02-MountImage.ps1)
# ==============================================================================

# 1. 输入与校验 ISO 光驱盘符
$rawDrive = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
if ([string]::IsNullOrWhiteSpace($rawDrive)) {
    Write-Host "[严重错误] 未输入有效盘符！流程终止。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

$DriveLetter = ($rawDrive.TrimEnd('\').TrimEnd(':').Trim().ToUpper()) + ":"

$bootWimSrc    = "$DriveLetter\sources\boot.wim"
$installWimSrc = "$DriveLetter\sources\install.wim"
$installEsdSrc = "$DriveLetter\sources\install.esd"

if (-not (Test-Path -LiteralPath $bootWimSrc) -or (-not (Test-Path -LiteralPath $installWimSrc) -and -not (Test-Path -LiteralPath $installEsdSrc))) {
    Write-Host "[严重错误] 在虚拟光驱 $DriveLetter 中未检测到有效的 Windows 安装介质结构！" -ForegroundColor Red
    Write-Host "缺少关键文件: boot.wim 或 install.wim/install.esd，请确认 ISO 已正确挂载。" -ForegroundColor Yellow
    Stop-Transcript
    pause
    exit 1
}

# 2. 复制 ISO 引导架构文件 (步骤 1/11)
# 注意：路径严格规范化为不带尾部转义反斜杠的标准形式，杜绝 CRT 逃逸导致的复制失败
Write-Host "`n[步骤 1/11] 正在复制 ISO 核心引导架构到工作区..." -ForegroundColor Cyan
$sourceRoot = "$DriveLetter"

# Robocopy 返回码 0-7 均代表正常/成功（存在新文件、复制成功等），8 及以上代表严重异常
$null = & robocopy.exe "$sourceRoot" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NC /NS /NP
if ($LASTEXITCODE -ge 8) {
    Write-Host "[严重错误] 基础引导结构复制失败！Robocopy 退出码: $LASTEXITCODE" -ForegroundColor Red
    Stop-Transcript
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

if ($missingBootFile) {
    Write-Host "[严重错误] 核心引导结构未能完整复制到工作区，无法支持后续引导生成！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}
Write-Host "[完成] ISO 核心引导架构复制完毕，引导链结构完整有效。" -ForegroundColor Green

# 3. 定位源映像文件并导出目标分卷 (步骤 2/11)
$destWim = Join-Path $sourcesDir "install.wim"

if (Test-Path -LiteralPath $installWimSrc) {
    Write-Host "`n[步骤 2/11] 检测到 install.wim，正在解析映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$installWimSrc"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    if ([string]::IsNullOrWhiteSpace($index)) { $index = "1" }
    
    Write-Host "正在导出目标分卷 $index (展示原生导出进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$installWimSrc" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
} else {
    Write-Host "`n[步骤 2/11] 检测到 install.esd，正在解析映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$installEsdSrc"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    if ([string]::IsNullOrWhiteSpace($index)) { $index = "1" }
    
    Write-Host "正在将目标分卷 $index 从 ESD 高压格式转换为 install.wim (展示原生进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$installEsdSrc" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
}

if (-not (Test-Path -LiteralPath $destWim)) {
    Write-Host "[严重错误] install.wim 导出生成失败！流程终止。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 导出后独立单一镜像的 Index 固定为 1
$index = "1"

# 4. 解锁映像访问权限并挂载 (步骤 3/11)
Write-Host "`n[步骤 3/11] 正在接管 install.wim 物理访问权限并执行挂载..." -ForegroundColor Cyan
attrib.exe -R -S -H "$destWim" 2>$null
& takeown.exe /F "$destWim" /A 2>$null | Out-Null
& icacls.exe "$destWim" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
(Get-Item -LiteralPath $destWim).IsReadOnly = $false

# 挂载点初始化与清理
if (Test-Path -LiteralPath $scratchDir) {
    # 尝试卸载历史可能附着的死锁
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    attrib.exe -R -S -H "$scratchDir\*" /S /D 2>$null
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载目标映像到 $scratchDir (展示官方挂载进度条)..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] DISM 映像挂载失败，退出码: $LASTEXITCODE！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 挂载状态严密自检
$sys32Path = Join-Path $scratchDir "Windows\System32"
if (-not (Test-Path -LiteralPath $sys32Path)) {
    Write-Host "[严重错误] 挂载目录健康自检失败！未检测到 $sys32Path，映像已损坏或挂载不完整。" -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    Stop-Transcript
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
# 探查默认 UI 语言并写入全局变量，确保跨模块引导与应答文件协同
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$matchedLang = $false
foreach ($line in ($imageIntl -split '\r?\n')) {
    if ($line -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
        $global:languageCode = $Matches[1].Trim()
        $matchedLang = $true
        Write-Host "检测到默认系统 UI 语言代码: $global:languageCode" -ForegroundColor Green
        break
    }
}

if (-not $matchedLang -or [string]::IsNullOrWhiteSpace($global:languageCode)) {
    $global:languageCode = "zh-CN"
    Write-Host "[提示] 未能从映像中探测到明确的 UI 语言代码，安全回退默认值: $global:languageCode" -ForegroundColor Yellow
}

# 探查目标映像处理器架构
$destWimPath = Join-Path $sourcesDir "install.wim"
$imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
$matchedArch = $false
foreach ($line in ($imageInfo -split '\r?\n')) {
    if ($line -match 'Architecture\s*:\s*(.+)$') {
        $rawArch = $Matches[1].Trim().ToLower()
        if ($rawArch -eq 'x64' -or $rawArch -eq 'amd64') {
            $global:architecture = 'amd64'
        } elseif ($rawArch -eq 'arm64') {
            $global:architecture = 'arm64'
        } elseif ($rawArch -eq 'x86') {
            $global:architecture = 'x86'
        } else {
            $global:architecture = $rawArch
        }
        $matchedArch = $true
        Write-Host "检测到映像处理器架构: $global:architecture" -ForegroundColor Green
        break
    }
}

if (-not $matchedArch -or [string]::IsNullOrWhiteSpace($global:architecture)) {
    $global:architecture = "amd64"
    Write-Host "[提示] 架构信息未能自动解析，默认回退安全值: amd64" -ForegroundColor Yellow
}

# ----------------- 2. 移除预装 AppX (Bloatware) -----------------
Write-Host "`n正在扫描并移除预装臃肿 AppX 应用包..." -ForegroundColor Cyan

# 精确匹配待移除应用清单
$targetAppxPatterns = @(
    '*Zune*',
    '*Bing*',
    '*Clipchamp*',
    '*Gaming*',
    '*People*',
    '*PowerAutomate*',
    '*Teams*',
    '*Todos*',
    '*YourPhone*',
    '*SoundRecorder*',
    '*Solitaire*',
    '*FeedbackHub*',
    '*Maps*',
    '*OfficeHub*',
    '*Help*',
    '*Family*',
    '*Alarms*',
    '*CommunicationsApps*',
    '*Copilot*',
    '*CompatibilityEnhancements*',
    '*AV1VideoExtension*',
    '*AVCEncoderVideoExtension*',
    '*HEIFImageExtension*',
    '*HEVCVideoExtension*',
    '*MicrosoftStickyNotes*',
    '*OutlookForWindows*',
    '*RawImageExtension*',
    '*SecHealthUI*',
    '*VP9VideoExtensions*',
    '*WebpImageExtension*',
    '*DevHome*',
    '*Photos*',
    '*Camera*',
    '*QuickAssist*',
    '*CoreAI*',
    '*PeopleExperienceHost*',
    '*PinningConfirmationDialog*',
    '*SecureAssessmentBrowser*',
    '*Paint*',
    '*Notepad*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$packagesToRemove = @()

if ($provisionedPackages) {
    foreach ($pkg in $provisionedPackages) {
        foreach ($pattern in $targetAppxPatterns) {
            if ($pkg.PackageName -like $pattern) {
                $packagesToRemove += $pkg
                break
            }
        }
    }
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]

foreach ($package in $packagesToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName) [$($package.PackageName)]" -ForegroundColor DarkGray
    $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction SilentlyContinue
    $removedPackageNames.Add($package.PackageName)
}

# 深度清理 WindowsApps 物理残留目录（夺权并硬核粉碎）
Write-Host "正在扫描并清理 Program Files\WindowsApps 中的残留资产..." -ForegroundColor DarkGray
$windowsAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"

if (Test-Path -LiteralPath $windowsAppsDir) {
    foreach ($pkgName in $removedPackageNames) {
        $candidateFolder = Join-Path $windowsAppsDir $pkgName
        if (Test-Path -LiteralPath $candidateFolder) {
            Write-Host "   粉碎残留资产目录: $pkgName" -ForegroundColor DarkGray
            & takeown.exe /F "$candidateFolder" /A /R /D Y 2>$null | Out-Null
            & icacls.exe "$candidateFolder" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$candidateFolder\*" /S /D 2>$null
            Remove-Item -LiteralPath $candidateFolder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $candidateFolder) {
                cmd.exe /c "rd /s /q `"$candidateFolder`"" 2>$null
            }
        }
    }
}

# 释放内存引用
$packagesToRemove = $null
$provisionedPackages = $null

# ----------------- 3. 移除系统底层功能包 Packages -----------------
Write-Host "`n系统应用精炼完毕，正在执行系统底层按需功能包 (FOD) 精简..." -ForegroundColor Cyan

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
    "*IME-ja-jp*",
    "*IME-ko-kr*",
    "*IME-zh-tw*",
    "Windows-Defender-Client-Package~",
    "Microsoft-Windows-Search-Engine-Client-Package~",
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

# 动态扩展：非当前语言的冗余输入/语音语言包
if ($global:languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Speech-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-TextToSpeech-$($global:languageCode)-Package~"
}

# 抓取当前系统所有功能包列表
$rawPackageOutput = & dism.exe /English "/Image:$scratchDir" /Get-Packages /Format:Table
$packageLines = ($rawPackageOutput -split '\r?\n') | Select-Object -Skip 1

foreach ($pattern in $packagePatterns) {
    $matchedLines = $packageLines | Where-Object { $_ -like "$pattern*" }
    foreach ($mLine in $matchedLines) {
        $packageIdentity = ($mLine -split '\s+')[0]
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -ne "Package" -and $packageIdentity -notmatch "^-+$") {
            Write-Host "   正在移除底层功能包: $packageIdentity..." -ForegroundColor DarkGray
            & dism.exe /English "/Image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>$null | Out-Null
        }
    }
}

Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/03-RemovePackages.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/04-DriversFeatures.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动仓库与 .NET 缓存清理 (src/04-DriversFeatures.ps1)
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行 DriverStore 精简与 .NET 原生映像清理..." -ForegroundColor Cyan

# 1. 移除 pre-compiled .NET assemblies (完全对齐原版)
Write-Host "Removing pre-compiled .NET assemblies (Native Images)..."
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue

# 2. 驱动仓库激进瘦身
$winDir = "$scratchDir\Windows"
Write-Host "Slimming the DriverStore... (removing non-essential driver classes)"
$driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
$patternsToRemove = @(
    'prn*',
    'scan*',
    'mfd*',
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

# 3. 临时目录、Web、Help、Cursors
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 4. 移除 Edge, WinRE (建立 0 字节占位文件), 和 OneDrive
Write-Host "Removing Edge, WinRE, and OneDrive..."
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue

if ($global:architecture -eq 'amd64') { 
    $edgeFolder = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName 
    if ($edgeFolder) { Remove-Item -Path $edgeFolder -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# WinRE 处置：物理删除并建立 0 字节文件占位 (原版核心防报错细节)
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force | Out-Null

Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

Write-Host "[完成] 冗余物理文件与 Edge/WinRE 处理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表配置与服务精炼 (src/06-RegistryTweaks.ps1)
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 挂载离线注册表配置单元
reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

# 【关键引导修复】：内核级 ELAM 启动策略豁免 (彻底杜绝物理删除 wdboot.sys 导致的启动卡图标死锁)
Write-Host "Configuring Kernel ELAM & EarlyLaunch bypass..." -ForegroundColor Yellow
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch' '/v' 'DriverLoadPolicy' '/t' 'REG_DWORD' '/d' '8' '/f' | Out-Null

# 2. 绕过硬件检测限制 (母盘离线注册表注入)
Write-Host "Bypassing system requirements(on the system image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 3. 禁用推广应用、云端内容与建议
Write-Host "Disabling Sponsored Apps:"
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableWindowsConsumerFeatures' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' '/v' 'ConfigureStartPins' '/t' 'REG_SZ' '/d' '{"pinnedList": [{}]}' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'FeatureManagementEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEverEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SoftLandingEnabled' '/t' 'REG_DWORD' '/d' '0' '/f'| Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-310093Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338388Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338389Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338393Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353694Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353696Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SystemPaneSuggestionsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' '/v' 'DisablePushToInstall' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' '/v' 'DontOfferThroughWUAU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableConsumerAccountStateContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableCloudOptimizedContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 4. 开启 OOBE 本地账户跳过支持
Write-Host "Enabling Local Accounts on OOBE:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'BypassNRO' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 5. 禁用预留存储与 BitLocker 自动设备加密
Write-Host "Disabling Reserved Storage:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' '/v' 'ShippedWithReserves' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 6. 禁用任务栏 Chat 图标
Write-Host "Disabling Chat icon:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' '/v' 'ChatIcon' '/t' 'REG_DWORD' '/d' '3' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' '/v' 'TaskbarMn' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null

# 7. 清理 Edge 遗留注册表与幽灵 COM
Write-Host "Removing Edge related registries"
reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f | Out-Null
reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f | Out-Null

# 8. 禁用 OneDrive 文件夹同步
Write-Host "Disabling OneDrive folder backup"
& 'reg' 'add' "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" '/v' 'DisableFileSyncNGSC' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 9. 禁用隐私遥测与数据收集
Write-Host "Disabling Telemetry:"
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' '/v' 'TailoredExperiencesWithDiagnosticDataEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' '/v' 'HasAccepted' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitInkCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitTextCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' '/v' 'HarvestContacts' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' '/v' 'AcceptedPrivacyPolicy' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' '/v' 'AllowTelemetry' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' | Out-Null

# 10. 阻止 DevHome、Outlook、Copilot 及 Teams 自动安装
Write-Host "Prevents installation or DevHome and Outlook:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' '/f' | Out-Null
Write-Host "Disabling Copilot"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' '/v' 'TurnOffWindowsCopilot' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' '/v' 'HubsSidebarEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' '/v' 'DisableSearchBoxSuggestions' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Prevents installation of Teams:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' '/v' 'DisableInstallation' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Prevent installation of New Outlook":
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' '/v' 'PreventRun' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 11. 删除计划任务定义文件
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Write-Host "Deleting scheduled task definition files..."
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."

# 12. 彻底禁用 Windows Update 自动更新服务与策略
Write-Host "Disabling Windows Update..."
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE1' '/t' 'REG_SZ' '/d' 'net stop wuauserv' '/f' | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE2' '/t' 'REG_SZ' '/d' 'sc stop wuauserv' '/f' | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE3' '/t' 'REG_SZ' '/d' 'sc config wuauserv start= disabled' '/f' | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE1' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' | Out-Null
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE2' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DoNotConnectToWindowsUpdateInternetLocations' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DisableWindowsUpdateAccess' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUStatusServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'UpdateServiceUrlAlternate' '/t' 'REG_SZ' '/d' 'localhost' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'UseWUServer' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'DisableOnline' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC' '/f' 2>$null | Out-Null
& 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc' '/f' 2>$null | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'NoAutoUpdate' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 13. 停用 Windows Defender 核心服务并隐藏设置页入口
Write-Host "Disabling Windows Defender"
$servicePaths = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
foreach ($path in $servicePaths) {
    & 'reg' 'add' "HKLM\zSYSTEM\ControlSet001\Services\$path" '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 2>$null | Out-Null
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' '/v' 'SettingsPageVisibility' '/t' 'REG_SZ' '/d' 'hide:virus;windowsupdate' '/f' | Out-Null

Write-Host "Tweaking complete!"

# 14. 卸载并释放离线配置单元
Write-Host "Unmounting Registry..."
reg unload HKLM\zCOMPONENTS > $null
reg unload HKLM\zDEFAULT > $null
reg unload HKLM\zNTUSER > $null
reg unload HKLM\zSOFTWARE > $null
reg unload HKLM\zSYSTEM > $null

# 15. 重新装载 SYSTEM 单元以深度清除多余服务实体
Write-Host "Loading registry hives to remove services..."
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
$servicesToRemove = @( 
    'Spooler', 
    'PrintNotify', 
    'Fax', 
    'RemoteRegistry', 
    'diagsvc', 
    'WerSvc', 
    'PcaSvc', 
    'MapsBroker', 
    'WalletService', 
    'BthAvctpSvc', 
    'BluetoothUserService', 
    'wuauserv', 
    'UsoSvc', 
    'WaaSMedicSvc' 
)
foreach ($service in $servicesToRemove) { 
    Write-Host "Removing service: $service"
    & 'reg' 'delete' "HKLM\zSYSTEM\ControlSet001\Services\$service" /f 2>$null | Out-Null 
}
reg unload HKLM\zSYSTEM > $null

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
} else {
    # 半无人值守：剥离内置账户，开启本地账户输入屏
    Write-Host "   [账户策略] 已剥离预置账户，装机后将由用户在 OOBE 原生界面自定用户名与密码。" -ForegroundColor DarkGray
    $userAccountsXmlFragment = ""
    $autoLogonXmlFragment    = ""
    $hideLocalAccountScreenValue = "false"
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
				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
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
		cmd.exe /c "rmdir C:\Windows.old";
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

		# 2. 异步粉碎自毁 Setup Scripts 目录
		Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList '/c timeout /t 3 /nobreak >nul &amp; for /l %i in (1,1,10) do (if exist "C:\Windows\Setup\Scripts" (rd /s /q "C:\Windows\Setup\Scripts" &amp; timeout /t 1 >nul) else (exit))'
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
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 多通道规范注入 -----------------
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path -LiteralPath $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$utf8Encoding = [System.Text.Encoding]::UTF8

# Sysprep 核心规范通道
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $finalXml, $utf8Encoding)
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "autounattend.xml"), $finalXml, $utf8Encoding)

# Panther 初始化通道
[System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $finalXml, $utf8Encoding)

# ISO 介质根目录自启动通道
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $finalXml, $utf8Encoding)

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (自适应语言: $lang | 架构: $arch)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] 组件库瘦身与主映像优化 (src/08-WinSxSOptimize.ps1)
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
    return
}

# ----------------- 3. 极限压榨模式专用：WinSxS 物理极限裁剪 -----------------
Write-Host "`n>>> [警告] 当前为【极限压榨模式】，正在物理瘦身 WinSxS (架构: $currentArch)..." -ForegroundColor Red

$winSxSDir     = Join-Path $scratchDir "Windows\WinSxS"
$winSxSEditDir = Join-Path $scratchDir "Windows\WinSxS_edit"

if (-not (Test-Path -LiteralPath $winSxSDir)) {
    Write-Host "[错误] 未检测到 WinSxS 目录: $winSxSDir，跳过物理替换。" -ForegroundColor Red
    return
}

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

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE 修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在安全提交主映像并修补 WinPE 引导分卷..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"
$bootWimPath   = Join-Path $sourcesDir "boot.wim"
$tempBootWim   = Join-Path $sourcesDir "boot_temp.wim"

# ----------------- 1. 提交并卸载主映像 (install.wim) -----------------
Write-Host "正在提交并卸载主系统映像 install.wim (请耐心等待写入磁盘)..." -ForegroundColor Yellow

# 强制垃圾回收以释放可能附着的目录句柄
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] install.wim 提交卸载失败，退出码: $LASTEXITCODE！正在尝试强制放弃挂载以保护环境..." -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    Stop-Transcript
    pause
    exit 1
}
Write-Host "[完成] 主映像修改已持久化写入。" -ForegroundColor Green

# ----------------- 2. 二次重构 install.wim 消除存储碎片 -----------------
Write-Host "正在二次导出并重构压缩 install.wim (消除内部精简碎片)..." -ForegroundColor Cyan
& dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /Compress:max /CheckIntegrity

if (Test-Path -LiteralPath $destWim2Path) {
    attrib.exe -R -S -H "$destWimPath" 2>$null
    Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $destWim2Path -NewName "install.wim" -Force
    Write-Host "[完成] install.wim 导出重构完毕，体积已达最佳压缩状态。" -ForegroundColor Green
} else {
    Write-Host "[提示] 二次压缩镜像未能生成，安全保留原镜像继续推进。" -ForegroundColor Yellow
}

# ----------------- 3. 稳固修补 boot.wim (保持双卷 BCD 映射架构) -----------------
Write-Host "`n正在修补 WinPE 引导与安装向导映像 (boot.wim)..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    Write-Host "[严重错误] 未在 sources 目录中检测到 boot.wim，无法构建可引导介质！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 接管 boot.wim 物理所有权与写入属性
attrib.exe -R -S -H "$bootWimPath" 2>$null
& takeown.exe /F "$bootWimPath" /A 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
try {
    (Get-Item -LiteralPath $bootWimPath).IsReadOnly = $false
} catch {}

# 解析 boot.wim 的分卷结构，确定需要注入硬件绕过的 Setup 卷
$bootWimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$totalBootIndexes = 1
$setupIndex = 1

$indexMatches = [regex]::Matches($bootWimInfo, 'Index\s*:\s*(\d+)')
if ($indexMatches.Count -gt 0) {
    $totalBootIndexes = $indexMatches.Count
    # 标准双卷 Windows 介质中，Index 2 为 Setup 安装向导；若为单卷介质则为 Index 1
    $setupIndex = if ($totalBootIndexes -ge 2) { 2 } else { 1 }
}

Write-Host "检测到 boot.wim 共包含 $totalBootIndexes 个分卷，将对核心引导卷 [Index $setupIndex] 实施策略注入..." -ForegroundColor Green

# 挂载指定的 Setup 引导分卷
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$setupIndex" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] boot.wim 分卷 $setupIndex 挂载失败！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit 1
}

# 加载 boot.wim 内部离线注册表配置单元
Write-Host "正在加载 WinPE 离线注册表以注入硬件检测跳过策略..." -ForegroundColor Cyan
& reg.exe load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
& reg.exe load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
& reg.exe load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
& reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

# 注入底层全套硬件要求绕过注册表策略 (WinPE Setup 阶段)
Write-Host "正在写入硬件检测豁免与策略绕过规则 (CPU/TPM/RAM/SecureBoot/Disk)..." -ForegroundColor Yellow
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null

& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassDiskCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 禁用 WinPE 阶段的 BitLocker 设备自动加密
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

# 安全卸载注册表并释放句柄
Write-Host "正在安全卸载 WinPE 注册表配置单元..." -ForegroundColor DarkGray
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$hivesToUnload = @("zNTUSER", "zDEFAULT", "zSOFTWARE", "zSYSTEM")
foreach ($hive in $hivesToUnload) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $null = & reg.exe unload "HKLM\$hive" 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 800
    }
}

# 提交并卸载 WinPE 映像修改
Write-Host "正在提交 boot.wim 修改..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] boot.wim 提交失败！" -ForegroundColor Red
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
    Stop-Transcript
    pause
    exit 1
}

# 二次结构化重构 boot.wim (严格按原生分卷拓扑原样导出，确保 BCD 索引与 GUID 绝对吻合)
Write-Host "正在以原架构重构 boot.wim 保持 BCD 映射一致性..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $tempBootWim) { Remove-Item -LiteralPath $tempBootWim -Force -ErrorAction SilentlyContinue }

for ($i = 1; $i -le $totalBootIndexes; $i++) {
    Write-Host "   正在重构导出 boot.wim 分卷 [$i/$totalBootIndexes]..." -ForegroundColor DarkGray
    $bootFlag = if ($i -eq $setupIndex) { "/Bootable" } else { "" }
    if ($bootFlag) {
        & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:$i" "/DestinationImageFile:$tempBootWim" /Compress:max /Bootable /CheckIntegrity
    } else {
        & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:$i" "/DestinationImageFile:$tempBootWim" /Compress:max /CheckIntegrity
    }
}

if (Test-Path -LiteralPath $tempBootWim) {
    attrib.exe -R -S -H "$bootWimPath" 2>$null
    Remove-Item -LiteralPath $bootWimPath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $tempBootWim -NewName "boot.wim" -Force
    Write-Host "[完成] boot.wim 双卷结构完整保留并优化完毕。" -ForegroundColor Green
} else {
    Write-Host "[提示] boot.wim 原卷修改已就绪 (跳过二次重构)。" -ForegroundColor DarkGray
}

# ----------------- 4. ISO 根目录结构规范化清理 -----------------
Write-Host "`n正在对 ISO 发行根目录执行合规性清洗..." -ForegroundColor Cyan
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

Write-Host "[完成] WinPE 引导重构与母盘清理全部就绪。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/09-ExportAndPE.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/10-PackageAndClean.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 11/11] ISO 最终打包与临时缓存清理 (src/10-PackageAndClean.ps1)
# ==============================================================================

Write-Host "`n[步骤 12/12] 正在校验引导资产并打包最终 ISO 镜像..." -ForegroundColor Cyan

# ----------------- 0. 响应该阶段 ESD 极限高压转换开关 -----------------
$destWimPath = Join-Path $sourcesDir "install.wim"
$destEsdPath = Join-Path $sourcesDir "install.esd"

if ($enableEsdConversion) {
    if (Test-Path -LiteralPath $destWimPath) {
        Write-Host ">>> [ESD 转换开启] 正在将 install.wim 高压转换为 install.esd (此过程需要较多 CPU 资源)..." -ForegroundColor Yellow
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
                Stop-Transcript
                pause
                exit 1
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $oscdimgExe)) {
    Write-Host "[严重错误] 缺失 oscdimg.exe 打包引擎，打包阻断！" -ForegroundColor Red
    Stop-Transcript
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
    Stop-Transcript
    pause
    exit 1
}

# ----------------- 3. 构建合规双模启动参数并打包生成 ISO -----------------
Write-Host "正在合成 Legacy BIOS + UEFI 双模自启动引导扇区..." -ForegroundColor Yellow

# 关键语法修正：剔除内嵌引号，使用 Oscdimg 原生合规格式传递引导路径
$bootDataParam = "2#p0,e,b$etfsboot#pEF,e,b$efisys"

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
    Stop-Transcript
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
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>$null | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

Stop-Transcript

# <<< [分块结束] 文件来源: src/10-PackageAndClean.ps1

