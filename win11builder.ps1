# ==============================================================================
#  win11 Builder - 终极压榨完美完整版 (v7.1 原生非阻塞·原子批处理·工业级终极版)
#  - [彻底防假死] 注册表改用原子批处理执行引擎，彻底解决管道缓冲区与杀软拦截死锁
#  - [内核级免疫] Win32 原生关闭控制台 QuickEdit 模式，杜绝鼠标点击控制台挂死
#  - [稳健卸载] 注册表 Hive 卸载引入 GC 强制释放与 5 次重试容错机制
#  - [语法安全] 修正倒计时函数的光标位置异常捕获与变量解析
#  - [双通道应答] 光驱根目录 + 离线 Panther/Sysprep 目录全自动化注入
# ==============================================================================

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

# 4. 内核级关闭控制台快速编辑模式 (彻底解决鼠标误点击黑框导致的线程挂起)
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
} catch {
    # 忽略非标准控制台宿主中的加载异常
}

# 5. 开启全程双重日志
$logFile = Join-Path -Path $scriptDir -ChildPath "win11_ultra_build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
try {
    Start-Transcript -Path $logFile -Append -Force
} catch {
    Write-Host "日志初始化失败: $_" -ForegroundColor Red
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " win11 Builder (全版本通用 + v7.1 原子批处理回归版) " -ForegroundColor Cyan
Write-Host " 日志文件: $logFile" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 6. 工作目录配置 (默认定向到 D 盘)
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

# 7. 用户模式选择交互
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host " 请选择精简制作模式 (Trim Mode):" -ForegroundColor Magenta
Write-Host " [1] 普通精简 (推荐: 极速流畅、稳定平衡、保留组件服务架构)" -ForegroundColor Green
Write-Host " [2] 极限压榨 (全版本自适应 WinSxS 瘦身 + 注册表物理抹杀服务)" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Magenta
$trimModeChoice = Read-Host "请输入对应数字 [1 或 2] (直接回车默认 1)"
if ($trimModeChoice -ne "2") {
    $trimMode = "1"
    Write-Host ">>> 已选择: [1] 普通精简模式" -ForegroundColor Green
} else {
    $trimMode = "2"
    Write-Host ">>> 已选择: [2] 极限压榨模式 (通用自适应换头 + 物理抹杀服务)" -ForegroundColor Red
}
Write-Host ""

Write-Host "清理残留挂载点并重置环境..." -ForegroundColor DarkGray
& reg.exe unload HKLM\zSOFTWARE 2>$null | Out-Null
& reg.exe unload HKLM\zSYSTEM 2>$null | Out-Null
& reg.exe unload HKLM\zNTUSER 2>$null | Out-Null
& dism.exe /English /Cleanup-Wim 2>$null | Out-Null
cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null

if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

$DriveLetter = Read-Host "请输入 Windows 11 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd('\').TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 在 $DriveLetter 中未找到有效的 Windows 安装镜像源！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

Write-Host "正在复制 Windows ISO 核心结构到工作区..." -ForegroundColor Green
& robocopy.exe "$DriveLetter\\" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NJH /NJS | Out-Null

$srcWim = "$DriveLetter\sources\install.wim"
$srcEsd = "$DriveLetter\sources\install.esd"
$destWim = "$sourcesDir\install.wim"

if (Test-Path $srcWim) {
    Write-Host "检测到 install.wim，获取映像分卷列表..." -ForegroundColor Green
    & dism.exe /English /Get-WimInfo "/WimFile:$srcWim"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在导出目标分卷到工作区..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcWim" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
} else {
    Write-Host "检测到 install.esd，获取映像分卷列表..." -ForegroundColor Yellow
    & dism.exe /English /Get-WimInfo "/WimFile:$srcEsd"
    $index = Read-Host "请输入要精简的目标版本 Index 序号"
    Write-Host "正在将目标分卷从 ESD 转换导出为 install.wim..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$srcEsd" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
}

if (-not (Test-Path $destWim)) {
    Write-Host "[严重错误] install.wim 导出失败！终止流程。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

$index = "1"

Write-Host "解锁 install.wim 访问权限..." -ForegroundColor Green
attrib.exe -R -S -H "$destWim" 2>$null
Start-Process -FilePath "takeown.exe" -ArgumentList "/F `"$destWim`"" -NoNewWindow -Wait
Start-Process -FilePath "icacls.exe" -ArgumentList "`"$destWim`" /grant *S-1-5-32-544:F /C /Q" -NoNewWindow -Wait
(Get-Item $destWim).IsReadOnly = $false

Write-Host "正在挂载 install.wim 到 $scratchDir..." -ForegroundColor Green
if (Test-Path $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

$mountResult = & dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"
$mountResult | Out-Host

if (-not (Test-Path "$scratchDir\Windows\System32")) {
    Write-Host "[严重错误] 映像挂载失败！终止运行。" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

# ================= 辅助函数区 =================
function Force-NukeFolderOrFile {
    param ([string]$Target)
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

function Safely-UnloadHive {
    param ([string]$HiveName)
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    for ($i = 1; $i -le 5; $i++) {
        $err = & reg.exe unload "$HiveName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "成功卸载离线配置单元: $HiveName" -ForegroundColor DarkGray
            return $true
        }
        Write-Host "正在等待释放句柄，尝试第 $i 次重试卸载 $HiveName..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 1
    }
    Write-Host "[警告] $HiveName 单元卸载超时，但将继续推进。" -ForegroundColor Yellow
    return $false
}

# ----------------- 1. UWP 卸载 + 【避开重解析点的安全物理强删】 -----------------
Write-Host "正在清理冗余 UWP 预装应用 (严格保留 OOBE 与系统代理依赖)..." -ForegroundColor Yellow

$preservedPackages = @(
    "*VCLibs*",
    "*UI.Xaml*",
    "*NET.Native*",
    "*Client.CBS*",
    "*ShellExperience*",
    "*AccountsControl*",
    "*CloudExperienceHost*",
    "*BioEnrollment*",
    "*DesktopAppInstaller*"
)

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir

foreach ($app in $appxPackages) {
    $shouldKeep = $false
    foreach ($pattern in $preservedPackages) {
        if ($app.PackageName -like $pattern -or $app.DisplayName -like $pattern) {
            $shouldKeep = $true
            break
        }
    }

    if ($shouldKeep) {
        Write-Host "保留核心基础组件: $($app.DisplayName)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "删除冗余应用: $($app.PackageName)" -ForegroundColor Cyan
    & dism.exe /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
}

$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path $winAppsDir) {
    Write-Host "正在安全物理强删 WindowsApps 废弃应用 (绝对保护系统底层重解析点)..." -ForegroundColor DarkGray
    & takeown.exe /F "$winAppsDir" /A 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
    
    $protectedJunctions = @("Deleted", "Merged", "Mutable", "MutableBackup", "Projected", "Packages")

    Get-ChildItem -Path $winAppsDir -Directory | Where-Object { 
        $dirName = $_.Name
        if ($protectedJunctions -contains $dirName) { return $false }

        $isPreserved = $false
        foreach ($pattern in $preservedPackages) {
            if ($dirName -like $pattern) {
                $isPreserved = $true
                break
            }
        }
        -not $isPreserved
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# ----------------- 2. 功能包清理 (保留中文 + 保护 Hans 字体) -----------------
Write-Host "正在检索系统组件包并执行【仅保留中文】深度剔除..." -ForegroundColor Yellow

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split "`n" | Select-Object -Skip 1

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

foreach ($line in $pkgLines) {
    $pkgId = ($line -split "\s+")[0]
    if (-not $pkgId -or $pkgId -eq "Package" -or $pkgId -match "^-+$") { continue }

    $shouldDelete = $false

    foreach ($bp in $basePackagesToRemove) {
        if ($pkgId -like "$bp*") {
            $shouldDelete = $true
            break
        }
    }

    if (-not $shouldDelete) {
        $isLangRelated = ($pkgId -match "LanguageFeatures" -or $pkgId -match "LanguagePack" -or $pkgId -match "TextToSpeech" -or $pkgId -match "Speech-" -or $pkgId -match "Handwriting-" -or $pkgId -match "OCR-")
        if ($isLangRelated -and ($pkgId -notmatch "zh-CN|zh-cn|Hans")) {
            $shouldDelete = $true
        }
    }

    if (-not $shouldDelete -and ($pkgId -match "IME-ja-jp" -or $pkgId -match "IME-ko-kr" -or $pkgId -match "IME-zh-tw")) {
        $shouldDelete = $true
    }

    if ($shouldDelete) {
        Write-Host "剔除组件/外语包: $pkgId" -ForegroundColor DarkYellow
        & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$pkgId" /NoRestart 2>$null | Out-Null
    }
}

# ----------------- 3. 安全驱动压榨 -----------------
Write-Host "正在执行安全驱动压榨 (剔除打印机/调制解调器/传真驱动)..." -ForegroundColor Yellow
$driverStorePath = Join-Path $scratchDir "Windows\System32\DriverStore\FileRepository"

$safeDriverPurgeList = @(
    "prn*.inf_*", "mdm*.inf_*", "fax*.inf_*", "scancopy.inf_*",
    "flpydisk.inf_*", "brmf*.inf_*", "hpq*.inf_*"
)

if (Test-Path $driverStorePath) {
    foreach ($pat in $safeDriverPurgeList) {
        Get-ChildItem -Path $driverStorePath -Filter $pat -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Force-NukeFolderOrFile $_.FullName
        }
    }
}

# ----------------- 4. 停用冗余老旧 Windows 特性 -----------------
Write-Host "关闭老旧 Windows 特性 (WorkFolders/Fax 等)..." -ForegroundColor Yellow
$featuresToDisable = @(
    "WorkFolders-Client", "Printing-Foundation-Features",
    "Printing-PrintToPDFServices-Features", "FaxServicesClientPackage", "MSRDC-Infrastructure"
)
foreach ($feat in $featuresToDisable) {
    & dism.exe /English /Image:$scratchDir /Disable-Feature "/FeatureName:$feat" /Remove /NoRestart 2>$null | Out-Null
}

# ----------------- 5. 物理粉碎大文件实体 -----------------
Write-Host "深度物理粉碎非必要大文件实体 (Edge/OneDrive/Defender/Speech)..." -ForegroundColor Yellow

$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\Edge")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\EdgeUpdate")

Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

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

Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

$systemApps = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path $systemApps) {
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" -or $_.Name -like "*Search*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\TTS\en-US")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Help")

$wallpapers = Join-Path $scratchDir "Windows\Web\Wallpaper"
if (Test-Path $wallpapers) {
    Get-ChildItem -Path $wallpapers -Recurse -File | Where-Object { $_.Name -ne "img0.jpg" } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\Screen")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\TouchKeyboard")

$mediaDir = Join-Path $scratchDir "Windows\Media"
if (Test-Path $mediaDir) {
    Get-ChildItem -Path $mediaDir -Filter "*.wav" | Where-Object { 
        $_.Name -notmatch "Windows (Background|Foreground|Error|Ding|Default)\.wav" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

$fontsPath = Join-Path $scratchDir "Windows\Fonts"
if (Test-Path $fontsPath) {
    Write-Host "正在精炼中文字体库..." -ForegroundColor DarkGray
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "calibri*.*", "arial*.*", "times*.*", "msyh*.*", "simsun*.*", "simhei*.*", "kaiu*.*", "mingliu*.*" | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 6. 离线注册表深度压榨 (原子批处理·彻底杜绝管道与杀软死锁) -----------------
Write-Host "正在挂载离线注册表配置单元..." -ForegroundColor Green
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"

attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null

& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null

Write-Host "正在通过独立批处理引擎执行原子注册表修改 (杜绝 PowerShell 管道卡顿)..." -ForegroundColor Green

$normalServices = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc", "WSearch",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter", "SecurityHealthService"
)
$defenderFullStack = @("WinDefend", "WdNisSvc", "Sense", "WdFilter", "WdNisDrv", "WdBoot")

# 构建批处理脚本实体
$batLines = New-Object System.Collections.Generic.List[string]
$batLines.Add("@echo off")
$batLines.Add("chcp 65001 >nul")

if ($trimMode -eq "2") {
    $batLines.Add("echo >>> 执行极限模式: 抹杀 Defender 与无用底层服务...")
    $batLines.Add('reg add "HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch" /v "DriverLoadPolicy" /t REG_DWORD /d 8 /f >nul 2>nul')
    $extremeDeleteServices = $normalServices + $defenderFullStack + @("Spooler", "PrintNotify", "Fax", "RemoteRegistry", "diagsvc")
    foreach ($svc in $extremeDeleteServices) {
        $batLines.Add("reg delete `"HKLM\zSYSTEM\ControlSet001\Services\$svc`" /f >nul 2>nul")
    }
} else {
    $batLines.Add("echo >>> 执行普通模式: 安全停用后台服务 (Start = 4)...")
    $allServicesToDisable = $normalServices + $defenderFullStack
    foreach ($svc in $allServicesToDisable) {
        $batLines.Add("reg add `"HKLM\zSYSTEM\ControlSet001\Services\$svc`" /v `"Start`" /t REG_DWORD /d 4 /f >nul 2>nul")
    }
}

# 遥测与基本优化
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MaxTelemetryAllowed" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f >nul 2>nul')

# 彻底禁用 OneDrive
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSync" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableMeteredNetworkFileSync" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableLibrariesStylePin" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDriveSetup" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" /v "System.IsPinnedToNameSpaceTree" /t REG_DWORD /d 0 /f >nul 2>nul')

# 搜索禁用
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f >nul 2>nul')

# Edge 关联清理与 Explorer 增强
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\MSEdgeHTM" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\MSEdgePDF" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\Applications\msedge.exe" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoUseStoreOpenWith" /t REG_DWORD /d 1 /f >nul 2>nul')

# 记事本关联修复
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt" /ve /t REG_SZ /d "txtfile" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt" /v "PerceivedType" /t REG_SZ /d "text" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids" /v "txtfile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt\ShellNew" /v "NullFile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile" /ve /t REG_SZ /d "文本文档" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile\DefaultIcon" /ve /t REG_EXPAND_SZ /d "%%SystemRoot%%\system32\imageres.dll,-102" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile\shell\open\command" /ve /t REG_EXPAND_SZ /d "\"%%SystemRoot%%\System32\notepad.exe\" \"%%1\"" /f >nul 2>nul')

$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml" /ve /t REG_SZ /d "xmlfile" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml" /v "PerceivedType" /t REG_SZ /d "text" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml\OpenWithProgids" /v "xmlfile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\xmlfile" /ve /t REG_SZ /d "XML 文档" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\xmlfile\shell\open\command" /ve /t REG_EXPAND_SZ /d "\"%%SystemRoot%%\System32\notepad.exe\" \"%%1\"" /f >nul 2>nul')

$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" /v "UseFilter" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe" /ve /t REG_EXPAND_SZ /d "%%SystemRoot%%\system32\notepad.exe" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\Applications\notepad.exe" /v "NoOpenWith" /f >nul 2>nul')

# 经典照片查看器激活
$photoExts = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".jfif")
$batLines.Add('reg add "HKLM\zSOFTWARE\RegisteredApplications" /v "Windows Photo Viewer" /t REG_SZ /d "SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" /f >nul 2>nul')
foreach ($ext in $photoExts) {
    $batLines.Add("reg add `"HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations`" /v `"$ext`" /t REG_SZ /d `"PhotoViewer.FileAssoc.Tiff`" /f >nul 2>nul")
    $batLines.Add("reg add `"HKLM\zSOFTWARE\Classes\$ext`" /ve /t REG_SZ /d `"PhotoViewer.FileAssoc.Tiff`" /f >nul 2>nul")
}

# 硬件绕过与 OOBE 优化
$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
foreach ($k in $labConfigKeys) {
    $batLines.Add("reg add `"HKLM\zSYSTEM\Setup\LabConfig`" /v `"$k`" /t REG_DWORD /d 1 /f >nul 2>nul")
}
$batLines.Add('reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "DisableOnline" /t REG_DWORD /d 1 /f >nul 2>nul')

# 写入临时批处理并以原生 cmd 快速执行 (0 句柄占用)
$tempBatFile = Join-Path $env:TEMP "win11_reg_apply.bat"
[System.IO.File]::WriteAllLines($tempBatFile, $batLines, [System.Text.Encoding]::ASCII)

$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tempBatFile`"" -NoNewWindow -Wait -PassThru
Remove-Item -LiteralPath $tempBatFile -Force -ErrorAction SilentlyContinue

Write-Host ">>> 注册表优化与服务配置已极速应用完成！" -ForegroundColor Green

# 释放并安全卸载配置单元
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null

# ----------------- 7. 注入 autounattend.xml (30秒智能倒计时无人值守) -----------------
Write-Host "正在配置高级无人值守应答文件..." -ForegroundColor Green

# 30 秒智能倒计时函数 (具备环境自适应防崩逻辑)
function Read-InputWithTimeout {
    param(
        [string]$Prompt = "请输入自定义用户名",
        [int]$Seconds = 30,
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
            Write-Host "`n>>> [超时] 超过 $Seconds 秒未输入，已自动采用默认用户名: $Default (密码自动留空)" -ForegroundColor Yellow
            return @{ TimedOut = $true; Value = $Default }
        }

        if ($inputStr.Length -eq 0 -and $remaining -ne $lastPrinted) {
            $lastPrinted = $remaining
            try { [Console]::CursorLeft = 0 } catch { }
            Write-Host -NoNewline "$Prompt (默认: $Default) [剩余 $remaining 秒]: " -ForegroundColor Cyan
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
                    try {
                        [Console]::CursorLeft = 0
                        $blank = " " * [Math]::Max(1, ([Console]::WindowWidth - 1))
                        Write-Host -NoNewline $blank
                        [Console]::CursorLeft = 0
                    } catch { }
                    Write-Host -NoNewline "${Prompt}: " -ForegroundColor Cyan
                }
                $inputStr.Append($key.KeyChar) | Out-Null
                Write-Host -NoNewline $key.KeyChar
            }
        }
        Start-Sleep -Milliseconds 50
    }
}

# 获取用户名
$userResult = Read-InputWithTimeout -Prompt "请输入登录用户名" -Seconds 30 -Default "Admin"
$inputUser = $userResult.Value

if ($inputUser -match "^(Administrator|Guest)$") {
    Write-Host "[警告] 输入了系统保留账户名 $inputUser，自动重置为 Admin！" -ForegroundColor Yellow
    $inputUser = "Admin"
}

# 密码设定
if ($userResult.TimedOut) {
    $inputPass = ""
} else {
    $inputPass = Read-Host "请输入登录密码 (直接回车表示留空无密码)"
}

$inputPassEscaped = [System.Security.SecurityElement]::Escape($inputPass)

$unattendTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
	<settings pass="offlineServicing"></settings>
	<settings pass="windowsPE">
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
		$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach ($f in $xmlFiles) {
			if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; }
		}

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

