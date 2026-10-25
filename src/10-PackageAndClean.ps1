# ==============================================================================
#  win11 Builder - [模块 11/11] ISO 最终打包与临时缓存清理 (src/10-PackageAndClean.ps1)
# ==============================================================================

Write-Host "`n[步骤 12/12] 正在校验引导资产并打包最终 ISO 镜像..." -ForegroundColor Cyan

# ----------------- 0. 响应该阶段 ESD 极限高压转换开关 -----------------
$esdEnabled = if ($null -ne $global:enableEsdConversion) { [bool]$global:enableEsdConversion } else { $false }

$destWimPath = Join-Path $sourcesDir "install.wim"
$destEsdPath = Join-Path $sourcesDir "install.esd"

if ($esdEnabled) {
    if (Test-Path -LiteralPath $destWimPath) {
        Write-Host ">>> [ESD 转换开启] 正在将 install.wim 高压转换为 install.esd (此过程需要较多 CPU 资源)..." -ForegroundColor Yellow
        & dism.exe /English /Export-Image "/SourceImageFile:$destWimPath" "/SourceIndex:1" "/DestinationImageFile:$destEsdPath" /Compress:recovery /CheckIntegrity

        if (Test-Path -LiteralPath $destEsdPath) {
            Remove-Item -LiteralPath $destWimPath -Force -ErrorAction SilentlyContinue
            Write-Host "[完成] 最终映像已成功转换为 ESD 极限高压格式！" -ForegroundColor Green
        } else {
            Write-Host "[警告] ESD 转换异常，安全保留原始 install.wim 进行打包。" -ForegroundColor Yellow
        }
    }
}

# ----------------- 1. 探测或自动拉取现代化 Oscdimg.exe 打包引擎 -----------------
$oscdimgExe = Join-Path $scriptDir "oscdimg.exe"

if (-not (Test-Path -LiteralPath $oscdimgExe)) {
    $adkOscdimg = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    if (Test-Path -LiteralPath $adkOscdimg) {
        Write-Host "从本地 Windows ADK 检测到 oscdimg.exe，正在提取..." -ForegroundColor Green
        Copy-Item -LiteralPath $adkOscdimg -Destination $oscdimgExe -Force
    } else {
        Write-Host "正在拉取支持现代 UEFI/UDF 2.0 规范的 oscdimg.exe 打包内核..." -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        $oscdimgUrl = "https://ghproxy.net/https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe"
        try {
            Invoke-WebRequest -Uri $oscdimgUrl -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 30
        } catch {
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/driver1998/oscdimg/master/oscdimg.exe" -OutFile $oscdimgExe -UseBasicParsing -TimeoutSec 15
            } catch {
                Write-Host "[严重错误] oscdimg.exe 自动下载失败！请手动将 Windows ADK 的 oscdimg.exe 放入脚本目录后再运行！" -ForegroundColor Red
                if ($global:transcriptActive) { Stop-Transcript }
                pause
                exit 1
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $oscdimgExe)) {
    Write-Host "[严重错误] 缺失 oscdimg.exe 打包引擎，打包阻断！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# 下载/复制后校验 PE 头与文件大小，防止 HTML 错误页或损坏文件被误用
try {
    $fi = Get-Item -LiteralPath $oscdimgExe
    $headBytes = [System.IO.File]::ReadAllBytes($oscdimgExe)
    $isPE = ($headBytes.Length -ge 2 -and $headBytes[0] -eq 0x4D -and $headBytes[1] -eq 0x5A)
    if ($fi.Length -lt 100KB -or -not $isPE) {
        Remove-Item -LiteralPath $oscdimgExe -Force -ErrorAction SilentlyContinue
        Write-Host "[严重错误] oscdimg.exe 校验失败（文件过小或非 PE 可执行），请手动放置 ADK 的 oscdimg.exe！" -ForegroundColor Red
        if ($global:transcriptActive) { Stop-Transcript }
        pause
        exit 1
    }
} catch {
    Write-Host "[严重错误] oscdimg.exe 校验异常: $_" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 2. 严密校验 Legacy + UEFI 双模引导引导文件 -----------------
$outputISO = Join-Path $scriptDir "win11_ultra_v7.iso"
$etfsboot  = Join-Path $workDir "boot\etfsboot.com"

# 优先选用免按任意键直进安装向导的 efisys_noprompt.bin
$efisys = Join-Path $workDir "efi\microsoft\boot\efisys_noprompt.bin"
if (-not (Test-Path -LiteralPath $efisys)) {
    $efisys = Join-Path $workDir "efi\microsoft\boot\efisys.bin"
}

if (-not (Test-Path -LiteralPath $etfsboot) -or -not (Test-Path -LiteralPath $efisys)) {
    Write-Host "[严重错误] 关键双模引导扇区镜像不存在！" -ForegroundColor Red
    Write-Host "缺少文件: etfsboot.com (BIOS) 或 efisys.bin/efisys_noprompt.bin (UEFI)" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 3. 构建合规双模启动参数并打包生成 ISO -----------------
Write-Host "正在合成 Legacy BIOS + UEFI 双模自启动引导扇区..." -ForegroundColor Yellow

# 路径加引号，支持工作目录含空格 (如 D:\My Build\win11)
$bootDataParam = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""

# 参数解析:
# -m: 允许生成大于 4.7GB 的 ISO
# -o: 优化重复文件存储 (单实例优化)
# -u2: 仅生成 UDF 文件系统
# -udfver102: UDF 1.02 兼容格式 (兼容几乎所有 BIOS/UEFI 固件)
# -h: 包含源目录中的所有隐藏文件 (关键！保证 boot.sdi 等不丢失)
# -l: 指定 ISO 卷标
$oscdimgArgs = @(
    "-m",
    "-o",
    "-u2",
    "-udfver102",
    "-h",
    "-lWIN11_ULTRA",
    "-bootdata:$bootDataParam",
    "$workDir",
    "$outputISO"
)

# 清理可能存在的旧镜像文件
if (Test-Path -LiteralPath $outputISO) {
    Remove-Item -LiteralPath $outputISO -Force -ErrorAction SilentlyContinue
}

Write-Host "正在执行 ISO 最终打包封装 (展示 Oscdimg 打包进度)..." -ForegroundColor Green
& $oscdimgExe @oscdimgArgs

if (-not (Test-Path -LiteralPath $outputISO)) {
    Write-Host "[严重错误] ISO 打包生成失败！" -ForegroundColor Red
    if ($global:transcriptActive) { Stop-Transcript }
    pause
    exit 1
}

# ----------------- 4. 汇总展示与收尾清理 -----------------
$isoSizeMB = [math]::Round((Get-Item -LiteralPath $outputISO).Length / 1MB, 2)
$isoSizeGB = [math]::Round((Get-Item -LiteralPath $outputISO).Length / 1GB, 2)

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "      全部构建流程圆满完成！ISO 引导镜像已生成: " -ForegroundColor Green
Write-Host "      路径: $outputISO" -ForegroundColor Yellow
Write-Host "      体积: $isoSizeMB MB ($isoSizeGB GB)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green

Write-Host "`n请按回车键 [ENTER] 执行临时挂载点清理并退出构建..." -ForegroundColor DarkGray
pause

Write-Host "正在清理临时工作区与残留挂载点..." -ForegroundColor DarkGray
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /Discard 2>&1 | Out-Null
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

if ($global:transcriptActive) {
    Stop-Transcript
    Start-Sleep -Milliseconds 300
}
