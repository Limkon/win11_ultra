# ==============================================================================
#  Windows 10/11 Builder - [模块 4/11] 预装应用与系统包精简 (src/03-RemovePackages.ps1)
#  [重构核心]：
#   1. 打印生态绝对保护：双模式下均不再移除 Printing-PMCPPC 打印管理包。
#   2. 普通模式 (健康精简)：
#      - 保留所有多媒体扩展解码器 (AV1, HEIF, HEVC, WebP)。
#      - 保留 Xbox 游戏服务架构与手柄联动组件。
#      - 保留 Windows Hello 生物识别 (人脸与指纹引导)。
#      - 保留 CJK (日韩繁) 输入法与基础 OCR 语言包。
#      - 保留 OpenSSH 客户端等开发调试组件。
#      - 仅通过官方 API 移除纯粹的无用推广及预装垃圾，不粉碎底层物理目录。
#   3. 极限模式 (极限压榨)：
#      - 保留原有激进粉碎逻辑与极窄组件库，但绝对豁免打印相关组件。
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在识别 Windows 版本、探查映像主语言并执行预装应用与功能包精简..." -ForegroundColor Cyan

# ----------------- 0. Windows 版本探针（不挂载离线注册表 hive） -----------------
function Get-OfflineWindowsRelease {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    # 从内核文件版本读取 build，避免为版本探测临时加载 SOFTWARE hive。
    # 某些释放映像/文件系统权限下 reg.exe load 会失败，即使映像本身可正常 DISM 服务。
    $kernelPath = Join-Path $ImagePath "Windows\System32\ntoskrnl.exe"
    if (-not (Test-Path -LiteralPath $kernelPath -PathType Leaf)) {
        throw "无法识别目标映像：缺少内核文件 ($kernelPath)。"
    }

    $kernelVersion = (Get-Item -LiteralPath $kernelPath -ErrorAction Stop).VersionInfo
    $build = [int]$kernelVersion.FileBuildPart
    if ($build -lt 10240) {
        $versionMatch = [regex]::Match([string]$kernelVersion.FileVersion, '^\d+\.\d+\.(\d+)')
        if ($versionMatch.Success) { $build = [int]$versionMatch.Groups[1].Value }
    }
    if ($build -lt 10240) {
        throw "无法从 ntoskrnl.exe 读取有效的 Windows build: $($kernelVersion.FileVersion)"
    }

    # DISM 的 Edition ID 可用于排除 Server，且无需直接加载目标注册表。
    $editionOutput = & dism.exe /English "/Image:$ImagePath" /Get-CurrentEdition 2>&1
    $editionExitCode = $LASTEXITCODE
    if ($editionExitCode -ne 0) {
        $detail = ($editionOutput | Out-String).Trim()
        throw "DISM 无法读取目标映像 Edition (退出码 $editionExitCode): $detail"
    }
    $editionText = ($editionOutput -join "`n")
    $editionMatch = [regex]::Match($editionText, '(?m)^\s*Current Edition\s*:\s*(.+?)\s*$')
    if (-not $editionMatch.Success) {
        throw "无法从 DISM 输出解析目标映像 Edition：$editionText"
    }
    $edition = $editionMatch.Groups[1].Value.Trim()
    if ($edition -match 'Server') {
        throw "检测到 Windows Server 映像 ($edition)；本工具仅支持 Windows 10/11 客户端映像。"
    }

    $family = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    return [pscustomobject]@{
        Family = $family
        Build = $build
        DisplayVersion = [string]$kernelVersion.ProductVersion
        ProductName = [string]$kernelVersion.ProductName
        EditionID = $edition
    }
}

$global:targetWindows = Get-OfflineWindowsRelease -ImagePath $scratchDir
$global:windowsFamily = $global:targetWindows.Family
$global:windowsBuild = $global:targetWindows.Build
$releaseLabel = if ($global:targetWindows.DisplayVersion) { "，版本 $($global:targetWindows.DisplayVersion)" } else { "" }
Write-Host "   [自动适配] 检测到 $($global:windowsFamily) build $($global:windowsBuild)$releaseLabel，Edition: $($global:targetWindows.EditionID)" -ForegroundColor Green

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

# ----------------- 1.1 架构探针（文件夹模式与通用自适应） -----------------
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
            if ($buffer[0] -ne 0x4D -or $buffer[1] -ne 0x5A) { return $null }
            $e_lfanew = [BitConverter]::ToInt32($buffer, 0x3C)
            if ($e_lfanew -lt 0 -or $e_lfanew -gt ($read - 6)) { return $null }
            if ($buffer[$e_lfanew] -ne 0x50 -or $buffer[$e_lfanew + 1] -ne 0x45 -or
                $buffer[$e_lfanew + 2] -ne 0x00 -or $buffer[$e_lfanew + 3] -ne 0x00) { return $null }
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

if (-not $matchedArch) {
    $ntoskrnlPath = Join-Path $scratchDir "Windows\System32\ntoskrnl.exe"
    $peArch = Get-ArchitectureFromPe -ExePath $ntoskrnlPath
    if ($peArch) {
        $global:architecture = $peArch
        $matchedArch = $true
        Write-Host "   [架构探针] 通过 ntoskrnl.exe PE 头识别架构: $peArch" -ForegroundColor DarkGray
    }
}

