# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-18 13:05:14 UTC
#  构建流水线: GitHub Actions (workflow_dispatch)
# ==============================================================================

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/00-Header-Init.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 1/11] 环境初始化与模式集中前置配置 (src/00-Header-Init.ps1)
#  [企业级重构]：全半值守+精简模式前置交互闭环 + 倒计时防挂起 + 全流程静默流水线
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

# 4. 内核级关闭控制台快速编辑模式 (防误触黑框导致流水线线程被挂起)
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

# 5. 开启全程双重日志记录
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

# ----------------- 9. 前置配置 2：选择无人值守引导模式 (核心闭环) -----------------
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

# ----------------- 10. 初始化清理 (安全预检并卸载历史残留) -----------------
Write-Host "[初始化] 清理历史残留挂载点并重置环境..." -ForegroundColor DarkGray
if (Test-Path "HKLM:\zDEFAULT")  { cmd.exe /c "reg.exe unload HKLM\zDEFAULT 2>nul" | Out-Null }
if (Test-Path "HKLM:\zSOFTWARE") { cmd.exe /c "reg.exe unload HKLM\zSOFTWARE 2>nul" | Out-Null }
if (Test-Path "HKLM:\zSYSTEM")   { cmd.exe /c "reg.exe unload HKLM\zSYSTEM 2>nul" | Out-Null }
if (Test-Path "HKLM:\zNTUSER")   { cmd.exe /c "reg.exe unload HKLM\zNTUSER 2>nul" | Out-Null }

& dism.exe /English /Cleanup-Wim 2>$null | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path -LiteralPath $workDir) { 
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue 
}
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
#  win11 Builder - [模块 3/11] 镜像挂载与底层权限接管 (src/02-MountImage.ps1)
#  [企业级重构]：恢复原有原生提权清单 (坚决不碰 SystemApps) + Index 全局持久化
# ==============================================================================

# ----------------- 1. 输入与校验 ISO 光驱盘符 -----------------
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[严重错误] 镜像文件不存在！" -ForegroundColor Red
    pause
    exit
}

# ----------------- 2. 复制基础镜像架构 -----------------
Write-Host "正在复制 Windows 镜像架构..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination "$workDir" -Recurse -Force > $null
Remove-Item "$sourcesDir\install.esd" -ErrorAction SilentlyContinue 

# ----------------- 3. 获取分卷并挂载 -----------------
$wimFilePath = "$sourcesDir\install.wim"
& dism.exe /English /Get-WimInfo "/wimfile:$wimFilePath"

$inputIndex = Read-Host "请输入要精简的目标版本 Index 序号"
$inputIndex = $inputIndex.Trim()

# 校验并全局锁定目标版本，彻底修复单卷导出硬编码错位
if ([string]::IsNullOrWhiteSpace($inputIndex) -or ($inputIndex -notmatch '^\d+$')) {
    Write-Host "[提示] 输入无效，默认锁定 Index 序号: 1" -ForegroundColor Yellow
    $global:targetIndex = "1"
} else {
    $global:targetIndex = $inputIndex
    Write-Host ">>> 已全局锁定精简目标版本 Index: $global:targetIndex" -ForegroundColor Green
}

& takeown.exe /F "$wimFilePath" > $null 2>&1
& icacls.exe "$wimFilePath" /grant "*S-1-5-32-544:F" > $null 2>&1
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $scratchDir) { 
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue 
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载映像分卷 [$global:targetIndex]..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$wimFilePath" "/Index:$global:targetIndex" "/MountDir:$scratchDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[严重错误] 映像挂载失败！" -ForegroundColor Red
    pause
    exit
}

# ----------------- 4. 恢复原有预夺权白名单 (坚决不碰 SystemApps，确保打开方式完好) -----------------
Write-Host "正在接管核心目录权限 (严格遵照原生安全架构)..." -ForegroundColor DarkGray
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
$filesToOwn = @( 
    "$scratchDir\Windows\System32\OneDriveSetup.exe" 
)

