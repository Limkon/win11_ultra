# ==============================================================================
#  win11 Builder - [模块 6/11] 物理文件实体清理 (src/05-PhysicalNuke.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 严禁粉碎 CJK 多语言字体库与输入法，防止游戏、网页、跨国文档与打印乱码。
#      - 严禁篡改/置空 WinRE 恢复环境 (winre.wim)，确保系统还原、安全模式与“重置此电脑”功能完好。
#      - 完整保留 TTS 语音引擎与系统光标库 (Cursors)。
#      - 仅安全清理纯冗余临时缓存、离线病毒库增量包与默认配置文件中的 OneDrive 残留。
#   2. 极限模式 (极限压榨)：
#      - 保留原有地毯式物理粉碎 (WinRE 零字节占位、字体库极限剔除、Edge/OneDrive 底层粉碎)。
# ==============================================================================

Write-Host "`n[步骤 7/11] 正在执行系统冗余物理文件清理..." -ForegroundColor Cyan
$winDir = "$scratchDir\Windows"

# ----------------- 1. 字体库处理 (按模式差异化) -----------------
$fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
if (Test-Path -LiteralPath $fontsPath) {
    if ($global:trimMode -eq "2") {
        # 极限模式：仅保留微软核心英文字体与简体中文字体，清理其他多语言字型
        Write-Host ">>> [极限压榨模式] 正在极限裁剪非核心字型库..." -ForegroundColor Yellow
        Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # 普通健康模式：完整保留字体库，确保全语言排版与打印光栅化绝对正常
        Write-Host "   [普通健康模式] 完整保留系统全套字型库，防止游戏、繁体网站及跨国文档乱码。" -ForegroundColor Green
    }
}

# ----------------- 2. 语音引擎与多语言输入法物理目录 -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 清理 TTS 语音引擎与外语输入法资产..." -ForegroundColor Yellow
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "   [普通健康模式] 保留 TTS 语音引擎与日韩繁输入法架构。" -ForegroundColor Green
}

# ----------------- 3. 通用安全清理项 (双模式均执行) -----------------
# 离线病毒定义更新包（开机联网后会自动下载最新基线）
Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue

# Windows 临时工作区
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# 用户配置文件下的 OneDrive 初始安装包缓存
$userProfileOneDrive = "$scratchDir\Users\Default\AppData\Local\Microsoft\OneDrive"
if (Test-Path -LiteralPath $userProfileOneDrive) {
    Remove-Item -LiteralPath $userProfileOneDrive -Recurse -Force -ErrorAction SilentlyContinue
}

# 帮助文档与示例壁纸清理
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
$webWallpaper = Join-Path $winDir "Web\Wallpaper"
if (Test-Path -LiteralPath $webWallpaper) {
    Remove-Item -Path $webWallpaper -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------- 4. 光标库 (Cursors) 处理 -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 清理系统指针库 (Cursors)..." -ForegroundColor Yellow
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Cursors") -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "   [普通健康模式] 完整保留鼠标指针库 (Cursors)，防止高分屏与游戏鼠标花屏。" -ForegroundColor Green
}

# ----------------- 5. Edge / OneDrive 物理地毯式粉碎（仅极限压榨模式） -----------------
if ($global:trimMode -eq "2") {
    Write-Host ">>> [极限压榨模式] 正在地毯式粉碎 Edge 和 OneDrive 磁盘实体残留..." -ForegroundColor Yellow

    $searchBases = @(
        "$scratchDir\Program Files",
        "$scratchDir\Program Files (x86)",
        "$scratchDir\Windows\System32",
        "$scratchDir\Windows\SysWOW64",
        "$scratchDir\Windows\WinSxS",
        "$scratchDir\Windows\SystemApps"
    )
    $patternsToDelete = @("*Edge*", "*MicrosoftEdge*", "*OneDrive*")

    foreach ($base in $searchBases) {
        if (Test-Path -LiteralPath $base) {
            foreach ($pattern in $patternsToDelete) {
                $items = Get-ChildItem -Path $base -Filter $pattern -ErrorAction SilentlyContinue
                if ($items) {
                    foreach ($item in $items) {
                        Write-Host "   [物理粉碎] 残留实体: $($item.FullName)" -ForegroundColor DarkGray
                        if ($item.PSIsContainer) {
                            & takeown.exe /F "$($item.FullName)" /A /R /D Y 2>&1 | Out-Null
                            & icacls.exe "$($item.FullName)" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                        }
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
} else {
    Write-Host "   [普通健康模式] 跳过 Program Files / System32 / SysWOW64 等系统关键目录的底层实体物理粉碎，改由官方 AppX 卸载与注册表策略禁用安全处理。" -ForegroundColor Green
}

# ----------------- 6. WinRE 恢复环境处理 (极其关键) -----------------
$winrePath = "$scratchDir\Windows\System32\Recovery\winre.wim"
if ($global:trimMode -eq "2") {
    # 极限模式：清空 WinRE 以换取 ~500MB 极限体积
    Write-Host ">>> [极限压榨模式] 正在将 WinRE 执行零字节占位 (释放 500MB)..." -ForegroundColor Yellow
    Remove-Item -Path $winrePath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $winrePath -ItemType File -Force | Out-Null
} else {
    # 普通健康模式：完整保留官方 winre.wim，确保重置此电脑与高级故障排查 100% 正常
    Write-Host "   [普通健康模式] 完整保留官方 WinRE 恢复环境，确保系统故障自愈、安全模式与“重置此电脑”功能绝对可用。" -ForegroundColor Green
}

Write-Host "[完成] 冗余物理文件与底层资产清理完毕。" -ForegroundColor Green
