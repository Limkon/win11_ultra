# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [重构加固]：动态语言感知 + 属性页 COM 架构保护 + 生产力组件保留
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 (彻底杜绝外语 ISO 报废) -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并清理冗余 UWP 预装应用..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. UWP 卸载 + 定向物理粉碎 -----------------
# 核心基础白名单（绝不能删除的底层基础框架与高频终端环境）
$preservedPackages = @(
    "*VCLibs*",
    "*UI.Xaml*",
    "*NET.Native*",
    "*Client.CBS*",
    "*ShellExperience*",
    "*AccountsControl*",
    "*CloudExperienceHost*",
    "*BioEnrollment*",
    "*WindowsTerminal*",        # 保留终端：彻底杜绝右键“在终端中打开”报找不到应用
    "*DesktopAppInstaller*"     # 保留应用安装程序：保留 Winget 与离线 MSIX/APPX 安装能力
)

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$totalAppx = $appxPackages.Count
$currentAppx = 0
$deletedAppxList = New-Object System.Collections.Generic.List[string]

foreach ($app in $appxPackages) {
    $currentAppx++
    $shouldKeep = $false
    foreach ($pattern in $preservedPackages) {
        if ($app.PackageName -like $pattern -or $app.DisplayName -like $pattern) {
            $shouldKeep = $true
            break
        }
    }

    $pct = [math]::Round(($currentAppx / [math]::Max(1, $totalAppx)) * 100)
    Write-Progress -Activity "正在清理 UWP 预装应用" -Status "[$currentAppx/$totalAppx] 正在处理: $($app.DisplayName)" -PercentComplete $pct

    if ($shouldKeep) {
        Write-Host "   [$currentAppx/$totalAppx] [保留核心] $($app.DisplayName)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "   [$currentAppx/$totalAppx] [删除应用] $($app.PackageName)" -ForegroundColor Yellow
    & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
    $deletedAppxList.Add($app.PackageName)
}
Write-Progress -Activity "正在清理 UWP 预装应用" -Completed

# 精准定向物理粉碎已卸载的应用实体 (绝不污染父目录 SDDL，彻底释放磁盘空间)
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path -LiteralPath $winAppsDir) {
    Write-Host "   正在执行 WindowsApps 废弃应用实体定向物理粉碎..." -ForegroundColor DarkGray

    foreach ($pkgName in $deletedAppxList) {
        $targetFolder = Join-Path $winAppsDir $pkgName
        if (Test-Path -LiteralPath $targetFolder) {
            Force-NukeFolderOrFile $targetFolder
        }
    }

    # 关键安全加固：确保父目录具备 ALL APPLICATION PACKAGES 只读权限，彻底杜绝沙箱进程闪退
    & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
}
Write-Host "[完成] UWP 应用清理与实体定向粉碎完毕。" -ForegroundColor Green

# ----------------- 2. 功能包清理 (严格保留 Search-Engine-Client 以固化属性页) -----------------
Write-Host "`n[步骤 5/11] 正在检索系统组件包并执行深度可选功能精简..." -ForegroundColor Cyan

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split '\r?\n' | Select-Object -Skip 1

# 基础需要剥离的无用功能包列表
# 【底层架构警示】：绝对不能删除 Microsoft-Windows-Search-Engine-Client-Package，
#  否则盘符属性页底部的索引复选框和文件高级属性 COM 结构会彻底暴毙，导致右键属性无反应！
$basePackagesToRemove = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~", # IE 基础可选组件彻底剔除
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

# 动态筛选需剔除的目标列表
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
                # 中文环境下，额外保留简体中文 Hans 标识
                if ($pkgId -match "zh-CN|zh-cn|Hans") { $isCurrentLang = $true }
            }
            if (-not $isCurrentLang) {
                $shouldDelete = $true
            }
        }
    }

    # 冗余非主语言输入法包判定 (仅在当前环境非对应语系时剔除)
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
Write-Host "[完成] 系统可选功能包精炼完毕 (Search-Engine-Client 核心属性底层接口已受保护保留)。" -ForegroundColor Green
