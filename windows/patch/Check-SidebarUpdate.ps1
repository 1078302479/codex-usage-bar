$ErrorActionPreference = 'Stop'
$repoDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$versionFile = Join-Path $repoDirectory '.local/windows-sidebar-version.txt'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { return }

$mutex = [Threading.Mutex]::new($false, 'Local\CodexUsageBarWindowsUpdate')
$ownsMutex = $false
$tempDirectory = $null
$accepted = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { return }

    $currentVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    $node = & (Join-Path $PSScriptRoot 'Resolve-SidebarNode.ps1')
    $updater = Join-Path $PSScriptRoot 'update-release.mjs'
    $result = & $node $updater check $currentVersion 2>$null
    if ($LASTEXITCODE -ne 0) { return }
    $update = $result | ConvertFrom-Json
    if (-not $update) { return }

    Add-Type -AssemblyName System.Windows.Forms
    $title = 'Codex UsageBar'
    $text = "Windows 版有更新：v$currentVersion → v$($update.version)。" +
        "`n`n是否下载并打开安装向导？安装前请保存工作并退出当前的 Codex UsageBar 窗口。"
    $choice = [Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Information', 'Button2')
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
    $accepted = $true

    $tempDirectory = (New-Item -ItemType Directory -Path (
        Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageBar-update-' + [guid]::NewGuid().ToString('N'))
    )).FullName
    $installer = Join-Path $tempDirectory 'CodexUsageBar-Windows-x64-Setup.exe'
    & $node $updater download $update.version $update.sha256 $update.size $installer 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Installer download or verification failed.' }
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf) -or
        (Get-Content -LiteralPath $versionFile -Raw).Trim() -ne $currentVersion) { return }

    # Preserve Windows' handling of an unsigned file downloaded from the Internet.
    Set-Content -LiteralPath $installer -Stream Zone.Identifier -Encoding Ascii -Value @('[ZoneTransfer]', 'ZoneId=3')
    Start-Process -FilePath $installer -Wait
} catch {
    if ($accepted) {
        [void][Windows.Forms.MessageBox]::Show(
            '更新包下载、校验或启动失败。你可以下次打开时重试，或从 GitHub 下载 Windows 安装包。',
            'Codex UsageBar', 'OK', 'Warning')
    }
} finally {
    if ($tempDirectory) {
        Remove-Item -LiteralPath (Join-Path $tempDirectory 'CodexUsageBar-Windows-x64-Setup.exe') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $tempDirectory 'CodexUsageBar-Windows-x64-Setup.exe.part') -Force -ErrorAction SilentlyContinue
        try { [IO.Directory]::Delete($tempDirectory) } catch [IO.IOException] {}
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
