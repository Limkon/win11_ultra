# ==============================================================================
#  win11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
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
            # 目录递归夺权、提权、解属性并粉碎
            & takeown.exe /F "$Target" /A /R /D Y 2>$null | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$Target\*" /S /D 2>$null
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "rd /s /q `"$Target`"" 2>$null
            }
        } else {
            # 单文件夺权、提权、解属性并粉碎
            & takeown.exe /F "$Target" /A 2>$null | Out-Null
            & icacls.exe "$Target" /grant "*S-1-5-32-544:F" /C /Q 2>$null | Out-Null
            attrib.exe -R -S -H "$Target" 2>$null
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $Target) {
                cmd.exe /c "del /f /q /a `"$Target`"" 2>$null
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
        [string]$HiveName
    )

    # 强制清理 .NET 运行时可能残留的注册表句柄
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
        Start-Sleep -Seconds 1
    }

    Write-Host "   [警告] $HiveName 单元卸载超时，继续推进后续流程。" -ForegroundColor Yellow
    return $false
}

# ----------------- 3. 智能倒计时输入函数 -----------------
function Read-InputWithTimeout {
    <#
    .SYNOPSIS
        带实时倒计时显示、支持退格与回车交互的安全输入读取器
    #>
    param (
        [string]$Prompt = "请输入自定义用户名",
        [int]$Seconds = 30,
        [string]$Default = "Admin"
    )

    # 如果在非控制台环境（如无句柄的自动化流水线），回退到 Read-Host
    try {
        $null = [Console]::KeyAvailable
    } catch {
        $fallback = Read-Host "$Prompt (回车默认: $Default)"
        if ([string]::IsNullOrWhiteSpace($fallback)) { return @{ TimedOut = $false; Value = $Default } }
        return @{ TimedOut = $false; Value = $fallback.Trim() }
    }

    $inputStr = New-Object System.Text.StringBuilder
    $startTime = [DateTime]::Now
    $lastPrinted = -1

    while ($true) {
        $remaining = $Seconds - [int]([DateTime]::Now - $startTime).TotalSeconds
        if ($remaining -le 0 -and $inputStr.Length -eq 0) {
            Write-Host "`n>>> [超时] 超过 $Seconds 秒未输入，已自动采用默认用户名: $Default (密码自动留空)" -ForegroundColor Yellow
            return @{ TimedOut = $true; Value = $Default }
        }

        # 刷新倒计时提示
        if ($inputStr.Length -eq 0 -and $remaining -ne $lastPrinted) {
            $lastPrinted = $remaining
            try { [Console]::CursorLeft = 0 } catch { }
            Write-Host -NoNewline "$Prompt (默认: $Default) [剩余 $remaining 秒]: " -ForegroundColor Cyan
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                $finalText = $inputStr.ToString().Trim()
                if ([string]::IsNullOrWhiteSpace($finalText)) {
                    return @{ TimedOut = $false; Value = $Default }
                }
                return @{ TimedOut = $false; Value = $finalText }
            }
            elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($inputStr.Length -gt 0) {
                    $inputStr.Remove($inputStr.Length - 1, 1) | Out-Null
                    Write-Host -NoNewline "`b `b"
                }
            }
            elseif ($key.KeyChar -ge 32) {
                if ($inputStr.Length -eq 0) {
                    try {
                        [Console]::CursorLeft = 0
                        $blank = " " * [Math]::Max(1, ([Console]::WindowWidth - 1))
                        Write-Host -NoNewline $blank
                        [Console]::CursorLeft = 0
                    } catch { }
                    Write-Host -NoNewline "${Prompt}: " -ForegroundColor Cyan
                }
                $inputStr.Append($key.KeyChar) | Out-Null
                Write-Host -NoNewline $key.KeyChar
            }
        }
        Start-Sleep -Milliseconds 50
    }
}
