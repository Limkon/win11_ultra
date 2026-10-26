# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 1. 语言与硬件架构深度探针 -----------------
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
Write-Host "`n[2.1] 正在动态扫描并移除预装臃肿 AppX 应用包..." -ForegroundColor Cyan

# 注意：*Notepad* 和 *Photos* 不在此列表中，确保不被移除
$targetAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*', 
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*', 
    '*SoundRecorder*', '*Solitaire*', '*FeedbackHub*', '*Maps*', 
    '*OfficeHub*', '*Help*', '*Family*', '*Alarms*', '*Camera*', 
    '*QuickAssist*', '*PeopleExperienceHost*', 
    '*PinningConfirmationDialog*', '*SecureAssessmentBrowser*',
    '*CommunicationsApps*', '*Copilot*', '*AV1VideoExtension*',
    '*HEIFImageExtension*', '*HEVCVideoExtension*', '*WebpImageExtension*'
)

# 框架组件保护白名单
$protectedFrameworkPatterns = @(
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.WindowsAppRuntime*',
    '*Microsoft.NET.Native*', '*Microsoft.Services.Store*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$appxToRemove = @()
$appxToKeep = @()

foreach ($pkg in $provisionedPackages) {
    $isProtected = $false
    foreach ($prot in $protectedFrameworkPatterns) {
        if ($pkg.PackageName -like $prot) { $isProtected = $true; break }
    }
    if ($isProtected) {
        $appxToKeep += $pkg
        continue
    }

    foreach ($pattern in $targetAppxPatterns) {
        if ($pkg.PackageName -like $pattern) {
            $appxToRemove += $pkg
            break
        }
    }
}

Write-Host "   [框架保护] 已自动拦截保留 $($appxToKeep.Count) 个核心依赖框架。" -ForegroundColor DarkGray
Write-Host "   [准备移除] 检测到 $($appxToRemove.Count) 个预装应用符合精简规则。" -ForegroundColor Yellow

$appxExeMap = @{
    'Microsoft.Windows.Photos'            = @('Photos.exe', 'Microsoft.Photos.exe')
    'Microsoft.ScreenSketch'              = @('SnippingTool.exe', 'ScreenSketch.exe')
    'Microsoft.People'                    = @('People.exe')
    'Microsoft.WindowsMaps'               = @('Maps.exe')
    'Microsoft.MicrosoftStickyNotes'      = @('Microsoft.MicrosoftStickyNotes.exe')
    'Microsoft.WindowsAlarms'             = @('WindowsAlarms.exe')
    'Microsoft.WindowsSoundRecorder'      = @('WindowsSoundRecorder.exe')
    'Microsoft.ZuneMusic'                 = @('Microsoft.ZuneMusic.exe')
    'Microsoft.ZuneVideo'                 = @('Microsoft.ZuneVideo.exe')
    'Microsoft.BingNews'                  = @('Microsoft.BingNews.exe')
    'Microsoft.BingWeather'               = @('Microsoft.BingWeather.exe')
    'Microsoft.WindowsCamera'             = @('WindowsCamera.exe')
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]
$global:removedAppxExeNames = New-Object System.Collections.Generic.List[string]

foreach ($package in $appxToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName)" -ForegroundColor DarkGray
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
    } catch {
        Write-Host "   [警告] 该包受系统保护或已被占用，跳过: $($package.PackageName)" -ForegroundColor DarkYellow
    }
    $removedPackageNames.Add($package.PackageName)

    foreach ($mapKey in $appxExeMap.Keys) {
        if ($package.PackageName -like "*$mapKey*") {
            foreach ($exeName in $appxExeMap[$mapKey]) {
                if (-not $global:removedAppxExeNames.Contains($exeName)) {
                    $global:removedAppxExeNames.Add($exeName)
                }
            }
            break
        }
    }
}

# 深度清理 WindowsApps 物理残留目录
$windowsAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path -LiteralPath $windowsAppsDir) {
    foreach ($pkgName in $removedPackageNames) {
        $candidateFolder = Join-Path $windowsAppsDir $pkgName
        if (Test-Path -LiteralPath $candidateFolder) {
            Write-Host "   粉碎残留资产目录: $pkgName" -ForegroundColor DarkGray
            & takeown.exe /F "$candidateFolder" /A /R /D Y 2>&1 | Out-Null
            & icacls.exe "$candidateFolder" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $candidateFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----------------- 3. 移除系统底层功能包 Packages (FOD) -----------------
Write-Host "`n[2.2] 正在动态扫描系统底层按需功能包 (FOD)..." -ForegroundColor Cyan

# 注意：不包含 WordPad，但也绝不包含任何与记事本有关的 FOD 条目
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~",
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "OpenSSH-Client-Package~",
    "*IME-ja-jp*", "*IME-ko-kr*", "*IME-zh-tw*",
    "Windows-Defender-Client-Package~",
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

if ($global:languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
}

$rawPackageOutput = & dism.exe /English "/Image:$scratchDir" /Get-Packages /Format:Table
$packageLines = ($rawPackageOutput -split '\r?\n') | Select-Object -Skip 1
$fodRemovedCount = 0

foreach ($pattern in $packagePatterns) {
    $matchedLines = $packageLines | Where-Object { $_ -like "$pattern*" }
    foreach ($mLine in $matchedLines) {
        $packageIdentity = ($mLine -split '\s+')[0]
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -ne "Package" -and $packageIdentity -notmatch "^-+$") {
            Write-Host "   正在移除 FOD: $packageIdentity" -ForegroundColor DarkGray
            & dism.exe /English "/Image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>&1 | Out-Null
            $fodRemovedCount++
        }
    }
}
Write-Host "   [执行完毕] 共清理 $fodRemovedCount 个底层功能包。" -ForegroundColor Yellow

Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green
