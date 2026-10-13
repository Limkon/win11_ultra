# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [重构加固]：动态语言感知 + 基于 Appslist.txt 黑名单过滤 + 属性页 COM 架构保护
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 (彻底杜绝外语 ISO 报废) -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并清理冗余 UWP 预装应用..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. 加载 Appslist.txt 黑名单规则 -----------------
# 自动探测 Appslist.txt 路径 (支持存放在脚本目录、项目根目录或当前工作目录)
$appsListCandidates = @(
    (Join-Path $scriptDir "Appslist.txt"),
    (Join-Path (Split-Path -Parent $scriptDir) "Appslist.txt"),
    (Join-Path (Get-Location) "Appslist.txt")
)

$appsListPath = $null
foreach ($path in $appsListCandidates) {
    if (Test-Path -LiteralPath $path) {
        $appsListPath = $path
        break
    }
}

$blacklistPatterns = New-Object System.Collections.Generic.List[string]

if ($appsListPath) {
    Write-Host "   [黑名单加载] 正在读取黑名单配置: $appsListPath" -ForegroundColor Green
    Get-Content -LiteralPath $appsListPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        # 跳过整行注释和空行
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith("#")) {
            # 剥离行尾内联注释 (如: Clipchamp.Clipchamp # Video editor...)
            $appId = ($line -split '#')[0].Trim()
            if (-not [string]::IsNullOrWhiteSpace($appId)) {
                $blacklistPatterns.Add("*$appId*")
            }
        }
    }
    Write-Host "   [黑名单加载] 成功加载 $($blacklistPatterns.Count) 条待卸载应用规则。" -ForegroundColor DarkGray
} else {
    Write-Host "   [警告] 未找到 Appslist.txt 文件！跳过 UWP 黑名单删除流程。" -ForegroundColor Yellow
}

# ----------------- 2. UWP 黑名单卸载 + 定向物理粉碎 -----------------
$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$totalAppx = $appxPackages.Count
$currentAppx = 0
$deletedAppxList = New-Object System.Collections.Generic.List[string]

foreach ($app in $appxPackages) {
    $currentAppx++
    $shouldDelete = $false

    # 在黑名单规则中匹配
    foreach ($pattern in $blacklistPatterns) {
        if ($app.PackageName -like $pattern -or $app.DisplayName -like $pattern) {
            $shouldDelete = $true
            break
        }
    }

    $pct = [math]::Round(($currentAppx / [math]::Max(1, $totalAppx)) * 100)
    Write-Progress -Activity "正在按黑名单清理 UWP 预装应用" -Status "[$currentAppx/$totalAppx] 正在比对: $($app.DisplayName)" -PercentComplete $pct

    if (-not $shouldDelete) {
        Write-Host "   [$currentAppx/$totalAppx] [保留应用] $($app.DisplayName)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "   [$currentAppx/$totalAppx] [黑名单命中·删除] $($app.PackageName)" -ForegroundColor Yellow
    & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
    $deletedAppxList.Add($app.PackageName)
}
Write-Progress -Activity "正在按黑名单清理 UWP 预装应用" -Completed

# 精准定向物理粉碎已卸载的应用实体 (绝不破坏父目录 SDDL，彻底释放磁盘空间)
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
Write-Host "[完成] UWP 黑名单应用清理与实体定向粉碎完毕。" -ForegroundColor Green

# ----------------- 3. 功能包清理 (严格保留 Search-Engine-Client 以固化属性页) -----------------
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
Write-Host "[完成] 系统可选功能包精炼完毕 (Search-Engine-Client 核心属性底层接口已受保护保留)。" -ForegroundColor Green
