param([switch]$VerifyOnly, [string]$PatchStage = '', [switch]$ShowErrors)
$ErrorActionPreference = 'Stop'
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testDirectory = Join-Path $repoDirectory '.local/windows-sidebar-client'
$testExecutable = Join-Path $testDirectory 'ChatGPT.exe'
$statusFile = Join-Path $repoDirectory '.local/windows-sidebar-launch.json'
$lockFile = Join-Path $repoDirectory '.local/windows-sidebar-launch.lock'
$launchLock = $null
$launched = $false
function Write-LaunchStatus([string]$State, [string]$Message) {
    @{ state = $State; message = $Message; time = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
}
try {
    if (-not $VerifyOnly) {
        try { $launchLock = [System.IO.File]::Open($lockFile, 'CreateNew', 'ReadWrite', 'None') }
        catch [System.IO.IOException] {
            Write-LaunchStatus 'operation-in-progress' 'A client update or launch already owns the lifecycle lock. Wait for it to finish.'
            return
        }
    }
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1') -VerifyOnly -PatchStage $PatchStage
    if ($VerifyOnly) { return }
    $clients = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    $patched = @($clients | Where-Object { $_.Path -eq $testExecutable })
    if ($patched.Count -gt 0) {
        # Existing-instance handling is owned by the client itself.
        Start-Process -FilePath $testExecutable -WorkingDirectory $testDirectory
        Write-LaunchStatus 'already-running' 'The patched client is already running.'
        $launched = $true
        return
    }
    $unknown = @($clients | Where-Object { -not $_.Path -or $_.Path -notmatch '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' })
    if ($unknown.Count -gt 0) { throw 'Another ChatGPT installation is running. Exit it before opening the sidebar test client.' }
    $windows = @($clients | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($windows.Count -gt 1) { throw 'Save and close the open client windows before switching.' }
    Write-LaunchStatus 'switching' 'Requesting normal exit of the installed client before launching the sidebar test client.'
    if ($windows.Count -eq 1) { $null = $windows[0].CloseMainWindow() }
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $clients = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
        if ($clients.Count -eq 0) { break }
        Write-LaunchStatus 'waiting-for-exit' 'Confirm normal exit in the current client. The verified sidebar test copy will open automatically.'
        Start-Sleep -Milliseconds 700
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($clients.Count -gt 0) { throw 'Current client is still running. Exit it and use the sidebar-test shortcut again.' }
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1') -LifecycleOwned -PatchStage $PatchStage
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $patched = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $testExecutable })
        $visible = @($patched | Where-Object { $_.MainWindowHandle -ne 0 })
    } while ($visible.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($visible.Count -eq 0) { throw 'No visible patched-client window was observed. Check client startup before retrying.' }
    Write-LaunchStatus 'window-started' 'Verified patched-client path and visible window. Sidebar rendering needs visual confirmation.'
    $launched = $true
} catch {
    Write-LaunchStatus 'failed' $_.Exception.Message
    if ($ShowErrors) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Codex UsageBar')
    }
    exit 1
} finally {
    if ($launchLock) {
        $launchLock.Dispose()
        Remove-Item -LiteralPath $lockFile
    }
    if ($launched -and (Test-Path -LiteralPath (Join-Path $repoDirectory '.local/windows-sidebar-version.txt') -PathType Leaf)) {
        $checker = Join-Path $PSScriptRoot 'Check-SidebarUpdate.ps1'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $checker + '"'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}
