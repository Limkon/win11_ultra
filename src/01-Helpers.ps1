# ==============================================================================
#  Windows 10/11 Builder - [模块 2/11] 核心辅助函数库 (src/01-Helpers.ps1)
#  [本版核心修复]：
#   1. 根治 Invoke-RegSilent 参数转义缺陷：
#      - 旧版将 `'(\\*)("|$)'` 统一替换为 `'$1$1\"$2'`，导致普通含 `\` 路径在行尾 `$`
#        被多拼一个 `\"`（变成带尾引号的假键名），含内嵌双引号与空格的值（如照片查看器）
#        提前闭合外层引号触发 `reg add 错误: 无效语法`。
#      - 新版严格遵循 Win32 CommandLineToArgvW 逆向规范：仅对内嵌 `"` 转义为 `\"`，
#        仅在外层加引号时将末尾连续 `\` 翻倍。
#   2. 新增 Win32 原生离线注册表特权辅助器 (REG_OPTION_BACKUP_RESTORE)：
#      - 解决 TrustedInstaller 独占项（如 Shell Extensions\Blocked）报“拒绝访问”问题；
#      - 零句柄泄漏（每次调用均在 finally 中同步 RegCloseKey），绝不阻塞 reg unload；
#      - 支持快速存在性探测与 NTLite 预精简映像安全服务配置（绝不误建残缺幽灵服务项）。
# ==============================================================================

