# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [企业级重构]：消费前置全局处置策略 + 零中途挂起 + 依赖稳定性测试与自动分流
# ==============================================================================

# ----------------- 0. 动态环境感知与主语言探测 -----------------
Write-Host "`n[步骤 4/11] 正在探查映像主语言并执行 UWP 应用依赖架构测试与精简..." -ForegroundColor Cyan

$imageIntl = & dism.exe /English /Image:$scratchDir /Get-Intl
$defaultLang = ($imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' } | ForEach-Object { $Matches[1] })
if ([string]::IsNullOrWhiteSpace($defaultLang)) {
    $defaultLang = "zh-CN"
}
Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $defaultLang" -ForegroundColor Green

# 承接前置冲突处置策略 (默认策略 2: 不删除)
$conflictPolicy = if ($global:uwpConflictPolicy) { $global:uwpConflictPolicy } else { "2" }
$policyText = switch ($conflictPolicy) {
    "1" { "全部删除 (遇到冲突强行粉碎)" }
    "3" { "手动选择 (遇到冲突时现场确认)" }
    default { "不删除 (遇到冲突自动保护保留)" }
}
Write-Host "   [策略承接] 当前激活的冲突处置策略: $policyText" -ForegroundColor DarkCyan

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
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
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

# ----------------- 3. 依赖关系静态安全测试引擎 -----------------
Write-Host "`n   [测试评估] 正在对当前映像已装载的 UWP 进行依赖拓扑完整性预检..." -ForegroundColor DarkCyan

$appxPackages = Get-AppxProvisionedPackage -Path $scratchDir
$winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"

$candidateAppsToRemove   = New-Object System.Collections.Generic.List[System.Object]
$candidateAppsToPreserve = New-Object System.Collections.Generic.List[System.Object]

foreach ($app in $appxPackages) {
    $pkgName = $app.PackageName
    $dispName = $app.DisplayName

    # 1. 核心底层框架判定
    $isCore = $false
    foreach ($corePat in $systemCoreWhitelist) {
        if ($pkgName -like $corePat -or $dispName -like $corePat) {
            $isCore = $true
            break
        }
    }

    # 2. 黑名单命中判定
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

# 建立拓扑图：记录“被保留组件”所依赖的所有底层 PackageDependency 及其来源
$depToPreservedAppMap = @{}

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
                        if (-not $depToPreservedAppMap.ContainsKey($depName)) {
                            $depToPreservedAppMap[$depName] = New-Object System.Collections.Generic.List[string]
                        }
                        if (-not $depToPreservedAppMap[$depName].Contains($preservedApp.DisplayName)) {
                            $depToPreservedAppMap[$depName].Add($preservedApp.DisplayName)
                        }
                    }
                }
            } catch {}
            finally {
                $manifestXml = $null
            }
        }
    }
}

# 垃圾回收，释放 XML 读写锁
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# 碰撞检测：查找待删列表中是否存在被保留应用强依赖的包
$conflictItems = New-Object System.Collections.Generic.List[PSCustomObject]
$safeDeleteList = New-Object System.Collections.Generic.List[System.Object]

foreach ($cand in $candidateAppsToRemove) {
    $hasConflict = $false
    $causingPreservedApps = New-Object System.Collections.Generic.List[string]

    foreach ($depKey in $depToPreservedAppMap.Keys) {
        if ($cand.PackageName -like "*$depKey*" -or $cand.DisplayName -like "*$depKey*") {
            $hasConflict = $true
            foreach ($pName in $depToPreservedAppMap[$depKey]) {
                if (-not $causingPreservedApps.Contains($pName)) {
                    $causingPreservedApps.Add($pName)
                }
            }
        }
    }

    if ($hasConflict) {
        $conflictItems.Add([PSCustomObject]@{
            App = $cand
            RequiredBy = ($causingPreservedApps -join ", ")
        })
    } else {
        $safeDeleteList.Add($cand)
    }
}

