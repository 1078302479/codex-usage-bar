<div align="center">
  <img src="docs/images/app-icon.png" width="128" alt="CodexUsageBar icon">
  <h1>CodexUsageBar</h1>
  <p>在 macOS 菜单栏查看 Codex 剩余额度、重置时间与 Token 活动。</p>
  <p>A native macOS menu bar app for Codex quota, reset times, and token activity.</p>
  <p><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
  <p><a href="https://github.com/1078302479/codex-usage-bar/releases/latest">下载安装包</a> · <a href="#从源码构建">从源码构建</a> · <a href="docs/architecture.md">技术说明</a></p>
</div>

## 简介

CodexUsageBar 是一个轻量的原生 macOS 菜单栏工具，使用 Swift、AppKit 和 SwiftUI 实现。它通过本机 Codex 的 App Server 读取当前登录账号的套餐额度和官方 Token 活动，不需要在应用中填写 API Key，也不依赖网页或 Python 后台服务。

这是独立的社区项目，与 OpenAI 没有隶属关系，也不是 OpenAI 官方应用。

## 功能

- **双窗口额度**：查看短周期和 7 天剩余、已用比例及重置时间；实际窗口长度以服务端返回为准。
- **百分比颜色规则**：5 小时与 7 天分别配置剩余比例区间和数字颜色，横排/堆叠均支持；默认沿用原字体颜色。
- **环形额度面板**：紧凑账号与套餐标签、环形剩余额度、清晰的活动统计，适配深浅色模式。
- **可定制菜单栏**：选择额度、重置时间、套餐、图标及标签，分隔符可开关和切换。
- **上下堆叠**：7 天额度在上，5 小时额度在下；也可使用普通单行显示。
- **精简重置显示**：短期只显示 `HH:mm`，长期只显示 `MM-dd`，描述前缀可单独关闭。
- **官方 Token 活动**：累计 Token、单日峰值、最长单轮运行时间、当前及最长连续活跃天数。
- **活动热力图**：最近 26 周每日用量，悬停或点击显示日期和精确 Token 数。
- **重置卡明细**：显示官方可用数量、最近到期时间、未来 72 小时内到期数量与各张卡片到期日期；未返回的日期不推算。
- **重置卡过期提醒**：设置中主动开启并允许系统通知后，提前 24 小时提醒；进入提醒范围后开启会在重新核验后补提醒。按账号与卡片持久去重，检测到已使用、过期或账号变化后取消对应提醒。
- **自动核验**：默认跟随本机客户端额度变化；面板可见时每 15 秒、后台每 60 秒补查额度，避免漏掉重置卡或其他设备的变化。另可选择 1、5、15 分钟定时核验。
- **连接自恢复**：网络请求失败、超时和子进程断开后按 5、15、30、60、120、300 秒逐步重试，最长每 5 分钟一次；检测到网络恢复后合并提前核验。需要登录、选择程序或更新 Codex 时停止自动重试。
- **明确更新状态**：显示已核验、数据已过期、网络请求失败、需要登录和版本不兼容等状态，区分最近成功核验与未核验缓存，并显示下次自动重试时间。
- **原生体验**：深色、浅色、跟随系统；弹窗按内容展开并可拖动调整高度；支持登录时自动启动。

后台资源优化：设置窗口关闭后释放，下次打开重建；额度弹窗关闭后释放视图，继续监听和核验额度，重新打开恢复当前数据与本次运行的高度偏好。菜单栏内容未变时复用图像。启动时遍历日志仅保留最近 24 个候选，避免保留全部历史文件列表（仍需遍历目录）。

## 界面预览

以下为维护者在 macOS 上运行 **v0.1.1** 的实际截图（2026-10-21），账号信息已遮盖。额度和 Token 数值仅代表截图时的账号状态；界面当前为中文。

### 菜单栏实际效果

原生菜单栏双行显示：上方为 **7 天剩余与重置日期**，下方为 **5 小时剩余与重置时间**，左侧为 Codex 图标。点击后展开额度面板；显示内容、标签和分隔符均可在设置中调整。

<img src="docs/images/screenshots/menubar-live.png" width="440" alt="macOS 菜单栏实际双行效果：上方 7d 75% / 10-27，下方 5h 98% / 18:52，点击展开 CodexUsageBar 面板；账号已遮盖">

### 额度面板与 Token 活动

