# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
# ==============================================================================

# ----------------- 1. UWP 卸载 + 物理强删 (两模式均执行) -----------------
Write-Host "`n[步骤 4/11] 正在清理冗余 UWP 预装应用 (严格保留 OOBE 与系统代理依赖)..." -ForegroundColor Cyan

# 核心基础白名单（绝不能删除的底层基础框架）
$preservedPackages = @(
    "*VCLibs*",
    "*UI.Xaml*",
    "*NET.Native*",
    "*Client.CBS*",
    "*ShellExperience*",
    "*AccountsControl*",
    "*CloudExperienceHost*",
    "*BioEnrollment*"
)

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$totalAppx = $appxPackages.Count
$currentAppx = 0

foreach ($app in $appxPackages) {
    $currentAppx++
    $shouldKeep = $false
    foreach ($pattern in $preservedPackages) {
        if ($app.PackageName -like $pattern -or $app.DisplayName -like $pattern) {
            $shouldKeep = $true
            break
        }
    }

    $pct = [math]::Round(($currentAppx / [math]::Max(1, $totalAppx)) * 100)
    Write-Progress -Activity "正在清理 UWP 预装应用" -Status "[$currentAppx/$totalAppx] 正在处理: $($app.DisplayName)" -PercentComplete $pct

    if ($shouldKeep) {
        Write-Host "   [$currentAppx/$totalAppx] [保留核心] $($app.DisplayName)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "   [$currentAppx/$totalAppx] [删除应用] $($app.PackageName)" -ForegroundColor Yellow
    & dism.exe /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
}
Write-Progress -Activity "正在清理 UWP 预装应用" -Completed

# 物理强删 WindowsApps 目录下的实体文件（严禁破坏父目录 SDDL，精准粉碎子目录）
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
if (Test-Path $winAppsDir) {
    Write-Host "   正在安全物理强删 WindowsApps 废弃应用实体 (极限压榨空间，保留核心框架)..." -ForegroundColor DarkGray

    $protectedJunctions = @("Deleted", "Merged", "Mutable", "MutableBackup", "Projected", "Packages")

    Get-ChildItem -Path $winAppsDir -Directory | Where-Object { 
        $dirName = $_.Name
        if ($protectedJunctions -contains $dirName) { return $false }

        $isPreserved = $false
        foreach ($pattern in $preservedPackages) {
            if ($dirName -like $pattern) {
                $isPreserved = $true
                break
            }
        }
        -not $isPreserved
    } | ForEach-Object {
        # 仅针对具体的废弃子文件夹执行夺权和物理粉碎，不动父目录的根安全描述符
        Force-NukeFolderOrFile $_.FullName
    }

    # 关键安全修复：向父目录恢复通用应用包只读权限，防止沙箱进程读取 CBS/XAML 框架时报拒绝访问
    & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
}
Write-Host "[完成] UWP 应用清理与实体强删完毕。" -ForegroundColor Green

# ----------------- 2. 功能包清理 (保留中文 + 保护 Hans 字体) -----------------
Write-Host "`n[步骤 5/11] 正在检索系统组件包并执行【仅保留中文】深度剔除..." -ForegroundColor Cyan

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split "`n" | Select-Object -Skip 1

# 基础需要剥离的无用功能包列表 (严格排除 IE 可选包，防止 DISM 连坐注销 Shell COM 接口)
$basePackagesToRemove = @(
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

# 筛选需剔除的目标列表
$targetPkgs = @()
foreach ($line in $pkgLines) {
    $pkgId = ($line -split "\s+")[0]
    if (-not $pkgId -or $pkgId -eq "Package" -or $pkgId -match "^-+$") { continue }

    $shouldDelete = $false
    foreach ($bp in $basePackagesToRemove) {
        if ($pkgId -like "$bp*") {
            $shouldDelete = $true
            break
        }
    }

    # 外语包判定（保留 zh-CN、zh-cn、Hans，其余语系全剔除）
    if (-not $shouldDelete) {
        $isLangRelated = ($pkgId -match "LanguageFeatures" -or $pkgId -match "LanguagePack" -or $pkgId -match "TextToSpeech" -or $pkgId -match "Speech-" -or $pkgId -match "Handwriting-" -or $pkgId -match "OCR-")
        if ($isLangRelated -and ($pkgId -notmatch "zh-CN|zh-cn|Hans")) {
            $shouldDelete = $true
        }
    }

    # 剔除日文、韩文、繁体中文输入法包
    if (-not $shouldDelete -and ($pkgId -match "IME-ja-jp" -or $pkgId -match "IME-ko-kr" -or $pkgId -match "IME-zh-tw")) {
        $shouldDelete = $true
    }

    if ($shouldDelete) { $targetPkgs += $pkgId }
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
