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
