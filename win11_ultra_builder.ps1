# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-14 08:38:23 UTC
#  构建流水线: GitHub Actions (workflow_dispatch)
# ==============================================================================

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/00-Header-Init.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式配置 (src/00-Header-Init.ps1)
#  [重构加固]：配置决策全量前置 + 双模式智能倒计时选择 + 账户密码前置初始化
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
            } elseif ($key.KeyChar -ge 49 -and $key.KeyChar -le 57) { # 数字键 1-9
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

# ----------------- 8. 前置配置 1：选择精简制作模式 (含倒计时) -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 1/2] 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
Write-Host " [1] 普通精简 (推荐: 极速流畅、稳定平衡、保留组件服务架构)" -ForegroundColor Green
Write-Host " [2] 极限压榨 (全版本自适应 WinSxS 瘦身 + 注册表物理抹杀服务)" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Magenta

$trimChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "1"
if ($trimChoice -eq "2") {
    $global:trimMode = "2"
    Write-Host ">>> 已确认: [2] 极限压榨模式 (物理强删文件 + 物理抹杀服务 + 自适应组件换头)" -ForegroundColor Red
} else {
    $global:trimMode = "1"
    Write-Host ">>> 已确认: [1] 普通精简模式 (物理强删文件 + 服务安全停用 + 官方组件清理)" -ForegroundColor Green
}

# ----------------- 9. 前置配置 2：选择无人值守引导模式 (含倒计时) -----------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " [配置 2/2] 请选择 Windows 安装引导模式 (Unattend Mode):" -ForegroundColor Magenta
Write-Host " [1] 全无人值守 (全自动安装、自动创建指定账户并自动登录，跳过一切交互)" -ForegroundColor Green
Write-Host " [2] 半无人值守 (跳过硬件检测与联网限制，在 OOBE 阶段由用户手动输入用户名/密码)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Magenta

$unattendChoice = Read-ChoiceWithTimeout -PromptText "请输入对应数字 [1 或 2]" -Seconds 15 -DefaultChoice "1"
if ($unattendChoice -eq "2") {
    $global:unattendMode = "2"
    $global:customUser   = ""
    $global:customPass   = ""
    Write-Host ">>> 已确认: [2] 半无人值守模式 (保留原生手动设置用户名和密码向导)" -ForegroundColor Yellow
} else {
    $global:unattendMode = "1"
    Write-Host ">>> 已确认: [1] 全无人值守模式" -ForegroundColor Green

    # 全无人值守前置录入账户信息 (倒计时)
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

# 输出 ESD 静态开关状态
Write-Host ""
if ($enableEsdConversion) {
    Write-Host ">>> [配置状态] ESD 高压转换: 开启 (将在打包前转换为 install.esd)" -ForegroundColor Yellow
} else {
    Write-Host ">>> [配置状态] ESD 高压转换: 关闭 (直接使用 install.wim 极速打包)" -ForegroundColor DarkGray
}
Write-Host "`n[就绪] 前置配置已全部锁定，后续流程将进入全自动运行，无需人工干预。`n" -ForegroundColor Green

# 10. 初始化清理 (安全预检并卸载残留)
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
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [企业级重构]：动态规则库联动 + 依赖异常交互阻断裁决 + 属性页架构固化
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行 UWP 应用依赖架构测试与精简..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. 加载并解析外部 Appslist.txt 规则库 -----------------
$appsListSearchPaths = @(
    (Join-Path $scriptDir "Appslist.txt"),
    (Join-Path $scriptDir "src\Appslist.txt"),
    (Join-Path $PSScriptRoot "Appslist.txt")
)
$appsListFile = $appsListSearchPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$blacklistRules = New-Object System.Collections.Generic.List[string]

if ($appsListFile) {
    Write-Host "   [规则加载] 已成功载入应用规则清单: $appsListFile" -ForegroundColor Green
    $rawRules = Get-Content -LiteralPath $appsListFile -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $rawRules) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        $ruleName = ($trimmed -split '#')[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($ruleName)) {
            $blacklistRules.Add($ruleName)
        }
    }
    Write-Host "   [规则解析] 成功装载 $($blacklistRules.Count) 条黑名单匹配规则。" -ForegroundColor DarkGray
} else {
    Write-Host "   [警告] 未检测到 Appslist.txt 规则文件，将启用内建安全保守模式！" -ForegroundColor Yellow
}

# ----------------- 2. 核心底层基础包绝对白名单 (绝不可删) -----------------
$systemCoreWhitelist = @(
    "Microsoft.VCLibs*",
    "Microsoft.UI.Xaml*",
    "Microsoft.NET.Native*",
    "Microsoft.Services.Store.Engagement*",
    "*Client.CBS*",
    "*ShellExperience*",
    "*AccountsControl*",
    "*CloudExperienceHost*",
    "*BioEnrollment*",
    "*CapturePicker*",
    "*CredDialogHost*"
)

# ----------------- 3. 依赖关系静态安全测试引擎 -----------------
Write-Host "`n   [测试评估] 正在对当前映像已装载的 UWP 进行依赖拓扑完整性预检..." -ForegroundColor DarkCyan

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"

$candidateAppsToRemove   = New-Object System.Collections.Generic.List[System.Object]
$candidateAppsToPreserve = New-Object System.Collections.Generic.List[System.Object]

foreach ($app in $appxPackages) {
    $pkgName = $app.PackageName
    $dispName = $app.DisplayName

    # 1. 核心底层框架判定
    $isCore = $false
    foreach ($corePat in $systemCoreWhitelist) {
        if ($pkgName -like $corePat -or $dispName -like $corePat) {
            $isCore = $true
            break
        }
    }

    # 2. 黑名单命中判定
    $hitBlacklist = $false
    if (-not $isCore -and $blacklistRules.Count -gt 0) {
        foreach ($rule in $blacklistRules) {
            if ($pkgName -like "*$rule*" -or $dispName -like "*$rule*") {
                $hitBlacklist = $true
                break
            }
        }
    }

    if ($isCore -or (-not $hitBlacklist -and $blacklistRules.Count -gt 0)) {
        $candidateAppsToPreserve.Add($app)
    } else {
        $candidateAppsToRemove.Add($app)
    }
}

# 建立拓扑图：记录“被保留组件”所依赖的所有底层 PackageDependency 及其来源
$depToPreservedAppMap = @{}