$autoUnattendXml = $unattendTemplate.Replace('__CUSTOM_USER__', $inputUser).Replace('__CUSTOM_PASS__', $inputPassEscaped)

$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$autoUnattendXml | Out-File -FilePath (Join-Path $sysprepDir "autounattend.xml") -Encoding utf8 -Force
$autoUnattendXml | Out-File -FilePath (Join-Path $pantherDir "unattend.xml") -Encoding utf8 -Force
$autoUnattendXml | Out-File -FilePath (Join-Path $workDir "autounattend.xml") -Encoding utf8 -Force

# ----------------- 8. 模式分支：极限模式执行【通用自适应 WinSxS 瘦身】 -----------------
if ($trimMode -eq "2") {
    Write-Host ">>> [极限模式] 执行通用自适应 WinSxS 组件库深度瘦身 (兼容全版本 Win11)..." -ForegroundColor Red
    
    $winsxsPath     = Join-Path $scratchDir "Windows\WinSxS"
    $winsxsEditPath = Join-Path $scratchDir "Windows\WinSxS_edit"

    $arch = if (Test-Path "$scratchDir\Windows\SysWOW64") { "amd64" } else { "arm64" }
    Write-Host ">>> 识别到系统架构为: $arch，正在构建动态保留链..." -ForegroundColor Cyan

    & takeown.exe /F "$winsxsPath" /R /D Y 2>$null | Out-Null
    & icacls.exe "$winsxsPath" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
    
    New-Item -Path $winsxsEditPath -ItemType Directory -Force | Out-Null

    # 保护通用核心元数据目录
    $metaDirs = @("Catalogs", "FileMaps", "Fusion", "InstallTemp", "Manifests", "Settings")
    foreach ($meta in $metaDirs) {
        $metaSrc = Join-Path $winsxsPath $meta
        if (Test-Path $metaSrc) {
            Copy-Item -Path $metaSrc -Destination (Join-Path $winsxsEditPath $meta) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 动态特征通配保留
    $featureKeywords = @(
        "*common-controls*",
        "*gdiplus*",
        "*isolationautomation*",
        "*proxystub*",
        "*servicingstack*",
        "*onecore*",
        "*vc*.crt*",
        "*termsrv-extra*"
    )

    Get-ChildItem -Path $winsxsPath -Directory | Where-Object {
        $dirName = $_.Name
        if ($metaDirs -contains $dirName) { return $false }

        if (-not ($dirName.StartsWith($arch) -or $dirName.StartsWith("x86") -or $dirName.StartsWith("msil"))) { 
            return $false 
        }

        foreach ($kw in $featureKeywords) {
            if ($dirName -like $kw) { return $true }
        }
        return $false
    } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $winsxsEditPath $_.Name) -Recurse -Force -ErrorAction SilentlyContinue
    }

    Force-NukeFolderOrFile $winsxsPath
    Rename-Item -Path $winsxsEditPath -NewName "WinSxS" -Force

    Write-Host ">>> 自适应 WinSxS 瘦身完成！已安全保留关键依赖。" -ForegroundColor Green
} else {
    Write-Host ">>> [普通模式] 执行官方标准 ResetBase 清理补丁缓存..." -ForegroundColor Green
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase 2>$null | Out-Null
}

