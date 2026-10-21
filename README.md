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
- **可定制菜单栏**：选择额度、重置时间、套餐、图标及标签，分隔符可开关和切换。
- **上下堆叠**：7 天额度在上，5 小时额度在下；也可使用普通单行显示。
- **精简重置显示**：短期只显示 `HH:mm`，长期只显示 `MM-dd`，描述前缀可单独关闭。
- **官方 Token 活动**：累计 Token、单日峰值、最长单轮运行时间、当前及最长连续活跃天数。
- **活动热力图**：最近 26 周每日用量，悬停或点击显示日期和精确 Token 数。
- **自动核验**：默认跟随本机客户端额度变化，另可选择 1、5、15 分钟定时核验。
- **原生体验**：深色、浅色、跟随系统；弹窗按内容展开并可拖动调整高度；支持登录时自动启动。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更高版本 |
| 首版安装包 | Apple Silicon / arm64 |
| Codex | 已安装并完成 ChatGPT 账号登录，版本需支持相关 App Server 接口 |
| 网络 | 可连接 Codex 官方服务 |

当前没有提供 Intel 安装包，也没有完成 Intel 实机验证。仅 API Key 登录不支持本应用需要的 ChatGPT 套餐与账号统计接口。

## 安装

1. 在 [Releases](https://github.com/1078302479/codex-usage-bar/releases/latest) 下载 `CodexUsageBar-0.1.1-mac-arm64.dmg`。
2. 双击 DMG，将 **CodexUsageBar** 拖到右侧 **Applications（应用程序）** 文件夹。
3. 推出安装磁盘，从“应用程序”打开应用。
4. 需要自启动时，进入 **设置 → 外观与关于 → 登录时自动启动**。

更新前先退出旧版。早期应用名为 UsageBar；安装新版后请从 CodexUsageBar 启动，避免同时打开旧副本。应用沿用原偏好标识，以保留菜单栏等设置。

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

原生检查包括 39 项核心断言与 9 项热力图命中检查。可选的文件监听与真实账号探针：

```sh
bash scripts/test-native.sh --watch
.build/QuotaProbe
.build/QuotaProbe --activity
```

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

当前不包含系统通知、逐会话 Token 明细或多服务商支持。认证过期、真实多账号切换、长时间运行、不同 Codex 版本，以及登录后自动启动仍需更广泛验证。首版已完成本机真实数据读取和主要界面验证。

欢迎通过 [Issues](https://github.com/1078302479/codex-usage-bar/issues) 提交问题。请附 macOS、芯片、Codex 和应用版本，并隐藏邮箱、账号标识、token 与用量等个人信息。维护说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开源协议与标识

本项目采用 **[Apache License 2.0](LICENSE)** 完全开源，允许免费使用、修改、分发及商业使用。再分发时须遵守协议，包括附带许可证、保留适用的版权及归属声明，并明确标注修改。版权及归属说明见 [NOTICE](NOTICE)。软件按“原样”提供，不附带担保。

此授权亦适用于本仓库发布的 v0.1.1 项目原创代码及其构建产物。Codex、OpenAI 及相关第三方名称和标识属于其各自权利人，不因本项目开源而获得额外的商标或第三方素材授权；本项目的名称用于说明适配对象。