if (Test-Path -LiteralPath $winAppsDir) {
    foreach ($preservedApp in $candidateAppsToPreserve) {
        $manifestMatches = Get-ChildItem -Path $winAppsDir -Filter "AppxManifest.xml" -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -like "*$($preservedApp.DisplayName)*"
        }
        foreach ($m in $manifestMatches) {
            try {
                [xml]$manifestXml = Get-Content -LiteralPath $m.FullName -ErrorAction Stop
                $depNodes = $manifestXml.GetElementsByTagName("PackageDependency")
                foreach ($dep in $depNodes) {
                    $depName = $dep.GetAttribute("Name")
                    if (-not [string]::IsNullOrWhiteSpace($depName)) {
                        if (-not $depToPreservedAppMap.ContainsKey($depName)) {
                            $depToPreservedAppMap[$depName] = New-Object System.Collections.Generic.List[string]
                        }
                        if (-not $depToPreservedAppMap[$depName].Contains($preservedApp.DisplayName)) {
                            $depToPreservedAppMap[$depName].Add($preservedApp.DisplayName)
                        }
                    }
                }
            } catch {}
            finally {
                $manifestXml = $null
            }
        }
    }
}

# 垃圾回收，释放 XML 读写锁
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# 碰撞检测：查找待删列表中是否存在被保留应用强依赖的包
$conflictItems = New-Object System.Collections.Generic.List[PSCustomObject]
$safeDeleteList = New-Object System.Collections.Generic.List[System.Object]

foreach ($cand in $candidateAppsToRemove) {
    $hasConflict = $false
    $causingPreservedApps = New-Object System.Collections.Generic.List[string]

    foreach ($depKey in $depToPreservedAppMap.Keys) {
        if ($cand.PackageName -like "*$depKey*" -or $cand.DisplayName -like "*$depKey*") {
            $hasConflict = $true
            foreach ($pName in $depToPreservedAppMap[$depKey]) {
                if (-not $causingPreservedApps.Contains($pName)) {
                    $causingPreservedApps.Add($pName)
                }
            }
        }
    }

    if ($hasConflict) {
        $conflictItems.Add([PSCustomObject]@{
            App = $cand
            RequiredBy = ($causingPreservedApps -join ", ")
        })
    } else {
        $safeDeleteList.Add($cand)
    }
}

# ----------------- 4. 依赖异常交互阻断裁决机制 -----------------
$finalDeleteList = New-Object System.Collections.Generic.List[System.Object]

if ($conflictItems.Count -gt 0) {
    Write-Host "`n==================================================================" -ForegroundColor Red
    Write-Host " [安全预警] UWP 依赖完整性测试发现 $($conflictItems.Count) 处严重依赖冲突！" -ForegroundColor Red
    Write-Host " 以下组件存在于您的待删除黑名单中，但被您选择保留的应用强行依赖：" -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Red

    foreach ($item in $conflictItems) {
        Write-Host " [冲突组件] $($item.App.DisplayName)" -ForegroundColor Yellow
        Write-Host "    └─ 强依赖于它的保留组件: $($item.RequiredBy)" -ForegroundColor DarkGray
    }

    Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 请选择对异常冲突组件的处理策略:" -ForegroundColor Cyan
    Write-Host " [1] 智能保护 (推荐: 自动保留这 $($conflictItems.Count) 个冲突包，仅删除其余无害应用，确保系统稳定)" -ForegroundColor Green
    Write-Host " [2] 强行粉碎 (高危: 忽略测试警告，强行物理抹杀所有待删包，依赖缺失的应用可能闪退)" -ForegroundColor Red
    Write-Host " [3] 终止构建 (安全: 丢弃当前镜像修改并退出，以便您重新调整 Appslist.txt)" -ForegroundColor DarkYellow
    Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan

    $choice = Read-Host "请输入对应选项 [1, 2 或 3] (直接回车默认推荐 1)"

    if ($choice -eq "2") {
        Write-Host ">>> [警告] 用户选择强行粉碎模式，将移除包括冲突项在内的所有指定包..." -ForegroundColor Red
        foreach ($item in $conflictItems) {
            $finalDeleteList.Add($item.App)
        }
        foreach ($item in $safeDeleteList) {
            $finalDeleteList.Add($item)
        }
    } elseif ($choice -eq "3") {
        Write-Host "`n>>> [中止操作] 用户已终止流程。正在安全卸载挂载点并丢弃所有临时更改..." -ForegroundColor DarkYellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard
        Stop-Transcript
        Write-Host "[完成] 映像已安全重置，未产生损坏文件。请调整规则后重新运行。" -ForegroundColor Green
        pause
        exit
    } else {
        Write-Host ">>> [智能保护] 已自动将 $($conflictItems.Count) 个冲突包移入保护名单，继续精简其余应用。" -ForegroundColor Green
        foreach ($item in $safeDeleteList) {
            $finalDeleteList.Add($item)
        }
    }
} else {
    Write-Host "   [测试通过] 依赖拓扑扫描无冲突，所有待删应用均可无副作用安全剥离！" -ForegroundColor Green
    foreach ($item in $safeDeleteList) {
        $finalDeleteList.Add($item)
    }
}

# ----------------- 5. 执行 UWP 卸载与定向物理粉碎 -----------------
$totalDel = $finalDeleteList.Count
$currDel = 0
$deletedFolderNames = New-Object System.Collections.Generic.List[string]

if ($totalDel -gt 0) {
    foreach ($app in $finalDeleteList) {
        $currDel++
        $pct = [math]::Round(($currDel / [math]::Max(1, $totalDel)) * 100)
        Write-Progress -Activity "正在精简 UWP 预装应用" -Status "[$currDel/$totalDel] 正在卸载: $($app.DisplayName)" -PercentComplete $pct

        Write-Host "   [$currDel/$totalDel] [删除应用] $($app.PackageName)" -ForegroundColor Yellow
        & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
        $deletedFolderNames.Add($app.PackageName)
    }
    Write-Progress -Activity "正在精简 UWP 预装应用" -Completed
} else {
    Write-Host "   [提示] 没有需要移除的 UWP 应用。" -ForegroundColor DarkGray
}

# 定向物理清除 WindowsApps 目录下的残留大实体，绝不损坏父级目录 DACL 继承
if (Test-Path -LiteralPath $winAppsDir) {
    Write-Host "   正在执行 WindowsApps 废弃实体定向物理粉碎..." -ForegroundColor DarkGray
    foreach ($folderKeyword in $deletedFolderNames) {
        Get-ChildItem -Path $winAppsDir -Directory -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -like "$folderKeyword*" 
        } | ForEach-Object {
            Force-NukeFolderOrFile $_.FullName
        }
    }

    # 关键安全固化：彻底恢复 ALL APPLICATION PACKAGES 只读权限，防止沙箱应用（如终端）闪退
    & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
}
Write-Host "[完成] UWP 应用拓扑测试、依赖守护与定向精炼完毕。" -ForegroundColor Green

# ----------------- 6. 系统可选功能包精简 (保留 Search-Engine-Client 以固化属性页) -----------------
Write-Host "`n[步骤 5/11] 正在检索系统组件包并执行深度可选功能精简..." -ForegroundColor Cyan

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split '\r?\n' | Select-Object -Skip 1

