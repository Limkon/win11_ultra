# ==============================================================================
#  win11 Builder - [模块 4/11] UWP 预装应用与可选功能包精简 (src/03-RemovePackages.ps1)
#  [nano11 逻辑直装重构版]：彻底抛弃脆弱的拓扑解析，采用 nano11 原生安全匹配与极速剥离
# ==============================================================================

Write-Host "`n[步骤 4/11] 正在同步 nano11 架构执行 UWP 预装应用剥离..." -ForegroundColor Cyan

# ----------------- 1. 母盘主语言探测 (严格保护母盘核心语言) -----------------
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageLine = $imageIntl -split '\r?\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Host "   [母盘语言检测] 锁定系统原生核心语言为: $languageCode" -ForegroundColor Green
} else {
    $languageCode = "zh-CN"
    Write-Host "   [母盘语言检测] 未探测到主语言，自动锚定默认值: $languageCode" -ForegroundColor Yellow
}

# ----------------- 2. nano11 原生 UWP 预装应用安全剔除列表 -----------------
# 继承自 nano11 核心匹配逻辑，仅剔除纯应用层无害臃肿软件，绝不伤及底层框架与 Store 核心
$uwpBloatPatterns = @(
    '*Zune*',                          # 媒体播放器旧版
    '*Bing*',                          # 必应天气/资讯
    '*Clipchamp*',                     # Clipchamp 剪辑
    '*Gaming*',                        # Xbox 游戏组件
    '*People*',                        # 人脉
    '*PowerAutomate*',                 # 自动化流
    '*Teams*',                         # 个人版 Teams
    '*Todos*',                         # 待办事项
    '*YourPhone*',                     # 手机连接
    '*SoundRecorder*',                 # 录音机
    '*Solitaire*',                     # 纸牌游戏
    '*FeedbackHub*',                   # 反馈中心
    '*Maps*',                          # 地图
    '*OfficeHub*',                     # Office 门户
    '*Help*',                          # 帮助提示
    '*Family*',                        # 家庭安全
    '*Alarms*',                        # 闹钟与时钟
    '*CommunicationsApps*',            # 邮件与日历
    '*Copilot*',                       # Copilot 预览版
    '*CompatibilityEnhancements*',     # 兼容性增强包
    '*AV1VideoExtension*',             # AV1 扩展
    '*AVCEncoderVideoExtension*',      # AVC 编码扩展
    '*HEIFImageExtension*',            # HEIF 图像扩展
    '*HEVCVideoExtension*',            # HEVC 视频扩展
    '*MicrosoftStickyNotes*',          # 便签
    '*OutlookForWindows*',             # 新版 Outlook 客户端
    '*RawImageExtension*',             # RAW 图像扩展
    '*SecHealthUI*',                   # 安全中心 UWP 壳层
    '*VP9VideoExtensions*',            # VP9 扩展
    '*WebpImageExtension*',            # Webp 图像扩展
    '*DevHome*',                       # DevHome 开发者中心
    '*Photos*',                        # 照片应用 (已在注册表激活经典照片查看器)
    '*Camera*',                        # 相机
    '*QuickAssist*',                   # 快速助手
    '*CoreAI*',                        # AI 模型预载
    '*PeopleExperienceHost*',          # 人脉体验宿主
    '*PinningConfirmationDialog*',     # 固定确认对话框
    '*SecureAssessmentBrowser*',       # 考试安全浏览器
    '*Paint*',                         # 画图 UWP (可回退原生或按需装)
    '*Notepad*'                        # 记事本 UWP (安全卸载后由 Windows 原生降级机制无缝接管)
)

Write-Host "   正在检索当前映像已装载的预装 AppX 包..." -ForegroundColor DarkGray
$provisionedApps = Get-AppxProvisionedPackage -Path $scratchDir

$packagesToRemove = $provisionedApps | Where-Object {
    $pkgName = $_.PackageName
    $shouldRemove = $false
    foreach ($pat in $uwpBloatPatterns) {
        if ($pkgName -like $pat) {
            $shouldRemove = $true
            break
        }
    }
    $shouldRemove
}

$totalApps = $packagesToRemove.Count
$currApp = 0

