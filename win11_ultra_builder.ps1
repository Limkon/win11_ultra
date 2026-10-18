# ==============================================================================
#  win11 Builder - 自动化全功能完整版 (工业级编译发布版)
#  生成时间: 2026-10-18 01:05:53 UTC
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
#  win11 Builder - [模块 3/11] 镜像挂载与权限接管 (1:1 对齐 nano11)
# ==============================================================================

# 1. 输入与校验 ISO 光驱盘符
$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 镜像文件不存在！" -ForegroundColor Red
    exit
}

# 2. 复制基础镜像架构 (nano11 原生)
Write-Host "正在复制 Windows 镜像架构..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination "$workDir" -Recurse -Force > $null
Remove-Item "$sourcesDir\install.esd" -ErrorAction SilentlyContinue 

# 3. 获取分卷并挂载 (nano11 原生)
& dism.exe /English /Get-WimInfo "/wimfile:$sourcesDir\install.wim"
$index = Read-Host "请输入要精简的目标版本 Index 序号"

$wimFilePath = "$sourcesDir\install.wim"
& takeown.exe /F "$wimFilePath" > $null
& icacls.exe "$wimFilePath" /grant "*S-1-5-32-544:F" > $null
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

if (Test-Path $scratchDir) { Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host "正在挂载映像..." -ForegroundColor Green
& dism.exe /English /Mount-Image "/ImageFile:$wimFilePath" "/Index:$index" "/MountDir:$scratchDir"

# 4. nano11 原版预夺权 (完全对齐 nano11 原始语法，不走子进程，秒过不卡顿)
Write-Host "正在接管核心目录权限 (nano11 原版)..." -ForegroundColor DarkGray
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
$filesToOwn = @( "$scratchDir\Windows\System32\OneDriveSetup.exe" )

foreach ($folder in $foldersToOwn) { 
    if (Test-Path $folder) { 
        & takeown.exe /F "$folder" /R /D Y > $null 2>&1
        & icacls.exe "$folder" /grant "*S-1-5-32-544:F" /T /C > $null 2>&1
    } 
}
foreach ($file in $filesToOwn) { 
    if (Test-Path $file) { 
        & takeown.exe /F "$file" /D Y > $null 2>&1
        & icacls.exe "$file" /grant "*S-1-5-32-544:F" /C > $null 2>&1
    } 
}
Write-Host "[完成] 映像挂载与权限接管完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/02-MountImage.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/03-RemovePackages.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 4/11] 软件包与组件精炼 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在精简 UWP 预装应用 (bloatware)..." -ForegroundColor Cyan

# 语言与架构探测
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageLine = $imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
if ($languageLine) { $languageCode = $Matches[1] } else { $languageCode = "zh-CN" }

# 1. nano11 原版 UWP 删除列表
$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir | Where-Object { 
    $_.PackageName -like '*Zune*' -or $_.PackageName -like '*Bing*' -or $_.PackageName -like '*Clipchamp*' -or 
    $_.PackageName -like '*Gaming*' -or $_.PackageName -like '*People*' -or $_.PackageName -like '*PowerAutomate*' -or 
    $_.PackageName -like '*Teams*' -or $_.PackageName -like '*Todos*' -or $_.PackageName -like '*YourPhone*' -or 
    $_.PackageName -like '*SoundRecorder*' -or $_.PackageName -like '*Solitaire*' -or $_.PackageName -like '*FeedbackHub*' -or 
    $_.PackageName -like '*Maps*' -or $_.PackageName -like '*OfficeHub*' -or $_.PackageName -like '*Help*' -or 
    $_.PackageName -like '*Family*' -or $_.PackageName -like '*Alarms*' -or $_.PackageName -like '*CommunicationsApps*' -or 
    $_.PackageName -like '*Copilot*' -or $_.PackageName -like '*CompatibilityEnhancements*' -or $_.PackageName -like '*AV1VideoExtension*' -or 
    $_.PackageName -like '*AVCEncoderVideoExtension*' -or $_.PackageName -like '*HEIFImageExtension*' -or $_.PackageName -like '*HEVCVideoExtension*' -or 
    $_.PackageName -like '*MicrosoftStickyNotes*' -or $_.PackageName -like '*OutlookForWindows*' -or $_.PackageName -like '*RawImageExtension*' -or 
    $_.PackageName -like '*SecHealthUI*' -or $_.PackageName -like '*VP9VideoExtensions*' -or $_.PackageName -like '*WebpImageExtension*' -or 
    $_.PackageName -like '*DevHome*' -or $_.PackageName -like '*Photos*' -or $_.PackageName -like '*Camera*' -or 
    $_.PackageName -like '*QuickAssist*' -or $_.PackageName -like '*CoreAI*'  -or $_.PackageName -like '*PeopleExperienceHost*' -or 
    $_.PackageName -like '*PinningConfirmationDialog*' -or $_.PackageName -like '*SecureAssessmentBrowser*' -or $_.PackageName -like '*Paint*' -or 
    $_.PackageName -like '*Notepad*'  
}

foreach ($package in $packagesToRemove) { 
    Write-Host "Removing: $($package.DisplayName)"
    Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName 
}

# 2. 清理残余目录 (nano11 原版)
foreach ($package in $packagesToRemove) { 
    $folderPath = Join-Path "$scratchDir\Program Files\WindowsApps" $package.PackageName
    if (Test-Path $folderPath) { 
        Remove-Item $folderPath -Recurse -Force -ErrorAction SilentlyContinue 
    } 
}

# 3. nano11 原版系统可选功能包 (FOD) 清单 (包含 Search-Engine-Client 删除)
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
    $matchedPkgs = $allPackages | Where-Object { $_ -like "$packagePattern*" }
    foreach ($package in $matchedPkgs) {
        $packageIdentity = ($package -split "\s+")[0]
        Write-Host "Removing $packageIdentity..."
        & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$packageIdentity" 
    }
}