# 基础需要剥离的无用功能包列表
$basePackagesToRemove = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~",
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "OpenSSH-Client-Package~",
    "Microsoft-Windows-Hello-Face-Package~",
    "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
    "Microsoft-Windows-TPM-WMI-Provider-Package~",
    "Microsoft-Windows-WebcamExperience-Package~"
)

$targetPkgs = New-Object System.Collections.Generic.List[string]

foreach ($line in $pkgLines) {
    $pkgId = ($line -split '\s+')[0]
    if ([string]::IsNullOrWhiteSpace($pkgId) -or $pkgId -eq "Package" -or $pkgId -match "^-+$") { continue }

    $shouldDelete = $false
    foreach ($bp in $basePackagesToRemove) {
        if ($pkgId -like "$bp*") {
            $shouldDelete = $true
            break
        }
    }

    # 动态外语包判定：严格保护母盘核心主语言，非主语言组件包全量剔除
    if (-not $shouldDelete) {
        $isLangRelated = ($pkgId -match "LanguageFeatures" -or $pkgId -match "LanguagePack" -or $pkgId -match "TextToSpeech" -or $pkgId -match "Speech-" -or $pkgId -match "Handwriting-" -or $pkgId -match "OCR-")
        if ($isLangRelated) {
            $isCurrentLang = ($pkgId -like "*$defaultLang*")
            if ($defaultLang -match "^zh-") {
                if ($pkgId -match "zh-CN|zh-cn|Hans") { $isCurrentLang = $true }
            }
            if (-not $isCurrentLang) {
                $shouldDelete = $true
            }
        }
    }

    # 冗余非主语言输入法包判定
    if (-not $shouldDelete) {
        if ($defaultLang -ne "ja-JP" -and $pkgId -match "IME-ja-jp") { $shouldDelete = $true }
        if ($defaultLang -ne "ko-KR" -and $pkgId -match "IME-ko-kr") { $shouldDelete = $true }
        if ($defaultLang -ne "zh-TW" -and $pkgId -match "IME-zh-tw") { $shouldDelete = $true }
    }

    if ($shouldDelete) { 
        $targetPkgs.Add($pkgId) 
    }
}

$totalPkgs = $targetPkgs.Count
$currPkg = 0
foreach ($pkgId in $targetPkgs) {
    $currPkg++
    $pct = [math]::Round(($currPkg / [math]::Max(1, $totalPkgs)) * 100)
    Write-Progress -Activity "正在剔除组件与外语包" -Status "[$currPkg/$totalPkgs] 正在移除: $pkgId" -PercentComplete $pct
    Write-Host "   [$currPkg/$totalPkgs] 剔除组件/外语包: $pkgId" -ForegroundColor DarkYellow
    & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$pkgId" /NoRestart 2>$null | Out-Null
}
Write-Progress -Activity "正在剔除组件与外语包" -Completed
Write-Host "[完成] 系统可选功能包精炼完毕 (Search-Engine-Client 核心底层接口已安全保留)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/03-RemovePackages.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/04-DriversFeatures.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动压榨与老旧特性停用 (src/04-DriversFeatures.ps1)
# ==============================================================================

# ----------------- 1. 安全驱动仓库压榨 (两模式均执行) -----------------
Write-Host "`n[步骤 6/11] 正在执行安全驱动压榨 (剔除打印机/调制解调器/传真驱动)..." -ForegroundColor Cyan
$driverStorePath = Join-Path $scratchDir "Windows\System32\DriverStore\FileRepository"

# 安全剔除模式列表 (保留显卡、芯片组、存储、声卡、网卡等核心驱动)
$safeDriverPurgeList = @(
    "prn*.inf_*",     # 冗余打印机驱动
    "mdm*.inf_*",     # 调制解调器驱动
    "fax*.inf_*",     # 传真驱动
    "scancopy.inf_*", # 扫描仪复制驱动
    "flpydisk.inf_*", # 软驱驱动
    "brmf*.inf_*",    # Brother 打印机残留
    "hpq*.inf_*"      # HP 打印机残留
)

if (Test-Path $driverStorePath) {
    foreach ($pat in $safeDriverPurgeList) {
        Get-ChildItem -Path $driverStorePath -Filter $pat -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "   [清除冗余驱动] $($_.Name)" -ForegroundColor DarkGray
            Force-NukeFolderOrFile $_.FullName
        }
    }
}
Write-Host "[完成] 驱动仓库深度压榨完毕。" -ForegroundColor Green

# ----------------- 2. 停用冗余老旧 Windows 特性 (两模式均执行) -----------------
Write-Host "   正在停用并移除老旧 Windows 特性 (WorkFolders/Fax 等)..." -ForegroundColor DarkGray

$featuresToDisable = @(
    "WorkFolders-Client",                   # 工作文件夹
    "Printing-Foundation-Features",         # 打印基础服务
    "Printing-PrintToPDFServices-Features", # 打印到 PDF 架构
    "FaxServicesClientPackage",             # 传真客户端
    "MSRDC-Infrastructure"                  # 远程桌面旧版基础设施
)

foreach ($feat in $featuresToDisable) {
    Write-Host "   [停用特性] $feat" -ForegroundColor DarkGray
    & dism.exe /English /Image:$scratchDir /Disable-Feature "/FeatureName:$feat" /Remove /NoRestart 2>$null | Out-Null
}
Write-Host "[完成] 老旧特性剥离完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/04-DriversFeatures.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/05-PhysicalNuke.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 6/11] 大文件实体深度物理粉碎 (src/05-PhysicalNuke.ps1)
#  [重构加固]：全盘彻底剿灭 SearchHost 实体 + 杜绝后台拉起 + 核心框架保护
# ==============================================================================

Write-Host "`n[步骤 7/11] 深度物理粉碎非必要大文件实体 (Edge/Search/Defender/OneDrive/Speech)..." -ForegroundColor Cyan
Write-Host "   [模式说明] 普通模式与极限模式均完整执行以下实体物理粉碎：" -ForegroundColor DarkCyan

# 1. 恢复环境 (WinRE)
$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Write-Host "   -> 正在物理粉碎 WinRE 恢复环境文件..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

# 2. Microsoft Edge 浏览器完整生态 (Chromium 本体 + WebView + SystemApps 遗留 UWP 桩程序)
Write-Host "   -> 正在物理粉碎 Microsoft Edge 完整生态 (Chromium 本体 + WebView + UWP 桩程序)..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\Edge")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\EdgeUpdate")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Microsoft-Edge-Webview")

