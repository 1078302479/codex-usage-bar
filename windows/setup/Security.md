# Windows 安装包签名与拦截复核

Windows 版从本机注册的 Microsoft Store Codex 包生成独立的侧栏副本。安装向导显示副本的签名影响。安装包、启动器和卸载器属于本项目，可由项目发布者签名。原厂安装包及修改后的客户端副本由用户本机提供和生成。

## 发布者签名

需要受信任的代码签名证书和 Windows SDK 的 SignTool。证书及可访问的私钥由维护者保管，构建脚本使用当前用户证书存储中的证书指纹选择密钥。

```powershell
./windows/setup/Build-Installer.ps1 -Compiler '<ISCC.exe>' -Version 0.1.2 -SignTool '<signtool.exe>' -SigningThumbprint '<40 位证书指纹>'
```

构建会对启动器、Inno Setup 安装程序和卸载器使用 SHA-256 及时间戳。安装包签名验证通过后才生成下载校验值。传给 GitHub Releases 的 EXE 和校验文件应来自同一次签名构建。[Microsoft 签名说明](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options) · [Inno Setup 签名说明](https://jrsoftware.org/ishelp/topic_setup_signtool.htm)

从 v0.1.2 起，安装向导直接调用 Windows 启动器，桌面和开始菜单快捷方式也使用该程序。GitHub 的预览版构建未配置代码签名证书，安装程序会显示为未签名。

## 分别记录两种告警

先在火绒的 **安全日志** 记录检测名称、拦截对象文件名、程序版本和病毒库版本。公开分享日志前遮盖本机用户名。可通过火绒的 **病毒上报** 入口查看样本复核渠道。[火绒操作手册](https://cdn-www.huorong.cn/Public/Uploads/uploadfile/files/20260512/%E7%81%AB%E7%BB%92%E5%AE%89%E5%85%A8%E8%BD%AF%E4%BB%B6%206.0%20%E7%94%A8%E6%88%B7%E6%93%8D%E4%BD%9C%E6%89%8B%E5%86%8C%EF%BC%886.0.10.0%E7%89%88%E6%9C%AC%EF%BC%89.pdf)

- **安装包或启动器告警**。提供项目 Release 链接、被拦文件名、SHA-256 和检测名称，请厂商复核具体的公开构建。安装包的 SHA-256 可从对应 Release 的 Assets 获取。
- **生成的 ChatGPT.exe 告警**。提供 Store 客户端版本、安装时生成的补丁清单中的原始与修改后 SHA-256，以及检测名称。清单位于安装目录下的 `.local\windows-sidebar-stage-*\usagebar-patch.json`。安全厂商可用相同的 Store 客户端版本和公开的 UsageBar 安装包在测试环境复现。

侧栏资源进入 Electron 的 ASAR 存档，修改后必须同步更新客户端 EXE 里的摘要。完整性校验继续运行，副本的原厂 Authenticode 签名会失效。项目签名只用于自有程序，修改后的 Codex 副本仍可能触发厂商的签名或行为检测。[Electron ASAR 完整性说明](https://www.electronjs.org/docs/latest/tutorial/asar-integrity)
