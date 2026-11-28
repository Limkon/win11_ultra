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

仓库根目录提供 `ntlite_safe_preset.xml`（基于 NTLite `pn.v1` 规范，适配 Windows 11 23H2 及通用客户端母盘）：

- **安全基线保护**：完整保留 `Client.CBS` / `Client.Core`（现代桌面与中文输入法候选框宿主）、`Edge WebView2` 运行时、32 位 MSHTML/JScript 安装器引擎、多媒体编解码器（`MediaFoundation` / `qWave`）、`W32Time` 时间同步、原生 Zip 解压、蓝牙/摄像头/打印/远程桌面客户端（`mstsc`）、中日韩繁字体库、应用商店与 `winget`、以及 `SFC` / `WinRE` 故障恢复与累积更新能力。
- **纯净瘦身范围**：安全移除 500+ 项无用组件（传统拨号调制解调器/软盘/磁带机驱动、百余种小语种键盘布局与外语包、Edge 浏览器本体与后台更新、OneDrive、Copilot、Cortana、Clipchamp、新闻天气等预装推广及遥测组件）。
- **使用方法**：在 NTLite 中加载原版映像后，通过 **预设 -> 导入** 载入 `ntlite_safe_preset.xml` 执行前置精简；若需进一步注入无人值守、跳过硬件限制与深层优化，可继续配合 `win11_ultra_builder.ps1`（推荐选择 `[1] 普通精简`）使用。

## 源码与发布脚本

可维护模块位于 `src/`。根目录 `win11_ultra_builder.ps1` 是可直接运行的合并版，模块顺序由 `.github/workflows/` 中的工作流维护。修改模块后应同步更新合并版。