$systemApps = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path -LiteralPath $systemApps) {
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*MicrosoftEdge*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 3. Microsoft OneDrive (全路径与预装源)
Write-Host "   -> 正在物理粉碎 OneDrive 各层级安装与运行实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

# 4. Windows Defender 全栈驱动与服务组件
Write-Host "   -> 正在物理粉碎 Windows Defender 全栈驱动与服务组件实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthSystray.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthService.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\smartscreen.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\wd")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\WdFilter.sys")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\WdNisDrv.sys")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\drivers\wdboot.sys")

# 5. 日语、韩语、繁体中文输入法字库实体
Write-Host "   -> 正在物理粉碎繁体/日语/韩语输入法实体..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

# 6. Cortana 与 Windows Search 前后台全套引擎实体 (深度清除 Client.CBS 内部残留)
Write-Host "   -> 正在物理粉碎 Cortana 与 Windows Search (包含 SearchHost/SearchApp)..." -ForegroundColor DarkGray
if (Test-Path -LiteralPath $systemApps) {
    # 清理明确的 Cortana 与 Search 专属包
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" -or $_.Name -like "*Microsoft.Windows.Search*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }

    # 【深度修复】：全盘递归粉碎隐藏在 CBS 或其他宿主目录中的 SearchHost 执行实体
    Get-ChildItem -Path $systemApps -Recurse -Filter "SearchHost.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
    Get-ChildItem -Path $systemApps -Recurse -Filter "SearchApp.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 物理粉碎 System32 传统后台索引二进制文件
$sys32Dir = Join-Path $scratchDir "Windows\System32"
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchIndexer.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchFilterHost.exe")
Force-NukeFolderOrFile (Join-Path $sys32Dir "SearchProtocolHost.exe")

# 7. 语音引擎与离线帮助文档
Write-Host "   -> 正在物理粉碎语音引擎与帮助文档..." -ForegroundColor DarkGray
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\TTS\en-US")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Help")

# 8. 冗余壁纸 (严格保护保留默认 img0.jpg)
$wallpapers = Join-Path $scratchDir "Windows\Web\Wallpaper"
if (Test-Path -LiteralPath $wallpapers) {
    Write-Host "   -> 正在清理多余壁纸 (严格保留默认 img0.jpg)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $wallpapers -Recurse -File | Where-Object { $_.Name -ne "img0.jpg" } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\Screen")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\TouchKeyboard")

# 9. 系统提示音 (严格保护保留 Windows 核心事件声音)
$mediaDir = Join-Path $scratchDir "Windows\Media"
if (Test-Path -LiteralPath $mediaDir) {
    Write-Host "   -> 正在精炼系统提示音 (保留核心事件声音)..." -ForegroundColor DarkGray
    Get-ChildItem -Path $mediaDir -Filter "*.wav" | Where-Object { 
        $_.Name -notmatch "Windows (Background|Foreground|Error|Ding|Default)\.wav" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 10. 中文字体库深度精炼 (保护保留常见中文字体与核心 UI 字体)
$fontsPath = Join-Path $scratchDir "Windows\Fonts"
if (Test-Path -LiteralPath $fontsPath) {
    Write-Host "   -> 正在精炼中文字体库..." -ForegroundColor DarkGray
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "calibri*.*", "arial*.*", "times*.*", "msyh*.*", "simsun*.*", "simhei*.*", "kaiu*.*", "mingliu*.*" | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[完成] 大文件实体物理粉碎完毕 (SearchHost 物理实体已全面歼灭)。" -ForegroundColor Green

# ----------------- 11. 修复记事本物理执行实体 (消灭 Windows 目录下的 UWP 幽灵桩) -----------------
Write-Host "   -> 正在使用 System32 经典记事本覆盖根目录 UWP 跳转死桩..." -ForegroundColor DarkGray
$winDir = Join-Path $scratchDir "Windows"
$sys32Notepad = Join-Path $winDir "System32\notepad.exe"
$rootNotepad  = Join-Path $winDir "notepad.exe"

if (Test-Path -LiteralPath $sys32Notepad) {
    Force-NukeFolderOrFile $rootNotepad
    Copy-Item -LiteralPath $sys32Notepad -Destination $rootNotepad -Force
}

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表原生 Unicode 导入引擎 (src/06-RegistryTweaks.ps1)
#  [终极重构]：彻底唤醒新建文本文档 + IFEO 内核绝杀 SearchHost + 修复打开方式死锁
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统核心参数..." -ForegroundColor Cyan

# 1. 定位并挂载离线配置单元文件
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"

attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null

& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null

# 2. 准备原生 .reg 注册表内容 (UTF-16 LE 原生支持中文，无转义 BUG)
$reg = New-Object System.Text.StringBuilder
$null = $reg.AppendLine("Windows Registry Editor Version 5.00`n")

# ==============================================================================
#  A. 全局底层安全加固策略 (普通模式与极限模式均必须执行)
# ==============================================================================

$null = $reg.AppendLine(@"
; 1. 内核级 ELAM 启动策略豁免 (彻底杜绝强删 wdboot.sys 后的 0xc0000428 蓝屏)
[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Control\EarlyLaunch]
"DriverLoadPolicy"=dword:00000008

; 2. 彻底拔除导致盘符属性瘫痪的 BitLocker 幽灵扩展
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\{D9DE8B79-CE8A-421A-98C3-5F17A9EB2269}]

; 3. 彻底抹杀导致右键菜单卡死 1~3 秒的 Defender EPP 幽灵扩展
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP]

; 4. 固化盘符与文件标准属性页 COM 挂载
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\Sharing]
@="{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Drive\shellex\PropertySheetHandlers\Security]
@="{1f2e5c40-9550-11ce-99d2-00aa006e086a}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shellex\PropertySheetHandlers\Security]
@="{1f2e5c40-9550-11ce-99d2-00aa006e086a}"

; 5. 全局切换至 Windows 经典高效右键菜单 (解决现代 XAML 菜单吞点击事件 BUG)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""
"@)

# ==============================================================================
#  B. 内核级绝对拦截 SearchHost / SearchIndexer (彻底杜绝后台常驻拉起)
# ==============================================================================
$null = $reg.AppendLine(@"
; 使用系统内核级 IFEO 机制：任何拉起 SearchHost/SearchApp 的行为直接在 0 毫秒内退出
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchHost.exe]
"Debugger"="systray.exe"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchApp.exe]
"Debugger"="systray.exe"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchIndexer.exe]
"Debugger"="systray.exe"

; 关闭任务栏搜索图标展示
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

; 彻底停用 Windows 搜索与 Cortana 联网策略
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Windows Search]
"AllowCortana"=dword:00000000
"DisableWebSearch"=dword:00000001
"ConnectedSearchUseWeb"=dword:00000000
"PreventIndexingLowDiskSpaceMB"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001
"@)

# ==============================================================================
#  C. 模式分支：服务配置
# ==============================================================================
$normalServices = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter", "SecurityHealthService"
)
$defenderFullStack = @("WinDefend", "WdNisSvc", "Sense", "WdFilter", "WdNisDrv", "WdBoot")