点击菜单栏即可查看两个独立窗口的剩余额度、重置时间及核验状态；下方展示累计 Token、单日峰值、连续活跃天数与近半年每日活动。热力图支持悬停或点击日期查看详情。

<table>
  <tr>
    <th>完整额度面板</th>
    <th>Token 统计与热力图日期提示（局部）</th>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/screenshots/quota-panel.png" width="360" alt="CodexUsageBar 实际额度面板：5 小时与 7 天剩余额度、重置时间、Token 统计和热力图"></td>
    <td valign="top"><img src="docs/images/screenshots/token-activity.png" width="460" alt="Token 统计与活动热力图，日期提示框显示 2026-10-14 和 219,779,583 Token"></td>
  </tr>
</table>

### 菜单栏定制与更新方式

选择展示哪些额度和重置时间、启用上下堆叠、调整标签与分隔符。默认跟随 Codex 客户端变化并向服务商核验；可在连接设置中查看更新状态和选择本机 Codex。

<table>
  <tr><th>菜单栏显示与排列</th><th>连接与更新</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/screenshots/menubar-settings.png" width="480" alt="菜单栏设置：显示内容、7 天与 5 小时堆叠、标签、重置描述和分隔符"></td>
    <td valign="top"><img src="docs/images/screenshots/connection.png" width="480" alt="连接与更新设置：跟随客户端、核验状态、账号套餐及 Codex 路径；账号已遮盖"></td>
  </tr>
</table>

### 外观与登录时启动

支持浅色、深色和跟随系统主题，并提供登录时自动启动开关。截图展示当前电脑的“跟随系统”配置，自启动开关当前为关闭状态。

<img src="docs/images/screenshots/appearance.png" width="640" alt="外观与关于设置：登录时自动启动开关、跟随系统主题及版本信息">

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更高版本 |
| 首版安装包 | Apple Silicon / arm64 |
| Codex | 已安装并完成 ChatGPT 账号登录，版本需支持相关 App Server 接口 |
| 网络 | 可连接 Codex 官方服务 |

当前没有提供 Intel 安装包，也没有完成 Intel 实机验证。仅 API Key 登录不支持本应用需要的 ChatGPT 套餐与账号统计接口。

## 安装

