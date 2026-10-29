# 发布流程 / Release checklist

1. 更新 `scripts/build-native.sh` 的版本/build 值，以及 `scripts/build-dmg.sh` 和 `native/Tools/DMGBackground.swift` 的对应版本；保持界面版本一致。
2. 运行 `bash scripts/test-native.sh`；按修改范围验证原生 UI 和可选监控探针。
3. 运行 `bash scripts/build-native.sh`，并执行 `codesign --verify --deep --strict build/CodexUsageBar.app`。
4. 安装 DMG 打包依赖并执行 `bash scripts/build-dmg.sh`。
5. 生成 ZIP：

```sh
ditto -c -k --sequesterRsrc --keepParent build/CodexUsageBar.app build/CodexUsageBar-0.1.5-mac-arm64.zip
```

6. 在 `build/` 为 DMG 和 ZIP 生成 `SHA256SUMS.txt`，校验包内可执行文件与本次构建一致。
7. 更新中文/英文 README 和 `docs/releases/` 版本说明，提交后创建对应的 tag。
8. 创建 GitHub Release，上传 DMG、ZIP 与 SHA256SUMS.txt。不要将安装包或个人诊断数据提交到 Git 历史。
9. 核对远端 tag 指向的 commit、Release 是否公开发布、资产名称和大小。下载远端资产校验 SHA256。

The initial public release is v0.1.1. macOS 14+ and arm64 are the advertised binary targets. Intel binaries require a separate build and validation. Ad-hoc signing is not notarization; do not label a release notarized unless the Apple submission and stapling checks actually pass.