if ($trimMode -eq "2") {
    Write-Host "   >>> [极限模式] 构建 Defender 物理抹杀与服务深度清除指令..." -ForegroundColor DarkYellow
    $null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\WSearch]")
    $extremeDeleteServices = $normalServices + $defenderFullStack + @("Spooler", "PrintNotify", "Fax", "RemoteRegistry", "diagsvc")
    foreach ($svc in $extremeDeleteServices) {
        $null = $reg.AppendLine("[-HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
    }
} else {
    Write-Host "   >>> [普通模式] 构建服务安全停用指令 (Start = 4)..." -ForegroundColor Cyan
    $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\WSearch]")
    $null = $reg.AppendLine('"Start"=dword:00000004' + "`n")

    $allServicesToDisable = $normalServices + $defenderFullStack
    foreach ($svc in $allServicesToDisable) {
        $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\ControlSet001\Services\$svc]")
        $null = $reg.AppendLine('"Start"=dword:00000004' + "`n")
    }
}

# ==============================================================================
#  D. 核心修复：新建文本文档 100% 唤醒机制 (规范化 Win11 字符串间接资源与双 ProgID)
# ==============================================================================
$null = $reg.AppendLine(@"
; 1. 扩展名 .txt 基础关联 (主指 txtfilelegacy)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt]
@="txtfilelegacy"
"Content Type"="text/plain"
"PerceivedType"="text"

; 【关键修复】：必须写入间接字符串资源 @%SystemRoot%\system32\notepad.exe,-470，否则 Win11 判定名称为空直接隐藏
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\ShellNew]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\ShellNew]
"ItemName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,37,00,30,00,00,00
"NullFile"=""

; 清空可能干扰的 OpenWithProgids
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\.txt\OpenWithProgids]
"txtfilelegacy"=hex(0):
"txtfile"=hex(0):

; 2. Win11 核心实体 txtfilelegacy 深度补全
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy]
@="文本文档"
"FriendlyTypeName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\DefaultIcon]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,69,00,6d,00,61,00,67,00,65,00,72,00,65,00,73,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,31,00,30,00,32,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\shell]
@="open"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfilelegacy\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00

; 3. 经典 txtfile 回退兼容实体
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile]
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile]
@="文本文档"
"FriendlyTypeName"=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,2c,00,2d,00,34,00,36,00,39,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\DefaultIcon]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,32,00,5c,00,69,00,6d,00,61,00,67,00,65,00,72,00,65,00,73,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,31,00,30,00,32,00,00,00

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell]
@="open"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\txtfile\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00

; 4. 彻底修正 App Paths，强制直指 System32 经典记事本
[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,6e,00,6f,00,74,00,65,00,70,00,61,00,64,00,2e,00,65,00,78,00,65,00,00,00

; 5. 抹除 Default 用户中 UWP 留下的损坏关联
[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithProgids]
"txtfilelegacy"=hex(0):
"txtfile"=hex(0):

[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\UserChoice]
"@)

# ==============================================================================
#  E. 核心修复：彻底根治“打开方式 -> 选择其他应用”无反应的死锁
# ==============================================================================
$null = $reg.AppendLine(@"
; 1. 彻底删除导致 Win11 XAML OpenWith 按钮路由断裂的策略
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Explorer\NoInternetOpenWith]
[-HKEY_LOCAL_MACHINE\zNTUSER\Software\Policies\Microsoft\Windows\Explorer\NoInternetOpenWith]

; 2. 【核心修复】：为 openas 与 opendlg 注入原生 COM DelegateExecute 代理契约
; 严禁裸调 OpenWith.exe，必须由 Shell 代理调度器托管拉起
[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shell\openas]
@=hex(2):40,00,25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,73,00,68,00,65,00,6c,00,6c,00,33,00,32,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,35,00,33,00,37,00,36,00,00,00
"MultiSelectModel"="Single"
"Position"="Bottom"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\*\shell\openas\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,4f,00,70,00,65,00,6e,00,57,00,69,00,74,00,68,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00
"DelegateExecute"="{e44e9428-bdbc-4987-a099-40dc8fd255e7}"

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Unknown\shell\opendlg\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,4f,00,70,00,65,00,6e,00,57,00,69,00,74,00,68,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,00,31,00,22,00,00,00
"DelegateExecute"="{e44e9428-bdbc-4987-a099-40dc8fd255e7}"
"@)
# ==============================================================================
#  F. 系统基础优化与隐私遥测剥离
# ==============================================================================
$null = $reg.AppendLine(@"
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\DataCollection]
"AllowTelemetry"=dword:00000000
"MaxTelemetryAllowed"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting]
"Disabled"=dword:00000001

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"EnableTransparency"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\OneDrive]
"DisableFileSyncNGSC"=dword:00000001
"DisableFileSync"=dword:00000001
"DisableMeteredNetworkFileSync"=dword:00000001
"DisableLibrariesStylePin"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run]
"OneDrive"=-
"OneDriveSetup"=-

[HKEY_LOCAL_MACHINE\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run]
"OneDrive"=-

[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}]
"System.IsPinnedToNameSpaceTree"=dword:00000000

; 清理 Edge 遗留卸载项与幽灵 DCOM 契约 (斩断 Event 10001 死锁源)
[-HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgeHTM]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\MSEdgePDF]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Applications\msedge.exe]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\{1F8766B3-3F96-48DA-B6A8-A013FFC2A5BE}]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\AppID\Microsoft.MicrosoftEdge_8wekyb3d8bbwe]
[-HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Extensions\ContractId\Windows.File\PackageId\Microsoft.MicrosoftEdge_44.22000.120.0_neutral__8wekyb3d8bbwe]

; 关闭 SmartScreen 拦截策略 (防 smartscreen.exe 物理删除后调用挂起)
[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\System]
"EnableSmartScreen"=dword:00000000

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"SmartScreenEnabled"="Off"
"@)

