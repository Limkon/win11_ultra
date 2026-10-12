# ==============================================================================
#  win11 Builder - [模块 7/11] 离线注册表原子深度优化 (src/06-RegistryTweaks.ps1)
# ==============================================================================

Write-Host "`n[步骤 8/11] 正在配置离线注册表并优化系统参数..." -ForegroundColor Cyan

# 1. 定位并挂载离线配置单元文件
$softwarePath = Join-Path $scratchDir "Windows\System32\config\SOFTWARE"
$systemPath   = Join-Path $scratchDir "Windows\System32\config\SYSTEM"
$ntuserPath   = Join-Path $scratchDir "Users\Default\ntuser.dat"

attrib.exe -R -S -H "$softwarePath" 2>$null
attrib.exe -R -S -H "$systemPath" 2>$null
attrib.exe -R -S -H "$ntuserPath" 2>$null

& reg.exe load HKLM\zSOFTWARE "$softwarePath" 2>$null | Out-Null
& reg.exe load HKLM\zSYSTEM "$systemPath" 2>$null | Out-Null
& reg.exe load HKLM\zNTUSER "$ntuserPath" 2>$null | Out-Null

# 2. 定义需停用/抹杀的服务清单
$normalServices = @(
    "SysMain", "DiagTrack", "dmwappushservice", "WerSvc", "PcaSvc", "WSearch",
    "MapsBroker", "SensorService", "SensrSvc", "lfsvc", "RetailDemo",
    "wisvc", "WalletService", "SharedRealitySvc", "XblAuthManager", "XblGameSave",
    "XboxNetApiSvc", "XboxGipSvc", "AllJoynRouter", "SecurityHealthService"
)
$defenderFullStack = @("WinDefend", "WdNisSvc", "Sense", "WdFilter", "WdNisDrv", "WdBoot")

# 3. 构造原子批处理执行指令流
$batLines = New-Object System.Collections.Generic.List[string]
$batLines.Add("@echo off")
$batLines.Add("chcp 65001 >nul")

# ----------------- 模式分支：服务配置 -----------------
if ($trimMode -eq "2") {
    $batLines.Add('echo >>> [极限模式] 执行 Defender 终极物理抹杀与服务清除...')
    # 解除 Windows 内核 ELAM 强制校验，杜绝 0x7B 蓝屏
    $batLines.Add('reg add "HKLM\zSYSTEM\ControlSet001\Control\EarlyLaunch" /v "DriverLoadPolicy" /t REG_DWORD /d 8 /f >nul 2>nul')
    $extremeDeleteServices = $normalServices + $defenderFullStack + @("Spooler", "PrintNotify", "Fax", "RemoteRegistry", "diagsvc")
    foreach ($svc in $extremeDeleteServices) {
        $batLines.Add("reg delete `"HKLM\zSYSTEM\ControlSet001\Services\$svc`" /f >nul 2>nul")
    }
} else {
    $batLines.Add('echo >>> [普通模式] 安全停用后台服务 (Start = 4)...')
    $allServicesToDisable = $normalServices + $defenderFullStack
    foreach ($svc in $allServicesToDisable) {
        $batLines.Add("reg add `"HKLM\zSYSTEM\ControlSet001\Services\$svc`" /v `"Start`" /t REG_DWORD /d 4 /f >nul 2>nul")
    }
}

# ----------------- 通用优化配置 (两模式均执行) -----------------
# 基础优化、遥测与透明度
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MaxTelemetryAllowed" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f >nul 2>nul')

# 彻底封锁 OneDrive
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSync" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableMeteredNetworkFileSync" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableLibrariesStylePin" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDriveSetup" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" /v "System.IsPinnedToNameSpaceTree" /t REG_DWORD /d 0 /f >nul 2>nul')

# 搜索禁用
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f >nul 2>nul')

# Edge 幽灵清理与打开方式本地化秒开
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\MSEdgeHTM" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\MSEdgePDF" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\Applications\msedge.exe" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoUseStoreOpenWith" /t REG_DWORD /d 1 /f >nul 2>nul')

