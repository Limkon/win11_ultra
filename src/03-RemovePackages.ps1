# ==============================================================================
#  win11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
#  重构要点：
#   1. 普通精简模式（trimMode != 2）：仅通过官方接口移除 Appx
#      (Remove-AppxProvisionedPackage) 与 FOD (Dism /Remove-Package)，
#      不再物理删除 SystemApps 目录、不再物理粉碎 WindowsApps 残留。
#   2. 极限压榨模式（trimMode == 2）：保留原有物理粉碎 SystemApps /
#      WindowsApps 残留逻辑。
#   3. Edge/Cortana 的 Appx 匹配、PackageFamilyName 解析、框架白名单、
#      关键组件校验全部保留。
#   4. [新增] 架构探测修复：文件夹模式（sourceMode == "3"）或 install.wim
#      不存在时，改为从 $scratchDir\Windows\System32\ntoskrnl.exe 的 PE 头
#      Machine 字段读取架构，避免 arm64 母盘被误判为 amd64。
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 1. 语言探针（DISM 离线操作，对文件夹模式有效） -----------------
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

# ----------------- 1.1 架构探针（文件夹模式修复） -----------------
# 优先顺序：
#   a) 非文件夹模式且 install.wim 存在 → DISM Get-WimInfo（原逻辑）
#   b) 文件夹模式 / install.wim 不存在 → ntoskrnl.exe PE 头 Machine 字段
#   c) 进程环境变量兜底 → amd64
function Get-ArchitectureFromPe {
    param([string]$ExePath)
    try {
        if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
        $fs = [System.IO.File]::Open($ExePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt 0x40) { return $null }
            $buffer = New-Object byte[] 0x400
            $read = $fs.Read($buffer, 0, $buffer.Length)
            if ($read -lt 0x40) { return $null }
            # 检查 MZ 签名
            if ($buffer[0] -ne 0x4D -or $buffer[1] -ne 0x5A) { return $null }
            # e_lfanew at 0x3C
            $e_lfanew = [BitConverter]::ToInt32($buffer, 0x3C)
            if ($e_lfanew -lt 0 -or $e_lfanew -gt ($read - 6)) { return $null }
            # 检查 PE\0\0 签名
            if ($buffer[$e_lfanew] -ne 0x50 -or $buffer[$e_lfanew + 1] -ne 0x45 -or
                $buffer[$e_lfanew + 2] -ne 0x00 -or $buffer[$e_lfanew + 3] -ne 0x00) { return $null }
            # Machine at e_lfanew + 4 (2 bytes LE)
            $machine = [BitConverter]::ToUInt16($buffer, $e_lfanew + 4)
            switch ($machine) {
                0x8664 { return 'amd64' }
                0xAA64 { return 'arm64' }
                0x014C { return 'x86'   }
                0x0200 { return 'ia64'  }
                default { return $null }
            }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

$matchedArch = $false
$global:architecture = $null

# a) 优先尝试 install.wim
$destWimPath = Join-Path $sourcesDir "install.wim"
if (Test-Path -LiteralPath $destWimPath) {
    $imageInfo = & dism.exe /English /Get-WimInfo "/wimFile:$destWimPath" "/index:1"
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
}

# b) install.wim 不存在或解析失败 → 从 ntoskrnl.exe PE 头读取
if (-not $matchedArch) {
    $ntoskrnlPath = Join-Path $scratchDir "Windows\System32\ntoskrnl.exe"
    $peArch = Get-ArchitectureFromPe -ExePath $ntoskrnlPath
    if ($peArch) {
        $global:architecture = $peArch
        $matchedArch = $true
        Write-Host "   [架构探针] 通过 ntoskrnl.exe PE 头识别架构: $peArch" -ForegroundColor DarkGray
    }
}

# c) 最终兜底
if (-not $matchedArch -or [string]::IsNullOrWhiteSpace($global:architecture)) {
    $envArch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE.ToLower() } else { "" }
    if ($envArch -eq 'arm64') { $global:architecture = 'arm64' }
    elseif ($envArch -eq 'x86') { $global:architecture = 'x86' }
    else { $global:architecture = 'amd64' }
    Write-Host "   [架构探针] 回退使用环境变量/默认值: $($global:architecture)" -ForegroundColor DarkYellow
}

# ----------------- 2. 移除预装 AppX (Bloatware + Edge + Cortana) -----------------
$targetAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*',
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*',
    '*SoundRecorder*', '*Solitaire*', '*FeedbackHub*', '*Maps*',
    '*OfficeHub*', '*Help*', '*Family*', '*Alarms*', '*Camera*',
    '*QuickAssist*', '*PeopleExperienceHost*', '*PinningConfirmationDialog*',
    '*SecureAssessmentBrowser*', '*CommunicationsApps*', '*Copilot*',
    '*AV1VideoExtension*', '*HEIFImageExtension*', '*HEVCVideoExtension*',
    '*WebpImageExtension*', '*Cortana*',
    '*MicrosoftEdge.Stable*', '*MicrosoftEdge*', '*Microsoft.MicrosoftEdge*',
    '*549981C3F5F10*'
)

