# ==============================================================================
#  Windows 10/11 Builder - [模块 5/11] 驱动仓库与 .NET 缓存清理 (src/04-DriversFeatures.ps1)
#  [重构核心]：
#   1. 普通模式 (健康精简)：
#      - 完整保留 DriverStore (FileRepository)，杜绝因缺失系统级基础驱动导致
#        新插打印机、蓝牙、网卡、显卡报 0x00000002 或驱动安装中断故障。
#      - 仅安全清理可重构的过期 .NET Native Images 缓存（系统空闲时会自动重构）。
#   2. 极限模式 (极限压榨)：
#      - 执行激进 DriverStore 瘦身，但【绝对豁免所有打印驱动 prn* 与一体机扫描驱动 wscsmd*】，
#        确保虚拟打印 (Print to PDF)、通用打印类驱动及打印向导在极限模式下绝对可用。
# ==============================================================================

Write-Host "`n[步骤 6/11] 正在执行 DriverStore 精简与 .NET 原生映像清理..." -ForegroundColor Cyan

# ----------------- 1. 通用阶段：移除 pre-compiled .NET assemblies (Native Images) -----------------
Write-Host "Cleaning pre-compiled .NET assemblies (Native Images)..." -ForegroundColor DarkGray

$nativeSearchPaths = @(
    "$scratchDir\Windows\assembly\NativeImages_*",
    "$scratchDir\Windows\Microsoft.NET\assembly\NativeImages_*"
)

foreach ($searchPath in $nativeSearchPaths) {
    $matchedItems = Get-Item -Path $searchPath -ErrorAction SilentlyContinue
    if ($matchedItems) {
        foreach ($item in $matchedItems) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----------------- 2. 驱动仓库按模式差异化处理 -----------------
$winDir = "$scratchDir\Windows"
$driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"

if ($global:trimMode -eq "2") {
    # --------------------------------------------------------------------------
    # 极限压榨模式：清理非关键硬件总线驱动，但【坚决保留所有打印相关驱动】
    # 绝对排除：prnms00* (Print to PDF/通用打印类), prnca00*, prnkm00*, wscsmd* (WIA扫描)
    # --------------------------------------------------------------------------
    Write-Host ">>> [极限压榨模式] 正在精简 DriverStore 非关键总线驱动 (已锁定保护打印驱动)..." -ForegroundColor Yellow

    # 剔除了所有 prn* 及扫描仪驱动，仅清理真正冗余的虚拟总线
    $patternsToRemove = @(
        'tapdrv*',
        'rdpbus.inf*',
        'tdibth.inf*'
    )

    if (Test-Path -LiteralPath $driverRepo) {
        $repoFolders = Get-ChildItem -LiteralPath $driverRepo -Directory -ErrorAction SilentlyContinue
        if ($repoFolders) {
            foreach ($folder in $repoFolders) {
                $driverName = $folder.Name
                foreach ($pattern in $patternsToRemove) {
                    if ($driverName -like $pattern) {
                        Write-Host "   [极限瘦身] 移除驱动包: $driverName" -ForegroundColor DarkGray
                        attrib.exe -R -S -H "$($folder.FullName)\*" /S /D 2>&1 | Out-Null
                        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        break
                    }
                }
            }
        }
    }
    Write-Host "[完成] 驱动仓库极限瘦身完毕（打印基础驱动已完整保留）。" -ForegroundColor Green
} else {
    # --------------------------------------------------------------------------
    # 普通健康模式：坚决不碰驱动仓库，保障 100% 硬件生态与即插即用完整性
    # --------------------------------------------------------------------------
    Write-Host "   [普通健康模式] 完整保留 DriverStore 驱动仓库，确保全系硬件即插即用、打印机与外设驱动链路绝对完整。" -ForegroundColor Green
}

Write-Host "[完成] 驱动与底层运行库缓存阶段处理完毕。" -ForegroundColor Green
