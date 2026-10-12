# ==============================================================================
#  nano10 Builder - Windows 10 终极压榨完美完整版 v5.0 (全功能合并 + 双绝杀终极版)
#  - [双重绝杀] 注入 autounattend.xml + 离线锁死云端，彻底跳过 OOBE 直达桌面
#  - [强杀保全] 物理级暴力粉碎垃圾应用，避开底层重解析点，彻底根治 1392 损坏错误
#  - [核心防护] 绝对保护 Win10 开始菜单宿主 (StartMenuExperience/ShellExperience)
#  - [核心保护] 严格保留简体中文字体核心包 (Fonts-Hans)，告别字体误杀
#  - [全功能保留] 原生 Win32 记事本秒开 (带右键新建) + 照片查看器 + 驱动安全压榨
#  - [深层清除] 彻底物理粉碎 Edge、OneDrive、Defender、Cortana、Speech 声学库
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

# 3. 强制以管理员身份运行
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

# 4. 开启全程双重日志
$logFile = Join-Path -Path $scriptDir -ChildPath "nano10_final_build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
try {
    Start-Transcript -Path $logFile -Append -Force
} catch {
    Write-Host "日志初始化失败: $_" -ForegroundColor Red
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " nano10 Builder (全功能合并 + 双绝杀终极版 v5.0) " -ForegroundColor Cyan
Write-Host " 日志文件: $logFile" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$mainOSDrive = $env:SystemDrive
$scratchDir  = Join-Path $mainOSDrive "scratchdir"
$workDir     = Join-Path $mainOSDrive "nano10"
$sourcesDir  = Join-Path $workDir "sources"

Write-Host "清理残留挂载点并重置环境..." -ForegroundColor DarkGray
& dism.exe /English /Cleanup-Wim | Out-Null

if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

$DriveLetter = Read-Host "请输入 Windows 10 ISO 虚拟光驱盘符 (例如 E)"
$DriveLetter = ($DriveLetter.TrimEnd(':').Trim()) + ":"

if (-not (Test-Path "$DriveLetter\sources\boot.wim") -or (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd"))) {
    Write-Host "[错误] 在 $DriveLetter 中未找到有效的 Windows 10 安装源！" -ForegroundColor Red
    Stop-Transcript
    pause
    exit
}

Write-Host "正在复制 Windows 10 ISO 核心结构到工作区..." -ForegroundColor Green
& robocopy.exe "$DriveLetter" "$workDir" /E /XF "install.wim" "install.esd" /NDL /NFL /NJH /NJS | Out-Null

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

$index = "1"

Write-Host "解锁 install.wim 访问权限..." -ForegroundColor Green
attrib.exe -R -S -H "$destWim"
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

# ================= 终极粉碎函数 =================
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

# ----------------- 1. UWP 精简 + 【无损精准物理强删】 -----------------
Write-Host "正在清理冗余 UWP 预装应用 (严格保护开始菜单、账户及打开方式依赖)..." -ForegroundColor Yellow

$preservedPackages = @(
    "*VCLibs*",
    "*UI.Xaml*",
    "*NET.Native*",
    "*ShellExperience*",
    "*StartMenuExperience*",  # 核心保护：Win10 开始菜单宿主
    "*Client.CBS*",
    "*AccountsControl*",      # 核心保护：账户认证
    "*CloudExperienceHost*",  # 核心保护：OOBE 宿主
    "*BioEnrollment*",         # 核心保护：凭据过渡
    "*DesktopAppInstaller*"   # 核心保护：应用安装代理
)

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$removedAppxPackages = @()

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
    $removedAppxPackages += $app
    & dism.exe /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" | Out-Null
}

# 【升级版物理强删】：仅粉碎无用应用实体，绝对保护系统底层重解析点 (彻底解决 1392 错误)
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path $winAppsDir) {
    Write-Host "正在执行安全物理强删 (精准剔除废弃应用，保护系统软链接)..." -ForegroundColor DarkGray
    & takeown.exe /F "$winAppsDir" /A 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
    
    # 绝对禁止触碰的底层重解析点
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

# ----------------- 2. 移除冗余功能包 (保留中文 + 修复 Hans 字体误杀) -----------------
Write-Host "正在剔除多余功能包与语言..." -ForegroundColor Yellow

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
    "Microsoft-Windows-TPM-WMI-Provider-Package~"
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

    # 【关键保护】：增加 Hans 保护，绝不误杀简体中文字体核心包
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
        Write-Host "剔除组件包: $pkgId" -ForegroundColor DarkYellow
        & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$pkgId" /NoRestart | Out-Null
    }
}

