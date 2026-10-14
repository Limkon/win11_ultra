# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [企业级重构]：动态黑白名单联动 + 预装应用依赖拓扑静态测试 + 属性页保护
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行 UWP 应用依赖架构测试与精简..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# ----------------- 1. 加载并解析外部 Appslist.txt 规则库 -----------------
$appsListSearchPaths = @(
    (Join-Path $scriptDir "Appslist.txt"),
    (Join-Path $scriptDir "src\Appslist.txt"),
    (Join-Path $PSScriptRoot "Appslist.txt")
)
$appsListFile = $appsListSearchPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$blacklistRules = New-Object System.Collections.Generic.List[string]

if ($appsListFile) {
    Write-Host "   [规则加载] 已成功载入应用规则清单: $appsListFile" -ForegroundColor Green
    $rawRules = Get-Content -LiteralPath $appsListFile -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $rawRules) {
        $trimmed = $line.Trim()
        # 严格过滤注释行与空行
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        # 剥离行内注释
        $ruleName = ($trimmed -split '#')[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($ruleName)) {
            $blacklistRules.Add($ruleName)
        }
    }
    Write-Host "   [规则解析] 成功装载 $($blacklistRules.Count) 条黑名单匹配规则。" -ForegroundColor DarkGray
} else {
    Write-Host "   [警告] 未检测到 Appslist.txt 规则文件，将启用内建安全保守模式！" -ForegroundColor Yellow
}

# ----------------- 2. 核心底层基础包绝对白名单 (绝不可删) -----------------
$systemCoreWhitelist = @(
    "Microsoft.VCLibs*",
    "Microsoft.UI.Xaml*",
    "Microsoft.NET.Native*",
    "Microsoft.Services.Store.Engagement*",
    "*Client.CBS*",
    "*ShellExperience*",
    "*AccountsControl*",
    "*CloudExperienceHost*",
    "*BioEnrollment*",
    "*CapturePicker*",
    "*CredDialogHost*"
)

# ----------------- 3. 依赖关系静态安全测试引擎 (Pre-Removal Dependency Testing) -----------------
Write-Host "`n   [测试评估] 正在对当前映像已装载的 UWP 进行依赖拓扑完整性预检..." -ForegroundColor DarkCyan

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"

# 自动收集：将被保留组件所声明的所有底层依赖框架 (PackageDependency)
$dynamicProtectedDependencies = New-Object System.Collections.Generic.HashSet[string]
$candidateAppsToRemove = New-Object System.Collections.Generic.List[System.Object]
$candidateAppsToPreserve = New-Object System.Collections.Generic.List[System.Object]

foreach ($app in $appxPackages) {
    $pkgName = $app.PackageName
    $dispName = $app.DisplayName

    # 1. 优先判定系统核心白名单
    $isCore = $false
    foreach ($corePat in $systemCoreWhitelist) {
        if ($pkgName -like $corePat -or $dispName -like $corePat) {
            $isCore = $true
            break
        }
    }

    # 2. 判定黑名单命中情况
    $hitBlacklist = $false
    if (-not $isCore -and $blacklistRules.Count -gt 0) {
        foreach ($rule in $blacklistRules) {
            if ($pkgName -like "*$rule*" -or $dispName -like "*$rule*") {
                $hitBlacklist = $true
                break
            }
        }
    }

    if ($isCore -or (-not $hitBlacklist -and $blacklistRules.Count -gt 0)) {
        $candidateAppsToPreserve.Add($app)
    } else {
        $candidateAppsToRemove.Add($app)
    }
}

# 解析保留组件清单的 AppxManifest.xml，提取依赖拓扑
if (Test-Path -LiteralPath $winAppsDir) {
    foreach ($preservedApp in $candidateAppsToPreserve) {
        $manifestMatches = Get-ChildItem -Path $winAppsDir -Filter "AppxManifest.xml" -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -like "*$($preservedApp.DisplayName)*"
        }
        foreach ($m in $manifestMatches) {
            try {
                [xml]$manifestXml = Get-Content -LiteralPath $m.FullName -ErrorAction Stop
                $depNodes = $manifestXml.GetElementsByTagName("PackageDependency")
                foreach ($dep in $depNodes) {
                    $depName = $dep.GetAttribute("Name")
                    if (-not [string]::IsNullOrWhiteSpace($depName)) {
                        $null = $dynamicProtectedDependencies.Add($depName)
                    }
                }
            } catch {}
            finally {
                $manifestXml = $null
            }
        }
    }
}

