# ==============================================================================
#  win11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
#  [本版修复] Invoke-RegSilent 方案 D：& reg.exe @RegArgs 直接调用
#    - 根因：原密集 `& 'reg' ... 2>&1 | Out-Null` 在连续调用时触发 PowerShell
#      匿名管道 + Out-Null 同步消费 + & 同步等待子进程的三重叠加单线程死锁
#      （reg.exe WaitReason=Executive, CPU=0 永久挂起）。
#    - 方案 D：& reg.exe @RegArgs 直接调用，不接任何管道/重定向/Start-Process。
#      reg.exe 的 stdout/stderr 继承父 console 句柄，同步写入 console 子系统，
#      不经过 PowerShell 匿名管道 → 零管道、零缓冲区、零调度死锁。
#      同时绕过 Start-Process 的两个坑：
#        ① -RedirectStandardOutput/Error 不能指向同一文件（含 "NUL"/"nul"）
#        ② -ArgumentList 拒绝含空字符串元素的数组（/d '' 场景）
#    - 副作用（有意保留）：reg.exe 输出会打印到控制台/日志，
#      使每条注册表操作的真实结果可见，失败时紧跟 错误: ... 行，便于追溯。
#  [保留] Force-NukeFolderOrFile / Safely-UnloadHive 字节级不变。
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

# ----------------- 3. reg.exe 直接执行器 (根治管道死锁) -----------------
function Invoke-RegSilent {
    <#
    .SYNOPSIS
        执行 reg.exe 并返回退出码，完全绕开 PowerShell 管道死锁。
    .DESCRIPTION
        本次卡死根因：主脚本密集调用 `& 'reg' 'add' ... 2>&1 | Out-Null`，
        PowerShell 的匿名管道 + Out-Null 同步消费 + & 同步等待子进程退出，
        三者叠加形成单线程死锁（reg.exe WaitReason=Executive, CPU=0 永久挂起）。

        本函数用 `& reg.exe @RegArgs` 直接调用：
          - reg.exe 的 stdout/stderr 继承父进程 console 句柄
          - 输出同步写入 console 子系统，不经过 PowerShell 匿名管道
          - 无管道缓冲区、无 Out-Null 消费、无单线程调度死锁

        同时绕开 Start-Process 的两个坑：
          - ① -RedirectStandardOutput/Error 不能指向同一文件（含 "NUL"/"nul"）
          - ② -ArgumentList 拒绝含空字符串元素的数组（/d '' 场景）

        副作用（有意保留）：reg.exe 输出会打印到控制台/日志，
        使每条注册表操作的真实结果可见。失败时紧跟 "错误: ..." 行，便于追溯。
    .PARAMETER RegArgs
        reg.exe 的完整参数数组，每个元素对应一个独立 argv token。
        带空格 / 中文 / % / & / | / 空字符串的值作为单个数组元素传入即可，
        splatting 机制自动处理引号，无需手动转义。
    .EXAMPLE
        Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\.txt', '/ve', '/t', 'REG_SZ', '/d', 'txtfile', '/f')
        Invoke-RegSilent @('add', 'HKLM\zSOFTWARE\Classes\.txt\ShellNew', '/v', 'NullFile', '/t', 'REG_SZ', '/d', '', '/f')
    .OUTPUTS
        System.Int32 - reg.exe 退出码（成功 0，失败非 0）
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$RegArgs
    )

    # 直接调用，不接任何管道/重定向/Start-Process：
    #   - 空字符串元素（/d ''）作为独立 argv token 正常传给 reg.exe
    #   - %、&、|、空格、中文全部安全（splatting 不经过 cmd 解析）
    #   - 输出打印到控制台/日志，真实结果可追溯
    & reg.exe @RegArgs
    return $LASTEXITCODE
}
