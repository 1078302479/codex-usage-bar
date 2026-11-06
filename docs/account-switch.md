# 账号切换（重启生效）

在菜单栏弹窗点击“切换并重启”，自动切换至备用账号。查看账号额度不改变执行身份。

切换前先核验目标账号登录，再请求当前 ChatGPT 客户端正常退出；未在 15 秒内退出则取消，不强制结束进程。请先完成任务并保存内容。

A 使用原 Codex 目录及默认配置，B 使用既有独立第二账号目录。桌面继续使用原默认数据目录，主进程固定原 CODEX_HOME；B 后台执行进程独立读取登录，共用原 sqlite_home 及 sessions、archived_sessions、worktrees、attachments，每次先退出后打开；不同时保留两个客户端。默认客户端配置和登录文件不被替换，也不复制 Token。B 启动器仅指定 CODEX_HOME 和文件凭证存储模式。

该实现移除了模型代理，不监听端口。Codex 登录应由所选账号目录提供。本机/备用角色根据当前桌面后台的已知进程启动参数识别，无法识别或有多个冲突客户端时禁用切换；此标记不是一次真实推理的执行验证。桌面内部环境变量随版本可能变化，切换后的实际客户端身份仍需核对。

# Account switching

Use the single switch-and-restart action in the popup to choose the alternate account automatically. The target login is checked before requesting a graceful quit. Switching aborts if the client does not quit within 15 seconds; no forced termination is used. Finish running tasks and save work first.

A retains its default Codex home; B uses its existing isolated account home. The desktop retains its original profile and home. The B backend uses separate authentication but shares the original SQLite directory and session/worktree/attachment paths. Existing B files are preserved before linking. Default config/auth files are not replaced. There is no model proxy or listener. The UI detects known backend launch patterns and disables switching for unknown/conflicting instances, rather than claiming a verified inference identity; check the native Codex account after restart. Internal desktop environment overrides remain version-sensitive.

## 新版项目状态兼容（v0.1.7）

新版 ChatGPT 客户端会在登录后恢复账号专属的桌面项目状态。目标账号的空列表可能覆盖已加载的本地项目列表，导致切换后侧边栏没有已有项目；项目数据库共用并不能单独解决此问题。

切换正常退出后，同步本地项目列表、排序、会话归属及项目 ID 映射到其他账号缓存与备用 CODEX_HOME。当前列表为空且只有一个非空账号缓存时恢复原列表；多个候选时停止，避免猜测。改写前备份为 `.codex-global-state.json.workspace-backup-*`；保留账号缓存 owner、atoms 和登录凭证，不复制认证。

升级后请保存任务，使用“切换并重启”切回原账号，再切到备用账号。已在 ChatGPT macOS 26.1103.31037 上完成实际切换，用户确认项目列表恢复。其他及后续客户端版本仍需验证。详见 [v0.1.7 升级说明](releases/v0.1.7.md)。

### Project visibility after a client update

Newer clients restore account-specific desktop project lists after login. v0.1.7 synchronizes local workspace fields into account caches after a graceful exit, restores an empty list only from one unambiguous nonempty cache, and backs up changed state. Credentials and account-specific UI settings remain isolated. Upgrade, finish running tasks, switch back to the original account, then switch to the alternate account again. Confirmed on ChatGPT macOS 26.1103.31037; future client versions may require adaptation.