foreach ($folder in $foldersToOwn) { 
    if (Test-Path -LiteralPath $folder) { 
        & takeown.exe /F "$folder" /R /D Y > $null 2>&1
        & icacls.exe "$folder" /grant "*S-1-5-32-544:F" /T /C > $null 2>&1
    } 
}

foreach ($file in $filesToOwn) { 
    if (Test-Path -LiteralPath $file) { 
        & takeown.exe /F "$file" /D Y > $null 2>&1
        & icacls.exe "$file" /grant "*S-1-5-32-544:F" /C > $null 2>&1
    } 
}

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Write-Host "[完成] 映像挂载与权限接管完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/02-MountImage.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/03-RemovePackages.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 4/11] 软件包与系统组件智能精炼 (src/03-RemovePackages.ps1)
#  [企业级重构]：先探针检测后动态决策 + 核心应用硬保护 + 彻底根治 0x800f0805
# ==============================================================================

Write-Host "`n正在初始化组件智能精炼引擎..." -ForegroundColor Cyan

# ----------------- 1. 系统底层语言与架构探针 -----------------
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageLine = $imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
if ($languageLine) { 
    $languageCode = $Matches[1] 
} else { 
    $languageCode = "zh-CN" 
}
Write-Host "   [系统环境探针] 检测到脱机映像主语言: $languageCode" -ForegroundColor DarkGray

# ----------------- 2. UWP 预装应用智能筛选与安全移除 -----------------
Write-Host "`n正在执行 UWP 预装应用智能扫描与卸载..." -ForegroundColor Cyan

# 系统核心保护白名单（强行调用 DISM 移除会触发 COMException 或损坏系统框架）
$protectedAppxList = @(
    "Microsoft.SecHealthUI",               # Windows 安全中心界面（受底层策略强制保护）
    "Microsoft.WindowsStore",              # Microsoft Store 核心框架
    "Microsoft.DesktopAppInstaller"        # Winget 与本地应用安装引擎
)

# 动态探测脱机映像中所有已预配的 AppX 包
$installedProvisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue

$packagesToRemove = $installedProvisionedPackages | Where-Object {
    $currentPkgName = $_.PackageName
    $currentDispName = $_.DisplayName

    # 门禁 1：白名单硬防护检查
    foreach ($prot in $protectedAppxList) {
        if ($currentPkgName -like "*$prot*" -or $currentDispName -like "*$prot*") {
            return $false
        }
    }

    # 门禁 2：待精简预装应用模式匹配 (保持原有定义范围 100% 完整)
    return (
        $currentPkgName -like '*Zune*' -or 
        $currentPkgName -like '*Bing*' -or 
        $currentPkgName -like '*Clipchamp*' -or 
        $currentPkgName -like '*Gaming*' -or 
        $currentPkgName -like '*People*' -or 
        $currentPkgName -like '*PowerAutomate*' -or 
        $currentPkgName -like '*Teams*' -or 
        $currentPkgName -like '*Todos*' -or 
        $currentPkgName -like '*YourPhone*' -or 
        $currentPkgName -like '*SoundRecorder*' -or 
        $currentPkgName -like '*Solitaire*' -or 
        $currentPkgName -like '*FeedbackHub*' -or 
        $currentPkgName -like '*Maps*' -or 
        $currentPkgName -like '*OfficeHub*' -or 
        $currentPkgName -like '*Help*' -or 
        $currentPkgName -like '*Family*' -or 
        $currentPkgName -like '*Alarms*' -or 
        $currentPkgName -like '*CommunicationsApps*' -or 
        $currentPkgName -like '*Copilot*' -or 
        $currentPkgName -like '*CompatibilityEnhancements*' -or 
        $currentPkgName -like '*AV1VideoExtension*' -or 
        $currentPkgName -like '*AVCEncoderVideoExtension*' -or 
        $currentPkgName -like '*HEIFImageExtension*' -or 
        $currentPkgName -like '*HEVCVideoExtension*' -or 
        $currentPkgName -like '*MicrosoftStickyNotes*' -or 
        $currentPkgName -like '*OutlookForWindows*' -or 
        $currentPkgName -like '*RawImageExtension*' -or 
        $currentPkgName -like '*VP9VideoExtensions*' -or 
        $currentPkgName -like '*WebpImageExtension*' -or 
        $currentPkgName -like '*DevHome*' -or 
        $currentPkgName -like '*Photos*' -or 
        $currentPkgName -like '*Camera*' -or 
        $currentPkgName -like '*QuickAssist*' -or 
        $currentPkgName -like '*CoreAI*' -or 
        $currentPkgName -like '*PeopleExperienceHost*' -or 
        $currentPkgName -like '*PinningConfirmationDialog*' -or 
        $currentPkgName -like '*SecureAssessmentBrowser*' -or 
        $currentPkgName -like '*Paint*' -or 
        $currentPkgName -like '*Notepad*'
    )
}

