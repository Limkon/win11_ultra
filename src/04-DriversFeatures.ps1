# ==============================================================================
#  win11 Builder - [模块 5/11] 驱动仓库精简 (1:1 对齐 nano11)
# ==============================================================================

Write-Host "`n正在精简驱动仓库 (nano11 原版)..." -ForegroundColor Cyan
$driverRepo = Join-Path "$scratchDir\Windows" "System32\DriverStore\FileRepository"

# nano11 原版仅剔除这 7 项无害驱动
$patternsToRemove = @(
    'prn*',
    'scan*',
    'mfd*',
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
                Write-Host "Removing: $driverFolder"
                Remove-Item -Path $_.FullName -Recurse -Force
                break
            }
        }
    }
}
Write-Host "[完成] 驱动精简完毕。" -ForegroundColor Green