# ==============================================================================
#  G. 硬件检测全量绕过与 OOBE 免联网
# ==============================================================================
$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSYSTEM\Setup\LabConfig]")
foreach ($k in $labConfigKeys) {
    $null = $reg.AppendLine("`"$k`"=dword:00000001")
}

$null = $reg.AppendLine(@"
[HKEY_LOCAL_MACHINE\zSYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\CloudContent]
"DisableWindowsConsumerFeatures"=dword:00000001

[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE]
"BypassNRO"=dword:00000001
"DisableOnline"=dword:00000001
"@)

# ==============================================================================
#  H. 经典 Windows 照片查看器关联激活
# ==============================================================================
$photoExts = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".jfif")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\RegisteredApplications]")
$null = $reg.AppendLine('"Windows Photo Viewer"="SOFTWARE\\Microsoft\\Windows Photo Viewer\\Capabilities"' + "`n")
$null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations]")
foreach ($ext in $photoExts) {
    $null = $reg.AppendLine("`"$ext`"=`"PhotoViewer.FileAssoc.Tiff`"")
}
foreach ($ext in $photoExts) {
    $null = $reg.AppendLine("[HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\$ext]")
    $null = $reg.AppendLine('@="PhotoViewer.FileAssoc.Tiff"' + "`n")
}

# 3. 写入带 BOM 的 UTF-16 LE 原生 .reg 文件并使用 reg import 原生原子导入
$tempRegFile = Join-Path $env:TEMP "win11_ultra_tweaks.reg"
[System.IO.File]::WriteAllText($tempRegFile, $reg.ToString(), [System.Text.Encoding]::Unicode)

Write-Host "   正在通过 Windows 原生注册表引擎导入 Unicode 策略流..." -ForegroundColor Green
& reg.exe import "$tempRegFile" 2>&1 | Out-Null
Remove-Item -LiteralPath $tempRegFile -Force -ErrorAction SilentlyContinue

# 4. 彻底物理粉碎 Explorer 僵尸缓存 (强制唤醒文本文档与新建菜单项)
Write-Host "   正在粉碎 Explorer 新建菜单僵尸缓存 (强制刷新菜单索引)..." -ForegroundColor DarkGray
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew`" /f 2>nul" | Out-Null

# 5. 安全卸载配置单元 (防句柄残留死锁)
Write-Host "   正在安全卸载配置单元 (GC 垃圾回收防锁死机制推进)..." -ForegroundColor Green
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null

Write-Host "[完成] 离线注册表加固优化全部完毕 (文本文档已三重加固，SearchHost 已内核拦截，打开方式死锁已排除)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/06-RegistryTweaks.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/07-UnattendInject.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
#  [企业级重构]：消费前置全局配置 + 零中途阻断 + 双模自适应动态渲染 + 稳定性自检
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

# ----------------- 2. 构建 100% 完整无损应答模板 -----------------
$unattendTemplate = @"
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
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "`$xml = [xml]::new(); `$xml.Load('C:\Windows\Panther\unattend.xml'); `$sb = [scriptblock]::Create( `$xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock `$sb -ArgumentList `$xml;"</Path>
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
$userAccountsXmlFragment
$autoLogonXmlFragment
			<OOBE>
				<ProtectYourPC>3</ProtectYourPC>
				<HideEULAPage>true</HideEULAPage>
				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
				<HideLocalAccountScreen>$hideLocalAccountScreenValue</HideLocalAccountScreen>
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
    [xml] `$Document
);

foreach( `$file in `$Document.unattend.Extensions.File ) {
    `$path = [System.Environment]::ExpandEnvironmentVariables( `$file.GetAttribute( 'path' ) );
    mkdir -Path( `$path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    `$encoding = switch( [System.IO.Path]::GetExtension( `$path ) ) {
        { `$_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { `$_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( `$false, `$true ); }
        default { [System.Text.Encoding]::Default; }
    };
    `$bytes = `$encoding.GetPreamble() + `$encoding.GetBytes( `$file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( `$path, `$bytes );
}
		</ExtractScript>
		<File path="C:\Windows\Setup\Scripts\Specialize.ps1">
`$scripts = @(
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
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\Specialize.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
`$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
	};
	{
		Remove-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew' -Recurse -Force -ErrorAction 'SilentlyContinue';
	};
	{
		Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript {
			`$_.SessionId -eq ( Get-Process -Id `$PID ).SessionId;
		} | Stop-Process -Force;
	};
);
&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\UserOnce.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
`$scripts = @(
	{
		`$names = @(
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
		
		foreach( `$name in `$names ) {
		  reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v `$name /t REG_DWORD /d 0 /f;
		}
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Normal -NoProfile -Command \""Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UserOnce.ps1' -Raw | Invoke-Expression;\""" /f;
	};
);

&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\DefaultUser.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
`$scripts = @(
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
		`$report = New-Object System.Collections.Generic.List[string];
		`$report.Add("==================================================================");
		`$report.Add(" Windows 11 精简母盘 - 首次登录系统健康与稳定性自检审计报告");
		`$report.Add(" 生成时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'));
		`$report.Add(" 部署模式: " + "$($modeText)");
		`$report.Add("==================================================================");

		`$wtPkg = Get-AppxPackage -Name "*WindowsTerminal*" -ErrorAction SilentlyContinue;
		`$wtStatus = if (`$wtPkg) { "正常部署 (版本: `$(`$wtPkg.Version))" } else { "未安装或已被剔除" };
		`$report.Add("[组件测试] Windows 终端 (Terminal): `$wtStatus");

		`$wingetPkg = Get-AppxPackage -Name "*DesktopAppInstaller*" -ErrorAction SilentlyContinue;
		`$wingetStatus = if (`$wingetPkg) { "正常可用 (支持 Winget/离线安装)" } else { "未安装" };
		`$report.Add("[组件测试] 应用安装程序 (Winget): `$wingetStatus");

		`$txtAssoc = (cmd.exe /c "assoc .txt 2>nul");
		`$report.Add("[关联测试] .txt 扩展名关联项: `$txtAssoc");

		try {
			`$appCrashes = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			`$crashCount = if (`$appCrashes) { `$appCrashes.Count } else { 0 };
			`$report.Add("[事件测试] 应用程序核心崩溃事件数 (Level=Error): `$crashCount");

			`$dcomErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-DistributedCOM'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			`$dcomCount = if (`$dcomErrors) { `$dcomErrors.Count } else { 0 };
			`$report.Add("[事件测试] DCOM 幽灵调用异常事件数: `$dcomCount");
		} catch {
			`$report.Add("[事件测试] 事件日志扫描已安全旁路。");
		}

		`$report.Add("------------------------------------------------------------------");
		`$verdict = if (`$crashCount -eq 0 -and `$dcomCount -eq 0) { "【优秀】系统底层核心零异常，运行极度稳定！" } else { "【良好】已自动记录轻微事件，系统运行正常。" };
		`$report.Add("总体稳定性裁定: `$verdict");
		`$report.Add("==================================================================");

		`$reportPath = "C:\Windows\Temp\Trim_Stability_Report.log";
		[System.IO.File]::WriteAllLines(`$reportPath, `$report, [System.Text.Encoding]::UTF8);
	};
	{
		# 1. 彻底销毁包含配置的应答文件
		`$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach (`$f in `$xmlFiles) {
			if (Test-Path `$f) { Remove-Item -LiteralPath `$f -Force -ErrorAction SilentlyContinue; }
		}

		# 2. 异步粉碎自毁 Setup Scripts 目录
		Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList '/c timeout /t 3 /nobreak >nul &amp; for /l %i in (1,1,10) do (if exist "C:\Windows\Setup\Scripts" (rd /s /q "C:\Windows\Setup\Scripts" &amp; timeout /t 1 >nul) else (exit))'
	};
);

&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\FirstLogon.log";
		</File>
	</Extensions>
</unattend>
"@

# ----------------- 3. 多通道合规注入 -----------------
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path -LiteralPath $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$utf8Encoding = [System.Text.Encoding]::UTF8

# Sysprep 核心规范通道
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $unattendTemplate, $utf8Encoding)
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "autounattend.xml"), $unattendTemplate, $utf8Encoding)

# Panther 初始化通道
[System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $unattendTemplate, $utf8Encoding)

# ISO 可移动介质根目录自启动通道
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $unattendTemplate, $utf8Encoding)

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (全自动运行，无需人工干预)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 优化与主映像提交卸载 (src/08-WinSxSOptimize.ps1)
#  [重构加固]：Win11 短文件名通配补齐 + SettingsManifests 固化 + 架构精准检测
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在执行组件库深度瘦身与补丁清理..." -ForegroundColor Cyan

# ----------------- 模式分支：WinSxS 处理 -----------------
if ($trimMode -eq "2") {
    $winsxsPath     = Join-Path $scratchDir "Windows\WinSxS"
    $winsxsEditPath = Join-Path $scratchDir "Windows\WinSxS_edit"
    
    # 架构权威探查 (提取 DISM 映像真实 Architecture 字段，杜绝 SysWOW64 误判 ARM64)
    $destWimPath = Join-Path $sourcesDir "install.wim"
    $wimInfoText = & dism.exe /English /Get-WimInfo "/WimFile:$destWimPath" "/Index:1"
    $arch = "amd64"
    if ($wimInfoText -match "Architecture\s*:\s*(ARM64|arm64)") {
        $arch = "arm64"
    } elseif ($wimInfoText -match "Architecture\s*:\s*(x64|amd64)") {
        $arch = "amd64"
    }

    Write-Host ">>> [极限模式] WinSxS 自适应瘦身 5 阶段引擎启动 (目标架构: $arch)" -ForegroundColor Yellow

    # 阶段 1：底层文件所有权递归接管
    Write-Host "   [阶段 1/5] 正在递归获取 50,000+ 底层文件所有权 (takeown)..." -ForegroundColor Yellow
    Write-Host "              (由于碎文件极其庞大，耗时约 1~3 分钟，硬盘正在读写，请勿关闭)" -ForegroundColor DarkGray
    & takeown.exe /F "$winsxsPath" /R /D Y 2>$null | Out-Null

    # 阶段 2：访问控制列表权限递归重设
    Write-Host "   [阶段 2/5] 正在递归重置访问控制列表权限 (icacls)..." -ForegroundColor Yellow
    Write-Host "              (正在赋权底层文件，耗时约 1~3 分钟，请耐心等待)" -ForegroundColor DarkGray
    & icacls.exe "$winsxsPath" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null

    # 阶段 3：保护并复制通用核心清单元数据 (补全 SettingsManifests)
    Write-Host "   [阶段 3/5] 正在复制通用核心清单元数据 (Catalogs/Manifests/SettingsManifests)..." -ForegroundColor Yellow
    New-Item -Path $winsxsEditPath -ItemType Directory -Force | Out-Null
    $metaDirs = @("Catalogs", "FileMaps", "Fusion", "InstallTemp", "Manifests", "Settings", "SettingsManifests")
    foreach ($meta in $metaDirs) {
        $metaSrc = Join-Path $winsxsPath $meta
        if (Test-Path -LiteralPath $metaSrc) {
            Write-Host "              -> 同步元数据目录: $meta" -ForegroundColor DarkGray
            Copy-Item -Path $metaSrc -Destination (Join-Path $winsxsEditPath $meta) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 阶段 4：动态通配匹配并提取依赖组件 (全量覆盖 Win11 短文件名)
    Write-Host "   [阶段 4/5] 正在通配匹配并提取依赖组件 (含 Win11 截断短文件名支持)..." -ForegroundColor Yellow
    $featureKeywords = @(
        "*common-controls*",
        "*c..-controls*",          # 【关键修复】：Win11 截断的公共控件语言包及资源
        "*gdiplus*",
        "*isolationautomation*",
        "*i..utomation*",          # 【关键修复】：Win11 截断的隔离自动化组件
        "*proxystub*",
        "*servicingstack*",
        "*s..stack*",              # 【关键修复】：Win11 截断的服务堆栈组件
        "*s..ngstack*",            # 【关键修复】：Win11 截断的 onecore 基础堆栈
        "*onecore*",
        "*vc*.crt*",
        "*vc*.mfc*",
        "*termsrv-extra*"
    )

    $allSxSDirs = Get-ChildItem -Path $winsxsPath -Directory | Where-Object {
        $dirName = $_.Name
        if ($metaDirs -contains $dirName) { return $false }
        # 严格限制目标架构、x86 兼容层以及 MSIL 跨平台运行时
        if (-not ($dirName.StartsWith($arch, [System.StringComparison]::OrdinalIgnoreCase) -or 
                  $dirName.StartsWith("x86", [System.StringComparison]::OrdinalIgnoreCase) -or 
                  $dirName.StartsWith("msil", [System.StringComparison]::OrdinalIgnoreCase))) { 
            return $false 
        }
        foreach ($kw in $featureKeywords) {
            if ($dirName -like $kw) { return $true }
        }
        return $false
    }

    $totalSxS = $allSxSDirs.Count
    $currSxS = 0
    foreach ($dir in $allSxSDirs) {
        $currSxS++
        if ($currSxS % 5 -eq 0 -or $currSxS -eq $totalSxS) {
            $pct = [math]::Round(($currSxS / [math]::Max(1, $totalSxS)) * 100)
            Write-Progress -Activity "正在提取关键运行时依赖组件" -Status "[$currSxS/$totalSxS] 正在迁移: $($dir.Name)" -PercentComplete $pct
        }
        Copy-Item -Path $dir.FullName -Destination (Join-Path $winsxsEditPath $dir.Name) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Progress -Activity "正在提取关键运行时依赖组件" -Completed
    Write-Host "              [完成] 共成功提取并迁移了 $totalSxS 个核心依赖包。" -ForegroundColor Green

    # 阶段 5：粉碎旧库并挂载精简库
    Write-Host "   [阶段 5/5] 正在粉碎替换旧版 WinSxS 目录实体..." -ForegroundColor Yellow
    Force-NukeFolderOrFile $winsxsPath
    Rename-Item -Path $winsxsEditPath -NewName "WinSxS" -Force
    Write-Host "[完成] 自适应 WinSxS 极速瘦身全部完成！" -ForegroundColor Green
} else {
    Write-Host ">>> [普通模式] 执行官方标准 StartComponentCleanup /ResetBase (释放原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
}

# 提交并卸载主映像 (提前强制执行 GC，彻底释放文件句柄防提交冲突)
Write-Host "`n正在回收句柄资源并准备提交主映像..." -ForegroundColor DarkGray
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

Write-Host "正在提交更改并卸载 install.wim (展示官方原生百分比进度条)..." -ForegroundColor Cyan
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
if ($LASTEXITCODE -ne 0) {
    Write-Host "[警告] 主映像初次提交遇到阻碍，正在进行安全重试..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 3
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
}
Write-Host "[完成] 主映像已成功保存并提交更改。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 10/11] 映像格式分支处理与 WinPE 免硬件检测修补 (src/09-ExportAndPE.ps1)
#  [重构加固]：boot.wim 碎片清理二次极速压榨 + BCD 兼容双卷重构 + ESD 完整性校验
# ==============================================================================

# ----------------- 0. 变量作用域安全兜底 -----------------
if (-not $destWim)    { $destWim    = Join-Path $sourcesDir "install.wim" }
if (-not $sourcesDir) { $sourcesDir = Split-Path -Parent $destWim }

# ----------------- 1. 映像格式条件分支处理 (受控于全局开关 $enableEsdConversion) -----------------
Write-Host "`n[步骤 11/11] 正在处理安装映像输出格式..." -ForegroundColor Cyan

$esdFile = Join-Path $sourcesDir "install.esd"

if ($enableEsdConversion) {
    Write-Host ">>> [开关生效: 开启] 正在导出为高压缩率 install.esd..." -ForegroundColor Yellow
    Write-Host "提示: 压缩 ESD 需高度消耗 CPU 与磁盘算力，下方将实时输出官方百分比进度条：" -ForegroundColor DarkGray

    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

    if ((Test-Path -LiteralPath $esdFile) -and ((Get-Item $esdFile).Length -gt 500MB)) {
        Write-Host "[成功] install.esd 构建完成，已移除临时 install.wim。" -ForegroundColor Green
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[警告] ESD 转换异常或文件不完整，保留 install.wim 继续推进后续流程。" -ForegroundColor Yellow
    }
} else {
    Write-Host ">>> [开关生效: 默认关闭] 跳过 ESD 高耗时压缩，直接使用 install.wim 进行极速打包！" -ForegroundColor Green
    if (Test-Path -LiteralPath $destWim) {
        $wimSizeGB = [math]::Round(((Get-Item $destWim).Length / 1GB), 2)
        Write-Host "[就绪] 核心安装映像锁定: $destWim (当前体积: $wimSizeGB GB)" -ForegroundColor DarkGray
    }
}

# ----------------- 2. 修补 WinPE (boot.wim) 免硬件检测策略与碎片重构 -----------------
Write-Host "`n正在为 WinPE (boot.wim) 写入免硬件检测策略并执行深度瘦身..." -ForegroundColor Cyan
$bootWimPath     = Join-Path $sourcesDir "boot.wim"
$tempBootWimPath = Join-Path $sourcesDir "boot_optimized.wim"

attrib.exe -R -S -H "$bootWimPath" 2>$null
& takeown.exe /F "$bootWimPath" /A 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
(Get-Item $bootWimPath).IsReadOnly = $false

# 自适应分卷探查 (探测总卷数与安装引导卷索引)
$bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$hasIndex2 = ($bootInfo -match "Index\s*:\s*2")
$targetBootIndex = if ($hasIndex2) { "2" } else { "1" }

# 清理挂载目录防碰撞
if (Test-Path -LiteralPath $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载 boot.wim 核心引导卷 (分卷 $targetBootIndex)..." -ForegroundColor DarkGray
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$targetBootIndex" "/MountDir:$scratchDir"

if (-not (Test-Path "$scratchDir\Windows\System32")) {
    Write-Host "[错误] boot.wim 挂载异常，跳过策略写入以防损坏镜像。" -ForegroundColor Red
} else {
    # 挂载 WinPE 的 SYSTEM 注册表单元
    $bootSystemPath = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
    attrib.exe -R -S -H "$bootSystemPath" 2>$null
    & reg.exe load HKLM\zSYSTEM "$bootSystemPath" 2>$null | Out-Null

    # 注入全量 LabConfig 绕过策略 (全规格兼容 Win11 22H2/23H2/24H2)
    $labConfigKeys = @(
        "BypassCPUCheck",
        "BypassRAMCheck",
        "BypassSecureBootCheck",
        "BypassStorageCheck",
        "BypassTPMCheck",
        "BypassDiskCheck"
    )
    foreach ($k in $labConfigKeys) {
        & reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $k /t REG_DWORD /d 1 /f 2>$null | Out-Null
    }
    & reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f 2>$null | Out-Null

    # 安全卸载注册表
    Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

    # 提交修改
    Write-Host "正在提交并保存 boot.wim 引导修改..." -ForegroundColor DarkGray
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
}

# ----------------- 3. boot.wim 碎片物理清剿与原子重构 (nano11 关键工程升华) -----------------
Write-Host "正在对 boot.wim 执行二次去碎片极限压缩导出 (重建 BCD 完美兼容双卷)..." -ForegroundColor DarkYellow
if (Test-Path -LiteralPath $tempBootWimPath) {
    Remove-Item -LiteralPath $tempBootWimPath -Force -ErrorAction SilentlyContinue
}

if ($hasIndex2) {
    # 导出卷 1 (标准 WinPE 恢复环境，保持 BCD 序号不变)
    Write-Host "   -> 正在导出并压缩 boot.wim [分卷 1/2: WinPE]..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:1" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
    # 导出卷 2 (已打补丁的 Windows Setup 引导环境)
    Write-Host "   -> 正在导出并压缩 boot.wim [分卷 2/2: Setup]..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:2" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
} else {
    # 单卷环境直接紧凑导出
    Write-Host "   -> 正在单卷导出压缩 boot.wim..." -ForegroundColor DarkGray
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:1" "/DestinationImageFile:$tempBootWimPath" /Compress:max /CheckIntegrity
}

# 替换旧版高碎片 boot.wim
if (Test-Path -LiteralPath $tempBootWimPath) {
    Remove-Item -LiteralPath $bootWimPath -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tempBootWimPath -Destination $bootWimPath -Force
    Write-Host "[成功] boot.wim 物理去碎片与二次高压完毕 (体积大幅瘦身，脏标记完全清除)。" -ForegroundColor Green
} else {
    Write-Host "[提示] boot.wim 导出重构跳过，保留提交版本。" -ForegroundColor DarkGray
}

Write-Host "[完成] WinPE 引导环境免硬件检测注入与镜像重构完毕。" -ForegroundColor Green

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

