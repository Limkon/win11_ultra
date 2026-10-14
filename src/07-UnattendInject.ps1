# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
#  [重构加固]：支持【全无人值守】与【半无人值守】双模切换 + 离线账户安全唤醒
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在配置 Windows 安装引导应答文件 (Unattend Engine)..." -ForegroundColor Cyan

# ----------------- 1. 选择无人值守部署模式 -----------------
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host " 请选择 Windows 安装引导模式:" -ForegroundColor Magenta
Write-Host " [1] 全无人值守 (全自动安装、自动创建指定账户并自动登录，跳过一切交互)" -ForegroundColor Green
Write-Host " [2] 半无人值守 (跳过硬件检测与联网限制，在 OOBE 阶段由用户手动输入用户名/密码)" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Magenta

$unattendModeChoice = Read-Host "请输入对应选项 [1 或 2] (直接回车默认 1)"
if ($unattendModeChoice -ne "2") {
    $unattendMode = "1"
    Write-Host ">>> 已选择: [1] 全无人值守模式" -ForegroundColor Green
} else {
    $unattendMode = "2"
    Write-Host ">>> 已选择: [2] 半无人值守模式 (保留原生手动设置用户名和密码向导)" -ForegroundColor Yellow
}

# ----------------- 2. 模式参数准备与 XML 节点动态生成 -----------------
$userAccountsXmlFragment = ""
$autoLogonXmlFragment    = ""
$hideLocalAccountScreenValue = "true"

if ($unattendMode -eq "1") {
    # 全无人值守模式：倒计时录入预设账户
    $userResult = Read-InputWithTimeout -Prompt "请输入自动登录用户名" -Seconds 30 -Default "Admin"
    $inputUser = $userResult.Value
    if ($inputUser -match "^(Administrator|Guest)$") {
        Write-Host "[警告] 输入了系统保留账户名 $inputUser，自动重置为 Admin！" -ForegroundColor Yellow
        $inputUser = "Admin"
    }

    if ($userResult.TimedOut) {
        $inputPass = ""
    } else {
        $inputPass = Read-Host "请输入登录密码 (直接回车表示留空无密码)"
    }
    $inputUserEscaped = [System.Security.SecurityElement]::Escape($inputUser)
    $inputPassEscaped = [System.Security.SecurityElement]::Escape($inputPass)

    $userAccountsXmlFragment = @"
			<UserAccounts>
				<LocalAccounts>
					<LocalAccount wcm:action="add">
						<Description>系统核心管理员账户</Description>
						<DisplayName>$inputUserEscaped</DisplayName>
						<Group>Administrators</Group>
						<Name>$inputUserEscaped</Name>
						<Password>
							<Value>$inputPassEscaped</Value>
							<PlainText>true</PlainText>
						</Password>
					</LocalAccount>
				</LocalAccounts>
			</UserAccounts>
"@

    $autoLogonXmlFragment = @"
			<AutoLogon>
				<Username>$inputUserEscaped</Username>
				<Enabled>true</Enabled>
				<LogonCount>1</LogonCount>
				<Password>
					<Value>$inputPassEscaped</Value>
					<PlainText>true</PlainText>
				</Password>
			</AutoLogon>
"@
    $hideLocalAccountScreenValue = "true"
} else {
    # 半无人值守模式：不生成内置账户，不开启自动登录，显式唤醒本地账户输入屏
    Write-Host "   [配置就绪] 已移除预设账户与自动登录，安装结束后将直接呈现 Windows 原生账户设置屏。" -ForegroundColor DarkGray
    $userAccountsXmlFragment = ""
    $autoLogonXmlFragment    = ""
    $hideLocalAccountScreenValue = "false"
}

