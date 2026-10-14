# ==============================================================================
#  win11 Builder - [模块 9/11] WinSxS 优化与主映像提交卸载 (src/08-WinSxSOptimize.ps1)
#  [架构重构]：彻底废除破坏性物理换头 + 拥抱官方 ResetBase 终极硬核精炼
# ==============================================================================

Write-Host "`n[步骤 10/11] 正在执行组件库深度瘦身与补丁清理..." -ForegroundColor Cyan

# ----------------- 模式分支：WinSxS 官方规范化深度精炼 -----------------
if ($trimMode -eq "2") {
    Write-Host ">>> [极限模式生效] 执行官方最高级 ResetBase 终极基准重置 (展示原生百分比进度条)..." -ForegroundColor Yellow
    Write-Host "    (此过程正在深度粉碎所有历史冗余补丁并折叠硬链接，绝不破坏组件完整性，耗时约 2~5 分钟)" -ForegroundColor DarkGray

    # 官方基准重置：彻底清除历史更新备份，将当前版本固化为基础基线，体积减小最激进且 100% 稳定
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
} else {
    Write-Host ">>> [普通模式生效] 执行官方标准 StartComponentCleanup 组件清理 (展示原生百分比进度条)..." -ForegroundColor Green
    & dism.exe /English /Image:$scratchDir /Cleanup-Image /StartComponentCleanup
}

# ----------------- 提交并卸载主系统映像 -----------------
Write-Host "`n正在回收句柄资源并准备提交主映像..." -ForegroundColor DarkGray
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

Write-Host "正在提交更改并卸载 install.wim (展示官方原生百分比进度条)..." -ForegroundColor Cyan
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit

if ($LASTEXITCODE -ne 0) {
    Write-Host "[警告] 主映像初次提交遇到阻碍，正在进行安全重试..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 3
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Commit
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "[完成] 主映像已成功保存并安全提交更改。" -ForegroundColor Green
} else {
    Write-Host "[严重错误] 主映像提交失败，请检查是否有文件被资源管理器或杀毒软件占用！" -ForegroundColor Red
}