# ----------------- 0. Win32 离线注册表特权与零句柄泄漏底层组件 -----------------
try {
    if (-not ('Win32Utils.OfflineRegHelper' -as [type])) {
        $offlineRegCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Win32Utils {
    public static class OfflineRegHelper {
        private static readonly IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));
        private const int KEY_QUERY_VALUE = 0x0001;
        private const int KEY_SET_VALUE = 0x0002;
        private const int KEY_CREATE_SUB_KEY = 0x0004;
        private const int KEY_ENUMERATE_SUB_KEYS = 0x0008;
        private const int DELETE = 0x00010000;
        private const int KEY_WOW64_64KEY = 0x0100;
        private const int REG_OPTION_BACKUP_RESTORE = 0x00000004;
        private const uint REG_SZ = 1;
        private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        private const uint TOKEN_QUERY = 0x0008;
        private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
        private static bool _privInitialized = false;

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES {
            public uint PrivilegeCount;
            public LUID Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValueW(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegOpenKeyExW(IntPtr hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegCreateKeyExW(IntPtr hKey, string lpSubKey, int Reserved, string lpClass, int dwOptions, int samDesired, IntPtr lpSecurityAttributes, out IntPtr phkResult, out int lpdwDisposition);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegSetValueExW(IntPtr hKey, string lpValueName, int Reserved, uint dwType, byte[] lpData, int cbData);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegQueryValueExW(IntPtr hKey, string lpValueName, IntPtr lpReserved, out uint lpType, IntPtr lpData, ref int lpcbData);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegEnumKeyExW(IntPtr hKey, uint dwIndex, StringBuilder lpName, ref uint lpcchName, IntPtr lpReserved, IntPtr lpClass, IntPtr lpcchClass, out long lpftLastWriteTime);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegDeleteTreeW(IntPtr hKey, string lpSubKey);

        [DllImport("advapi32.dll")]
        private static extern int RegCloseKey(IntPtr hKey);

        public static void EnsurePrivileges() {
            if (_privInitialized) return;
            IntPtr hToken = IntPtr.Zero;
            try {
                if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken)) {
                    string[] privs = new string[] { "SeBackupPrivilege", "SeRestorePrivilege", "SeTakeOwnershipPrivilege" };
                    for (int i = 0; i < privs.Length; i++) {
                        LUID luid;
                        if (LookupPrivilegeValueW(null, privs[i], out luid)) {
                            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                            tp.PrivilegeCount = 1;
                            tp.Luid = luid;
                            tp.Attributes = SE_PRIVILEGE_ENABLED;
                            AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                        }
                    }
                    _privInitialized = true;
                }
            } finally {
                if (hToken != IntPtr.Zero) CloseHandle(hToken);
            }
        }

        public static bool KeyExists(string subKey) {
            if (string.IsNullOrEmpty(subKey)) return false;
            IntPtr hKey = IntPtr.Zero;
            try {
                int rc = RegOpenKeyExW(HKEY_LOCAL_MACHINE, subKey, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, out hKey);
                return (rc == 0 || rc == 5);
            } finally {
                if (hKey != IntPtr.Zero) RegCloseKey(hKey);
            }
        }

        public static bool ValueExists(string subKey, string valueName) {
            if (string.IsNullOrEmpty(subKey)) return false;
            IntPtr hKey = IntPtr.Zero;
            try {
                int rc = RegOpenKeyExW(HKEY_LOCAL_MACHINE, subKey, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, out hKey);
                if (rc != 0) return false;
                uint vType = 0;
                int cbData = 0;
                int qrc = RegQueryValueExW(hKey, valueName, IntPtr.Zero, out vType, IntPtr.Zero, ref cbData);
                return (qrc == 0 || qrc == 234);
            } finally {
                if (hKey != IntPtr.Zero) RegCloseKey(hKey);
            }
        }

        public static int SetStringValuePrivileged(string subKey, string valueName, string valueData) {
            EnsurePrivileges();
            IntPtr hKey = IntPtr.Zero;
            int disp = 0;
            try {
                int rc = RegCreateKeyExW(
                    HKEY_LOCAL_MACHINE,
                    subKey,
                    0,
                    null,
                    REG_OPTION_BACKUP_RESTORE,
                    KEY_SET_VALUE | KEY_CREATE_SUB_KEY | KEY_WOW64_64KEY,
                    IntPtr.Zero,
                    out hKey,
                    out disp
                );
                if (rc != 0) return rc;
                string text = (valueData == null) ? "" : valueData;
                byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
                return RegSetValueExW(hKey, valueName, 0, REG_SZ, bytes, bytes.Length);
            } finally {
                if (hKey != IntPtr.Zero) RegCloseKey(hKey);
            }
        }

        public static int DeleteSubKeyPrivileged(string subKey) {
            if (!KeyExists(subKey)) return 0;
            EnsurePrivileges();
            int rc = RegDeleteTreeW(HKEY_LOCAL_MACHINE, subKey);
            if (rc == 0 || rc == 2) return 0;
            int lastSlash = subKey.LastIndexOf('\\');
            if (lastSlash <= 0) return rc;
            string parentPath = subKey.Substring(0, lastSlash);
            string childName = subKey.Substring(lastSlash + 1);
            IntPtr hParent = IntPtr.Zero;
            int disp = 0;
            try {
                int prc = RegCreateKeyExW(
                    HKEY_LOCAL_MACHINE,
                    parentPath,
                    0,
                    null,
                    REG_OPTION_BACKUP_RESTORE,
                    DELETE | KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE | KEY_CREATE_SUB_KEY | KEY_WOW64_64KEY,
                    IntPtr.Zero,
                    out hParent,
                    out disp
                );
                if (prc != 0) return prc;
                int drc = RegDeleteTreeW(hParent, childName);
                return (drc == 2) ? 0 : drc;
            } finally {
                if (hParent != IntPtr.Zero) RegCloseKey(hParent);
            }
        }

        public static int CleanTrailingQuoteChildren(string parentSubKey) {
            if (!KeyExists(parentSubKey)) return 0;
            EnsurePrivileges();
            List<string> dirtyNames = new List<string>();
            IntPtr hKey = IntPtr.Zero;
            int disp = 0;
            try {
                int rc = RegCreateKeyExW(
                    HKEY_LOCAL_MACHINE,
                    parentSubKey,
                    0,
                    null,
                    REG_OPTION_BACKUP_RESTORE,
                    KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE | KEY_WOW64_64KEY,
                    IntPtr.Zero,
                    out hKey,
                    out disp
                );
                if (rc != 0) return 0;
                uint index = 0;
                while (true) {
                    uint cchName = 512;
                    StringBuilder sb = new StringBuilder((int)cchName);
                    long ft = 0;
                    int erc = RegEnumKeyExW(hKey, index, sb, ref cchName, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out ft);
                    if (erc == 259) break;
                    if (erc == 0) {
                        string name = sb.ToString();
                        if (name.EndsWith("\"", StringComparison.Ordinal)) {
                            dirtyNames.Add(name);
                        }
                    }
                    index++;
                    if (index > 100000) break;
                }
            } finally {
                if (hKey != IntPtr.Zero) RegCloseKey(hKey);
            }

            int removed = 0;
            for (int i = 0; i < dirtyNames.Count; i++) {
                string fullChild = parentSubKey + "\\" + dirtyNames[i];
                if (DeleteSubKeyPrivileged(fullChild) == 0) {
                    removed++;
                }
            }
            return removed;
        }
    }
}
'@
        $null = Add-Type -TypeDefinition $offlineRegCs -Language CSharp -ErrorAction SilentlyContinue
    }
} catch {}

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
        执行 reg.exe 并返回退出码，彻底免疫管道死锁、引号污染与交互式挂起。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$RegArgs,

        [switch]$Quiet
    )

    # 1. 标准 Win32 CommandLineToArgvW 参数序列化（精准处理空串、空格、内嵌双引号与末尾反斜杠）
    $escapedTokens = foreach ($arg in $RegArgs) {
        if ($null -eq $arg -or $arg.Length -eq 0) {
            '""'
        } elseif ($arg -notmatch '[\s"]') {
            $arg
        } else {
            $escaped = $arg -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"' + $escaped + '"'
        }
    }
    $argumentsString = $escapedTokens -join ' '

    # 2. 构建独立进程环境（直接调用 CreateProcessW，不经由 cmd.exe）
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
        if (-not $Quiet) {
            Write-Host "   [错误] 无法启动 reg.exe: $_" -ForegroundColor Red
        }
        return -1
    }

    # 3. 物理切断标准输入流，防任何 (Yes/No)? 交互提示挂死
    try { $proc.StandardInput.Close() } catch {}
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    # 4. 10 秒硬性超时防护
    $finished = $proc.WaitForExit(10000)
    if (-not $finished) {
        try { $proc.Kill() } catch {}
        try { $proc.WaitForExit() } catch {}
        $proc.Dispose()
        Write-Host "   [严重警告] reg.exe 响应超时已被强制终止: reg.exe $argumentsString" -ForegroundColor Red
        return -1
    }

    $proc.WaitForExit()
    $stdOut = $stdoutTask.Result
    $stdError = $stderrTask.Result
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    # 5. 非静默模式下输出诊断信息
    if ($exitCode -ne 0 -and -not $Quiet) {
        $diagnostic = if (-not [string]::IsNullOrWhiteSpace($stdError)) { $stdError } else { $stdOut }
        if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
            Write-Host ("   [reg 警告 ({0})] {1}" -f $exitCode, $diagnostic.Trim()) -ForegroundColor DarkYellow
        }
    }

    return $exitCode
}

# ----------------- 4. 离线注册表安全探针与幂等读写辅助器 -----------------
function ConvertTo-HklmSubKey {
    param([string]$KeyPath)
    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return "" }
    return ($KeyPath -replace '^(?i)(HKEY_LOCAL_MACHINE|HKLM):?\\', '')
}

function Test-OfflineRegKey {
    <#
    .SYNOPSIS
        零句柄泄漏探测 HKLM 下离线挂载子项是否存在（兼容 NTLite 已精简缺失项）
    #>
    param([Parameter(Mandatory = $true)][string]$SubKey)
    $clean = ConvertTo-HklmSubKey -KeyPath $SubKey
    if ([string]::IsNullOrEmpty($clean)) { return $false }

    $helper = 'Win32Utils.OfflineRegHelper' -as [type]
    if ($helper) {
        return [bool]$helper::KeyExists($clean)
    }
    return ((Invoke-RegSilent -RegArgs @('query', "HKLM\$clean") -Quiet) -eq 0)
}

function Test-OfflineRegValue {
    <#
    .SYNOPSIS
        零句柄泄漏探测 HKLM 下指定注册表值是否存在
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$ValueName
    )
    $clean = ConvertTo-HklmSubKey -KeyPath $SubKey
    if ([string]::IsNullOrEmpty($clean)) { return $false }

    $helper = 'Win32Utils.OfflineRegHelper' -as [type]
    if ($helper) {
        return [bool]$helper::ValueExists($clean, $ValueName)
    }
    return ((Invoke-RegSilent -RegArgs @('query', "HKLM\$clean", '/v', $ValueName) -Quiet) -eq 0)
}

function Remove-OfflineRegKey {
    <#
    .SYNOPSIS
        幂等删除离线注册表子项：仅在键存在时删除，避免对 NTLite 已删项狂刷报错
    #>
    param([Parameter(Mandatory = $true)][string]$SubKey)
    $clean = ConvertTo-HklmSubKey -KeyPath $SubKey
    if (-not (Test-OfflineRegKey -SubKey $clean)) {
        return $false
    }
    $rc = Invoke-RegSilent -RegArgs @('delete', "HKLM\$clean", '/f') -Quiet
    if ($rc -eq 0) { return $true }

    $helper = 'Win32Utils.OfflineRegHelper' -as [type]
    if ($helper) {
        return ($helper::DeleteSubKeyPrivileged($clean) -eq 0)
    }
    return $false
}

function Remove-OfflineRegValue {
    <#
    .SYNOPSIS
        幂等删除离线注册表键值：仅在值存在时删除
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$ValueName
    )
    $clean = ConvertTo-HklmSubKey -KeyPath $SubKey
    if (-not (Test-OfflineRegValue -SubKey $clean -ValueName $ValueName)) {
        return $false
    }
    return ((Invoke-RegSilent -RegArgs @('delete', "HKLM\$clean", '/v', $ValueName, '/f') -Quiet) -eq 0)
}

function Set-OfflineRegSzPrivileged {
    <#
    .SYNOPSIS
        使用 SeRestorePrivilege (REG_OPTION_BACKUP_RESTORE) 写入受 TrustedInstaller 保护的离线注册表项
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [AllowEmptyString()][string]$ValueData = ""
    )
    $clean = ConvertTo-HklmSubKey -KeyPath $SubKey
    $helper = 'Win32Utils.OfflineRegHelper' -as [type]
    if ($helper) {
        $rc = $helper::SetStringValuePrivileged($clean, $ValueName, $ValueData)
        if ($rc -eq 0) { return 0 }
        Write-Host "   [reg 特权写入警告 ($rc)] HKLM\$clean -> $ValueName" -ForegroundColor DarkYellow
        return $rc
    }
    return (Invoke-RegSilent -RegArgs @('add', "HKLM\$clean", '/v', $ValueName, '/t', 'REG_SZ', '/d', $ValueData, '/f'))
}

function Get-OfflineControlSets {
    <#
    .SYNOPSIS
        枚举离线 SYSTEM 配置单元中实际存在的 ControlSet00x（替代离线不存在的 CurrentControlSet）
    #>
    param([string]$SystemHiveMount = 'zSYSTEM')
    $found = @()
    foreach ($cs in @('ControlSet001', 'ControlSet002', 'ControlSet003', 'ControlSet004')) {
        if (Test-OfflineRegKey -SubKey "$SystemHiveMount\$cs") {
            $found += $cs
        }
    }
    if ($found.Count -eq 0) { return @('ControlSet001') }
    return $found
}

function Set-OfflineServiceStart {
    <#
    .SYNOPSIS
        安全修改离线服务启动类型：仅当服务项真实存在时才写入 Start，
        严防对已被 NTLite 物理移除的服务误创建缺少 ImagePath/Type 的残缺幽灵服务项。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][int]$StartType,
        [string]$SystemHiveMount = 'zSYSTEM'
    )
    $updated = $false
    foreach ($cs in (Get-OfflineControlSets -SystemHiveMount $SystemHiveMount)) {
        $svcKey = "$SystemHiveMount\$cs\Services\$ServiceName"
        if (Test-OfflineRegKey -SubKey $svcKey) {
            $rc = Invoke-RegSilent -RegArgs @('add', "HKLM\$svcKey", '/v', 'Start', '/t', 'REG_DWORD', '/d', ([string]$StartType), '/f')
            if ($rc -eq 0) { $updated = $true }
        }
    }
    return $updated
}