# 提交并卸载主镜像
Write-Host "正在保存并卸载 install.wim..." -ForegroundColor Green
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# ----------------- 9. 导出为高压缩率 ESD -----------------
Write-Host "正在导出为高压缩率 install.esd..." -ForegroundColor Green
$esdFile = Join-Path $sourcesDir "install.esd"
& dism.exe /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

if (Test-Path -LiteralPath $esdFile) {
    Write-Host "[成功] install.esd 构建完成，已移除临时 install.wim。" -ForegroundColor Green
    Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[警告] ESD 转换异常，保留 install.wim 继续流程。" -ForegroundColor Yellow
}

# ----------------- 10. 修补 WinPE (boot.wim) -----------------
Write-Host "为 WinPE (boot.wim) 写入免硬件检测策略..." -ForegroundColor Green
$bootWimPath = Join-Path $sourcesDir "boot.wim"
attrib.exe -R -S -H "$bootWimPath" 2>$null

$bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$bootIndex = "2"
if ($bootInfo -notmatch "Index : 2") { $bootIndex = "1" }

& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$bootIndex" "/MountDir:$scratchDir"

$bootSystemPath = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
attrib.exe -R -S -H "$bootSystemPath" 2>$null
& reg.exe load HKLM\zSYSTEM "$bootSystemPath" 2>$null | Out-Null

foreach ($k in $labConfigKeys) {
    & reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $k /t REG_DWORD /d 1 /f 2>$null | Out-Null
}

Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# ----------------- 11. 最终打包生成 ISO (完美 UEFI + BIOS 双模引导) -----------------
Write-Host "正在打包最终可引导 ISO 镜像 (兼容 BIOS + UEFI)..." -ForegroundColor Green

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

$outputISO = Join-Path $scriptDir "win11_ultra_v7.iso"
$etfsboot = Join-Path $workDir "boot\etfsboot.com"

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

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " 构建完毕！ISO 镜像输出路径:" -ForegroundColor Green
Write-Host " $outputISO" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

Read-Host "按回车键 [ENTER] 清理临时工作缓存..."

cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript
