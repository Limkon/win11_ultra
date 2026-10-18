# ==============================================================================
#  win11 Builder - [模块 6/11] 冗余大文件与组件实体物理清理 (src/05-PhysicalNuke.ps1)
#  [企业级重构]：深度提权穿透粉碎 + 彻底连根拔起 Edge 全栈 + 字体与外壳安全精简
# ==============================================================================

Write-Host "`n正在执行大文件实体物理深度清理..." -ForegroundColor Cyan
$winDir = Join-Path $scratchDir "Windows"

# ----------------- 0. 本地底层穿透粉碎工具函数 -----------------
function Nuke-PathEntity {
    <#
    .SYNOPSIS
        先探针探测、解除只读属性、接管所有权并强制物理粉碎，杜绝权限拦截
    #>
    param([string]$TargetPath)
    if (Test-Path -LiteralPath $TargetPath) {
        & takeown.exe /F "$TargetPath" /A /R /D Y > $null 2>&1
        & icacls.exe "$TargetPath" /grant "*S-1-5-32-544:F" /T /C /Q > $null 2>&1
        attrib.exe -R -S -H "$TargetPath" /S /D > $null 2>&1
        if ((Get-Item -LiteralPath $TargetPath).PSIsContainer) {
            cmd.exe /c "rd /s /q `"$TargetPath`"" > $null 2>&1
        } else {
            cmd.exe /c "del /f /q /a `"$TargetPath`"" > $null 2>&1
        }
    }
}

# ----------------- 1. 系统字体智能精炼 (保留中英文核心字体) -----------------
Write-Host "   -> 正在精简冗余外文字体库..." -ForegroundColor DarkGray
$fontsPath = Join-Path $winDir "Fonts"
if (Test-Path -LiteralPath $fontsPath) { 
    # 排除关键中英文及系统核心字体，剔除其他冗余字体
    Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*", "msyh*.*", "simsun*.*", "simhei*.*" | ForEach-Object {
        attrib.exe -R -S -H "$($_.FullName)" 2>$null
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    # 清理特大冷门东亚字体与历史字体
    Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" | ForEach-Object {
        attrib.exe -R -S -H "$($_.FullName)" 2>$null
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------- 2. TTS 语音引擎与 Defender 更新缓存 -----------------
Write-Host "   -> 正在清理 TTS 离线引擎与 Defender 冗余缓存..." -ForegroundColor DarkGray
Nuke-PathEntity (Join-Path $winDir "Speech\Engines\TTS")
Nuke-PathEntity "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates"

# ----------------- 3. 繁体、日文、韩文输入法组件 -----------------
Write-Host "   -> 正在清理东亚非必要输入法引擎..." -ForegroundColor DarkGray
Nuke-PathEntity "$scratchDir\Windows\System32\InputMethod\CHT"
Nuke-PathEntity "$scratchDir\Windows\System32\InputMethod\JPN"
Nuke-PathEntity "$scratchDir\Windows\System32\InputMethod\KOR"

# ----------------- 4. 临时目录、壁纸、帮助文档与指针 -----------------
Write-Host "   -> 正在清理系统帮助、壁纸、临时缓存与指针..." -ForegroundColor DarkGray
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Nuke-PathEntity (Join-Path $winDir "Web")
Nuke-PathEntity (Join-Path $winDir "Help")
Nuke-PathEntity (Join-Path $winDir "Cursors")

# ----------------- 5. 彻底连根拔起 Microsoft Edge 全栈体系 -----------------
Write-Host "   -> 正在全维度物理粉碎 Microsoft Edge 及其关联更新通道..." -ForegroundColor DarkGray

# 5.1 粉碎 Program Files (x86) 实体目录
$edgeDirs = @(
    "$scratchDir\Program Files (x86)\Microsoft\Edge",
    "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
    "$scratchDir\Program Files (x86)\Microsoft\EdgeCore",
    "$scratchDir\Program Files (x86)\Microsoft\EdgeWebView",
    "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
)
foreach ($dir in $edgeDirs) {
    Nuke-PathEntity $dir
}

# 5.2 粉碎 SystemApps 中的 Edge 核心骨架
$edgeSystemApps = Get-ChildItem -Path "$scratchDir\Windows\SystemApps" -Filter "*MicrosoftEdge*" -Directory -ErrorAction SilentlyContinue
foreach ($sa in $edgeSystemApps) {
    Nuke-PathEntity $sa.FullName
}

# 5.3 物理清理 Edge 快捷方式（杜绝安装后桌面上遗留无效白图标）
$edgeShortcuts = @(
    "$scratchDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
    "$scratchDir\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
    "$scratchDir\Users\Default\Desktop\Microsoft Edge.lnk",
    "$scratchDir\Users\Public\Desktop\Microsoft Edge.lnk"
)
foreach ($lnk in $edgeShortcuts) {
    if (Test-Path -LiteralPath $lnk) {
        attrib.exe -R -S -H "$lnk" 2>$null
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    }
}

# 5.4 清理 Edge 升级计划任务定义
$edgeTasks = Get-ChildItem -Path "$scratchDir\Windows\System32\Tasks" -Filter "*MicrosoftEdge*" -Recurse -File -ErrorAction SilentlyContinue
foreach ($task in $edgeTasks) {
    Remove-Item -LiteralPath $task.FullName -Force -ErrorAction SilentlyContinue
}

# ----------------- 6. 移除 OneDrive 与 WinRE 安全占位 -----------------
Write-Host "   -> 正在移除 OneDrive 安装包并重置 WinRE 恢复环境占位..." -ForegroundColor DarkGray
Nuke-PathEntity "$scratchDir\Windows\System32\OneDriveSetup.exe"

# 剥离 winre.wim 并建立 0 字节只读安全占位，规避安装程序校验异常
$winrePath = "$scratchDir\Windows\System32\Recovery\winre.wim"
if (Test-Path -LiteralPath $winrePath) {
    attrib.exe -R -S -H "$winrePath" 2>$null
    Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllBytes($winrePath, [byte[]]@())
attrib.exe +R +H +S "$winrePath" 2>$null

# ----------------- 7. 执行第一轮 DISM 组件存储基线深度固化 -----------------
Write-Host "   -> 正在执行组件存储基线深度固化..." -ForegroundColor DarkGray

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

& dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "[完成] 大文件与 Edge 全栈体系实体物理清理完毕。" -ForegroundColor Green
