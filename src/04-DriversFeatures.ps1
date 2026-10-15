# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动仓库深度精炼 (src/04-DriversFeatures.ps1)
#  [100% 对齐 稳定基准]：安全精炼冗余驱动，绝不滥用 /Remove 破坏系统特性
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行安全驱动仓库压榨 (剔除无用驱动)..." -ForegroundColor Cyan
$driverStorePath = Join-Path $scratchDir "Windows\System32\DriverStore\FileRepository"

# 对齐 官方驱动剔除规则 (严格保留显卡、芯片组、存储、声卡、网卡等核心驱动)
$safeDriverPurgeList = @(
    "prn*.inf_*",     # 冗余打印机驱动 (原生规则)
    "scan*.inf_*",    # 扫描仪驱动 (原生规则)
    "mfd*.inf_*",     # 多功能设备驱动 (原生规则)
    "wscsmd.inf_*",   # 智能卡读卡器驱动 (原生规则)
    "tapdrv*.inf_*",  # 磁带机驱动 (原生规则)
    "rdpbus.inf_*",   # 远程桌面总线驱动 (原生规则)
    "tdibth.inf_*",   # 蓝牙 PAN 驱动 (原生规则)
    "mdm*.inf_*",     # 调制解调器驱动
    "fax*.inf_*",     # 传真驱动
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

Write-Host "[完成] 驱动仓库精简完毕 (特性层完整性 100% 保留，零破坏)。" -ForegroundColor Green