1. 在 [Releases](https://github.com/1078302479/codex-usage-bar/releases/latest) 下载 `CodexUsageBar-0.1.4-mac-arm64.dmg`。
2. 双击 DMG，将 **CodexUsageBar** 拖到右侧 **Applications（应用程序）** 文件夹。
3. 推出安装磁盘，从“应用程序”打开应用。
4. 需要自启动时，进入 **设置 → 外观与关于 → 登录时自动启动**。

更新前先退出旧版，安装新版后请从 CodexUsageBar 启动，避免同时打开旧副本。应用沿用原偏好标识，以保留菜单栏等设置。

**签名说明：**首版采用临时签名，尚未完成 Apple Developer ID 签名及公证，macOS 可能显示安全提示。请核对来源和 Release 中的 SHA256 校验文件；不希望运行未公证构建时，可从源码自行构建。登录项可能需要在系统设置中批准，建议先将应用放到固定位置再开启。

## 首次使用

应用会自动发现本机 Codex 可执行文件。若发现失败，在“设置 → 连接与更新”选择路径；请先通过 Codex 自己完成登录。面板显示脱敏账号，CLI 与桌面客户端可能使用不同登录身份，请核对。

应用不会直接读取认证文件、保存 token 或发起模型推理。Codex 管理认证和网络请求。应用会保存显示偏好和脱敏的额度缓存，并在每次启动后重新核验；Token 活动数据仅驻留内存。

## 数据口径与更新

- 剩余按服务端 `100 − usedPercent` 计算，各窗口独立展示，不相加。
- 默认监听本机额度事件并合并核验；启动、打开面板、唤醒及重置边界也会查询。
- **不保证与 Codex 客户端或其他设备瞬时同步。**其他设备的变化可能要等下一次核验才能显示。
- 旧快照以 `*` 标记，未知、未核验或重置待确认显示 `--`；不会到点自动补为 100%。
- Token 汇总来自官方 `account/usage/read`，可能存在延迟。缺失数据不会当作零，也不会用本机日志推算全账号统计。
- “最长单轮”表示官方返回的单轮运行时长，不是整个会话持续时间。
- 时间统一按 **Asia/Shanghai（北京时间）**显示；热力图日期沿用服务端日期桶。

详见 [技术说明](docs/architecture.md) 和 [官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。

## 从源码构建

需要 macOS、支持 Swift 6 的 Xcode 或 Command Line Tools，以及系统 Python 3（仅测试/打包时使用）。

```sh
git clone https://github.com/1078302479/codex-usage-bar.git
cd codex-usage-bar
bash scripts/build-native.sh
```

输出：`build/CodexUsageBar.app`。原生应用本身没有 Python 或 npm 运行时依赖。

运行检查：

```sh
bash scripts/test-native.sh
python3 -m unittest discover -s tests -v
node --check prototype/app.js
```

原生检查包括 39 项核心断言、9 项热力图命中检查，以及 1,000 个日志文件的最近候选筛选检查。可选的窗口生命周期、文件监听与真实账号探针：

```sh
bash scripts/test-native.sh --ui
bash scripts/test-native.sh --transport
bash scripts/test-native.sh --watch
.build/QuotaProbe
.build/QuotaProbe --activity
```

`--ui` 在桌面会话中反复打开和关闭设置窗口 30 次、额度弹窗 100 次，验证窗口和视图控制器释放、重新打开、弹窗高度保留与菜单图像复用；使用临时偏好，不发起账号请求。短周期检查不代表长时间运行或真实休眠唤醒的内存验收。

默认还运行恢复协调与状态回归：事件合并、递增退避、手动重试、需要用户处理时停止重试、网络恢复提示、休眠取消及迟到结果隔离。`--transport` 使用临时模拟 CLI 验证真实 stdio、子进程退出重连、超时恢复和请求中模拟休眠/唤醒；不更改真实网络或让整机休眠。

真实账号探针输出含脱敏账号和用量元数据，提交 Issue 前请先检查并删除个人信息。受限执行环境可能阻止 App Server、FSEvents 或磁盘镜像操作，请在正常 macOS 终端运行。

## 打包 DMG

```sh
python3 -m pip install --target .build/dmg-python ds-store==1.3.1 mac-alias==2.2.2
bash scripts/build-dmg.sh
```

脚本制作带拖动安装布局的只读 DMG，并执行镜像校验；不会自动安装到“应用程序”。产物与缓存默认不提交 Git。

## 项目结构

```text
native/Sources/     原生界面、账号额度适配、日志监听和统计
native/Resources/   已确认的应用图标与资源说明
native/Tests/       额度、格式、偏好迁移和热力图检查
native/Tools/       图标生成、安装背景与诊断探针
scripts/           构建、测试、打包及早期协议验证
prototype/         早期浏览器原型，部分交互为演示数据
tests/             早期 Python 适配器测试
docs/              架构、版本说明和维护文档
```

## 限制与反馈

当前仅支持重置卡过期通知，不含低额度通知、逐会话 Token 明细或多服务商支持。重置卡提醒默认关闭；开启后每 15 分钟核验卡片状态，并在已知提醒时刻前额外核验。其他设备使用卡片后，要等再次核验才能取消本地提醒。正常退出应用保留已安排的本地通知；关机、休眠或专注模式可能延迟投递。系统横幅投递与跨重启表现仍需在用户允许通知后实测。

认证过期、真实多账号切换、长时间运行、不同 Codex 版本，以及登录后自动启动仍需更广泛验证。已完成本机真实数据读取、重置卡明细和主要界面验证。

欢迎通过 [Issues](https://github.com/1078302479/codex-usage-bar/issues) 提交问题。请附 macOS、芯片、Codex 和应用版本，并隐藏邮箱、账号标识、token 与用量等个人信息。维护说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开源协议与标识

本项目采用 **[Apache License 2.0](LICENSE)** 完全开源，允许免费使用、修改、分发及商业使用。再分发时须遵守协议，包括附带许可证、保留适用的版权及归属声明，并明确标注修改。版权及归属说明见 [NOTICE](NOTICE)。软件按“原样”提供，不附带担保。

此授权亦适用于本仓库发布的 v0.1.1 项目原创代码及其构建产物。Codex、OpenAI 及相关第三方名称和标识属于其各自权利人，不因本项目开源而获得额外的商标或第三方素材授权；本项目的名称用于说明适配对象。