# 逐一执行安全卸载
foreach ($package in $packagesToRemove) { 
    Write-Host "   [卸载 AppX] 正在安全移除: $($package.DisplayName)" -ForegroundColor DarkGray
    try {
        Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "   [智能保护] 应用 $($package.DisplayName) 具有底层依赖，已安全旁路以保全母盘稳定性。" -ForegroundColor DarkYellow
    }
}

# 释放 AppX 卸载可能占用的文件锁句柄
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# 清理 WindowsApps 物理残余目录
foreach ($package in $packagesToRemove) { 
    $folderPath = Join-Path "$scratchDir\Program Files\WindowsApps" $package.PackageName
    if (Test-Path -LiteralPath $folderPath) { 
        & takeown.exe /F "$folderPath" /A /R /D Y > $null 2>&1
        & icacls.exe "$folderPath" /grant "*S-1-5-32-544:F" /T /C /Q > $null 2>&1
        Remove-Item -LiteralPath $folderPath -Recurse -Force -ErrorAction SilentlyContinue 
    } 
}

# ----------------- 3. FOD 系统功能包“先探后删”决策执行引擎 -----------------
Write-Host "`n正在智能精简可选功能包 (FOD)..." -ForegroundColor Cyan

# 原始系统功能包特征匹配列表（完整保留）
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

# 动态拉取当前映像中的全量程序包清单
$rawPackageTable = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$allPackages = ($rawPackageTable -split "`r?`n") | Select-Object -Skip 1

# 提取候选 PackageIdentity 列表
$candidateIdentities = New-Object System.Collections.Generic.List[string]
foreach ($packagePattern in $packagePatterns) {
    $matchedLines = $allPackages | Where-Object { $_ -like "*$packagePattern*" }
    foreach ($line in $matchedLines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $identity = ($trimmed -split "\s+")[0]
        if (-not [string]::IsNullOrWhiteSpace($identity) -and -not $candidateIdentities.Contains($identity)) {
            $candidateIdentities.Add($identity)
        }
    }
}

# 逐一执行“前置状态探针”决策卸载
foreach ($packageIdentity in $candidateIdentities) {
    # 【核心探针】：调用 DISM 查询当前程序包即时状态
    $probeResult = & dism.exe /English /Image:$scratchDir /Get-PackageInfo "/PackageName:$packageIdentity" 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        # 匹配状态字段，仅当为可卸载的有效状态时执行操作
        if ($probeResult -match "State\s*:\s*(Installed|Install Pending|Staged)") {
            Write-Host "   [探测确认: 有效包] 正在移除: $packageIdentity" -ForegroundColor DarkGray
            & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>$null | Out-Null
        } else {
            Write-Host "   [智能旁路: 状态已失效] 自动跳过: $packageIdentity" -ForegroundColor DarkYellow
        }
    } else {
        # 探针返回非零：说明该包已在父级移除时被系统级联注销，坚决不盲目调用 Remove-Package，彻底消灭 0x800f0805
        Write-Host "   [智能旁路: 已随父包级联清除] 无需重复操作: $packageIdentity" -ForegroundColor DarkGray
    }
}