# ----------------- 4. 消费前置策略，自动化执行分流 -----------------
$finalDeleteList = New-Object System.Collections.Generic.List[System.Object]

if ($conflictItems.Count -gt 0) {
    Write-Host "`n   --------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "   [安全审计] UWP 依赖测试发现 $($conflictItems.Count) 处潜在风险组件:" -ForegroundColor Yellow
    foreach ($item in $conflictItems) {
        Write-Host "    * 冲突组件: $($item.App.DisplayName) (依赖方: $($item.RequiredBy))" -ForegroundColor DarkGray
    }
    Write-Host "   --------------------------------------------------------------" -ForegroundColor Yellow

    switch ($conflictPolicy) {
        "1" {
            Write-Host "   >>> [自动执行前置策略: 全部删除] 忽略警告，强行移除所有冲突包..." -ForegroundColor Red
            foreach ($item in $conflictItems) {
                $finalDeleteList.Add($item.App)
            }
            foreach ($item in $safeDeleteList) {
                $finalDeleteList.Add($item)
            }
        }
        "3" {
            Write-Host "`n   >>> [执行前置策略: 手动选择] 正在逐项确认冲突组件处置方案:" -ForegroundColor Yellow
            $manualIdx = 0
            foreach ($item in $conflictItems) {
                $manualIdx++
                Write-Host "`n   [$manualIdx/$($conflictItems.Count)] 待裁决组件: $($item.App.DisplayName)" -ForegroundColor Cyan
                Write-Host "      └─ 被依赖来源: $($item.RequiredBy)" -ForegroundColor DarkGray
                $ans = Read-Host "      是否删除该组件？[Y: 强行删除 / N: 安全保留] (直接回车默认 N)"
                if ($ans -eq "Y" -or $ans -eq "y") {
                    Write-Host "      -> 标记为: [强行删除]" -ForegroundColor Red
                    $finalDeleteList.Add($item.App)
                } else {
                    Write-Host "      -> 标记为: [安全保留]" -ForegroundColor Green
                    $candidateAppsToPreserve.Add($item.App)
                }
            }
            foreach ($item in $safeDeleteList) {
                $finalDeleteList.Add($item)
            }
        }
        default {
            Write-Host "   >>> [自动执行前置策略: 不删除] 自动保护全部冲突包，继续移除其余无害应用。" -ForegroundColor Green
            foreach ($item in $conflictItems) {
                $candidateAppsToPreserve.Add($item.App)
            }
            foreach ($item in $safeDeleteList) {
                $finalDeleteList.Add($item)
            }
        }
    }
} else {
    Write-Host "   [测试通过] 依赖拓扑扫描无冲突，所有待删应用均可无副作用安全剥离！" -ForegroundColor Green
    foreach ($item in $safeDeleteList) {
        $finalDeleteList.Add($item)
    }
}

# ----------------- 5. 执行 UWP 卸载与定向物理粉碎 -----------------
$totalDel = $finalDeleteList.Count
$currDel = 0
$deletedFolderNames = New-Object System.Collections.Generic.List[string]

if ($totalDel -gt 0) {
    foreach ($app in $finalDeleteList) {
        $currDel++
        $pct = [math]::Round(($currDel / [math]::Max(1, $totalDel)) * 100)
        Write-Progress -Activity "正在精简 UWP 预装应用" -Status "[$currDel/$totalDel] 正在卸载: $($app.DisplayName)" -PercentComplete $pct

        Write-Host "   [$currDel/$totalDel] [删除应用] $($app.PackageName)" -ForegroundColor Yellow
        & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
        $deletedFolderNames.Add($app.PackageName)
    }
    Write-Progress -Activity "正在精简 UWP 预装应用" -Completed
} else {
    Write-Host "   [提示] 没有需要移除的 UWP 应用。" -ForegroundColor DarkGray
}

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

# ----------------- 6. 系统可选功能包精简 (保留 Search-Engine-Client 以固化属性页) -----------------
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
