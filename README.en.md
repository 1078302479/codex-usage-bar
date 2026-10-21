<div align="center">
  <img src="docs/images/app-icon.png" width="128" alt="CodexUsageBar icon">
  <h1>CodexUsageBar</h1>
  <p>A native macOS menu bar app for Codex quota, reset times, and token activity.</p>
  <p><a href="README.md">简体中文</a> · <strong>English</strong></p>
  <p><a href="https://github.com/1078302479/codex-usage-bar/releases/latest">Download</a> · <a href="#build-from-source">Build from source</a> · <a href="docs/architecture.md">Architecture</a></p>
</div>

## Overview

CodexUsageBar is a lightweight macOS menu bar utility built with Swift, AppKit, and SwiftUI. It reads quota and official account token activity through your local Codex App Server. No API key entry, browser backend, or Python service is required by the native app.

This is an independent community project, not an official OpenAI application or an OpenAI-affiliated product.

## Features

- Remaining allowance and reset times for independent short-term and weekly windows; actual durations come from the service.
- Configurable menu bar metrics, provider icon, labels, plan name, and separators.
- Stacked mode: weekly allowance above the 5-hour allowance, or a regular single-line layout.
- Compact resets: `HH:mm` for the short window and `MM-dd` for the long window, with independently optional descriptions.
- Official lifetime tokens, peak daily tokens, longest-running turn, and current/longest activity streaks.
- A 26-week heatmap with immediate hover/click details and exact daily token counts.
- Event-following refresh by default, with optional 1-, 5-, and 15-minute polling.
- Light, dark, and system appearance; an expanding/resizable popover; macOS login-item support.

Background resources: settings windows are released on close, and the quota panel releases its view while hidden. Quota monitoring and validation continue. Reopening restores current data and the panel height for the current run. Unchanged menu artwork is reused. Startup log discovery retains only the newest 24 candidates while still enumerating the directory.

## Screenshots

Captured from **v0.1.1** running on the maintainer's Mac on 2026-10-21. Account information has been covered. Quota and token values reflect only the account state at capture time. The current UI is Chinese.

### Actual menu bar appearance

The native menu bar shows two stacked rows: **weekly remaining allowance and reset date** above **5-hour remaining allowance and reset time**, with the Codex icon on the left. Click to open the quota panel. Displayed metrics, labels, and separators are configurable.

<img src="docs/images/screenshots/menubar-live.png" width="440" alt="Actual macOS menu bar: 7d 75% / 10-27 above 5h 98% / 18:52, with the CodexUsageBar panel open and account covered">

### Quota panel and token activity

Click the menu bar item to see remaining allowance, reset times, and validation status for two independent windows. The panel also shows lifetime tokens, peak daily usage, activity streaks, and six months of daily activity. Hover over or click a heatmap date to inspect details.

<table>
  <tr><th>Full quota panel</th><th>Token activity and date tooltip (crop)</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/screenshots/quota-panel.png" width="360" alt="Actual quota panel with short-term and weekly allowance, resets, token summaries, and heatmap"></td>
    <td valign="top"><img src="docs/images/screenshots/token-activity.png" width="460" alt="Token summaries and daily heatmap with a tooltip showing 2026-10-14 and 219,779,583 Token"></td>
  </tr>
</table>

### Menu bar customization and refresh

Choose which quota and reset values appear, enable stacked rows, and configure labels and separators. Refresh follows local Codex changes and validates against the service by default. Connection settings show update status and let you select the local Codex executable.

<table>
  <tr><th>Menu bar contents and layout</th><th>Connection and refresh</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/screenshots/menubar-settings.png" width="480" alt="Menu bar settings for metrics, stacked weekly and short-term rows, labels, and separators"></td>
    <td valign="top"><img src="docs/images/screenshots/connection.png" width="480" alt="Client-following refresh, validation status, plan, and executable settings; account covered"></td>
  </tr>
</table>

### Appearance and launch at login

Choose light, dark, or system appearance and optionally launch at login. This Mac currently uses system appearance, with launch at login disabled.

<img src="docs/images/screenshots/appearance.png" width="640" alt="Appearance settings showing launch at login, system theme, and app version">

## Requirements

| Item | Requirement |
| --- | --- |
| OS | macOS 14 or later |
| First release binary | Apple Silicon / arm64 |
| Codex | Installed and signed in with a ChatGPT account; required App Server methods must be supported |
| Network | Access to official Codex services |

No Intel binary is provided and Intel hardware has not been validated. API-key-only authentication does not provide the ChatGPT quota/account activity used by this app.

## Install