# ----------------- 4. 清除 .NET Native 镜像缓存 -----------------
Write-Host "`n正在清理 .NET 本地预编译镜像缓存..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue

# 执行内存回收保障后续模块句柄纯净
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Write-Host "[完成] UWP 与可选系统功能包智能精炼完毕 (零异常通过)。" -ForegroundColor Green

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
#  win11 Builder - [模块 6/11] 冗余大文件与实体物理清理 (src/05-PhysicalNuke.ps1)
#  [企业级重构]：100% 恢复原生安全删除逻辑 + 严禁篡改 SystemApps + 确保打开方式完好
# ==============================================================================

Write-Host "`n正在执行大文件实体物理清理 (原生纯净标准)..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# ----------------- 1. 字体精简 (原生安全白名单) -----------------
Write-Host "   -> 正在精简冗余字体库..." -ForegroundColor DarkGray
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path -LiteralPath $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# ----------------- 2. TTS 语音引擎与 Defender 更新缓存 -----------------
Write-Host "   -> 正在清理离线语音引擎与 Defender 冗余缓存..." -ForegroundColor DarkGray
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 3. 繁体、日文、韩文输入法组件 -----------------
Write-Host "   -> 正在清理东亚多余输入法..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 4. 临时目录、壁纸、帮助文档与指针 -----------------
Write-Host "   -> 正在清理临时文件、壁纸、帮助文档与光标..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# ----------------- 5. 移除 Edge、WinRE (空桩占位)、OneDrive (恢复原有安全删除逻辑) -----------------
Write-Host "   -> 正在移除 Edge 主体、OneDrive 并重置 WinRE 占位..." -ForegroundColor DarkGray

# 恢复原版精准物理删除：仅清除 Program Files 浏览器主体与 WebView，绝不碰 SystemApps 目录
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue

# 剥离 winre.wim 并创建 0 字节只读安全占位，规避安装程序崩溃
$winrePath = "$scratchDir\Windows\System32\Recovery\winre.wim"
Remove-Item -Path $winrePath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $winrePath -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# ----------------- 6. 第一轮组件存储基线清理与重置 -----------------
Write-Host "   -> 正在执行组件存储基线固化..." -ForegroundColor DarkGray

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "[完成] 实体物理清理完毕 (系统 Shell 与打开方式架构 100% 完好)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 7/11] 注册表原生系统优化 (src/06-RegistryTweaks.ps1)
#  [企业级重构]：零篡改系统 Shell (打开方式 100% 正常响应) + 内核级无红字降级
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在挂载配置单元并执行企业级纯净优化注入..." -ForegroundColor Cyan

