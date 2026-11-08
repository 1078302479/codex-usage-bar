# Codex UsageBar Windows 版

[English](README.en.md) · [补丁原理与开发命令](patch/README.md) · [macOS 版](https://github.com/1078302479/codex-usage-bar/tree/main)

在 Codex 桌面客户端的左侧导航栏显示短周期和每周剩余额度。悬停查看北京时间的重置时间与倒计时。重置卡区域显示可用数量、近期到期统计和默认展开的逐卡明细，点击「使用」可定位到官方设置里的「使用限额重置」，由用户确认使用。

这是社区维护的实验版。安装脚本从本机官方客户端生成独立测试副本，补丁保留资源完整性校验，但修改后的 EXE 原签名会失效。若 Windows 或组织策略阻止启动，请使用官方安装版。项目源码采用 [Apache 2.0](../LICENSE)，客户端资源仍受其原授权约束。

## 安装

1. 在 Windows 11 x64 上先通过 Microsoft Store 安装官方 Codex。
2. 下载并双击 [CodexUsageBar-Windows-x64-Setup.exe](https://github.com/1078302479/codex-usage-bar/releases/download/windows-v0.1.5/CodexUsageBar-Windows-x64-Setup.exe)，按安装向导完成。
3. 保存工作并退出当前 Codex，从桌面或开始菜单打开 **Codex UsageBar**。

安装包自带 Node.js 和所需依赖。安装过程会用本机 Store 客户端生成副本，需要预留几 GB 磁盘空间。已实测客户端内部版本 `26.1103.31037`，对应 Store 包 `26.1103.3517.0`。遇到其他客户端版本时，安装程序会先做兼容性检查。安装包尚未签名，Windows 可能显示发布者未知。

从 v0.1.2 起，安装和快捷方式由项目自有的 Windows 启动器处理。安装向导会说明生成副本对原厂签名的影响。[代码签名与安全软件复核说明](setup/Security.md)

从 v0.1.1 起，桌面和开始菜单快捷方式会在打开客户端后后台检查 GitHub 上的 Windows 版本。发现新版时会询问是否下载，校验 SHA-256 后打开安装向导。安装前请保存工作并退出当前 Codex UsageBar。v0.1.0 用户需先手动运行一次新版 EXE。

官方 Codex 更新后，重新运行安装包即可尝试生成对应版本的副本。卸载入口在 **Windows 设置 → 应用 → 已安装的应用 → Codex UsageBar (Windows)**。若安装失败，可在 `%LOCALAPPDATA%\CodexUsageBar-setup.log` 查看原因。

## 置顶额度弹框

悬停打开侧栏弹框，点击右上角的图钉。额度会显示在独立置顶小窗中，点击其他窗口也会继续显示。可拖动小窗标题区域调整位置，或再次点图钉关闭。此功能需要客户端通过窗口结构兼容检查。

## 设置窗口

启动 Codex UsageBar 后，点击任务栏右下角的托盘图标即可打开设置。若图标被收起，可在「^」里找到，也可从开始菜单打开 **Codex UsageBar Settings**。关闭设置窗口后图标继续驻留，右键可打开或重启 Codex、退出托盘。

窗口可以查看本机版本、手动检查并下载 Windows 更新，以及开关启动时检查。侧栏显示选项包括短周期额度、周额度、额度重置时间与倒计时、重置卡，以及是否默认展开卡片明细。

点击「保存设置」后，若有显示变化，窗口会提示重新启动。确认后会正常关闭并重新打开 Codex，应用设置时可能需要片刻。选择稍后重启时，设置会保留到下次重新打开。手动运行安装包升级或卸载时，请退出 Codex 并在托盘菜单选择「退出托盘」。

## 从源码安装

需要 Git、Node.js 22+ 和 pnpm。

在 PowerShell 中执行以下命令。

```powershell
git clone --branch windows --single-branch https://github.com/1078302479/codex-usage-bar.git
cd codex-usage-bar
pnpm --dir windows install --frozen-lockfile
powershell -NoProfile -File windows/Install-Sidebar.ps1
```

安装会在仓库的 `.local` 目录生成补丁、完整测试副本和还原备份，需要预留几 GB 磁盘空间。安装完成后保存工作并退出官方客户端，双击桌面 **Codex UsageBar (Windows)** 快捷方式。也可以从仓库根目录运行以下命令。

```powershell
powershell -NoProfile -File windows/patch/Open-SidebarClient.ps1
```

如果自动发现失败，可通过 `-SourceApp` 传入原客户端中同时包含 `ChatGPT.exe` 和 `resources/app.asar` 的目录。安装命令加 `-SkipShortcut` 可以跳过创建桌面快捷方式。

## 源码安装的更新与恢复

- **更新组件**：运行 `git pull --ff-only` 和 `pnpm --dir windows install --frozen-lockfile`。退出测试副本，将 `.local/windows-sidebar-client` 移到备份位置，再运行安装命令。这样可以保留上一份测试副本及其还原备份。
- **官方客户端升级后**：测试副本仍对应生成时的版本。退出并移走旧测试副本，再运行安装命令。新版结构兼容时会自动生成补丁，结构不兼容时请提交版本号和报错。
- **还原测试副本**：退出测试副本，运行下面的 `restore` 命令。它会核验当前文件与备份。
- **卸载**：退出测试副本，删除本项目生成的桌面快捷方式和 `.local` 下的测试副本、补丁目录、备份。日常可直接用 Windows 原有的 Codex 入口打开官方版。

```powershell
$stage = (Get-Content .local/windows-sidebar-active-stage.txt -Raw).Trim()
node windows/patch/manage.mjs restore .local/windows-sidebar-client $stage
```

## 常见问题

- **看不到侧栏数字**：用本项目的桌面快捷方式打开测试副本。开始菜单和之前固定的官方图标通常仍指向官方安装版。
- **启动器在等待退出**：使用客户端的 **文件 → 退出**，或从托盘菜单退出，随后等待启动器完成切换。
- **安装中途失败**：先读控制台报错。若留下未完成的测试副本，确认客户端已退出，再将该副本目录移到备份位置后重试。保留生成的补丁清单，便于核对。
- **数量或到期时间待确认**：取决于当前账号的服务端响应。重置卡明细加载失败时可在弹框里重试。

报告问题时请附 Windows 版本、客户端版本和经过脱敏的报错。项目的 `.local` 目录只用于本机安装与验证，发布内容是源码和安装脚本。

## 开发验证

```powershell
pnpm --dir windows test
node windows/server.mjs --demo
```

演示服务使用示例数据，在本机浏览器预览早期 Web 原型。真实客户端侧栏使用 `windows/patch` 中的原生界面补丁。

使用 Inno Setup 6.7.4 构建安装包。在安装锁定依赖后，从仓库根目录运行 `./windows/setup/Build-Installer.ps1 -Compiler '<ISCC.exe 路径>'`，生成的 EXE 和 SHA-256 文件在 `.local/windows-package`。构建脚本会下载并校验固定版本的 Node.js x64 运行时。