# 框架组件保护白名单
$protectedFrameworkPatterns = @(
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.WindowsAppRuntime*',
    '*Microsoft.NET.Native*', '*Microsoft.Services.Store*'
)

# 普通精简模式额外安装依赖保护
$installDependencyPatterns = @(
    '*OneSettings*', '*UniversalTelemetryClient*', '*CrossDevice*',
    '*Client.WebExperience*', '*Windows.ShellExperience*',
    '*Windows.CloudExperienceHost*', '*UEV*', '*WindowsFeedbackHub*'
)

$provisionedPackages = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue
$appxToRemove = @()
$appxToKeep = @()

foreach ($pkg in $provisionedPackages) {
    $isProtected = $false
    foreach ($prot in $protectedFrameworkPatterns) {
        if ($pkg.PackageName -like $prot) { $isProtected = $true; break }
    }
    if ($isProtected) { $appxToKeep += $pkg; continue }

    if ($global:trimMode -ne "2") {
        $isInstallDep = $false
        foreach ($dep in $installDependencyPatterns) {
            if ($pkg.PackageName -like $dep) { $isInstallDep = $true; break }
        }
        if ($isInstallDep) { $appxToKeep += $pkg; continue }
    }

    foreach ($pattern in $targetAppxPatterns) {
        if ($pkg.PackageName -like $pattern) { $appxToRemove += $pkg; break }
    }
}

Write-Host "   [框架保护] 已自动拦截保留 $($appxToKeep.Count) 个核心依赖框架/安装依赖组件。" -ForegroundColor DarkGray
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
    'Microsoft.MicrosoftEdge.Stable'      = @('msedge.exe', 'MicrosoftEdge.exe')
    'Microsoft.MicrosoftEdge'             = @('MicrosoftEdge.exe')
    'Microsoft.549981C3F5F10'             = @('Cortana.exe')
}

$removedPackageNames = New-Object System.Collections.Generic.List[string]
$global:removedAppxExeNames = New-Object System.Collections.Generic.List[string]
$global:deprovisionedAppxFamilies = New-Object System.Collections.Generic.List[string]

foreach ($package in $appxToRemove) {
    Write-Host "   正在移除应用: $($package.DisplayName)" -ForegroundColor DarkGray
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
    } catch {
        Write-Host "   [警告] 该包受系统保护或已被占用，跳过: $($package.PackageName)" -ForegroundColor DarkYellow
    }
    $removedPackageNames.Add($package.PackageName)

    $familyName = $null
    $pkgParts = $package.PackageName -split '_'
    if ($pkgParts.Count -ge 2) {
        $firstPart = $pkgParts[0]
        $lastPart = $pkgParts[-1]
        if ($lastPart -match '^[a-z0-9]{13}$') {
            $familyName = "$($firstPart)_$($lastPart)"
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

# ----------------- 2.1 WindowsApps 物理残留清理（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
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
} else {
    Write-Host "   [普通精简] 跳过 WindowsApps 物理残留粉碎，保留官方组件注册一致性。" -ForegroundColor DarkGray
}

# ----------------- 3. SystemApps 物理粉碎（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
    $sysAppsPath = Join-Path $scratchDir "Windows\SystemApps"
    if (Test-Path -LiteralPath $sysAppsPath) {
        $sysAppsToDelete = @("*Cortana*", "*Edge*", "*PeopleExperienceHost*", "*SecureAssessmentBrowser*", "*549981C3F5F10*")
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
} else {
    Write-Host "   [普通精简] 跳过 SystemApps 物理粉碎，仅依赖 Appx 官方移除与 Deprovisioned 标记。" -ForegroundColor DarkGray
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

# ----------------- 4. 移除系统底层功能包 Packages (FOD，官方 Remove-Package) -----------------
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