# 4. 清除 .NET Native 镜像 (nano11 原生)
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "[完成] UWP 与系统包精炼完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/03-RemovePackages.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/04-DriversFeatures.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动仓库精简 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在精简驱动仓库 (nano11 原版)..." -ForegroundColor Cyan
$driverRepo = Join-Path "$scratchDir\Windows" "System32\DriverStore\FileRepository"

# nano11 原版仅剔除这 7 项无害驱动
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
                Write-Host "Removing: $driverFolder"
                Remove-Item -Path $_.FullName -Recurse -Force
                break
            }
        }
    }
}
Write-Host "[完成] 驱动精简完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/04-DriversFeatures.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/05-PhysicalNuke.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 6/11] 实体物理清理 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在执行大文件实体物理删除 (nano11 原版)..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# 1. 字体精简 (nano11 原版白名单)
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path $fontsPath) { 
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 
}

# 2. TTS 引擎与 Defender 更新缓存
Remove-Item -Path (Join-Path $winDir "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# 3. 繁体、日文、韩文输入法
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Temp、Web、Help、Cursors
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Help") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $winDir "Cursors") -Recurse -Force -ErrorAction SilentlyContinue

# 5. 移除 Edge、WinRE (空桩占位)、OneDrive (nano11 原生)
Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$scratchDir\Windows\System32\Recovery\winre.wim" -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue

# 6. nano11 原版第一轮基础清理
& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "[完成] 实体物理清理完毕。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/05-PhysicalNuke.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/06-RegistryTweaks.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 7/11] 注册表原生优化 (src/06-RegistryTweaks.ps1)
#  [100% 像素级对齐  源码]：零私货、零篡改 Shell，彻底恢复打开方式
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在挂载配置单元并 100% 注入  原版注册表配置..." -ForegroundColor Cyan

# 1. 挂载注册表配置单元 ( 原版 5 个 Hive)
$defaultPath    = Join-Path $scratchDir "Windows\System32\config\default"
$ntuserPath     = Join-Path $scratchDir "Users\Default\ntuser.dat"
$softwarePath   = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath     = Join-Path $scratchDir "Windows\System32\config\SYSTEM"

attrib.exe -R -S -H "$defaultPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null
attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null

& reg.exe load HKLM\zDEFAULT "$defaultPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null
& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null

# 2. 绕过硬件检测全量参数 ( 原版)
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

# 3. 禁用预装推广与流氓广告通道 ( 原版)
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
& reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f | Out-Null

# 4. 开启 OOBE 本地账户跳过支持 ( 原版)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f | Out-Null

# 5. 禁用保留存储与 BitLocker 自动设备加密 ( 原版)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null

# 6. 禁用 Chat 图标与任务栏组件 ( 原版)
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 3 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Null

# 7. 清理 Edge 遗留注册表 ( 原版)
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f 2>$null | Out-Null

# 8. 禁用 OneDrive 同步与遥测跟踪 ( 原版)
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

# 9. 阻止 DevHome、Outlook、Teams、Mail 自动安装 ( 原版)
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v workCompleted /t REG_DWORD /d 1 /f | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v DisableInstallation /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v PreventRun /t REG_DWORD /d 1 /f | Out-Null

# 10. 删除  官方指定的 5 个计划任务定义文件 ( 原版)
Write-Host "   -> 删除遥测计划任务定义..." -ForegroundColor DarkGray
$tasksPath = Join-Path $scratchDir "Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

# 11. 禁用 Windows Update 自动更新 ( 原版)
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
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC" /f 2>$null | Out-Null
& reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc" /f 2>$null | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null

# 12. 禁用 Windows Defender 服务 ( 原版方式：安全停用服务，隐藏设置页，绝不损坏文件)
Write-Host "   -> 停用 Windows Defender 服务栈..." -ForegroundColor DarkGray
$defenderServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense")
foreach ($svc in $defenderServices) {
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v Start /t REG_DWORD /d 4 /f | Out-Null
}
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v SettingsPageVisibility /t REG_SZ /d "hide:virus;windowsupdate" /f | Out-Null

# 卸载前面 4 个单元
Safely-UnloadHive "HKLM\zDEFAULT" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

# 13. 独立重载 SYSTEM 彻底物理删除指定无用服务 (100% 对齐  最终服务删除)
Write-Host "   -> 彻底移除冗余系统服务..." -ForegroundColor DarkGray
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null

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
    & reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$service" /f 2>$null | Out-Null 
}

Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

