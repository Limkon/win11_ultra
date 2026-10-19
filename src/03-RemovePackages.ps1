# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行 UWP 应用精简..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. UWP 预装应用通配精简与物理清理 -----------------
Write-Host "Removing provisioned AppX packages (bloatware)..."
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
    $_.PackageName -like '*CoreAI*'  -or 
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

Write-Host "[完成] UWP 预装应用卸载与 WindowsApps 残留清理完毕。" -ForegroundColor Green

# ----------------- 2. 系统可选功能包精简 (保留 Search-Engine-Client 以固化属性页) -----------------
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