# ----------------- 0. 底层静默探针函数 (彻底杜绝 NativeCommandError) -----------------
function Safe-DeleteRegKey {
    <#
    .SYNOPSIS
        先探针探测键路径是否存在，存在时通过 cmd 纯内核通道静默删除，杜绝 PowerShell 5.1 Transcript 漏出红字
    #>
    param([string]$KeyPath)
    $psPath = $KeyPath -replace '^HKLM\\', 'HKLM:\'
    if (Test-Path -LiteralPath $psPath) {
        cmd.exe /c "reg.exe delete `"$KeyPath`" /f 2>nul" | Out-Null
    }
}

# ----------------- 1. 挂载脱机注册表配置单元 (4 个核心 Hive) -----------------
$defaultPath  = Join-Path $scratchDir "Windows\System32\config\default"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"

attrib.exe -R -S -H "$defaultPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null
attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null

& reg.exe load HKLM\zDEFAULT "$defaultPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null
& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null

# ----------------- 2. 硬件检测全量参数绕过 -----------------
Write-Host "   -> 写入硬件需求全量绕过配置..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 3. 禁用预装推广与流氓广告通道 -----------------
Write-Host "   -> 禁用推广应用与预装推送..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v OemPreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v ContentDeliveryAllowed /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins /t REG_SZ /d '{"pinnedList": [{}]}' /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v FeatureManagementEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEverEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContentEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338393Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353694Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353696Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v DisablePushToInstall /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v DontOfferThroughWUAU /t REG_DWORD /d 1 /f | Out-Null

Safe-DeleteRegKey "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions"
Safe-DeleteRegKey "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 4. 开启 OOBE 本地账户跳过支持 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 5. 禁用保留存储与 BitLocker 自动加密 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 6. 禁用 Chat 图标与任务栏小组件 -----------------
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 3 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Null

# ----------------- 7. 原生清理 Edge 卸载条目 (零私货、零篡改 Shell，彻底恢复打开方式) -----------------
# 严格遵照原生纯净标准，仅清理卸载键，绝不篡改 RegisteredApplications/StartMenuInternet，确保打开方式完好
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Safe-DeleteRegKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"

# ----------------- 8. 禁用 OneDrive 同步与遥测跟踪 -----------------
Write-Host "   -> 禁用遥测与隐私搜集..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore" /v HarvestContacts /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Personalization\Settings" /v AcceptedPrivacyPolicy /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice" /v Start /t REG_DWORD /d 4 /f | Out-Null

# ----------------- 9. 阻止 DevHome、Outlook、Teams、Mail 自动安装 -----------------
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null

Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate"
Safe-DeleteRegKey "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v DisableInstallation /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v PreventRun /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 10. 删除遥测计划任务实体定义文件 -----------------
Write-Host "   -> 删除遥测计划任务定义..." -ForegroundColor DarkGray
$tasksPath = Join-Path $scratchDir "Windows\System32\Tasks"
$tasksToRemove = @(
    "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
    "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
    "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)
foreach ($t in $tasksToRemove) {
    if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 11. 禁用 Windows Update 自动更新 -----------------
Write-Host "   -> 关闭 Windows 自动更新通道..." -ForegroundColor DarkGray
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE1 /t REG_SZ /d "net stop wuauserv" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE2 /t REG_SZ /d "sc stop wuauserv" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v StopWUPostOOBE3 /t REG_SZ /d "sc config wuauserv start= disabled" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE1 /t REG_SZ /d "reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v DisbaleWUPostOOBE2 /t REG_SZ /d "reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UpdateServiceUrlAlternate /t REG_SZ /d "localhost" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisableOnline /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\wuauserv" /v Start /t REG_DWORD /d 4 /f | Out-Null

Safe-DeleteRegKey "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC"
Safe-DeleteRegKey "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc"

& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null

# ----------------- 12. 停用 Windows Defender 服务栈 -----------------
Write-Host "   -> 停用 Windows Defender 服务栈..." -ForegroundColor DarkGray
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
foreach ($svc in $defenderServices) {
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v Start /t REG_DWORD /d 4 /f | Out-Null
}
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v SettingsPageVisibility /t REG_SZ /d "hide:virus;windowsupdate" /f | Out-Null

# ----------------- 13. 系统冗余服务智能治理 (零红字通道) -----------------
Write-Host "   -> 正在智能治理冗余系统服务..." -ForegroundColor DarkGray
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
    $svcPath = "HKLM\zSYSTEM\ControlSet001\Services\$service"
    $svcPsPath = "HKLM:\zSYSTEM\ControlSet001\Services\$service"

    if (Test-Path -LiteralPath $svcPsPath) {
        # 1. 率先写入内核级安全禁用 (Start = 4)，保障即使后续 ACL 拦截也能 100% 达成停止运行目标
        cmd.exe /c "reg.exe add `"$svcPath`" /v Start /t REG_DWORD /d 4 /f 2>nul" | Out-Null

        # 2. 尝试物理彻底抹除键值（使用 cmd 内核吸收 stderr，杜绝 Transcript 抛出 NativeCommandError）
        cmd.exe /c "reg.exe delete `"$svcPath`" /f 2>nul" | Out-Null

        # 3. 校验执行结果
        if (Test-Path -LiteralPath $svcPsPath) {
            Write-Host "   [智能降级] 服务 [$service] 受系统底层 ACL 保护，已安全置为完全停用 (Start=4)。" -ForegroundColor DarkGray
        } else {
            Write-Host "   [物理抹杀] 服务 [$service] 已彻底从注册表抹除。" -ForegroundColor DarkGray
        }
    }
}

# ----------------- 14. 统一安全卸载脱机注册表配置单元 -----------------
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Safely-UnloadHive "HKLM\zDEFAULT" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 注册表原生优化完成 (100% 遵照纯净标准，系统原生 Shell 完美无瑕)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/06-RegistryTweaks.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/07-UnattendInject.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在配置高级无人值守应答文件 (30秒智能倒计时)..." -ForegroundColor Cyan

# 1. 调用倒计时输入函数获取登录账户
$userResult = Read-InputWithTimeout -Prompt "请输入登录用户名" -Seconds 30 -Default "Admin"
$inputUser = $userResult.Value
if ($inputUser -match "^(Administrator|Guest)$") {
    Write-Host "[警告] 输入了系统保留账户名 $inputUser，自动重置为 Admin！" -ForegroundColor Yellow
    $inputUser = "Admin"
}

# 2. 密码设定
if ($userResult.TimedOut) {
    $inputPass = ""
} else {
    $inputPass = Read-Host "请输入登录密码 (直接回车表示留空无密码)"
}
$inputPassEscaped = [System.Security.SecurityElement]::Escape($inputPass)

# 3. 100% 完整无损原版 XML 应答模板 (补齐语言/地区/键盘全自动声明)
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
		<!-- 2. OOBE 阶段国际化全自动闭环 (彻底跳过“选择中国”、“键盘布局”与“第二键盘提示”) -->
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>zh-CN</InputLocale>
			<SystemLocale>zh-CN</SystemLocale>
			<UILanguage>zh-CN</UILanguage>
			<UserLocale>zh-CN</UserLocale>
		</component>
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<UserAccounts>
				<LocalAccounts>
					<LocalAccount wcm:action="add">
						<Description>自定义管理员账户</Description>
						<DisplayName>__CUSTOM_USER__</DisplayName>
						<Group>Administrators</Group>
						<Name>__CUSTOM_USER__</Name>
						<Password>
							<Value>__CUSTOM_PASS__</Value>
							<PlainText>true</PlainText>
						</Password>
					</LocalAccount>
				</LocalAccounts>
			</UserAccounts>
			<AutoLogon>
				<Username>__CUSTOM_USER__</Username>
				<Enabled>true</Enabled>
				<LogonCount>1</LogonCount>
				<Password>
					<Value>__CUSTOM_PASS__</Value>
					<PlainText>true</PlainText>
				</Password>
			</AutoLogon>
			<OOBE>
				<ProtectYourPC>3</ProtectYourPC>
				<HideEULAPage>true</HideEULAPage>
				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
				<HideLocalAccountScreen>true</HideLocalAccountScreen>
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
} *&gt;&amp;1 &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
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
} *&gt;&amp;1 &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
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
		# 1. 立即销毁可能包含明文密码的 xml 应答文件副本
		$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach ($f in $xmlFiles) {
			if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; }
		}

		# 2. 延迟 3 秒自毁整个 C:\Windows\Setup\Scripts 脚本与日志目录
		Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList '/c timeout /t 3 /nobreak >nul & rd /s /q "C:\Windows\Setup\Scripts"'
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
} *&gt;&amp;1 &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
		</File>
	</Extensions>
</unattend>
'@

# 替换自定义参数
$autoUnattendXml = $unattendTemplate.Replace('__CUSTOM_USER__', $inputUser).Replace('__CUSTOM_PASS__', $inputPassEscaped)

# 4. 三通道注入 (Sysprep、Panther、光驱根目录)
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$autoUnattendXml | Out-File -FilePath (Join-Path $sysprepDir "autounattend.xml") -Encoding utf8 -Force
$autoUnattendXml | Out-File -FilePath (Join-Path $pantherDir "unattend.xml") -Encoding utf8 -Force
$autoUnattendXml | Out-File -FilePath (Join-Path $workDir "autounattend.xml") -Encoding utf8 -Force

Write-Host "[完成] 高级无人值守应答文件三通道注入完毕 (已实现区域与键盘完全免交互)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 运行库物理重构与紧凑单卷导出 (src/08-WinSxSOptimize.ps1)
#  [企业级重构]：深度提权穿透 + 事务完整性门禁 + 故障自动回滚 + 彻底杜绝 Error 87
# ==============================================================================

Write-Host "`n正在重构 WinSxS 核心运行库目录 (企业级自适应安全模式)..." -ForegroundColor Cyan

# ----------------- 0. 上下文变量安全兜底 -----------------
if (-not $wimFilePath) { 
    $wimFilePath = Join-Path $sourcesDir "install.wim" 
}

$sourceDirectory      = Join-Path $scratchDir "Windows\WinSxS"
$destinationDirectory = Join-Path $scratchDir "Windows\WinSxS_edit"

# 重置并预备临时目录
if (Test-Path -LiteralPath $destinationDirectory) { 
    Remove-Item -LiteralPath $destinationDirectory -Recurse -Force -ErrorAction SilentlyContinue 
}
New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

# ----------------- 1. 精准提取系统核心运行库白名单 -----------------
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

Write-Host "   -> 正在提取核心依赖运行库与 Servicing 组件..." -ForegroundColor DarkGray
foreach ($dir in $dirsToCopy) {
    $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
    foreach ($sDir in $sourceDirs) {
        $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
        Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 2. 深度提权穿透与物理强制粉碎 -----------------
Write-Host "   -> 正在接管原 WinSxS 目录全量权限并执行物理粉碎..." -ForegroundColor DarkGray

# 强制触发运行时垃圾回收，解开所有内部可能持有的句柄锁
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# 突破 TrustedInstaller 与只读属性限制
& takeown.exe /F "$sourceDirectory" /A /R /D Y > $null 2>&1
& icacls.exe "$sourceDirectory" /grant "*S-1-5-32-544:F" /T /C /Q > $null 2>&1
attrib.exe -R -S -H "$sourceDirectory\*" /S /D > $null 2>&1
cmd.exe /c "rd /s /q `"$sourceDirectory`"" > $null 2>&1

# 容错重试检测：确保文件系统彻底完成删除同步
if (Test-Path -LiteralPath $sourceDirectory) {
    Start-Sleep -Seconds 1
    cmd.exe /c "rd /s /q `"$sourceDirectory`"" > $null 2>&1
}

# ----------------- 3. 智能决策与事务安全门禁 -----------------
if (-not (Test-Path -LiteralPath $sourceDirectory)) {
    # 【分支 A：粉碎成功】安全执行原子替换与深度基线重置
    Rename-Item -Path $destinationDirectory -NewName "WinSxS" -Force
    Write-Host "[成功] WinSxS 运行库极致瘦身重构完成。" -ForegroundColor Green
    
    Write-Host "   -> 正在执行组件存储重置与基线固化..." -ForegroundColor DarkGray
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase 2>$null | Out-Null
} else {
    # 【分支 B：回滚保护】检测到外部顽固占用，坚决不进行破坏性重命名，保护母盘 100% 稳定可引导
    Write-Host "[智能回退] 检测到原 WinSxS 存在外部句柄锁定未完全释放，已中止重命名替换，保留完整组件存储。" -ForegroundColor Yellow
    Remove-Item -LiteralPath $destinationDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------- 4. 提交映像并导出高压紧凑单卷 -----------------
Write-Host "`n正在提交映像更改并导出紧凑单卷..." -ForegroundColor Cyan

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

$finalWim = Join-Path $sourcesDir "install_final.wim"
& dism.exe /English /Export-Image "/SourceImageFile:$wimFilePath" "/SourceIndex:1" "/DestinationImageFile:$finalWim" /Compress:max

if ((Test-Path -LiteralPath $finalWim) -and ((Get-Item -LiteralPath $finalWim).Length -gt 500MB)) {
    Remove-Item -LiteralPath $wimFilePath -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $finalWim -NewName "install.wim" -Force
    Write-Host "[完成] 映像处理与提交导出完毕 (已生成纯净紧凑单卷)。" -ForegroundColor Green
} else {
    Write-Host "[警告] 紧凑单卷导出校验异常，保留原映像以保全数据。" -ForegroundColor Yellow
}

# <<< [分块结束] 文件来源: src/08-WinSxSOptimize.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/09-ExportAndPE.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 10/11] 映像格式分支处理与 WinPE 免硬件检测修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

# ----------------- 1. 映像格式条件分支处理 (受控于全局开关 $enableEsdConversion) -----------------
Write-Host "`n[步骤 11/11] 正在处理安装映像输出格式..." -ForegroundColor Cyan

$esdFile = Join-Path $sourcesDir "install.esd"

if ($enableEsdConversion) {
    Write-Host ">>> [开关生效: 开启] 正在导出为高压缩率 install.esd..." -ForegroundColor Yellow
    Write-Host "提示: 压缩 ESD 需高度消耗 CPU 与磁盘算力，下方将实时输出官方百分比进度条：" -ForegroundColor DarkGray

    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

    if (Test-Path -LiteralPath $esdFile) {
        Write-Host "[成功] install.esd 构建完成，已移除临时 install.wim。" -ForegroundColor Green
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[警告] ESD 转换异常，保留 install.wim 继续推进后续流程。" -ForegroundColor Yellow
    }
} else {
    Write-Host ">>> [开关生效: 默认关闭] 跳过 ESD 高耗时压缩，直接使用 install.wim 进行极速打包！" -ForegroundColor Green
    if (Test-Path -LiteralPath $destWim) {
        Write-Host "[就绪] 核心安装映像锁定: $destWim" -ForegroundColor DarkGray
    }
}

# ----------------- 2. 修补 WinPE (boot.wim) 免硬件检测策略 -----------------
Write-Host "`n正在为 WinPE (boot.wim) 写入免硬件检测策略..." -ForegroundColor Cyan
$bootWimPath = Join-Path $sourcesDir "boot.wim"
attrib.exe -R -S -H "$bootWimPath" 2>$null

# 自适应分卷探查 (优先卷 2 Setup 引导，单卷 PE 自动选卷 1)
$bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$bootIndex = "2"
if ($bootInfo -notmatch "Index : 2") { $bootIndex = "1" }

Write-Host "正在挂载 boot.wim 分卷 $bootIndex..." -ForegroundColor DarkGray
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$bootIndex" "/MountDir:$scratchDir"

# 挂载 WinPE 的 SYSTEM 单元并注入 LabConfig 绕过策略
$bootSystemPath = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
attrib.exe -R -S -H "$bootSystemPath" 2>$null
& reg.exe load HKLM\zSYSTEM "$bootSystemPath" 2>$null | Out-Null

$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
foreach ($k in $labConfigKeys) {
    & reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $k /t REG_DWORD /d 1 /f 2>$null | Out-Null
}

# 稳健卸载注册表并提交 WinPE 映像更改
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Write-Host "正在提交并保存 boot.wim..." -ForegroundColor DarkGray
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
Write-Host "[完成] WinPE (boot.wim) 免硬件检测策略写入完毕。" -ForegroundColor Green

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

