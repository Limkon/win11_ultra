# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 1. 语言与硬件架构深度探针 -----------------
# 探查默认 UI 语言并写入全局变量，确保跨模块引导与应答文件协同
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$matchedLang = $false
foreach ($line in ($imageIntl -split '\r?\n')) {
    if ($line -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
        $global:languageCode = $Matches[1].Trim()
        $matchedLang = $true
        Write-Host "检测到默认系统 UI 语言代码: $global:languageCode" -ForegroundColor Green
        break
    }
}

if (-not $matchedLang -or [string]::IsNullOrWhiteSpace($global:languageCode)) {
    $global:languageCode = "zh-CN"
    Write-Host "[提示] 未能从映像中探测到明确的 UI 语言代码，安全回退默认值: $global:languageCode" -ForegroundColor Yellow
}

# 探查目标映像处理器架构
$destWimPath = Join-Path $sourcesDir "install.wim"
$imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
$matchedArch = $false
foreach ($line in ($imageInfo -split '\r?\n')) {
    if ($line -match 'Architecture\s*:\s*(.+)$') {
        $rawArch = $Matches[1].Trim().ToLower()
        if ($rawArch -eq 'x64' -or $rawArch -eq 'amd64') {
            $global:architecture = 'amd64'
        } elseif ($rawArch -eq 'arm64') {
            $global:architecture = 'arm64'
        } elseif ($rawArch -eq 'x86') {
            $global:architecture = 'x86'
        } else {
            $global:architecture = $rawArch
        }
        $matchedArch = $true
        Write-Host "检测到映像处理器架构: $global:architecture" -ForegroundColor Green
        break
    }
}

if (-not $matchedArch -or [string]::IsNullOrWhiteSpace($global:architecture)) {
    $global:architecture = "amd64"
    Write-Host "[提示] 架构信息未能自动解析，默认回退安全值: amd64" -ForegroundColor Yellow
}

# ----------------- 2. 移除预装 AppX (Bloatware) -----------------
Write-Host "`n正在扫描并移除预装臃肿 AppX 应用包..." -ForegroundColor Cyan

# 精确匹配待移除应用清单
$targetAppxPatterns = @(
    '*Zune*',
    '*Bing*',
    '*Clipchamp*',
    '*Gaming*',
    '*People*',
    '*PowerAutomate*',
    '*Teams*',
    '*Todos*',
    '*YourPhone*',
    '*SoundRecorder*',
    '*Solitaire*',
    '*FeedbackHub*',
    '*Maps*',
    '*OfficeHub*',
    '*Help*',
    '*Family*',
    '*Alarms*',
    '*CommunicationsApps*',
    '*Copilot*',
    '*CompatibilityEnhancements*',
    '*AV1VideoExtension*',
    '*AVCEncoderVideoExtension*',
    '*HEIFImageExtension*',
    '*HEVCVideoExtension*',
    '*MicrosoftStickyNotes*',
    '*OutlookForWindows*',
    '*RawImageExtension*',
    '*SecHealthUI*',
    '*VP9VideoExtensions*',
    '*WebpImageExtension*',
    '*DevHome*',
    '*Photos*',
    '*Camera*',
    '*QuickAssist*',
    '*CoreAI*',
    '*PeopleExperienceHost*',
    '*PinningConfirmationDialog*',
    '*SecureAssessmentBrowser*',
    '*Paint*',
    '*Notepad*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$packagesToRemove = @()

if ($provisionedPackages) {
    foreach ($pkg in $provisionedPackages) {
        foreach ($pattern in $targetAppxPatterns) {
            if ($pkg.PackageName -like $pattern) {
                $packagesToRemove += $pkg
                break
            }
        }
    }
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]

foreach ($package in $packagesToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName) [$($package.PackageName)]" -ForegroundColor DarkGray
    $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction SilentlyContinue
    $removedPackageNames.Add($package.PackageName)
}

# 深度清理 WindowsApps 物理残留目录（夺权并硬核粉碎）
Write-Host "正在扫描并清理 Program Files\WindowsApps 中的残留资产..." -ForegroundColor DarkGray
$windowsAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"

if (Test-Path -LiteralPath $windowsAppsDir) {
    foreach ($pkgName in $removedPackageNames) {
        $candidateFolder = Join-Path $windowsAppsDir $pkgName
        if (Test-Path -LiteralPath $candidateFolder) {
            Write-Host "   粉碎残留资产目录: $pkgName" -ForegroundColor DarkGray
            & takeown.exe /F "$candidateFolder" /A /R /D Y 2>$null | Out-Null
            & icacls.exe "$candidateFolder" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$candidateFolder\*" /S /D 2>$null
            Remove-Item -LiteralPath $candidateFolder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $candidateFolder) {
                cmd.exe /c "rd /s /q `"$candidateFolder`"" 2>$null
            }
        }
    }
}

# 释放内存引用
$packagesToRemove = $null
$provisionedPackages = $null

# ----------------- 3. 移除系统底层功能包 Packages -----------------
Write-Host "`n系统应用精炼完毕，正在执行系统底层按需功能包 (FOD) 精简..." -ForegroundColor Cyan

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

# 动态扩展：非当前语言的冗余输入/语音语言包
if ($global:languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Speech-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-TextToSpeech-$($global:languageCode)-Package~"
}

# 抓取当前系统所有功能包列表
$rawPackageOutput = & dism.exe /English "/Image:$scratchDir" /Get-Packages /Format:Table
$packageLines = ($rawPackageOutput -split '\r?\n') | Select-Object -Skip 1

foreach ($pattern in $packagePatterns) {
    $matchedLines = $packageLines | Where-Object { $_ -like "$pattern*" }
    foreach ($mLine in $matchedLines) {
        $packageIdentity = ($mLine -split '\s+')[0]
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -ne "Package" -and $packageIdentity -notmatch "^-+$") {
            Write-Host "   正在移除底层功能包: $packageIdentity..." -ForegroundColor DarkGray
            & dism.exe /English "/Image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>$null | Out-Null
        }
    }
}

Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green
