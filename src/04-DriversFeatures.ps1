# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动压榨与老旧特性停用 (src/04-DriversFeatures.ps1)
# ==============================================================================

# ----------------- 1. 安全驱动仓库压榨 (两模式均执行) -----------------
Write-Host "`n[步骤 6/11] 正在执行安全驱动压榨 (剔除打印机/调制解调器/传真驱动)..." -ForegroundColor Cyan
$driverStorePath = Join-Path $scratchDir "Windows\System32\DriverStore\FileRepository"

# 安全剔除模式列表 (保留显卡、芯片组、存储、声卡、网卡等核心驱动)
$safeDriverPurgeList = @(
    "prn*.inf_*",     # 冗余打印机驱动
    "mdm*.inf_*",     # 调制解调器驱动
    "fax*.inf_*",     # 传真驱动
    "scancopy.inf_*", # 扫描仪复制驱动
    "flpydisk.inf_*", # 软驱驱动
    "brmf*.inf_*",    # Brother 打印机残留
    "hpq*.inf_*"      # HP 打印机残留
)

if (Test-Path $driverStorePath) {
    foreach ($pat in $safeDriverPurgeList) {
        Get-ChildItem -Path $driverStorePath -Filter $pat -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "   [清除冗余驱动] $($_.Name)" -ForegroundColor DarkGray
            Force-NukeFolderOrFile $_.FullName
        }
    }
}
Write-Host "[完成] 驱动仓库深度压榨完毕。" -ForegroundColor Green

# ----------------- 2. 停用冗余老旧 Windows 特性 (两模式均执行) -----------------
Write-Host "   正在停用并移除老旧 Windows 特性 (WorkFolders/Fax 等)..." -ForegroundColor DarkGray

$featuresToDisable = @(
    "WorkFolders-Client",                   # 工作文件夹
    "Printing-Foundation-Features",         # 打印基础服务
    "Printing-PrintToPDFServices-Features", # 打印到 PDF 架构
    "FaxServicesClientPackage",             # 传真客户端
    "MSRDC-Infrastructure"                  # 远程桌面旧版基础设施
)

foreach ($feat in $featuresToDisable) {
    Write-Host "   [停用特性] $feat" -ForegroundColor DarkGray
    & dism.exe /English /Image:$scratchDir /Disable-Feature "/FeatureName:$feat" /Remove /NoRestart 2>$null | Out-Null
}
Write-Host "[完成] 老旧特性剥离完毕。" -ForegroundColor Green
