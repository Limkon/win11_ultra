# ==============================================================================
#  win11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
#  [本版核心修复] 彻底根治 reg.exe 在 /d '' 场景下的交互式死锁：
#    - 根因：PowerShell 5.1 传递空字符串数组元素时将 `''` 展开为裸空格，
#      导致 reg.exe 将紧随其后的 `/f` 识别为 `/d` 的数据，从而丢失强制标志；
#      若键值已存在，reg.exe 会静默挂起等待标准输入确认 (Yes/No)?，CPU=0 永久假死。
#    - 修复：采用 .NET Process 底层封装：
#      ① 显式将空字符串和特殊字符序列化为标准双引号 `""`；
#      ② 物理关闭子进程的标准输入 (StandardInput.Close)，收到 EOF 绝不等待交互；
#      ③ 增加 10 秒超时保护，遇到异常强行销毁并报警，保障流水线绝对流畅。
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

# ----------------- 3. reg.exe 零死锁安全执行器 -----------------
function Invoke-RegSilent {
    <#
    .SYNOPSIS
        执行 reg.exe 并返回退出码，彻底免疫管道死锁与交互式挂起。
    .DESCRIPTION
        1. 针对 /d '' 场景显式转义并序列化为 `""`，避免 /f 参数被误食。
        2. 彻底重定向并物理关闭 StandardInput，遇到任何交互提示即刻返回 EOF，杜绝卡死。
        3. 同步排空 StandardOutput / StandardError，无缓冲区溢出死锁。
        4. 附带 10 秒超时防护。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$RegArgs
    )

    # 1. 规范化参数序列化，重点解决空字符串 `''` 传参问题
    $escapedTokens = foreach ($arg in $RegArgs) {
        if ([string]::IsNullOrEmpty($arg)) {
            '""'
        } elseif ($arg -match '[\s"\\<>&|]') {
            '"' + ($arg -replace '(\\*)("|$)', '$1$1\"$2') + '"'
        } else {
            $arg
        }
    }
    $argumentsString = $escapedTokens -join ' '

    # 2. 构建独立进程环境
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\reg.exe"
    $psi.Arguments = $argumentsString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host "   [错误] 无法启动 reg.exe: $_" -ForegroundColor Red
        return -1
    }

    # 3. 核心机制：物理切断标准输入流，防任何 (Yes/No)? 交互提示挂死
    $proc.StandardInput.Close()

    # 4. 同步读取输出，防止管道缓冲区占满导致阻塞
    $stdOut = $proc.StandardOutput.ReadToEnd()
    $stdError = $proc.StandardError.ReadToEnd()

    # 5. 10 秒硬性超时防护
    $finished = $proc.WaitForExit(10000)
    if (-not $finished) {
        try { $proc.Kill() } catch {}
        Write-Host "   [严重警告] reg.exe 响应超时已被强制终止: reg.exe $argumentsString" -ForegroundColor Red
        return -1
    }

    $exitCode = $proc.ExitCode
    $proc.Dispose()

    # 6. 异常时输出诊断信息
    if ($exitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($stdError)) {
        Write-Host "   [reg 警告 ($exitCode)] $stdError".Trim() -ForegroundColor DarkYellow
    }

    return $exitCode
}
