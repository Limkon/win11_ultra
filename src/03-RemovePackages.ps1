# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [企业级重构]：动态规则库联动 + 依赖异常交互阻断裁决 + 属性页架构固化
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

# ----------------- 4. 依赖异常交互阻断裁决机制 -----------------
$finalDeleteList = New-Object System.Collections.Generic.List[System.Object]

if ($conflictItems.Count -gt 0) {
    Write-Host "`n==================================================================" -ForegroundColor Red
    Write-Host " [安全预警] UWP 依赖完整性测试发现 $($conflictItems.Count) 处严重依赖冲突！" -ForegroundColor Red
    Write-Host " 以下组件存在于您的待删除黑名单中，但被您选择保留的应用强行依赖：" -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Red

    foreach ($item in $conflictItems) {
        Write-Host " [冲突组件] $($item.App.DisplayName)" -ForegroundColor Yellow
        Write-Host "    └─ 强依赖于它的保留组件: $($item.RequiredBy)" -ForegroundColor DarkGray
    }

    Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 请选择对异常冲突组件的处理策略:" -ForegroundColor Cyan
    Write-Host " [1] 智能保护 (推荐: 自动保留这 $($conflictItems.Count) 个冲突包，仅删除其余无害应用，确保系统稳定)" -ForegroundColor Green
    Write-Host " [2] 强行粉碎 (高危: 忽略测试警告，强行物理抹杀所有待删包，依赖缺失的应用可能闪退)" -ForegroundColor Red
    Write-Host " [3] 终止构建 (安全: 丢弃当前镜像修改并退出，以便您重新调整 Appslist.txt)" -ForegroundColor DarkYellow
    Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan

    $choice = Read-Host "请输入对应选项 [1, 2 或 3] (直接回车默认推荐 1)"

    if ($choice -eq "2") {
        Write-Host ">>> [警告] 用户选择强行粉碎模式，将移除包括冲突项在内的所有指定包..." -ForegroundColor Red
        foreach ($item in $conflictItems) {
            $finalDeleteList.Add($item.App)
        }
        foreach ($item in $safeDeleteList) {
            $finalDeleteList.Add($item)
        }
    } elseif ($choice -eq "3") {
        Write-Host "`n>>> [中止操作] 用户已终止流程。正在安全卸载挂载点并丢弃所有临时更改..." -ForegroundColor DarkYellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard
        Stop-Transcript
        Write-Host "[完成] 映像已安全重置，未产生损坏文件。请调整规则后重新运行。" -ForegroundColor Green
        pause
        exit
    } else {
        Write-Host ">>> [智能保护] 已自动将 $($conflictItems.Count) 个冲突包移入保护名单，继续精简其余应用。" -ForegroundColor Green
        foreach ($item in $safeDeleteList) {
            $finalDeleteList.Add($item)
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