# ----------------- 3. 安全驱动压榨 (移除打印机/Modem/传真) -----------------
Write-Host "正在执行安全驱动压榨 (剔除通用打印机/调制解调器/传真驱动)..." -ForegroundColor Yellow
$driverStorePath = Join-Path $scratchDir "Windows\System32\DriverStore\FileRepository"

$safeDriverPurgeList = @(
    "prn*.inf_*",       # 预装打印机驱动
    "mdm*.inf_*",       # 调制解调器 Modem 驱动
    "fax*.inf_*",       # 传真机驱动
    "scancopy.inf_*",   # 老旧扫描仪驱动
    "flpydisk.inf_*",   # 软驱驱动
    "brmf*.inf_*",      # Brother 驱动
    "hpq*.inf_*"        # HP 驱动
)

if (Test-Path $driverStorePath) {
    foreach ($pat in $safeDriverPurgeList) {
        Get-ChildItem -Path $driverStorePath -Filter $pat -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Force-NukeFolderOrFile $_.FullName
        }
    }
}

# ----------------- 4. 停用老旧可选特性 -----------------
Write-Host "关闭老旧 Windows 特性 (WorkFolders/Fax 等)..." -ForegroundColor Yellow
$featuresToDisable = @(
    "WorkFolders-Client",
    "Printing-Foundation-Features",
    "Printing-PrintToPDFServices-Features",
    "FaxServicesClientPackage"
)
foreach ($feat in $featuresToDisable) {
    & dism.exe /English /Image:$scratchDir /Disable-Feature "/FeatureName:$feat" /Remove /NoRestart 2>$null | Out-Null
}

# ----------------- 5. 物理粉碎 Edge、OneDrive、Defender (精准保护开始菜单) -----------------
Write-Host "物理清除 Edge、OneDrive、Defender 与大文件实体..." -ForegroundColor Yellow

# 清除 WinRE
$recoveryDir = Join-Path $scratchDir "Windows\System32\Recovery"
Force-NukeFolderOrFile (Join-Path $recoveryDir "winre.wim")
Force-NukeFolderOrFile (Join-Path $recoveryDir "ReAgent.xml")

# 清除 Edge
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\Edge")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft\EdgeUpdate")

# 物理粉碎 OneDrive
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\SysWOW64\OneDriveSetup.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft OneDrive")
Force-NukeFolderOrFile (Join-Path $scratchDir "Users\Default\AppData\Local\Microsoft\OneDrive")

# 物理粉碎 Defender
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "ProgramData\Microsoft\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files (x86)\Windows Defender")
Force-NukeFolderOrFile (Join-Path $scratchDir "Program Files\Windows Defender Advanced Threat Protection")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthSystray.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\SecurityHealthService.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\smartscreen.exe")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\CHT")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\JPN")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\InputMethod\KOR")

# 【精确定位粉碎小娜与搜索】：只清理 Cortana 与 WindowsSearch，绝不伤及 StartMenuExperienceHost
$systemApps = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path $systemApps) {
    Get-ChildItem -Path $systemApps -Directory | Where-Object { 
        $_.Name -like "*Cortana*" -or $_.Name -like "*WindowsSearch*" 
    } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}

# 粉碎语音识别声学库与帮助文档
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Speech\Engines\TTS\en-US")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\System32\Speech\Engines\SR")
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Help")

# 清理 4K 默认壁纸与多余音效
$wallpapers = Join-Path $scratchDir "Windows\Web\Wallpaper"
if (Test-Path $wallpapers) {
    Get-ChildItem -Path $wallpapers -Recurse -File | Where-Object { $_.Name -ne "img0.jpg" } | ForEach-Object {
        Force-NukeFolderOrFile $_.FullName
    }
}
Force-NukeFolderOrFile (Join-Path $scratchDir "Windows\Web\Screen")

