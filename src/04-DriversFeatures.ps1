# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动仓库与 .NET 缓存清理 (src/04-DriversFeatures.ps1)
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行 DriverStore 精简与 .NET 原生映像清理..." -ForegroundColor Cyan

# 1. 移除 pre-compiled .NET assemblies (覆盖旧版与新路径)
Write-Host "Removing pre-compiled .NET assemblies (Native Images)..."
$nativeImagePaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)
foreach ($p in $nativeImagePaths) {
    Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. 驱动仓库激进瘦身
# 注：仅删除通用打印/扫描类 INF 前缀，保留厂商专用驱动；
#     原 'scan*'、'mfd*' 通配符会误伤扫描仪与多功能设备核心驱动，已收窄。
$winDir = "$scratchDir\Windows"
Write-Host "Slimming the DriverStore... (removing non-essential driver classes)"
$driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
$patternsToRemove = @(
    'prnms00*',
    'prnms001*',
    'prnms002*',
    'prnms003*',
    'prnms004*',
    'prnms005*',
    'prnca00*',
    'prnkm00*',
    'wscsmd.inf*',
    'tapdrv*',
    'rdpbus.inf*',
    'tdibth.inf*'
)

if (Test-Path $driverRepo) {
    Get-ChildItem -Path $driverRepo -Directory | ForEach-Object {
        $driverFolder = $_.Name
        foreach ($pattern in $patternsToRemove) {
            if ($driverFolder -like $pattern) {
                Write-Host "Removing non-essential driver package: $driverFolder"
                attrib.exe -R -S -H "$($_.FullName)\*" /S /D 2>&1 | Out-Null
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
}
Write-Host "[完成] 驱动与底层运行库缓存精简完毕。" -ForegroundColor Green
