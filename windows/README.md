# Codex UsageBar Windows 版

[English](README.en.md) · [补丁原理与开发命令](patch/README.md) · [macOS 版](https://github.com/1078302479/codex-usage-bar/tree/main)

在 Codex 桌面客户端的左侧导航栏显示短周期和每周剩余额度。悬停查看北京时间的重置时间与倒计时。重置卡区域显示可用数量、近期到期统计和默认展开的逐卡明细，点击「使用」可定位到官方设置里的「使用限额重置」，由用户确认使用。

这是社区维护的实验版。安装脚本从本机官方客户端生成独立测试副本，补丁保留资源完整性校验，但修改后的 EXE 原签名会失效。若 Windows 或组织策略阻止启动，请使用官方安装版。项目源码采用 [Apache 2.0](../LICENSE)，客户端资源仍受其原授权约束。

## 安装

准备 Windows 11 x64、通过 Microsoft Store 安装的 Codex 桌面客户端、Git、Node.js 22+ 和 pnpm。已实测的客户端内部版本为 `26.1103.31037`，对应 Store 包 `26.1103.3517.0`。其他版本由脚本先分析界面结构和资源校验格式，检查不通过时停止。

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

## 更新与恢复

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
