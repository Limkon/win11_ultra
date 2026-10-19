# ==============================================================================
#  win11 Builder - [模块 10/11] 映像提交、二次重构与 WinPE 修补 (src/09-ExportAndPE.ps1)
# ==============================================================================

Write-Host "`n[步骤 11/11] 正在卸载主映像并二次导出重建 install.wim..." -ForegroundColor Cyan

$destWimPath   = Join-Path $sourcesDir "install.wim"
$destWim2Path  = Join-Path $sourcesDir "install2.wim"

# 1. 提交并卸载主映像
Write-Host "Cleaning up and unmounting install.wim..."
& dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase
& dism.exe /English /unmount-image "/mountdir:$scratchDir" /commit

# 2. 导出并重构 install.wim 清理碎片 (完全移植原版)
Write-Host "Exporting and compressing install.wim..."
& dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destWim2Path" /compress:max
Remove-Item -Path $destWimPath -Force -ErrorAction SilentlyContinue
Rename-Item -Path $destWim2Path -NewName "install.wim"

# 3. 修补 boot.wim (完全移植原版：提取 Index 2，挂载，注入策略，二次导出为全新 boot.wim)
Write-Host "`nShrinking boot.wim and bypassing requirements..." -ForegroundColor Cyan
$bootWimPath      = Join-Path $sourcesDir "boot.wim"
$newBootWimPath   = Join-Path $sourcesDir "boot_new.wim"
$finalBootWimPath = Join-Path $sourcesDir "boot_final.wim"

Write-Host "Taking ownership of $bootWimPath..."
& takeown.exe /F "$bootWimPath" 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" 2>$null | Out-Null
try {
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {}

Write-Host "Exporting modified setup image (index 2) from boot.wim..."
& dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" /SourceIndex:2 "/DestinationImageFile:$newBootWimPath"
& dism.exe /English /mount-image "/imagefile:$newBootWimPath" /index:1 "/mountdir:$scratchDir"

# 加载 boot.wim 注册表配置单元 (使用统一变量 $scratchDir)
reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

Write-Host "Bypassing system requirements(on the boot image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null

Write-Host "Tweaking boot image complete!"
Write-Host "Unmounting Registry..."
reg unload HKLM\zNTUSER > $null
reg unload HKLM\zDEFAULT > $null
reg unload HKLM\zSOFTWARE > $null
reg unload HKLM\zSYSTEM > $null

Start-Sleep -Seconds 3
& dism.exe /English /unmount-image "/mountdir:$scratchDir" /commit

& takeown.exe /F "$bootWimPath" 2>$null | Out-Null
& icacls.exe "$bootWimPath" /grant "*S-1-5-32-544:F" 2>$null | Out-Null
Remove-Item -Path $bootWimPath -Force -ErrorAction SilentlyContinue

& dism.exe /English /Export-Image "/SourceImageFile:$newBootWimPath" /SourceIndex:1 "/DestinationImageFile:$finalBootWimPath" /compress:max
Remove-Item -Path $newBootWimPath -Force -ErrorAction SilentlyContinue
Rename-Item -Path $finalBootWimPath -NewName "boot.wim"

# 4. 根目录无用文件清理 (保持 ISO 极简结构)
Write-Host "Performing final cleanup of installation folder root..."
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "setup.exe", "autounattend.xml")
Get-ChildItem -Path $workDir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Write-Host "Removing non-essential file/folder from ISO root: $($_.Name)"
    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[完成] WinPE 引导重构与母盘清理全部完毕。" -ForegroundColor Green