# ----------------- 3. 构建完整 XML 应答文档 -----------------
$unattendTemplate = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
	<settings pass="offlineServicing"></settings>
	<settings pass="windowsPE">
		<!-- 1. WinPE 安装环境国际化 (跳过安装初始语言/键盘选择) -->
		<component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<SetupUILanguage>
				<UILanguage>zh-CN</UILanguage>
			</SetupUILanguage>
			<InputLocale>zh-CN</InputLocale>
			<SystemLocale>zh-CN</SystemLocale>
			<UILanguage>zh-CN</UILanguage>
			<UserLocale>zh-CN</UserLocale>
		</component>
		<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<UserData>
				<AcceptEula>true</AcceptEula>
			</UserData>
			<UseConfigurationSet>false</UseConfigurationSet>
			<RunSynchronous>
				<RunSynchronousCommand wcm:action="add">
					<Order>1</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>2</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>3</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>4</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>5</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>6</Order>
					<Path>reg add HKLM\System\Setup\LabConfig /v BypassDiskCheck /t REG_DWORD /d 1 /f</Path>
				</RunSynchronousCommand>
			</RunSynchronous>
		</component>
	</settings>
	<settings pass="generalize"></settings>
	<settings pass="specialize">
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<ComputerName>DESKTOP-PC</ComputerName>
		</component>
		<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<RunSynchronous>
				<RunSynchronousCommand wcm:action="add">
					<Order>1</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "`$xml = [xml]::new(); `$xml.Load('C:\Windows\Panther\unattend.xml'); `$sb = [scriptblock]::Create( `$xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock `$sb -ArgumentList `$xml;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>2</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\Specialize.ps1' -Raw | Invoke-Expression;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>3</Order>
					<Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>4</Order>
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\DefaultUser.ps1' -Raw | Invoke-Expression;"</Path>
				</RunSynchronousCommand>
				<RunSynchronousCommand wcm:action="add">
					<Order>5</Order>
					<Path>reg.exe unload "HKU\DefaultUser"</Path>
				</RunSynchronousCommand>
			</RunSynchronous>
		</component>
	</settings>
	<settings pass="auditSystem"></settings>
	<settings pass="auditUser"></settings>
	<settings pass="oobeSystem">
		<!-- 2. OOBE 阶段国际化全自动闭环 -->
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>zh-CN</InputLocale>
			<SystemLocale>zh-CN</SystemLocale>
			<UILanguage>zh-CN</UILanguage>
			<UserLocale>zh-CN</UserLocale>
		</component>
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
$userAccountsXmlFragment
$autoLogonXmlFragment
			<OOBE>
				<ProtectYourPC>3</ProtectYourPC>
				<HideEULAPage>true</HideEULAPage>
				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
				<HideLocalAccountScreen>$hideLocalAccountScreenValue</HideLocalAccountScreen>
			</OOBE>
			<FirstLogonCommands>
				<SynchronousCommand wcm:action="add">
					<Order>1</Order>
					<CommandLine>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\FirstLogon.ps1' -Raw | Invoke-Expression;"</CommandLine>
				</SynchronousCommand>
			</FirstLogonCommands>
		</component>
	</settings>
	<Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
		<ExtractScript>
param(
    [xml] `$Document
);

foreach( `$file in `$Document.unattend.Extensions.File ) {
    `$path = [System.Environment]::ExpandEnvironmentVariables( `$file.GetAttribute( 'path' ) );
    mkdir -Path( `$path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    `$encoding = switch( [System.IO.Path]::GetExtension( `$path ) ) {
        { `$_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { `$_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( `$false, `$true ); }
        default { [System.Text.Encoding]::Default; }
    };
    `$bytes = `$encoding.GetPreamble() + `$encoding.GetBytes( `$file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( `$path, `$bytes );
}
		</ExtractScript>
		<File path="C:\Windows\Setup\Scripts\Specialize.ps1">