1. Download `CodexUsageBar-0.1.2-mac-arm64.dmg` from [Releases](https://github.com/1078302479/codex-usage-bar/releases/latest).
2. Open the DMG and drag **CodexUsageBar** into **Applications**.
3. Eject the installation disk and launch the app from Applications.
4. Optionally enable **Settings → Appearance & About → Launch at login**. The current UI is in Chinese.

Quit older copies before updating, launch CodexUsageBar after installation. The bundle identity is retained to preserve existing preferences.

**Signing:** the first release is ad-hoc signed and is not Apple Developer ID signed or notarized. macOS may show a security prompt. Check the release source and SHA256 checksums; build from source if you prefer not to run an unnotarized binary. Login items can require approval in System Settings and should be registered after moving the app to a stable location.

## Getting started

The app discovers Codex automatically. If discovery fails, select the executable in the connection settings. Sign in through Codex itself and check the masked account shown in the panel: the CLI and desktop client may use different accounts.

The app does not directly read authentication files, persist tokens, or start model inference. Codex owns authentication and network requests. Display preferences and a masked quota cache are stored locally; cached quota is revalidated after every launch. Account token activity is kept in memory only.

## Data and refresh behavior

- Remaining allowance is `100 − usedPercent`, with independent windows.
- The default mode observes local quota events and validates changes against the service. Startup, opening the panel, waking, and reset boundaries also trigger checks.
- **Instant synchronization with the Codex client or other devices is not guaranteed.** Remote changes may appear at the next validation.
- Stale values have `*`; unknown, unverified, and reset-pending values show `--`. A timer never fabricates a refill to 100%.
- Activity comes from official `account/usage/read` and may lag. Missing data is not zero; local logs are not used to invent account-wide totals.
- Longest-running turn means the service's turn duration, not total conversation wall-clock time.
- Times use **Asia/Shanghai**. Heatmap dates preserve the service's date buckets.

See [architecture notes](docs/architecture.md) and the [official App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Build from source

Use macOS with a Swift 6-capable Xcode/Command Line Tools installation. Python 3 is used for tests and packaging, not by the native runtime.

```sh
git clone https://github.com/1078302479/codex-usage-bar.git
cd codex-usage-bar
bash scripts/build-native.sh
```

Output: `build/CodexUsageBar.app`.

Checks:

```sh
bash scripts/test-native.sh
python3 -m unittest discover -s tests -v
node --check prototype/app.js
```

The native suite includes 39 core checks, 9 heatmap hit-region checks, and recent-file selection across 1,000 logs. Optional window lifecycle, real filesystem, and account probes:

```sh
bash scripts/test-native.sh --ui
bash scripts/test-native.sh --watch
.build/QuotaProbe
.build/QuotaProbe --activity
```

`--ui` exercises 30 settings-window cycles and 100 panel cycles with isolated preferences and no account requests, checking resource release, reopening, height retention, and menu artwork reuse. These checks do not validate extended uptime or real sleep/wake memory behavior.

Live probes print masked account/usage metadata; review and redact their output before sharing. Restricted environments may block App Server, FSEvents, or disk-image operations; use a normal macOS terminal.

## Package a DMG

```sh
python3 -m pip install --target .build/dmg-python ds-store==1.3.1 mac-alias==2.2.2
bash scripts/build-dmg.sh
```

The script creates a read-only drag-to-install DMG and verifies its checksum. It does not install the app automatically. Build products and caches are excluded from Git.

## Repository layout

```text
native/Sources/     Native UI, quota client, local event monitoring and activity
native/Resources/   Approved application artwork and resource notes
native/Tests/       Quota, formatting, preference migration and heatmap checks
native/Tools/       Icon generation, installer artwork and diagnostic probes
scripts/           Build, test, package and early protocol experiments
prototype/         Early browser prototype; some interactions use demo data
tests/             Python adapter tests
docs/              Architecture, release notes and maintenance documentation
```

## Limits and feedback

System notifications, per-session token details, and additional providers are not included. Expired authentication, real account switching, extended uptime, different Codex versions, and actual login-after-reboot behavior need broader validation. Real local account reads and the main native UI flows have been verified.

Report issues through [GitHub Issues](https://github.com/1078302479/codex-usage-bar/issues). Include macOS, architecture, Codex, and app versions. Remove account identifiers, email addresses, tokens, and personal usage information. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License and marks

This project is fully open source under the **[Apache License 2.0](LICENSE)**, permitting free use, modification, redistribution, and commercial use. Redistribution must comply with the license, including providing a copy of the license, retaining applicable copyright and attribution notices, and prominently marking modified files. See [NOTICE](NOTICE) for attribution. The software is provided "AS IS", without warranties.

This grant also covers the project's original code and its builds published as v0.1.1 in this repository. Codex, OpenAI, and other third-party names and marks remain the property of their owners. This license grants no additional rights to third-party trademarks or assets; the project name describes the supported service.
