# ==============================================================================
#  win11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
#  [本版新增] Invoke-RegSilent：
#    - 用 Start-Process + -RedirectStandardOutput/Error "NUL" 执行 reg.exe
#    - 文件句柄级重定向（CreateProcess STARTUPINFO.hStdOutput = NUL），
#      完全绕开 PowerShell 匿名管道，根治"连续 & reg ... | Out-Null 密集
#      调用导致 PowerShell 单线程管道调度死锁 + reg.exe WaitReason=Executive
#      CPU=0 永久挂起"问题（本次卡死根因）
#    - 数组参数形式，调用方无需手动引号转义，% & | ; 空格全部安全
#    - 保留原 Force-NukeFolderOrFile / Safely-UnloadHive 字节级不变
# ==============================================================================

# ----------------- 1. 终极物理粉碎函数 -----------------
function Force-NukeFolderOrFile {
    <#
    .SYNOPSIS
        强行接管文件/文件夹所有权，注入最高权限并彻底粉碎删除
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return }

        if ($item.PSIsContainer) {
            & takeown.exe /F "$Target" /A /R /D Y 2>&1 | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
            # 仅当目录存在子项时才启动 attrib，避免空目录无谓进程启动
            if (Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue) {
                attrib.exe -R -S -H "$Target\*" /S /D 2>&1 | Out-Null
            }
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "rd /s /q `"$Target`"" 2>&1 | Out-Null
            }
        } else {
            & takeown.exe /F "$Target" /A 2>&1 | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /C /Q 2>&1 | Out-Null
            attrib.exe -R -S -H "$Target" 2>&1 | Out-Null
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "del /f /q /a `"$Target`"" 2>&1 | Out-Null
            }
        }
    }
}

# ----------------- 2. 注册表安全卸载函数 (防死锁/重试机制) -----------------
function Safely-UnloadHive {
    <#
    .SYNOPSIS
        带有垃圾回收与 5 次重试容错机制的离线注册表 Hive 卸载器
    .PARAMETER HiveName
        完整 Hive 路径，必须包含 HKLM\ 前缀（例如 "HKLM\zSYSTEM"）
    .PARAMETER AbortOnFailure
        默认 $false：5 次重试失败后仅警告并继续（原版行为，向后兼容）
        $true：卸载失败立即停止 transcript、pause 并 exit 1，
               供关键 hive（如 06 模块第一轮 zSOFTWARE）使用
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$HiveName,

        [bool]$AbortOnFailure = $false
    )

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    for ($i = 1; $i -le 5; $i++) {
        $null = & reg.exe unload "$HiveName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   [卸载完成] 注册表配置单元: $HiveName" -ForegroundColor DarkGray
            return $true
        }
        Write-Host "   [等待句柄释放] 正在尝试第 $i 次重试卸载 $HiveName..." -ForegroundColor DarkYellow

        # 每次重试前做一次 GC 回收窗口，提升 svchost 句柄释放成功率
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1
    }

    if ($AbortOnFailure) {
        Write-Host "[严重错误] $HiveName 单元卸载超时（5 次重试全部失败），为避免半挂载态污染后续操作，流程中止。" -ForegroundColor Red
        Write-Host "           可能原因：svchost 仍持有该 hive 句柄，建议重启系统后重试。" -ForegroundColor Yellow
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }

    Write-Host "   [警告] $HiveName 单元卸载超时，继续推进后续流程。" -ForegroundColor Yellow
    return $false
}

# ----------------- 3. reg.exe 静默执行器 (根治管道死锁) -----------------
# 模块级共享临时文件：Start-Process 的 -RedirectStandardOutput/Error 不允许
# 两个参数指向同一文件（"NUL" 与 "nul" 在 Start-Process 的字符串比较里仍被判相同），
# 因此用两个不同的 TEMP 文件，一次性创建、全程复用，避免 340 次文件 I/O。
$script:InvokeRegStdOut = [System.IO.Path]::GetTempFileName()
$script:InvokeRegStdErr = [System.IO.Path]::GetTempFileName()

function Invoke-RegSilent {
    <#
    .SYNOPSIS
        执行 reg.exe 并静默丢弃 stdout/stderr，彻底绕开 PowerShell 管道死锁。
    .DESCRIPTION
        本次卡死根因：主脚本密集调用 `& 'reg' 'add' ... 2>&1 | Out-Null`，
        PowerShell 的匿名管道 + `Out-Null` 同步消费 + `&` 同步等待子进程退出，
        三者叠加形成单线程死锁（reg.exe WaitReason=Executive, CPU=0 永久挂起）。
        本函数改用 Start-Process 的 -RedirectStandardOutput/Error 指向两个不同的
        TEMP 文件（Start-Process 不允许两个重定向参数指向同一文件），
        由 CreateProcess 直接把子进程 stdout/stderr 句柄指向文件，
        子进程输出同步写文件丢弃，无管道、无缓冲区、无调度死锁。
    .PARAMETER RegArgs
        reg.exe 的完整参数数组，每个元素对应一个独立 argv token。
        带空格 / 中文 / % / & / | 的值作为单个数组元素传入即可，
        PowerShell 自动加引号，无需手动转义。
        允许空字符串元素（如 /d ''），供 NullFile / AlwaysShowExt 等空值场景使用。
    .EXAMPLE
        Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\.txt', '/ve', '/t', 'REG_SZ', '/d', 'txtfile', '/f')
    .OUTPUTS
        System.Int32 - reg.exe 退出码（成功 0，失败非 0，进程启动失败 -1）
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$RegArgs
    )

    try {
        $p = Start-Process -FilePath "reg.exe" -ArgumentList $RegArgs -Wait -NoNewWindow -PassThru `
                           -RedirectStandardOutput $script:InvokeRegStdOut `
                           -RedirectStandardError  $script:InvokeRegStdErr `
                           -ErrorAction Stop
        if ($null -eq $p) { return -1 }
        return $p.ExitCode
    } catch {
        return -1
    }
}
