# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-19 05:35:39 UTC
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
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 在 $DriveLetter 中未找到有效的 Windows 安装镜像源 (缺少 boot.wim 或 install.wim/esd)！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 2. 复制 ISO 引导架构文件 (步骤 1/11)
Write-Host "`n[步骤 1/11] 正在复制 ISO 核心引导结构到工作区..." -ForegroundColor Cyan
& robocopy.exe "$DriveLetter\\" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NC /NS /NP | Out-Null
Write-Host "[完成] 基础架构复制完毕。" -ForegroundColor Green

# 3. 定位源映像文件并导出目标分卷 (步骤 2/11)
$srcWim = "$DriveLetter\sources\install.wim"
$srcEsd = "$DriveLetter\sources\install.esd"
$destWim = "$sourcesDir\install.wim"

if (Test-Path $srcWim) {
    Write-Host "`n[步骤 2/11] 检测到 install.wim，获取映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$srcWim"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在导出目标分卷 (展示官方原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcWim" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
} else {
    Write-Host "`n[步骤 2/11] 检测到 install.esd，获取映像分卷列表..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$srcEsd"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在将目标分卷从 ESD 转换导出为 install.wim (展示官方原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcEsd" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
}

if (-not (Test-Path $destWim)) {
    Write-Host "[严重错误] install.wim 导出失败！终止流程。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 导出后独立单一镜像的 Index 固定为 1
$index = "1"

# 4. 解锁映像访问权限并正式挂载 (步骤 3/11)
Write-Host "`n[步骤 3/11] 解锁 install.wim 访问权限并挂载..." -ForegroundColor Cyan
attrib.exe -R -S -H "$destWim" 2>$null
Start-Process -FilePath "takeown.exe" -ArgumentList "/F `"$destWim`"" -NoNewWindow -Wait
Start-Process -FilePath "icacls.exe" -ArgumentList "`"$destWim`" /grant *S-1-5-32-544:F /C /Q" -NoNewWindow -Wait
(Get-Item $destWim).IsReadOnly = $false

if (Test-Path $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载 install.wim 到 $scratchDir (展示官方挂载进度条)..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"

# 挂载状态校验
if (-not (Test-Path "$scratchDir\Windows\System32")) {
    Write-Host "[严重错误] 映像挂载失败！System32 目录不存在，终止运行。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}
Write-Host "[完成] 系统映像挂载成功。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/02-MountImage.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/03-RemovePackages.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# 1. 语言与架构探测 (完全对齐原版)
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
if ($languageLine) { 
    $languageCode = $Matches[1]
    Write-Host "Default system UI language code: $languageCode" -ForegroundColor Green
} else { 
    Write-Host "Default system UI language code not found." -ForegroundColor Yellow
}

$destWimPath = Join-Path $sourcesDir "install.wim"
$imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
$lines = $imageInfo -split '\r?\n'
foreach ($line in $lines) { 
    if ($line -like '*Architecture : *') { 
        $global:architecture = $line -replace 'Architecture : ',''; 
        if ($global:architecture -eq 'x64') { $global:architecture = 'amd64' }; 
        Write-Host "Architecture: $global:architecture" -ForegroundColor Green
        break 
    } 
}
if (-not $global:architecture) { 
    $global:architecture = "amd64"
    Write-Host "Architecture information fallback: amd64" -ForegroundColor Yellow
}

# 2. 移除预装 AppX (Bloatware)
Write-Host "Removing provisioned AppX packages (bloatware)..." -ForegroundColor Cyan
$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir | Where-Object { 
    $_.PackageName -like '*Zune*' -or 
    $_.PackageName -like '*Bing*' -or 
    $_.PackageName -like '*Clipchamp*' -or 
    $_.PackageName -like '*Gaming*' -or 
    $_.PackageName -like '*People*' -or 
    $_.PackageName -like '*PowerAutomate*' -or 
    $_.PackageName -like '*Teams*' -or 
    $_.PackageName -like '*Todos*' -or 
    $_.PackageName -like '*YourPhone*' -or 
    $_.PackageName -like '*SoundRecorder*' -or 
    $_.PackageName -like '*Solitaire*' -or 
    $_.PackageName -like '*FeedbackHub*' -or 
    $_.PackageName -like '*Maps*' -or 
    $_.PackageName -like '*OfficeHub*' -or 
    $_.PackageName -like '*Help*' -or 
    $_.PackageName -like '*Family*' -or 
    $_.PackageName -like '*Alarms*' -or 
    $_.PackageName -like '*CommunicationsApps*' -or 
    $_.PackageName -like '*Copilot*' -or 
    $_.PackageName -like '*CompatibilityEnhancements*' -or 
    $_.PackageName -like '*AV1VideoExtension*' -or 
    $_.PackageName -like '*AVCEncoderVideoExtension*' -or 
    $_.PackageName -like '*HEIFImageExtension*' -or 
    $_.PackageName -like '*HEVCVideoExtension*' -or 
    $_.PackageName -like '*MicrosoftStickyNotes*' -or 
    $_.PackageName -like '*OutlookForWindows*' -or 
    $_.PackageName -like '*RawImageExtension*' -or 
    $_.PackageName -like '*SecHealthUI*' -or 
    $_.PackageName -like '*VP9VideoExtensions*' -or 
    $_.PackageName -like '*WebpImageExtension*' -or 
    $_.PackageName -like '*DevHome*' -or 
    $_.PackageName -like '*Photos*' -or 
    $_.PackageName -like '*Camera*' -or 
    $_.PackageName -like '*QuickAssist*' -or 
    $_.PackageName -like '*CoreAI*' -or 
    $_.PackageName -like '*PeopleExperienceHost*' -or 
    $_.PackageName -like '*PinningConfirmationDialog*' -or 
    $_.PackageName -like '*SecureAssessmentBrowser*' -or 
    $_.PackageName -like '*Paint*' -or 
    $_.PackageName -like '*Notepad*' 
}

foreach ($package in $packagesToRemove) { 
    Write-Host "Removing: $($package.DisplayName)"
    Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName 
}

Write-Host "Attempting to remove leftover WindowsApps folders..."
foreach ($package in $packagesToRemove) { 
    $folderPath = Join-Path "$scratchDir\Program Files\WindowsApps" $package.PackageName
    if (Test-Path $folderPath) { 
        Write-Host "Deleting folder: $($package.PackageName)"
        Remove-Item $folderPath -Recurse -Force -ErrorAction SilentlyContinue 
    } 
}

# 3. 移除系统底层功能包 Packages (完全移植原版规则)
Write-Host "Removing of system apps complete! Now proceeding to removal of system packages..." -ForegroundColor Cyan

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

if ($languageCode -and $languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~"
}

$allPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$allPackages = $allPackages -split "`n" | Select-Object -Skip 1

foreach ($packagePattern in $packagePatterns) {
    $matchedPackages = $allPackages | Where-Object { $_ -like "$packagePattern*" }
    foreach ($package in $matchedPackages) {
        $packageIdentity = ($package -split "\s+")[0]
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -ne "Package" -and $packageIdentity -notmatch "^-+$") {
            Write-Host "Removing $packageIdentity..."
            & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>$null | Out-Null
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
#  [终极稳固]：消除反引号跨行隐患 + 单语句顺序安全替换 + 杜绝 ParserError
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在加载全局配置并注入 Windows 安装引导应答文件..." -ForegroundColor Cyan

# ----------------- 0. 承接前置配置与安全兜底 -----------------
$mode = if ($global:unattendMode) { $global:unattendMode } else { "1" }
$user = if ($global:customUser)   { $global:customUser }   else { "Admin" }
$pass = if ($global:customPass)   { $global:customPass }   else { "" }

$modeText = if ($mode -eq "2") { "半无人值守 (手动设置账户向导)" } else { "全无人值守 (自动配置并登录)" }
Write-Host "   [配置承接] 当前激活模式: $modeText" -ForegroundColor Green

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

# ----------------- 2. 纯字面量无损模板 -----------------
$unattendTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
	<settings pass="offlineServicing"></settings>
	<settings pass="windowsPE">
		<!-- 1. WinPE 安装环境国际化 (跳过安装初始语言/键盘选择) -->
		<component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<SetupUILanguage>
				<UILanguage>zh-CN</UILanguage>
			</SetupUILanguage>
			<InputLocale>zh-CN</InputLocale>
			<SystemLocale>zh-CN</SystemLocale>
			<UILanguage>zh-CN</UILanguage>
			<UserLocale>zh-CN</UserLocale>
		</component>
		<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<ComputerName>DESKTOP-PC</ComputerName>
		</component>
		<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>zh-CN</InputLocale>
			<SystemLocale>zh-CN</SystemLocale>
			<UILanguage>zh-CN</UILanguage>
			<UserLocale>zh-CN</UserLocale>
		</component>
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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

# ----------------- 3. 单语句独立安全替换 (彻底免疫空格与反引号陷阱) -----------------
$finalXml = $unattendTemplate
$finalXml = $finalXml.Replace('__USER_ACCOUNTS__', $userAccountsXmlFragment)
$finalXml = $finalXml.Replace('__AUTO_LOGON__', $autoLogonXmlFragment)
$finalXml = $finalXml.Replace('__HIDE_LOCAL_ACCOUNT_SCREEN__', $hideLocalAccountScreenValue)
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 多通道合规注入 -----------------
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

# ISO 可移动介质根目录自启动通道
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $finalXml, $utf8Encoding)

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (全自动运行，无需人工干预)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] 组件库瘦身与主映像提交 (src/08-WinSxSOptimize.ps1)
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在重置组件基线并执行 WinSxS 裁剪..." -ForegroundColor Cyan

# 关键：原版在动 WinSxS 前先由 DISM 做完整的基线重置，解决注册表引用与底层不一致
Write-Host "Executing DISM StartComponentCleanup /ResetBase..." -ForegroundColor Yellow
& dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "Taking ownership of the WinSxS folder. This might take a while..." -ForegroundColor Yellow
& takeown.exe /f "$scratchDir\Windows\WinSxS" /r 2>$null | Out-Null
& icacls.exe "$scratchDir\Windows\WinSxS" /grant "*S-1-5-32-544:F" /T /C 2>$null | Out-Null

$folderPath = "$scratchDir\Windows\WinSxS_edit"
$sourceDirectory = "$scratchDir\Windows\WinSxS"
$destinationDirectory = "$scratchDir\Windows\WinSxS_edit"
New-Item -Path $folderPath -ItemType Directory -Force | Out-Null

if ($global:architecture -eq "amd64") {
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
    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
        foreach ($sDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
            Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} elseif ($global:architecture -eq "arm64") {
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
    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
        foreach ($sDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
            Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }  
}

Write-Host "Deleting WinSxS. This may take a while..." -ForegroundColor Yellow
Remove-Item -Path "$scratchDir\Windows\WinSxS" -Recurse -Force -ErrorAction SilentlyContinue
Rename-Item -Path "$scratchDir\Windows\WinSxS_edit" -NewName "WinSxS" -Force

Write-Host "[完成] WinSxS 裁剪与置换完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE 修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在卸载主映像并二次导出重建 install.wim..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"

# 1. 提交并卸载主映像
Write-Host "Cleaning up and unmounting install.wim..."
& dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase
& dism.exe /English /unmount-image "/mountdir:$scratchDir" /commit

# 2. 导出并重构 install.wim 清理碎片 (完全移植原版)
Write-Host "Exporting and compressing install.wim..."
& dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /compress:max
Remove-Item -Path $destWimPath -Force -ErrorAction SilentlyContinue
Rename-Item -Path $destWim2Path -NewName "install.wim"

# 3. 修补 boot.wim (完全移植原版：提取 Index 2，挂载，注入策略，二次导出为全新 boot.wim)
Write-Host "`nShrinking boot.wim and bypassing requirements..." -ForegroundColor Cyan
$bootWimPath      = Join-Path $sourcesDir "boot.wim"
$newBootWimPath   = Join-Path $sourcesDir "boot_new.wim"
$finalBootWimPath = Join-Path $sourcesDir "boot_final.wim"

Write-Host "Taking ownership of $bootWimPath..."
& takeown.exe /F "$bootWimPath" 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" 2>$null | Out-Null
try {
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {}

Write-Host "Exporting modified setup image (index 2) from boot.wim..."
& dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" /SourceIndex:2 "/DestinationImageFile:$newBootWimPath"
& dism.exe /English /mount-image "/imagefile:$newBootWimPath" /index:1 "/mountdir:$scratchDir"

# 加载 boot.wim 注册表配置单元 (使用统一变量 $scratchDir)
reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

Write-Host "Bypassing system requirements(on the boot image):"
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
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

Write-Host "Tweaking boot image complete!"
Write-Host "Unmounting Registry..."
reg unload HKLM\zNTUSER > $null
reg unload HKLM\zDEFAULT > $null
reg unload HKLM\zSOFTWARE > $null
reg unload HKLM\zSYSTEM > $null

Start-Sleep -Seconds 3
& dism.exe /English /unmount-image "/mountdir:$scratchDir" /commit

& takeown.exe /F "$bootWimPath" 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" 2>$null | Out-Null
Remove-Item -Path $bootWimPath -Force -ErrorAction SilentlyContinue

& dism.exe /English /Export-Image "/SourceImageFile:$newBootWimPath" /SourceIndex:1 "/DestinationImageFile:$finalBootWimPath" /compress:max
Remove-Item -Path $newBootWimPath -Force -ErrorAction SilentlyContinue
Rename-Item -Path $finalBootWimPath -NewName "boot.wim"

# 4. 根目录无用文件清理 (保持 ISO 极简结构)
Write-Host "Performing final cleanup of installation folder root..."
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "setup.exe", "autounattend.xml")
Get-ChildItem -Path $workDir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Write-Host "Removing non-essential file/folder from ISO root: $($_.Name)"
    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[完成] WinPE 引导重构与母盘清理全部完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/09-ExportAndPE.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/10-PackageAndClean.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 11/11] ISO 最终打包与临时缓存清理 (src/10-PackageAndClean.ps1)
# ==============================================================================

Write-Host "`n正在打包最终可引导 ISO 镜像 (兼容 BIOS + UEFI 双模引导)..." -ForegroundColor Cyan

# 1. 探测或自动获取 oscdimg.exe
$oscdimgExe = Join-Path $scriptDir "oscdimg.exe"

if (-not (Test-Path $oscdimgExe)) {
    $adkOscdimg = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    if (Test-Path $adkOscdimg) {
        Write-Host "从本地 Windows ADK 检测到 oscdimg.exe，正在提取..." -ForegroundColor Green
        Copy-Item -Path $adkOscdimg -Destination $oscdimgExe -Force
    } else {
        Write-Host "正在拉取支持现代 UEFI 的 oscdimg.exe..." -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        $oscdimgUrl = "https://ghproxy.net/https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe"
        try {
            Invoke-WebRequest -Uri $oscdimgUrl -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 30
        } catch {
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe" -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 15
            } catch {
                Write-Host "[严重错误] oscdimg.exe 自动下载失败！请手动将 Windows ADK 现代版的 oscdimg.exe 放入脚本目录后再运行！" -ForegroundColor Red
                Stop-Transcript
                pause
                exit
            }
        }
    }
}

if (-not (Test-Path $oscdimgExe)) {
    Write-Host "[严重错误] 缺失 oscdimg.exe，流程阻断！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 2. 校验关键引导记录文件
$outputISO = Join-Path $scriptDir "win11_ultra_v7.iso"
$etfsboot = Join-Path $workDir "boot\etfsboot.com"

# 优先选用免按任意键的 efisys_noprompt.bin
$efisys = Join-Path $workDir "efi\microsoft\boot\efisys_noprompt.bin"
if (-not (Test-Path $efisys)) {
    $efisys = Join-Path $workDir "efi\microsoft\boot\efisys.bin"
}

if (-not (Test-Path $etfsboot) -or -not (Test-Path $efisys)) {
    Write-Host "[严重错误] 缺少关键引导文件 (etfsboot.com 或 efisys.bin)，无法创建 UEFI 镜像！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# 3. 构造双模启动参数并打包 ISO
$bootData = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""

$oscdimgArgs = @(
    "-m",
    "-o",
    "-u2",
    "-udfver102",
    "-bootdata:$bootData",
    "$workDir",
    "$outputISO"
)

& $oscdimgExe @oscdimgArgs

# 4. 构建完成与提示
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " 全部构建圆满完成！ISO 镜像输出路径:" -ForegroundColor Green
Write-Host " $outputISO" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

Read-Host "按回车键 [ENTER] 清理临时工作缓存并退出..."

# 5. 清理挂载点与临时缓存
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript

# <<< [分块结束] 文件来源: src/10-PackageAndClean.ps1