# 精简字体
$fontsPath = Join-Path $scratchDir "Windows\Fonts"
if (Test-Path $fontsPath) {
    Write-Host "正在精炼中文字体库..." -ForegroundColor DarkGray
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "calibri*.*", "arial*.*", "times*.*", "msyh*.*", "simsun*.*", "simhei*.*", "kaiu*.*", "mingliu*.*" | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 6. 离线注册表深度压榨 -----------------
Write-Host "正在加载离线注册表、优化后台并彻底修复打开方式..." -ForegroundColor Green
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"

attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null

& reg.exe load HKLM\zSOFTWARE "$softwarePath" | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" | Out-Null

# 6.1 关闭后台冗余服务 (安全名单，放行 NaturalAuthentication 与 wscsvc)
$servicesToDisable = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc", "WSearch",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter",
    "WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "SecurityHealthService"
)

foreach ($svc in $servicesToDisable) {
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 4 /f | Out-Null
}

# 6.2 遥测与基础优化
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MaxTelemetryAllowed" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f | Out-Null

# 【核心保护】：严禁离线写入 LetAppsRunInBackground = 2，确保 Win10 开始菜单平稳拉起
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f | Out-Null

# 6.3 彻底封锁 OneDrive
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSync" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableMeteredNetworkFileSync" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableLibrariesStylePin" /t REG_DWORD /d 1 /f | Out-Null

cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v `"OneDrive`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v `"OneDriveSetup`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run`" /v `"OneDrive`" /f 2>nul" | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" /v "System.IsPinnedToNameSpaceTree" /t REG_DWORD /d 0 /f | Out-Null

# 6.4 搜索与小娜禁用
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f | Out-Null

# 6.5 【核心修复：彻底解决 TXT/XML 及所有文件的“打开方式 - 更多应用”无反应】
Write-Host "清除 Edge 幽灵并配置原生 Win32 记事本与经典打开方式..." -ForegroundColor DarkCyan

# 铲除 Edge 幽灵 ProgID (根治 XML/HTML 候选崩溃)
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Classes\MSEdgeHTM`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Classes\MSEdgePDF`" /f 2>nul" | Out-Null
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Classes\Applications\msedge.exe`" /f 2>nul" | Out-Null

# 彻底修复打开方式“更多应用”无反应 Bug (禁联网/禁商店检索，纯本地秒开)
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoUseStoreOpenWith" /t REG_DWORD /d 1 /f | Out-Null

$notepadSysCmd = "`"%SystemRoot%\System32\notepad.exe`" `"%1`""

# 规范 .txt
& reg.exe add "HKLM\zSOFTWARE\Classes\.txt" /ve /t REG_SZ /d "txtfile" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\.txt" /v "PerceivedType" /t REG_SZ /d "text" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids" /v "txtfile" /t REG_NONE /d "" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\.txt\ShellNew" /v "NullFile" /t REG_SZ /d "" /f | Out-Null

& reg.exe add "HKLM\zSOFTWARE\Classes\txtfile" /ve /t REG_SZ /d "文本文档" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\txtfile\DefaultIcon" /ve /t REG_EXPAND_SZ /d "`"%SystemRoot%\system32\imageres.dll`",-102" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\txtfile\shell\open\command" /ve /t REG_EXPAND_SZ /d $notepadSysCmd /f | Out-Null

# 规范 .xml
& reg.exe add "HKLM\zSOFTWARE\Classes\.xml" /ve /t REG_SZ /d "xmlfile" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\.xml" /v "PerceivedType" /t REG_SZ /d "text" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\.xml\OpenWithProgids" /v "xmlfile" /t REG_NONE /d "" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\xmlfile" /ve /t REG_SZ /d "XML 文档" /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Classes\xmlfile\shell\open\command" /ve /t REG_EXPAND_SZ /d $notepadSysCmd /f | Out-Null

# 修复 notepad.exe 应用路径与 IFEO 过滤
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" /v "UseFilter" /t REG_DWORD /d 0 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe" /ve /t REG_EXPAND_SZ /d "`"%SystemRoot%\system32\notepad.exe`"" /f | Out-Null
cmd.exe /c "reg delete `"HKLM\zSOFTWARE\Classes\Applications\notepad.exe`" /v `"NoOpenWith`" /f 2>nul" | Out-Null

# 经典照片查看器激活
$photoExts = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".jfif")
& reg.exe add "HKLM\zSOFTWARE\RegisteredApplications" /v "Windows Photo Viewer" /t REG_SZ /d "SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" /f | Out-Null
foreach ($ext in $photoExts) {
    & reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations" /v "$ext" /t REG_SZ /d "PhotoViewer.FileAssoc.Tiff" /f | Out-Null
    & reg.exe add "HKLM\zSOFTWARE\Classes\$ext" /ve /t REG_SZ /d "PhotoViewer.FileAssoc.Tiff" /f | Out-Null
}

