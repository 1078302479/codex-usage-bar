## 中文下载与安装

适用于 **Windows 11 x64**。在 Codex 左侧栏查看短周期和每周剩余额度，悬停可查看重置时间与重置卡明细。

1. 先通过 Microsoft Store 安装官方 Codex。
2. 在本页下方的 **Assets** 下载 **CodexUsageBar-Windows-x64-Setup.exe**，双击并按向导安装。运行环境已经打包，直接安装即可。
3. 保存工作并退出当前 Codex，再从桌面或开始菜单打开 **Codex UsageBar**。

从 v0.1.2 起，安装与启动使用项目自有的 Windows 程序，安装包移除了 PowerShell 脚本。安装向导会提示内嵌侧栏副本的签名影响。[签名与拦截复核说明](https://github.com/1078302479/codex-usage-bar/blob/windows/windows/setup/Security.md)

从 v0.1.1 起，每次通过桌面或开始菜单打开 Codex UsageBar，都会在后台检查 Windows 更新。有新版时可以确认下载，校验 SHA-256 后会打开安装向导。安装前请保存工作并退出当前 Codex UsageBar。v0.1.0 用户需先手动运行一次新版安装包。

卸载入口在 **Windows 设置 → 应用 → 已安装的应用 → Codex UsageBar (Windows)**。

这是社区预览版。安装程序会从本机的 Store 版 Codex 生成独立副本。安装包尚未签名，Windows 可能提示发布者未知。**Assets** 同时提供 SHA-256 校验文件。

[完整中文安装说明](https://github.com/1078302479/codex-usage-bar/blob/windows/windows/README.md)

## Download and install in English

Install the official Microsoft Store edition of Codex on **Windows 11 x64**. Under **Assets** below, download and run **CodexUsageBar-Windows-x64-Setup.exe**. Setup includes its own runtime.

After setup, save your work, exit Codex, and open **Codex UsageBar** from the desktop or Start menu. Setup generates a separate client copy from your Store installation. The installer is unsigned, and a SHA-256 checksum is available under **Assets**.

Starting with v0.1.2, the setup and shortcuts use the project's Windows launcher. The installer explains the signature impact on the separate Codex copy.

Starting with v0.1.1, each shortcut launch checks for Windows updates in the background. Confirm the prompt to download and verify the installer, then follow the setup wizard. Upgrade from v0.1.0 by running the new installer once.

[Full English instructions](https://github.com/1078302479/codex-usage-bar/blob/windows/windows/README.en.md)