if (-not $matchedArch -or [string]::IsNullOrWhiteSpace($global:architecture)) {
    $envArch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE.ToLower() } else { "" }
    if ($envArch -eq 'arm64') { $global:architecture = 'arm64' }
    elseif ($envArch -eq 'x86') { $global:architecture = 'x86' }
    else { $global:architecture = 'amd64' }
    Write-Host "   [架构探针] 回退使用环境变量/默认值: $($global:architecture)" -ForegroundColor DarkYellow
}

# ----------------- 2. 区分模式构建预装 AppX 移除清单 -----------------
# 基础推广与无用流氓软件（双模式均移除）
$baseBloatAppxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*People*',
    '*PowerAutomate*', '*Teams*', '*Todos*', '*YourPhone*',
    '*Solitaire*', '*FeedbackHub*', '*Maps*',
    '*OfficeHub*', '*Help*', '*Family*',
    '*PeopleExperienceHost*', '*PinningConfirmationDialog*',
    '*SecureAssessmentBrowser*', '*CommunicationsApps*', '*Copilot*',
    '*Cortana*', '*MicrosoftEdge.Stable*', '*MicrosoftEdge*', '*Microsoft.MicrosoftEdge*',
    '*549981C3F5F10*'
)

if ($global:trimMode -eq "2") {
    # 极限压榨模式：额外移除游戏核心组件、现代多媒体扩展、系统录音机与相机
    $targetAppxPatterns = $baseBloatAppxPatterns + @(
        '*Gaming*',
        '*SoundRecorder*',
        '*Camera*',
        '*Alarms*',
        '*QuickAssist*',
        '*AV1VideoExtension*',
        '*HEIFImageExtension*',
        '*HEVCVideoExtension*',
        '*WebpImageExtension*'
    )
} else {
    # 普通健康模式：严格保护游戏架构、影音解码、相机、录音机、快速助手
    $targetAppxPatterns = $baseBloatAppxPatterns
}

# 核心依赖框架白名单（坚决不触碰）
$protectedFrameworkPatterns = @(
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.WindowsAppRuntime*',
    '*Microsoft.NET.Native*', '*Microsoft.Services.Store*'
)

# 系统安装依赖防护清单
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

Write-Host "   [框架保护] 已自动拦截保留 $($appxToKeep.Count) 个核心依赖框架/关键组件。" -ForegroundColor DarkGray
Write-Host "   [准备移除] 检测到 $($appxToRemove.Count) 个预装应用符合当前精简规则。" -ForegroundColor Yellow

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
    $removeSucceeded = $false
    try {
        $null = Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop
        $removeSucceeded = $true
    } catch {
        Write-Host "   [警告] 应用移除失败，跳过其残留清理和防重装标记: $($package.PackageName) ($_ )" -ForegroundColor DarkYellow
    }
    if (-not $removeSucceeded) { continue }
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
    Write-Host "   [普通健康模式] 跳过 WindowsApps 物理残留粉碎，保留组件注册表链一致性。" -ForegroundColor DarkGray
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
    Write-Host "   [普通健康模式] 跳过 SystemApps 物理粉碎，仅依赖 AppX 官方通道卸载。" -ForegroundColor DarkGray
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
# 注意：双模式均已剔除 "Microsoft-Windows-Printing-PMCPPC-FoD-Package~"，确保打印管理可用！
$baseFodPatterns = @(
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~"
)

if ($global:trimMode -eq "2") {
    # 极限压榨模式：额外清除 Defender 客户端、生化识别、辅助工具、远程调试
    $packagePatterns = $baseFodPatterns + @(
        "OpenSSH-Client-Package~",
        "*IME-ja-jp*", "*IME-ko-kr*", "*IME-zh-tw*",
        "Windows-Defender-Client-Package~",
        "Microsoft-Windows-Hello-Face-Package~",
        "Microsoft-Windows-Hello-BioEnrollment-Package~",
        "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
        "Microsoft-Windows-TPM-WMI-Provider-Package~",
        "Microsoft-Windows-Narrator-App-Package~",
        "Microsoft-Windows-Magnifier-App-Package~",
        "Microsoft-Windows-WebcamExperience-Package~",
        "Microsoft-Media-MPEG2-Decoder-Package~"
    )

    if ($global:languageCode -ne "zh-CN") {
        $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$($global:languageCode)-Package~"
        $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$($global:languageCode)-Package~"
    }
} else {
    # 普通健康模式：完整保留 Hello人脸/指纹、OpenSSH、日韩繁输入法、MPEG2解码等基础功能
    $packagePatterns = $baseFodPatterns
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
            if ($LASTEXITCODE -eq 0) {
                $fodRemovedCount++
            } else {
                Write-Host "   [警告] FOD 移除失败 (DISM $LASTEXITCODE): $packageIdentity" -ForegroundColor DarkYellow
            }
        }
    }
}
Write-Host "   [执行完毕] 共清理 $fodRemovedCount 个底层功能包。" -ForegroundColor Yellow
Write-Host "[完成] 应用与系统组件包移除完毕。" -ForegroundColor Green
