# ==============================================================================
#  win11 Builder - [模块 10/11] 映像格式分支处理与 WinPE 免硬件检测修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

# ----------------- 1. 映像格式条件分支处理 (受控于全局开关 $enableEsdConversion) -----------------
Write-Host "`n[步骤 11/11] 正在处理安装映像输出格式..." -ForegroundColor Cyan

$esdFile = Join-Path $sourcesDir "install.esd"

if ($enableEsdConversion) {
    Write-Host ">>> [开关生效: 开启] 正在导出为高压缩率 install.esd..." -ForegroundColor Yellow
    Write-Host "提示: 压缩 ESD 需高度消耗 CPU 与磁盘算力，下方将实时输出官方百分比进度条：" -ForegroundColor DarkGray

    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:1" "/DestinationImageFile:$esdFile" /Compress:recovery /CheckIntegrity

    if (Test-Path -LiteralPath $esdFile) {
        Write-Host "[成功] install.esd 构建完成，已移除临时 install.wim。" -ForegroundColor Green
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[警告] ESD 转换异常，保留 install.wim 继续推进后续流程。" -ForegroundColor Yellow
    }
} else {
    Write-Host ">>> [开关生效: 默认关闭] 跳过 ESD 高耗时压缩，直接使用 install.wim 进行极速打包！" -ForegroundColor Green
    if (Test-Path $destWim) {
        Write-Host "[就绪] 核心安装映像锁定: $destWim" -ForegroundColor DarkGray
    }
}

# ----------------- 2. 修补 WinPE (boot.wim) 免硬件检测策略 -----------------
Write-Host "`n正在为 WinPE (boot.wim) 写入免硬件检测策略..." -ForegroundColor Cyan
$bootWimPath = Join-Path $sourcesDir "boot.wim"
attrib.exe -R -S -H "$bootWimPath" 2>$null

# 自适应分卷探查 (优先卷 2 Setup 引导，单卷 PE 自动选卷 1)
$bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
$bootIndex = "2"
if ($bootInfo -notmatch "Index : 2") { $bootIndex = "1" }

Write-Host "正在挂载 boot.wim 分卷 $bootIndex..." -ForegroundColor DarkGray
& dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$bootIndex" "/MountDir:$scratchDir"

# 挂载 WinPE 的 SYSTEM 单元并注入 LabConfig 绕过策略
$bootSystemPath = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
attrib.exe -R -S -H "$bootSystemPath" 2>$null
& reg.exe load HKLM\zSYSTEM "$bootSystemPath" 2>$null | Out-Null

$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
foreach ($k in $labConfigKeys) {
    & reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $k /t REG_DWORD /d 1 /f 2>$null | Out-Null
}

# 稳健卸载注册表并提交 WinPE 映像更改
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Write-Host "正在提交并保存 boot.wim..." -ForegroundColor DarkGray
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
Write-Host "[完成] WinPE (boot.wim) 免硬件检测策略写入完毕。" -ForegroundColor Green
