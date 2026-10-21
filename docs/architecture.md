# 技术说明 / Architecture

## 数据链路 / Data flow

```text
NSStatusItem / SwiftUI
        │
     AppState
        │
     CodexClient actor
        │  JSON-RPC over stdio
        ▼
  codex app-server
        │
        ▼
 Official Codex services
```

- `initialize` → `initialized` 建立独立连接。
- `account/read` → `account/rateLimits/read` → `account/read` 核对读取前后账号。
- `account/usage/read` 获取官方汇总及每日桶，也验证账号作用域。
- 只允许所需的只读 RPC，不发起模型任务或额度重置操作。

The app owns one App Server child process. An actor coordinates requests, timeouts, notifications, and termination. It only shuts down the process it created. No arbitrary RPC proxy or credential-entry UI is exposed.

## 更新 / Refresh

默认跟随事件，无固定分钟数轮询。FSEvents 发现新会话文件，文件描述符监听处理追加写入；近期 token_count 额度指纹发生变化后合并触发服务端核验。日志值不直接覆盖已验证的账号额度。

Startup, panel opening, wake, reset boundaries, and explicit refresh also validate quota. User-selectable fixed intervals are separate from event following. Token activity is reused for up to five minutes on the same account except on manual refresh.

This is a local observation strategy, not a guarantee of matching an undocumented client refresh interval. Other-device updates may remain invisible until the next service query.

## 恢复与状态 / Recovery and status (v0.1.3)

AppState owns one refresh chain, one coalesced event task, and at most one retry task. Recoverable failures use 5/15/30/60/120/300-second backoff. Automatic events, polling, and panel opening do not bypass a pending retry or a user-action error; explicit refresh can retry immediately. Healthy event-following mode does not gain periodic polling. NWPathMonitor is only a hint to expedite a retry after an offline-to-online transition; it does not prove service availability.

Sleep, stop, account changes, and CLI configuration changes advance an epoch and invalidate old request ownership. New requests wait for prior shutdown tasks. The client also checks its process generation after asynchronous RPC boundaries, so old continuations cannot mutate or shut down a replacement connection. Sleep cancels retries and timers; duplicate wake callbacks coalesce into one delayed validation.

状态区与菜单栏提示区分已核验、过期、重置待确认、查询中、网络请求失败、超时、连接断开、需要登录、版本不兼容、程序/权限问题及无额度。最近成功时间只来自成功的查询；启动缓存不能伪装为本次成功核验。失败消息不展示原始服务端错误或凭证。Token 活动不支持时只影响活动区，保持额度功能可用。

Tests use isolated preferences and synthetic clients by default. Optional real-stdio fixtures test failures, child termination, deadlines, and simulated sleep/wake without changing system connectivity or sleep. Physical sleep/wake, real network interruption, and extended uptime remain separate manual acceptance work.

## 准确性 / Accuracy

- 两个窗口独立，剩余为 `100 − usedPercent`。
- `null`、越界数字与明确的零不同；不将无数据视作满额。
- 服务端重置时间到达后等待确认，不本地生成 100%。
- 超过五分钟的额度快照标旧；未验证的缓存不展示为当前有效值。
- Token summary 直接读取官方字段；重复日期不重复累加，缺失日期不补零。

## 本地数据 / Local data

UserDefaults stores display preferences and a quota cache with a masked account label, hashed account scope, plan, timestamp, and quota metadata. Raw account identifiers used during validation are not persisted by this app. Token activity stays in memory. Codex itself manages authentication.

`com.guoyuming.UsageBar` remains the bundle identifier for compatibility with the earlier application name. New builds use CodexUsageBar as their display name and executable name.

## 界面与系统集成 / UI and system integration

- `NSStatusItem` + template/color rendering for normal and two-row menu bar layouts.
- A bounded, measured popover expands to available screen height; a drag handle adjusts its height.
- A native tracking view implements the heatmap and immediate hover/click tooltips.
- AppKit owns appearance changes, avoiding conflicting SwiftUI color-scheme overrides.
- `SMAppService.mainApp` reads and updates the real login-item state. Registration can fail or require approval.

## 打包与验证 / Packaging

Swift source builds into an ad-hoc-signed app bundle. The approved artwork generates all 10 standard iconset representations. The DMG script creates an HFS+ image, writes Finder layout/background data, compresses it to UDZO, and verifies it. The release also provides ZIP and SHA256 checksums.

Public releases must distinguish build/test verification from reboot/login validation or Apple notarization. The initial build is not notarized.

## 官方协议 / Official protocol

[Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) documents the account, rate-limit, and token-activity methods used here. Supported versions, account entitlements, and server fields can change. Missing or unsupported responses are surfaced as unavailable data.
