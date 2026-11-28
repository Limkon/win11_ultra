# Windows 10/11 Ultra Builder

一个以 DISM 为核心的离线 Windows 映像精简脚本，支持 Windows 10 与 Windows 11 客户端映像。脚本会读取目标映像 `SOFTWARE` 注册表中的 build，自动判断系统版本并选择对应设置；无需手动切换 Win10/Win11 配置。

## 使用方法

1. 在 Windows 10/11 上以管理员身份运行 **Windows PowerShell 5.1**。
2. 进入仓库目录，执行：

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   .\win11_ultra_builder.ps1
   ```

3. 按提示选择精简模式、源 ISO/WIM/ESD 或已释放映像目录，以及目标映像 Index。

目标映像支持 Windows 10 build 10240 及以上、Windows 11 build 22000 及以上。Windows Server 和其他系统会在修改前被拒绝。请先备份原始映像；“极限压榨”会移除更多组件并缩减恢复/更新能力，推荐先用普通精简模式验证。

## 配套 NTLite 安全精简预设

仓库根目录提供两份基于 NTLite `pn.v1` 规范的安全预设配置（适配 Windows 11 23H2 及通用客户端母盘）：

- **`ntlite_safe_preset.xml`（全兼容标准版）**：完整保留 `Client.CBS` / `Client.Core`（现代桌面、打开方式窗口与中文输入法候选框宿主）、`Edge WebView2` 运行时、32 位 MSHTML/JScript 安装器引擎、多媒体编解码器（`MediaFoundation` / `qWave`）、`W32Time` 时间同步、原生 Zip 解压、蓝牙/摄像头/打印/远程桌面客户端（`mstsc`）、中日韩繁字体库、应用商店、`winget`、基础工具及 `SFC` / `WinRE` 故障恢复能力，并关闭 `OptimizeAppX` 以保护 `Microsoft.VCLibs` / `UI.Xaml` 共享运行库。
- **`ntlite_safe_preset2.xml`（无商店/无多余内置应用纯净版）**：在保留全部底层运行库、输入法、驱动锁、`AppxSupport` 框架依赖与记事本（确保未知文件类型“打开方式”弹窗与运行库引用计数正常）的基础上，额外移除应用商店、照片、画图、计算器、截图工具、终端、Xbox 等内置 UWP 应用，适合自行安装第三方常用软件的场景。
- **使用方法**：在 NTLite 中加载原版映像后，通过 **预设 -> 导入** 载入对应 `.xml` 执行前置精简；若需进一步注入无人值守、跳过硬件限制与阻断打开方式联网查商店（`NoUseStoreOpenWith`），可继续配合 `win11_ultra_builder.ps1` 使用。

## 源码与发布脚本

可维护模块位于 `src/`。根目录 `win11_ultra_builder.ps1` 是可直接运行的合并版，模块顺序由 `.github/workflows/` 中的工作流维护。修改模块后应同步更新合并版。