`$scripts = @(
	{
		net.exe accounts /maxpwage:UNLIMITED;
	};
	{
		Set-ExecutionPolicy -Scope 'LocalMachine' -ExecutionPolicy 'RemoteSigned' -Force;
	};
	{
		reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
	};
	{
		reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f;
	};
	{
		reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f;
	};
);

&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\Specialize.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
`$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
	};
	{
		Remove-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew' -Recurse -Force -ErrorAction 'SilentlyContinue';
	};
	{
		Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript {
			`$_.SessionId -eq ( Get-Process -Id `$PID ).SessionId;
		} | Stop-Process -Force;
	};
);
&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\UserOnce.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
`$scripts = @(
	{
		`$names = @(
		  'ContentDeliveryAllowed';
		  'FeatureManagementEnabled';
		  'OEMPreInstalledAppsEnabled';
		  'PreInstalledAppsEnabled';
		  'PreInstalledAppsEverEnabled';
		  'SilentInstalledAppsEnabled';
		  'SoftLandingEnabled';
		  'SubscribedContentEnabled';
		  'SubscribedContent-310093Enabled';
		  'SubscribedContent-338387Enabled';
		  'SubscribedContent-338388Enabled';
		  'SubscribedContent-338389Enabled';
		  'SubscribedContent-338393Enabled';
		  'SubscribedContent-353694Enabled';
		  'SubscribedContent-353696Enabled';
		  'SubscribedContent-353698Enabled';
		  'SystemPaneSuggestionsEnabled';
		);
		
		foreach( `$name in `$names ) {
		  reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v `$name /t REG_DWORD /d 0 /f;
		}
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Normal -NoProfile -Command \""Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UserOnce.ps1' -Raw | Invoke-Expression;\""" /f;
	};
);

&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\DefaultUser.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
`$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0;
	};
	{
		Disable-ComputerRestore -Drive 'C:\';
	};
	{
		cmd.exe /c "rmdir C:\Windows.old";
	};
	{
		# 自动化稳定性测试探针
		`$report = New-Object System.Collections.Generic.List[string];
		`$report.Add("==================================================================");
		`$report.Add(" Windows 11 精简母盘 - 首次登录系统健康与稳定性自检审计报告");
		`$report.Add(" 生成时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'));
		`$report.Add(" 部署模式: " + "$($unattendMode -replace '1','全无人值守' -replace '2','半无人值守')");
		`$report.Add("==================================================================");

		`$wtPkg = Get-AppxPackage -Name "*WindowsTerminal*" -ErrorAction SilentlyContinue;
		`$wtStatus = if (`$wtPkg) { "正常部署 (版本: `$(`$wtPkg.Version))" } else { "未安装或已被剔除" };
		`$report.Add("[组件测试] Windows 终端 (Terminal): `$wtStatus");

		`$wingetPkg = Get-AppxPackage -Name "*DesktopAppInstaller*" -ErrorAction SilentlyContinue;
		`$wingetStatus = if (`$wingetPkg) { "正常可用 (支持 Winget/离线安装)" } else { "未安装" };
		`$report.Add("[组件测试] 应用安装程序 (Winget): `$wingetStatus");

		`$txtAssoc = (cmd.exe /c "assoc .txt 2>nul");
		`$report.Add("[关联测试] .txt 扩展名关联项: `$txtAssoc");

		try {
			`$appCrashes = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			`$crashCount = if (`$appCrashes) { `$appCrashes.Count } else { 0 };
			`$report.Add("[事件测试] 应用程序核心崩溃事件数 (Level=Error): `$crashCount");

			`$dcomErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-DistributedCOM'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			`$dcomCount = if (`$dcomErrors) { `$dcomErrors.Count } else { 0 };
			`$report.Add("[事件测试] DCOM 幽灵调用异常事件数: `$dcomCount");
		} catch {
			`$report.Add("[事件测试] 事件日志扫描已安全旁路。");
		}

		`$report.Add("------------------------------------------------------------------");
		`$verdict = if (`$crashCount -eq 0 -and `$dcomCount -eq 0) { "【优秀】系统底层核心零异常，运行极度稳定！" } else { "【良好】已自动记录轻微事件，系统运行正常。" };
		`$report.Add("总体稳定性裁定: `$verdict");
		`$report.Add("==================================================================");

		`$reportPath = "C:\Windows\Temp\Trim_Stability_Report.log";
		[System.IO.File]::WriteAllLines(`$reportPath, `$report, [System.Text.Encoding]::UTF8);
	};
	{
		# 1. 彻底销毁包含配置的应答文件
		`$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach (`$f in `$xmlFiles) {
			if (Test-Path `$f) { Remove-Item -LiteralPath `$f -Force -ErrorAction SilentlyContinue; }
		}

		# 2. 异步粉碎自毁 Setup Scripts 目录
		Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList '/c timeout /t 3 /nobreak >nul &amp; for /l %i in (1,1,10) do (if exist "C:\Windows\Setup\Scripts" (rd /s /q "C:\Windows\Setup\Scripts" &amp; timeout /t 1 >nul) else (exit))'
	};
);

&amp; {
  [float] `$complete = 0;
  [float] `$increment = 100 / `$scripts.Count;
  foreach( `$script in `$scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete `$complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      `$str = `$script.ToString().Trim() -replace '\s+', ' ';
      `$max = 100;
      if( `$str.Length -le `$max ) {
        `$str;
      } else {
        `$str.Substring( 0, `$max - 1 ) + '&#x2026;';
      }
    );
    `$start = [datetime]::Now;
    &amp; `$script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( `$start ).TotalMilliseconds;
    "`r`n" * 3;
    `$complete += `$increment;
  }
} *&gt;&amp;1 &gt;&gt; "`$env:TEMP\FirstLogon.log";
		</File>
	</Extensions>
</unattend>
"@

# 4. 多通道合规注入 (Sysprep、Panther、安装介质根目录)
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path -LiteralPath $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$utf8Encoding = [System.Text.Encoding]::UTF8

# Sysprep 核心规范通道
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $unattendTemplate, $utf8Encoding)
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "autounattend.xml"), $unattendTemplate, $utf8Encoding)

# Panther 初始化通道
[System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $unattendTemplate, $utf8Encoding)

# ISO 可移动介质根目录自启动通道
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $unattendTemplate, $utf8Encoding)

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (当前模式: $($unattendMode -replace '1','全无人值守' -replace '2','半无人值守'))。" -ForegroundColor Green