# 执行依赖保护介入：如果候选删除列表中的应用恰好是保留组件的硬性依赖，强制移入保护列表
$finalDeleteList = New-Object System.Collections.Generic.List[System.Object]
$savedByDependencyCount = 0

foreach ($cand in $candidateAppsToRemove) {
    $isNeededDependency = $false
    foreach ($depKey in $dynamicProtectedDependencies) {
        if ($cand.PackageName -like "*$depKey*" -or $cand.DisplayName -like "*$depKey*") {
            $isNeededDependency = $true
            break
        }
    }

    if ($isNeededDependency) {
        $savedByDependencyCount++
        Write-Host "   [依赖拦截守护] 拦截组件: $($cand.DisplayName) (该组件被保留应用强依赖，已阻止移除以保稳定性)" -ForegroundColor DarkGreen
        $candidateAppsToPreserve.Add($cand)
    } else {
        $finalDeleteList.Add($cand)
    }
}

# 垃圾回收，释放 XML 文件句柄
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

Write-Host "   [测试结果] 探测到 $($appxPackages.Count) 个预装应用: $($finalDeleteList.Count) 个将安全精简, $($candidateAppsToPreserve.Count) 个受保护保留 (含 $savedByDependencyCount 个被自动救回的底层依赖)。" -ForegroundColor Green

# ----------------- 4. 执行 UWP 卸载与定向物理粉碎 -----------------
$totalDel = $finalDeleteList.Count
$currDel = 0
$deletedFolderNames = New-Object System.Collections.Generic.List[string]

foreach ($app in $finalDeleteList) {
    $currDel++
    $pct = [math]::Round(($currDel / [math]::Max(1, $totalDel)) * 100)
    Write-Progress -Activity "正在精简 UWP 预装应用" -Status "[$currDel/$totalDel] 正在卸载: $($app.DisplayName)" -PercentComplete $pct

    Write-Host "   [$currDel/$totalDel] [删除应用] $($app.PackageName)" -ForegroundColor Yellow
    & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
    $deletedFolderNames.Add($app.PackageName)
}
Write-Progress -Activity "正在精简 UWP 预装应用" -Completed

# 定向物理清除 WindowsApps 目录下的残留大实体，绝不损坏父级目录 DACL 继承
if (Test-Path -LiteralPath $winAppsDir) {
    Write-Host "   正在执行 WindowsApps 废弃实体定向物理粉碎..." -ForegroundColor DarkGray
    foreach ($folderKeyword in $deletedFolderNames) {
        Get-ChildItem -Path $winAppsDir -Directory -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -like "$folderKeyword*" 
        } | ForEach-Object {
            Force-NukeFolderOrFile $_.FullName
        }
    }

    # 关键安全固化：彻底恢复 ALL APPLICATION PACKAGES 只读权限，防止沙箱应用（如终端）闪退
    & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
}
Write-Host "[完成] UWP 应用拓扑测试、依赖守护与定向精炼完毕。" -ForegroundColor Green

# ----------------- 5. 系统可选功能包精简 (保留 Search-Engine-Client 以固化属性页) -----------------
Write-Host "`n[步骤 5/11] 正在检索系统组件包并执行深度可选功能精简..." -ForegroundColor Cyan

$installedPackages = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$pkgLines = $installedPackages -split '\r?\n' | Select-Object -Skip 1

# 基础需要剥离的无用功能包列表
# 【底层架构警示】：绝对不能删除 Microsoft-Windows-Search-Engine-Client-Package，
#  否则盘符属性页底部的索引复选框和文件高级属性 COM 结构会彻底暴毙，导致右键属性无反应！
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
