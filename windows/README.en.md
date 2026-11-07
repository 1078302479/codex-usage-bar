# Codex UsageBar for Windows

[简体中文](README.md) · [Technical notes](patch/README.md) · [macOS branch](https://github.com/1078302479/codex-usage-bar/tree/main)

See short-window and weekly quota in the Codex desktop sidebar. Hover for reset times, countdowns, and reset-credit details. **Use** opens the official Usage limit resets settings section, where you can confirm redemption.

This experimental community build generates a separate client copy from your installed client. Modifying the copy invalidates the original executable signature. If Windows or your organization blocks the copy, use the official installation. Project source is licensed under [Apache 2.0](../LICENSE).

## Install

1. Install the official Microsoft Store edition of Codex on Windows 11 x64.
2. Download and run [CodexUsageBar-Windows-x64-Setup.exe](https://github.com/1078302479/codex-usage-bar/releases/download/windows-v0.1.0/CodexUsageBar-Windows-x64-Setup.exe).
3. Save your work and exit Codex, then open **Codex UsageBar** from the desktop or Start menu.

Setup includes Node.js and dependencies. Leave several GB free for the locally generated client copy. Setup is unsigned and checks the Store client for compatibility. It was tested with internal build `26.1103.31037` in Store package `26.1103.3517.0`.

To upgrade, exit Codex UsageBar and run the new installer. Rerun it after a Store client update to rebuild the local copy. Use **Settings → Apps → Installed apps → Codex UsageBar (Windows)** to uninstall. For installation failures, see `%LOCALAPPDATA%\CodexUsageBar-setup.log`.

## Install from source

Install Git, Node.js 22+, and pnpm first.

```powershell
git clone --branch windows --single-branch https://github.com/1078302479/codex-usage-bar.git
cd codex-usage-bar
pnpm --dir windows install --frozen-lockfile
powershell -NoProfile -File windows/Install-Sidebar.ps1
```

Save your work and exit the running client. Open **Codex UsageBar (Windows)** from the desktop, or run `powershell -NoProfile -File windows/patch/Open-SidebarClient.ps1` from the repository root. Use `-SourceApp` to provide the original app directory manually or `-SkipShortcut` to skip creating the desktop shortcut.

## Update or remove a source installation

Run `git pull --ff-only` and `pnpm --dir windows install --frozen-lockfile`. Exit the test copy, move `.local/windows-sidebar-client` to a backup location, and rerun the installer. Follow the same copy-and-install steps after an official client update. The installer checks the updated client for compatibility.

To restore the generated copy, exit it and run the following commands.

```powershell
$stage = (Get-Content .local/windows-sidebar-active-stage.txt -Raw).Trim()
node windows/patch/manage.mjs restore .local/windows-sidebar-client $stage
```

To uninstall, exit the copy and remove its desktop shortcut and generated project files under `.local`. Launch the official client from its normal Windows entry. For bug reports, include the Windows and client versions and redacted errors.

Run the automated checks with `pnpm --dir windows test`.

To build the EXE, install the locked dependencies and run `./windows/setup/Build-Installer.ps1 -Compiler '<path to ISCC.exe>'` with Inno Setup 6.7.4. The build writes the EXE and checksum to `.local/windows-package`.