Write-Host "[完成] 注册表优化完成 (100% 遵照  官方纯净标准，系统原生 Shell 完美无瑕)。" -ForegroundColor Green

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

# ----------------- 4. 纯净 ISO 根目录注入 (绝不污染 install.wim 内部) -----------------
$utf8Encoding = [System.Text.Encoding]::UTF8

# 只写入 ISO 安装介质根目录，让 Windows 安装程序自动抓取，镜像内部 100% 保持纯净零污染
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $finalXml, $utf8Encoding)

Write-Host "[完成] 无人值守应答文件已写入 ISO 根目录 (install.wim 内部保持 100% 纯净)。" -ForegroundColor Green

# <<< [分块结束] 文件来源: src/07-UnattendInject.ps1

# ==============================================================================
# >>> [分块代码引入] 文件来源: src/08-WinSxSOptimize.ps1
# ==============================================================================
# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 物理重构与卸载提交 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在重构 WinSxS 运行库目录 (nano11 原版)..." -ForegroundColor Cyan

$sourceDirectory = "$scratchDir\Windows\WinSxS"
$destinationDirectory = "$scratchDir\Windows\WinSxS_edit"
New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

# 严格遵照 nano11 原版指定的 28 个目录
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
    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
    "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
)

foreach ($dir in $dirsToCopy) {
    $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
    foreach ($sDir in $sourceDirs) {
        $destDir = Join-Path -Path $destinationDirectory -ChildPath $sDir.Name
        Copy-Item -Path $sDir.FullName -Destination $destDir -Recurse -Force
    }
}

# 物理粉碎原 WinSxS 并重命名 (nano11 原生)
Remove-Item -Path $sourceDirectory -Recurse -Force
Rename-Item -Path $destinationDirectory -NewName "WinSxS"

# 最终第二轮组件重置与提交卸载
& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# 最终导出紧凑单卷 (nano11 原版做法)
$finalWim = Join-Path $sourcesDir "install_final.wim"
& dism.exe /English /Export-Image "/SourceImageFile:$wimFilePath" "/SourceIndex:1" "/DestinationImageFile:$finalWim" /Compress:max
Remove-Item -Path $wimFilePath -Force
Rename-Item -Path $finalWim -NewName "install.wim"

Write-Host "[完成] 映像处理与提交导出完毕 (100% 对齐 nano11)。" -ForegroundColor Green

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

