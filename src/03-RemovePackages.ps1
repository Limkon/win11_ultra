# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [架构重构]：标准 DISM 原生卸载体系 + 保护底层 ACL 与框架签名 + 杜绝暴力夺权
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并清理冗余 UWP 预装应用..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. 加载 Appslist.txt 黑名单规则 -----------------
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
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith("#")) {
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

# ----------------- 2. UWP 规范级 DISM 卸载 (严禁暴力夺权 WindowsApps) -----------------
$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$totalAppx = $appxPackages.Count
$currentAppx = 0

foreach ($app in $appxPackages) {
    $currentAppx++
    $shouldDelete = $false

    # 绝对核心保护白名单 (即便黑名单手误写入也坚决不删)
    if ($app.PackageName -like "*WindowsStore*" -or 
        $app.PackageName -like "*VCLibs*" -or 
        $app.PackageName -like "*UI.Xaml*" -or
        $app.PackageName -like "*Appinstaller*") {
        Write-Host "   [$currentAppx/$totalAppx] [底层框架免疫保护] $($app.DisplayName)" -ForegroundColor Green
        continue
    }

    # 匹配黑名单规则
    foreach ($pattern in $blacklistPatterns) {
        if ($app.PackageName -like $pattern -or $app.DisplayName -like $pattern) {
            $shouldDelete = $true
            break
        }
    }

    $pct = [math]::Round(($currentAppx / [math]::Max(1, $totalAppx)) * 100)
    Write-Progress -Activity "正在通过官方 DISM API 规范卸载 UWP" -Status "[$currentAppx/$totalAppx] 比对: $($app.DisplayName)" -PercentComplete $pct

    if (-not $shouldDelete) {
        Write-Host "   [$currentAppx/$totalAppx] [保留组件] $($app.DisplayName)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "   [$currentAppx/$totalAppx] [DISM 卸载] $($app.PackageName)" -ForegroundColor Yellow
    # 严格使用官方 DISM 命令脱机注销，由系统自动维护 StateRepository 数据库一致性
    & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
}
Write-Progress -Activity "正在通过官方 DISM API 规范卸载 UWP" -Completed

# 确保父目录具备标准沙箱安全只读权限
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path -LiteralPath $winAppsDir) {
    & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
}
Write-Host "[完成] UWP 预装应用官方标准精简完毕 (框架契约完好)。" -ForegroundColor Green

# ----------------- 3. 功能包清理 (严格保留核心属性扩展底层) -----------------
Write-Host "`n[步骤 5/11] 正在检索系统组件包并执行深度可选功能精简..." -ForegroundColor Cyan

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split '\r?\n' | Select-Object -Skip 1

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

    # 动态外语包与输入法清理 (严格保护母盘核心主语言)
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
Write-Host "[完成] 系统可选功能包精炼完毕。" -ForegroundColor Green