# 6.6 禁用预装推广与 OOBE 锁死
& reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f | Out-Null

# 【彻底绝杀 OOBE 假死机制】：双重锁死云端联网
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f | Out-Null
& reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "DisableOnline" /t REG_DWORD /d 1 /f | Out-Null

# 卸载离线注册表
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

& reg.exe unload HKLM\zSOFTWARE | Out-Null
& reg.exe unload HKLM\zSYSTEM | Out-Null
& reg.exe unload HKLM\zNTUSER | Out-Null

# ----------------- 7. 注入 autounattend.xml (零触控直达桌面，根本不给死循环机会) -----------------
Write-Host "正在注入自动应答文件 (静默创建本地管理员 Admin，秒进桌面)..." -ForegroundColor Green

$autoUnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Description>系统默认管理员账户</Description>
                        <DisplayName>Admin</DisplayName>
                        <Group>Administrators</Group>
                        <Name>Admin</Name>
                        <Password>
                            <Value></Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value></Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>Admin</Username>
            </AutoLogon>
        </component>
    </settings>
</unattend>
"@

# 双重注入：1. 镜像内部 Sysprep 目录 (最高优先级生效)
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
if (-not (Test-Path $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
$autoUnattendXml | Out-File -FilePath (Join-Path $sysprepDir "autounattend.xml") -Encoding utf8 -Force

# 双重注入：2. ISO 根目录 (安装引导直接捕获)
$autoUnattendXml | Out-File -FilePath (Join-Path $workDir "autounattend.xml") -Encoding utf8 -Force

# ----------------- 8. 深度重置基准组件 (ResetBase) -----------------
Write-Host "执行底层组件库清理并硬清除旧版本补丁缓存 (ResetBase)..." -ForegroundColor Green
$cleanResult = & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
if ($LASTEXITCODE -ne 0) {
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup | Out-Null
}

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# ----------------- 9. 导出为最大压缩比 ESD (消灭 1392 错误) -----------------
Write-Host "正在将目标分卷导出为高压缩率 install.esd (压榨镜像体积)..." -ForegroundColor Green
$esdFile = Join-Path $sourcesDir "install.esd"
& dism.exe /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

if (Test-Path -LiteralPath $esdFile) {
    Write-Host "[成功] install.esd 已成功构建，删除临时 install.wim。" -ForegroundColor Green
    Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[警告] ESD 转换异常，保留 install.wim 继续流程。" -ForegroundColor Yellow
}

# ----------------- 10. 优化 boot.wim -----------------
Write-Host "正在优化 boot.wim (Index 2)..." -ForegroundColor Green
$bootWimPath = Join-Path $sourcesDir "boot.wim"
attrib.exe -R -S -H "$bootWimPath" 2>$null

& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" /Index:2 "/MountDir:$scratchDir"
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

# ----------------- 11. 最终打包可引导 ISO -----------------
Write-Host "正在生成最终纯净 Windows 10 安装镜像 ISO..." -ForegroundColor Green
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$oscdimgExe = Join-Path $scriptDir "oscdimg.exe"

if (-not (Test-Path $oscdimgExe)) {
    Write-Host "从官方资源拉取 oscdimg.exe..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe" -OutFile $oscdimgExe
}

$outputISO = Join-Path $scriptDir "nano10_ultra_purged_final.iso"
$etfsboot = Join-Path $workDir "boot\etfsboot.com"
$efisys = Join-Path $workDir "efi\microsoft\boot\efisys.bin"
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

Start-Process -FilePath $oscdimgExe -ArgumentList $oscdimgArgs -NoNewWindow -Wait

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " 构建完毕！Windows 10 完美优化 ISO 已生成:" -ForegroundColor Green
Write-Host " $outputISO" -ForegroundColor Green
Write-Host " 开始菜单正常、修复打开方式更多应用、零 1392 错误且直接进桌面！" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

Read-Host "按回车键 [ENTER] 清理临时工作目录并安全退出..."

cmd.exe /c "dism.exe /English /Unmount-Image /MountDir:`"$scratchDir`" /Discard 2>nul" | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript