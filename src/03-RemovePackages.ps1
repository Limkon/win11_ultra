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
