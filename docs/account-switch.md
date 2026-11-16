# 多账号切换（重启生效） / Multi-account switching

在首页点击“管理账号”，原地添加账号，再点击“登录”打开官方网页登录。设置中的多账号管理保留，两个入口使用同一份账号数据。未登录条目只显示在管理界面。

当前客户端用户为“主账号”。其他已登录账号为“备用账号 1…N”，Plus 优先，同套餐按添加顺序排列。点击账号邮箱或额度只查看详情；点击“↔ 切换”才核验目标登录、请求客户端正常退出并重启。15 秒内未退出则取消，不强制结束客户端。请先保存任务。

更多菜单提供重新登录、退出和删除。删除必须二次确认；当前账号需先切换到其他账号后才能删除。退出成功后立即更新列表，后台清理不阻塞界面；失败则保留条目。退出仅清登录及额度缓存，删除另外移除账号条目，本地项目、聊天与模型配置不删除。

各账号凭证分目录存储；桌面继续使用固定的本地工作空间，共用 SQLite、会话、工作树、附件及 config.toml 提供商配置。原有备用目录文件先备份再链接，不导入其历史。以当前本地项目列表为准（包括空列表），切换逻辑不从其他账号缓存恢复或合并项目，不请求云端项目和聊天同步。不会重建之前已被删除的 custom 配置。

执行身份通过客户端最外层后端进程定位登录目录，再用 account/read 与监测身份匹配。无法识别、身份重复或冲突时禁用切换；不是实际推理的执行验收。客户端内部环境覆盖可能随更新变化，重启后请核对实际登录用户。

1～2 个已登录账号显示 Token 活动，卡片明细默认收起；3 个及以上隐藏活动、默认展开明细。手动调整在同一数量档位保留，跨档位应用新默认。

## English

Manage accounts in place using Manage accounts; Settings remains a second entry to the same data. Add an account, then use the official web login. Unsigned entries are hidden from the normal home view. The current desktop user is primary; Plus backups sort first, then insertion order within a tier.

Clicking a card views details. Its switch button validates the target login, requests a graceful quit, and restarts the client. Save work first; switching aborts after 15 seconds if quitting is incomplete. Deletion requires confirmation and is unavailable for the active account. Successful logout updates the list before background cleanup; failures retain the entry.

Credentials remain separate; all profiles share the fixed local workspace and provider configuration. Existing secondary files are backed up rather than imported. Local project state, including an empty list, is authoritative; the switcher does not fetch cloud projects/chats or recover projects from other account caches. Removed custom-provider definitions must be restored separately.

Identification uses the outermost desktop backend and account/read. Unknown or ambiguous identities disable switching. This is not an inference-level verification; check the actual desktop login after restart. Internal client interfaces may change. See [v0.1.8 notes](releases/v0.1.8.md) for testing limits.