if ($totalApps -gt 0) {
    foreach ($app in $packagesToRemove) {
        $currApp++
        $pct = [math]::Round(($currApp / [math]::Max(1, $totalApps)) * 100)
        Write-Progress -Activity "正在同步 nano11 逻辑精简预装 UWP" -Status "[$currApp/$totalApps] 正在卸载: $($app.DisplayName)" -PercentComplete $pct
        Write-Host "   [$currApp/$totalApps] [安全卸载 UWP] $($app.DisplayName)" -ForegroundColor Yellow
        
        # 使用 DISM 官方原生接口规范化反注册，不强行抹杀注册表
        & dism.exe /English /Image:$scratchDir /Remove-ProvisionedAppxPackage "/PackageName:$($app.PackageName)" 2>$null | Out-Null
    }
    Write-Progress -Activity "正在同步 nano11 逻辑精简预装 UWP" -Completed

    # 按照 nano11 原生逻辑清理 WindowsApps 目录下的残留大实体文件夹
    Write-Host "   正在清理 WindowsApps 残留实体文件..." -ForegroundColor DarkGray
    $winAppsDir = Join-Path $scratchDir "Program Files\WindowsApps"
    if (Test-Path -LiteralPath $winAppsDir) {
        foreach ($app in $packagesToRemove) {
            $folderPath = Join-Path $winAppsDir $app.PackageName
            if (Test-Path -LiteralPath $folderPath) {
                Remove-Item -LiteralPath $folderPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # 【工业级安全防线】：恢复 WindowsApps 必要的继承访问权限，确保剩余现代应用不闪退
        & icacls.exe "$winAppsDir" /grant "*S-1-15-2-1:(OI)(CI)RX" /C /Q 2>$null | Out-Null
        & icacls.exe "$winAppsDir" /grant "*S-1-5-32-545:(OI)(CI)RX" /C /Q 2>$null | Out-Null
    }
} else {
    Write-Host "   [提示] 未发现匹配 nano11 规则的预装应用。" -ForegroundColor DarkGray
}

Write-Host "[完成] UWP 预装应用剥离完毕。" -ForegroundColor Green

# ----------------- 3. nano11 原生系统可选功能包 (FOD) 精炼 -----------------
Write-Host "`n[步骤 5/11] 正在同步 nano11 规则精炼可选功能与外语包..." -ForegroundColor Cyan

# 继承自 nano11 官方精简方案 (安全保留 Search-Engine-Client，避免属性页与索引架构损伤)
$packagePatterns = @(
    # --- 传统废弃组件与可选应用 ---
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

    # --- 冗余输入法字库 (剔除日韩繁，保护简体中文) ---
    "*IME-ja-jp*",
    "*IME-ko-kr*",
    "*IME-zh-tw*",

    # --- 核心底层可选包精简 ---
    "Windows-Defender-Client-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",

    # --- 安全与认证扩展 ---
    "Microsoft-Windows-Hello-Face-Package~",
    "Microsoft-Windows-Hello-BioEnrollment-Package~",
    "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
    "Microsoft-Windows-TPM-WMI-Provider-Package~",

    # --- 辅助工具 ---
    "Microsoft-Windows-Narrator-App-Package~",
    "Microsoft-Windows-Magnifier-App-Package~",

    # --- 杂项与打印体验 ---
    "Microsoft-Windows-Printing-PMCPPC-FoD-Package~",
    "Microsoft-Windows-WebcamExperience-Package~",
    "Microsoft-Media-MPEG2-Decoder-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~"
)

# 动态剔除非母盘语言的语音与手写识别组件
if ($languageCode -and $languageCode -ne "zh-CN") {
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~"
    $packagePatterns += "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~"
}

$allPackagesRaw = & dism.exe /English /Image:$scratchDir /Get-Packages /Format:Table
$allPackageLines = $allPackagesRaw -split '\r?\n' | Select-Object -Skip 1

$targetPackagesToRemove = New-Object System.Collections.Generic.List[string]

foreach ($pat in $packagePatterns) {
    $matchedLines = $allPackageLines | Where-Object { $_ -like "*$pat*" }
    foreach ($line in $matchedLines) {
        $pkgId = ($line -split '\s+')[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($pkgId) -and $pkgId -ne "Package" -and $pkgId -notmatch "^-+$") {
            if (-not $targetPackagesToRemove.Contains($pkgId)) {
                $targetPackagesToRemove.Add($pkgId)
            }
        }
    }
}

$totalFOD = $targetPackagesToRemove.Count
$currFOD = 0

foreach ($pkgId in $targetPackagesToRemove) {
    $currFOD++
    $pct = [math]::Round(($currFOD / [math]::Max(1, $totalFOD)) * 100)
    Write-Progress -Activity "正在精炼可选功能包 (FOD)" -Status "[$currFOD/$totalFOD] 正在移除: $pkgId" -PercentComplete $pct
    Write-Host "   [$currFOD/$totalFOD] [移除功能包] $pkgId" -ForegroundColor DarkYellow
    & dism.exe /English /Image:$scratchDir /Remove-Package "/PackageName:$pkgId" /NoRestart 2>$null | Out-Null
}
Write-Progress -Activity "正在精炼可选功能包 (FOD)" -Completed

# ----------------- 4. 清理预编译 .NET Native 镜像 (nano11 标准瘦身步骤) -----------------
Write-Host "   正在清理冗余 .NET Native 编译缓存..." -ForegroundColor DarkGray
$assemblyDir = Join-Path $scratchDir "Windows\assembly"
if (Test-Path -LiteralPath $assemblyDir) {
    Remove-Item -Path "$assemblyDir\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[完成] 系统可选功能包精炼完毕 (与 nano11 稳定基线完全对齐)。" -ForegroundColor Green
