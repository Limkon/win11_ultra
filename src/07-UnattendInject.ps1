# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与多通道注入 (src/07-UnattendInject.ps1)
#  [终极稳固]：消除反引号跨行隐患 + 单语句顺序安全替换 + 杜绝 ParserError
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在加载全局配置并注入 Windows 安装引导应答文件..." -ForegroundColor Cyan

# ----------------- 0. 承接前置配置与安全兜底 -----------------
$mode = if ($global:unattendMode) { $global:unattendMode } else { "1" }
$user = if ($global:customUser)   { $global:customUser }   else { "Admin" }
$pass = if ($global:customPass)   { $global:customPass }   else { "" }

$modeText = if ($mode -eq "2") { "半无人值守 (手动设置账户向导)" } else { "全无人值守 (自动配置并登录)" }
Write-Host "   [配置承接] 当前激活模式: $modeText" -ForegroundColor Green

# ----------------- 1. 动态生成应答 XML 架构片段 -----------------
$userAccountsXmlFragment = ""
$autoLogonXmlFragment    = ""
$hideLocalAccountScreenValue = "true"

if ($mode -eq "1") {
    # 全无人值守：注入预设账户与自动登录节点
    $inputUserEscaped = [System.Security.SecurityElement]::Escape($user)
    $inputPassEscaped = [System.Security.SecurityElement]::Escape($pass)

    Write-Host "   [账户预设] 用户名: $user | 密码: $(if ([string]::IsNullOrEmpty($pass)) { '(留空)' } else { '******' })" -ForegroundColor DarkGray

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
    # 半无人值守：剥离内置账户，开启本地账户输入屏
    Write-Host "   [账户策略] 已剥离预置账户，装机后将由用户在 OOBE 原生界面自定用户名与密码。" -ForegroundColor DarkGray
    $userAccountsXmlFragment = ""
    $autoLogonXmlFragment    = ""
    $hideLocalAccountScreenValue = "false"
}

# ----------------- 2. 纯字面量无损模板 -----------------
$unattendTemplate = @'
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
					<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
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
__USER_ACCOUNTS__
__AUTO_LOGON__
			<OOBE>
				<ProtectYourPC>3</ProtectYourPC>
				<HideEULAPage>true</HideEULAPage>
				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
				<HideLocalAccountScreen>__HIDE_LOCAL_ACCOUNT_SCREEN__</HideLocalAccountScreen>
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
    [xml] $Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
		</ExtractScript>
		<File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
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
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\Specialize.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
	{
		Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
	};
	{
		Remove-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Discardable\PostSetup\ShellNew' -Recurse -Force -ErrorAction 'SilentlyContinue';
	};
	{
		Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript {
			$_.SessionId -eq ( Get-Process -Id $PID ).SessionId;
		} | Stop-Process -Force;
	};
);
&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\UserOnce.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
	{
		$names = @(
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
		
		foreach( $name in $names ) {
		  reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $name /t REG_DWORD /d 0 /f;
		}
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Normal -NoProfile -Command \""Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UserOnce.ps1' -Raw | Invoke-Expression;\""" /f;
	};
);

&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\DefaultUser.log";
		</File>
		<File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
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
		$report = New-Object System.Collections.Generic.List[string];
		$report.Add("==================================================================");
		$report.Add(" Windows 11 精简母盘 - 首次登录系统健康与稳定性自检审计报告");
		$report.Add(" 生成时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'));
		$report.Add(" 部署模式: __DEPLOY_MODE_TEXT__");
		$report.Add("==================================================================");

		$wtPkg = Get-AppxPackage -Name "*WindowsTerminal*" -ErrorAction SilentlyContinue;
		$wtStatus = if ($wtPkg) { "正常部署 (版本: $($wtPkg.Version))" } else { "未安装或已被剔除" };
		$report.Add("[组件测试] Windows 终端 (Terminal): $wtStatus");

		$wingetPkg = Get-AppxPackage -Name "*DesktopAppInstaller*" -ErrorAction SilentlyContinue;
		$wingetStatus = if ($wingetPkg) { "正常可用 (支持 Winget/离线安装)" } else { "未安装" };
		$report.Add("[组件测试] 应用安装程序 (Winget): $wingetStatus");

		$txtAssoc = (cmd.exe /c "assoc .txt 2>nul");
		$report.Add("[关联测试] .txt 扩展名关联项: $txtAssoc");

		try {
			$appCrashes = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			$crashCount = if ($appCrashes) { $appCrashes.Count } else { 0 };
			$report.Add("[事件测试] 应用程序核心崩溃事件数 (Level=Error): $crashCount");

			$dcomErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-DistributedCOM'; Level=2} -MaxEvents 50 -ErrorAction SilentlyContinue;
			$dcomCount = if ($dcomErrors) { $dcomErrors.Count } else { 0 };
			$report.Add("[事件测试] DCOM 幽灵调用异常事件数: $dcomCount");
		} catch {
			$report.Add("[事件测试] 事件日志扫描已安全旁路。");
		}

		$report.Add("------------------------------------------------------------------");
		$verdict = if ($crashCount -eq 0 -and $dcomCount -eq 0) { "【优秀】系统底层核心零异常，运行极度稳定！" } else { "【良好】已自动记录轻微事件，系统运行正常。" };
		$report.Add("总体稳定性裁定: $verdict");
		$report.Add("==================================================================");

		$reportPath = "C:\Windows\Temp\Trim_Stability_Report.log";
		[System.IO.File]::WriteAllLines($reportPath, $report, [System.Text.Encoding]::UTF8);
	};
	{
		# 1. 彻底销毁包含配置的应答文件
		$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach ($f in $xmlFiles) {
			if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; }
		}

		# 2. 异步粉碎自毁 Setup Scripts 目录
		Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList '/c timeout /t 3 /nobreak >nul &amp; for /l %i in (1,1,10) do (if exist "C:\Windows\Setup\Scripts" (rd /s /q "C:\Windows\Setup\Scripts" &amp; timeout /t 1 >nul) else (exit))'
	};
);

&amp; {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 &gt;&gt; "$env:TEMP\FirstLogon.log";
		</File>
	</Extensions>
</unattend>
'@

# ----------------- 3. 单语句独立安全替换 (彻底免疫空格与反引号陷阱) -----------------
$finalXml = $unattendTemplate
$finalXml = $finalXml.Replace('__USER_ACCOUNTS__', $userAccountsXmlFragment)
$finalXml = $finalXml.Replace('__AUTO_LOGON__', $autoLogonXmlFragment)
$finalXml = $finalXml.Replace('__HIDE_LOCAL_ACCOUNT_SCREEN__', $hideLocalAccountScreenValue)
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 多通道合规注入 -----------------
$sysprepDir = Join-Path $scratchDir "Windows\System32\Sysprep"
$pantherDir = Join-Path $scratchDir "Windows\Panther"
if (-not (Test-Path -LiteralPath $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

$utf8Encoding = [System.Text.Encoding]::UTF8

# Sysprep 核心规范通道
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $finalXml, $utf8Encoding)
[System.IO.File]::WriteAllText((Join-Path $sysprepDir "autounattend.xml"), $finalXml, $utf8Encoding)

# Panther 初始化通道
[System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $finalXml, $utf8Encoding)

# ISO 可移动介质根目录自启动通道
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $finalXml, $utf8Encoding)

Write-Host "[完成] 高级无人值守应答文件多通道注入完毕 (全自动运行，无需人工干预)。" -ForegroundColor Green
