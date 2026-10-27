# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
#  重构要点：
#   1. 动态收集被移除 AppX 的 PackageFamilyName，写入全局供 06 模块落盘
#      Deprovisioned 标记，阻止 Windows 在 OOBE/功能更新时重新预配。
#   2. 保留原有语言/架构探针、框架白名单、物理粉碎、SystemApps 清理、
#      关键组件校验、FOD 移除全部逻辑。
#   3. PackageFamilyName 解析失败时仅警告，不中断流程。
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 1. 语言与硬件架构深度探针 -----------------
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$matchedLang = $false
foreach ($line in ($imageIntl -split '\r?\n')) {
    if ($line -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
        $global:languageCode = $Matches[1].Trim()
        $matchedLang = $true
        break
    }
}
if (-not $matchedLang) { $global:languageCode = "zh-CN" }

$destWimPath = Join-Path $sourcesDir "install.wim"
$imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
$matchedArch = $false
foreach ($line in ($imageInfo -split '\r?\n')) {
    if ($line -match 'Architecture\s*:\s*(.+)$') {
        $rawArch = $Matches[1].Trim().ToLower()
        if ($rawArch -eq 'x64' -or $rawArch -eq 'amd64') { $global:architecture = 'amd64' }
        elseif ($rawArch -eq 'arm64') { $global:architecture = 'arm64' }
        elseif ($rawArch -eq 'x86') { $global:architecture = 'x86' }
        else { $global:architecture = $rawArch }
        $matchedArch = $true
        break
    }
}
if (-not $matchedArch) { $global:architecture = "amd64" }

# ----------------- 2. 移除预装 AppX (Bloatware) -----------------
# 注意：保留 *Paint* 和 *Notepad*；相机保留在精简列表中（按之前逻辑）。
$targetAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*', 
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*', 
    '*SoundRecorder*', '*Solitaire*', '*FeedbackHub*', '*Maps*', 
    '*OfficeHub*', '*Help*', '*Family*', '*Alarms*', '*Camera*', 
    '*QuickAssist*', '*PeopleExperienceHost*', '*PinningConfirmationDialog*', 
    '*SecureAssessmentBrowser*', '*CommunicationsApps*', '*Copilot*', 
    '*AV1VideoExtension*', '*HEIFImageExtension*', '*HEVCVideoExtension*', 
    '*WebpImageExtension*', '*Cortana*'
)

# 框架组件保护白名单：任何通配符都不得误伤这些包
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

# AppX 包名 -> HKCR\Applications 下对应 exe 名的映射 (用于后续 06 模块修复关联)
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
# 新增：收集被移除预装应用的 PackageFamilyName，供 06 模块写入 Deprovisioned
$global:deprovisionedAppxFamilies = New-Object System.Collections.Generic.List[string]

foreach ($package in $appxToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName)" -ForegroundColor DarkGray
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
    } catch {
        Write-Host "   [警告] 该包受系统保护或已被占用，跳过: $($package.PackageName)" -ForegroundColor DarkYellow
    }
    $removedPackageNames.Add($package.PackageName)

    # 解析 PackageFamilyName：预配包名可能是 FamilyName 本身，也可能是完整 PackageFullName
    # FamilyName 形如 Name_PublisherId（PublisherId 为 13 位小写字母数字）
    $familyName = $null
    if ($package.PackageName -match '^([^_]+_[a-z0-9]{13})$') {
        $familyName = $Matches[1]
    } elseif ($package.PackageName -match '^([^_]+_[^_]+_[^_]+_[^_]+_[a-z0-9]{13})$') {
        # 完整包名 Name_Version_Arch_Resource_PublisherId，取首尾拼成 FamilyName
        $parts = $package.PackageName -split '_'
        if ($parts.Count -ge 5) {
            $familyName = "$($parts[0])_$($parts[-1])"
        }
    }

    if ($familyName -and -not $global:deprovisionedAppxFamilies.Contains($familyName)) {
        $global:deprovisionedAppxFamilies.Add($familyName)
    } elseif (-not $familyName) {
        Write-Host "   [提示] 无法解析 PackageFamilyName，跳过 Deprovisioned 标记: $($package.PackageName)" -ForegroundColor DarkGray
    }

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

Write-Host "   [Deprovision] 已收集 $($global:deprovisionedAppxFamilies.Count) 个包家族名，将在注册表阶段写入防重装标记。" -ForegroundColor DarkGray

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

# ----------------- 3. 暴力物理粉碎系统级残留 (断根 Edge/Cortana) -----------------
$sysAppsPath = Join-Path $scratchDir "Windows\SystemApps"
if (Test-Path -LiteralPath $sysAppsPath) {
    $sysAppsToDelete = @("*Cortana*", "*Edge*", "*PeopleExperienceHost*", "*SecureAssessmentBrowser*")
    foreach ($pattern in $sysAppsToDelete) {
        $items = Get-ChildItem -Path $sysAppsPath -Filter $pattern -Directory -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            Write-Host "   删除 SystemApps 目录: $($item.Name)" -ForegroundColor DarkGray
            & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
            & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 关键组件完整性校验
$openWithExe = Join-Path $scratchDir "Windows\System32\OpenWith.exe"
$shell32Dll  = Join-Path $scratchDir "Windows\System32\shell32.dll"
$shCoreDll   = Join-Path $scratchDir "Windows\System32\shcore.dll"
foreach ($critical in @($openWithExe, $shell32Dll, $shCoreDll)) {
    if (-not (Test-Path -LiteralPath $critical)) {
        Write-Host "[严重警告] 关键 Shell/OpenWith 组件缺失: $critical —— 精简过度！" -ForegroundColor Red
    }
}

# ----------------- 4. 移除系统底层功能包 Packages (FOD) -----------------
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
        if (-not [string]::IsNullOrWhiteSpace($packageIdentity) -and $packageIdentity -notmatch "^-+$" -and $packageIdentity -ne "Package") {
            Write-Host "   正在移除 FOD: $packageIdentity" -ForegroundColor DarkGray
            & dism.exe /English "/Image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" /NoRestart 2>&1 | Out-Null
            $fodRemovedCount++
        }
    }
}
Write-Host "   [执行完毕] 共清理 $fodRemovedCount 个底层功能包。" -ForegroundColor Yellow
Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green