# 经典记事本文件关联秒开修复
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt" /ve /t REG_SZ /d "txtfile" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt" /v "PerceivedType" /t REG_SZ /d "text" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt\OpenWithProgids" /v "txtfile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.txt\ShellNew" /v "NullFile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile" /ve /t REG_SZ /d "文本文档" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile\DefaultIcon" /ve /t REG_EXPAND_SZ /d "%%SystemRoot%%\system32\imageres.dll,-102" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\txtfile\shell\open\command" /ve /t REG_EXPAND_SZ /d "\"%%SystemRoot%%\System32\notepad.exe\" \"%%1\"" /f >nul 2>nul')

$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml" /ve /t REG_SZ /d "xmlfile" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml" /v "PerceivedType" /t REG_SZ /d "text" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\.xml\OpenWithProgids" /v "xmlfile" /t REG_SZ /d "" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\xmlfile" /ve /t REG_SZ /d "XML 文档" /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Classes\xmlfile\shell\open\command" /ve /t REG_EXPAND_SZ /d "\"%%SystemRoot%%\System32\notepad.exe\" \"%%1\"" /f >nul 2>nul')

$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" /v "UseFilter" /t REG_DWORD /d 0 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe" /ve /t REG_EXPAND_SZ /d "%%SystemRoot%%\system32\notepad.exe" /f >nul 2>nul')
$batLines.Add('reg delete "HKLM\zSOFTWARE\Classes\Applications\notepad.exe" /v "NoOpenWith" /f >nul 2>nul')

# 经典 Windows 照片查看器激活
$photoExts = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".jfif")
$batLines.Add('reg add "HKLM\zSOFTWARE\RegisteredApplications" /v "Windows Photo Viewer" /t REG_SZ /d "SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" /f >nul 2>nul')
foreach ($ext in $photoExts) {
    $batLines.Add("reg add `"HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations`" /v `"$ext`" /t REG_SZ /d `"PhotoViewer.FileAssoc.Tiff`" /f >nul 2>nul")
    $batLines.Add("reg add `"HKLM\zSOFTWARE\Classes\$ext`" /ve /t REG_SZ /d `"PhotoViewer.FileAssoc.Tiff`" /f >nul 2>nul")
}

# 硬件要求绕过、消费者功能关闭与 OOBE 免联网
$labConfigKeys = @("BypassCPUCheck", "BypassRAMCheck", "BypassSecureBootCheck", "BypassStorageCheck", "BypassTPMCheck", "BypassDiskCheck")
foreach ($k in $labConfigKeys) {
    $batLines.Add("reg add `"HKLM\zSYSTEM\Setup\LabConfig`" /v `"$k`" /t REG_DWORD /d 1 /f >nul 2>nul")
}
$batLines.Add('reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f >nul 2>nul')
$batLines.Add('reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "DisableOnline" /t REG_DWORD /d 1 /f >nul 2>nul')

# 4. 写入并调用原生 cmd 快速执行批处理
$tempBatFile = Join-Path $env:TEMP "win11_reg_apply.bat"
[System.IO.File]::WriteAllLines($tempBatFile, $batLines, [System.Text.Encoding]::ASCII)

Write-Host "   正在应用原子注册表指令流 (瞬间完成，零阻塞)..." -ForegroundColor Green
$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tempBatFile`"" -NoNewWindow -Wait -PassThru
Remove-Item -LiteralPath $tempBatFile -Force -ErrorAction SilentlyContinue

# 5. 安全释放并卸载离线 Hive 单元
Write-Host "   正在安全卸载配置单元 (防句柄残留)..." -ForegroundColor Green
Safely-UnloadHive "HKLM\zSOFTWARE" | Out-Null
Safely-UnloadHive "HKLM\zSYSTEM" | Out-Null
Safely-UnloadHive "HKLM\zNTUSER" | Out-Null
Write-Host "[完成] 离线注册表优化全部完毕。" -ForegroundColor Green
