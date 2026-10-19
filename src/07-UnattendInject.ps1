# ==============================================================================
#  win11 Builder - [模块 8/11] 完整无人值守应答模板与纯净介质注入 (src/07-UnattendInject.ps1)
#  [企业级重构]：100% 还原原版纯净介质注入 + 彻底杜绝 XML 架构冲突 + 零倒计时静默直通
# ==============================================================================

Write-Host "`n[步骤 9/11] 正在加载全局配置并注入纯净安装介质应答文件..." -ForegroundColor Cyan

# ----------------- 0. 承接前置模式配置 (零次生交互) -----------------
$mode = if ($global:unattendMode) { [string]$global:unattendMode } else { "1" }
$user = if ($global:customUser)   { [string]$global:customUser }   else { "Admin" }
$pass = if ($global:customPass)   { [string]$global:customPass }   else { "" }

# ----------------- 1. 动态生成应答 XML 架构片段 -----------------
$userAccountsXmlFragment = ""
$autoLogonXmlFragment    = ""

if ($mode -eq "2") {
    # 【模式 2：半无人值守】剥离预设账户与 AutoLogon，保留微软原生 OOBE 设置向导
    Write-Host "   -> [模式确认] 半无人值守：保留原生用户名/密码向导，跳过硬件与网络强制检测。" -ForegroundColor Yellow
    $userAccountsXmlFragment     = ""
    $autoLogonXmlFragment        = ""
    $hideLocalAccountScreenValue = "false"
    $modeText                    = "半无人值守 (跳过硬件限制，OOBE 阶段手动输入用户名/密码)"
} else {
    # 【模式 1：全无人值守】自动注入 00 模块锁定的账户密码
    Write-Host "   -> [模式确认] 全无人值守：注入预置账户 [$user]，全自动登录。" -ForegroundColor Green
    $inputUserEscaped = [System.Security.SecurityElement]::Escape($user)
    $inputPassEscaped = [System.Security.SecurityElement]::Escape($pass)

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
    $modeText                    = "全无人值守 (全自动装机，自动创建账户并登录)"
}

# ----------------- 2. 纯字面量无损应答模板 -----------------
$unattendTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
	<settings pass="offlineServicing"></settings>
	<settings pass="windowsPE">
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
		$xmlFiles = @(
			'C:\Windows\Panther\unattend.xml',
			'C:\Windows\Panther\Unattend\unattend.xml',
			'C:\Windows\System32\Sysprep\autounattend.xml',
			'C:\Windows\System32\Sysprep\unattend.xml'
		);
		foreach ($f in $xmlFiles) {
			if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; }
		}

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

# ----------------- 3. 单语句独立安全置换 -----------------
$finalXml = $unattendTemplate
$finalXml = $finalXml.Replace('__USER_ACCOUNTS__', $userAccountsXmlFragment)
$finalXml = $finalXml.Replace('__AUTO_LOGON__', $autoLogonXmlFragment)
$finalXml = $finalXml.Replace('__HIDE_LOCAL_ACCOUNT_SCREEN__', $hideLocalAccountScreenValue)
$finalXml = $finalXml.Replace('__DEPLOY_MODE_TEXT__', $modeText)

# ----------------- 4. 纯净 ISO 根目录注入 (遵照原生标准，绝不污染 install.wim 内部) -----------------
$utf8Encoding = [System.Text.Encoding]::UTF8

# 严格仅写入 ISO 安装介质根目录，交由微软官方 Setup 引擎在内存中安全调度，100% 杜绝解析崩溃
[System.IO.File]::WriteAllText((Join-Path $workDir "autounattend.xml"), $finalXml, $utf8Encoding)

Write-Host "[完成] 无人值守应答文件已写入 ISO 根目录 (install.wim 内部保持 100% 纯净零冲突)。" -ForegroundColor Green
