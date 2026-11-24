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

## 源码与发布脚本

可维护模块位于 `src/`。根目录 `win11_ultra_builder.ps1` 是可直接运行的合并版，模块顺序由 `.github/workflows/` 中的工作流维护。修改模块后应同步更新合并版。
