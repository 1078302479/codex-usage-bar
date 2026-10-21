# 维护与贡献 / Contributing

## 本地开发 / Development

1. 在 macOS 安装支持 Swift 6 的 Xcode Command Line Tools。
2. 执行 `bash scripts/build-native.sh`。
3. 执行 `bash scripts/test-native.sh`，需要实际文件监听验证时加 `--watch`。
4. 修改 Python 原型时运行 `python3 -m unittest discover -s tests -v`；修改原型 JS 时运行 `node --check prototype/app.js`。

The native runtime must remain independent of the prototype's Python server. Keep App Server protocol handling outside SwiftUI views. Do not read, duplicate, commit, or print authentication credentials.

## 数据与隐私 / Data and privacy

Do not attach raw `~/.codex` files, authentication data, unredacted account screenshots, or live probe output to issues or PRs. Prefer synthetic fixtures and describe the data state rather than the user's identity. Internal design history and personal screenshots are intentionally excluded from the public repository.

## 检查范围 / Validation

Use focused assertions for data formatting, unknown/zero/reset states, preference migration, and heatmap hit regions. Use actual GUI checks for native appearance, positioning, tooltip interaction, and menu bar rendering. A successful build does not establish visual correctness or login-item behavior after reboot.

## 发布 / Release

See [docs/releasing.md](docs/releasing.md). Update both README languages and the release notes when behavior changes. Do not change bundle identity casually because it affects preferences, single-instance detection, and login items.

No contribution license has been selected yet. Discuss licensing with the repository owner before submitting code intended for redistribution.
