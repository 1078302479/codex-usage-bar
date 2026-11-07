param([Parameter(Mandatory = $true)][string]$PreviousStage,
      [Parameter(Mandatory = $true)][string]$NewStage)
$ErrorActionPreference = 'Stop'
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testDirectory = Join-Path $repoDirectory '.local/windows-sidebar-client'
$testExecutable = Join-Path $testDirectory 'ChatGPT.exe'
$statusFile = Join-Path $repoDirectory '.local/windows-sidebar-style-update.json'
$lockFile = Join-Path $repoDirectory '.local/windows-sidebar-launch.lock'
$updateLock = $null
$diagnosticFile = Join-Path $repoDirectory '.local/windows-sidebar-update-manager.log'
$nodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source
$manager = Join-Path $PSScriptRoot 'manage.mjs'
function Write-UpdateStatus([string]$State, [string]$Message) {
    @{ state = $State; message = $Message; time = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
}
function Invoke-PatchManager([string]$Action, [string]$Stage) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $managerOutput = & $nodeExecutable $manager $Action $testDirectory $Stage 2>&1 | Out-String
        $managerExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    "[$Action] $managerOutput" | Add-Content -LiteralPath $diagnosticFile -Encoding UTF8
    if ($managerExit -ne 0) { throw "Patch manager failed during ${Action}: $managerOutput" }
}
try {
    # Share the lock with every shortcut and launcher for the whole replacement
    # and restart transaction. A second shortcut cannot reopen the old copy.
    $updateLock = [System.IO.File]::Open($lockFile, 'CreateNew', 'ReadWrite', 'None')
    $PreviousStage = (Resolve-Path -LiteralPath $PreviousStage).Path
    $NewStage = (Resolve-Path -LiteralPath $NewStage).Path
    Invoke-PatchManager 'verify' $PreviousStage
    $oldManifest = Get-Content -LiteralPath (Join-Path $PreviousStage 'usagebar-patch.json') -Raw | ConvertFrom-Json
    $newManifest = Get-Content -LiteralPath (Join-Path $NewStage 'usagebar-patch.json') -Raw | ConvertFrom-Json
    foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) {
        if ($oldManifest.files.$relative.before -ne $newManifest.files.$relative.before) {
            throw 'Style update requires the same underlying client version.'
        }
    }
    Write-UpdateStatus 'waiting' 'Preparing normal restart of the test copy for the official menu style.'
    Start-Sleep -Seconds 5
    $clients = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $testExecutable })
    $windows = @($clients | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($windows.Count -gt 1) { throw 'Multiple test-copy windows are open; close them before updating.' }
    if ($windows.Count -eq 1) { $null = $windows[0].CloseMainWindow() }
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $clients = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $testExecutable })
        if ($clients.Count -eq 0) { break }
        Write-UpdateStatus 'waiting-for-exit' 'Exit the test copy normally to install the new style; no processes will be forced to stop.'
        Start-Sleep -Milliseconds 700
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($clients.Count -gt 0) { throw 'Timed out waiting for normal exit. Existing patch remains active.' }
    Invoke-PatchManager 'restore' $PreviousStage
    try { Invoke-PatchManager 'apply' $NewStage } catch {
        Write-UpdateStatus 'failed' 'Style application failed after restoring the original files in the test copy. Use the installed official app while inspecting the error.'
        throw
    }
    Invoke-PatchManager 'verify' $NewStage
    Set-Content -LiteralPath (Join-Path $repoDirectory '.local/windows-sidebar-active-stage.txt') -Value $NewStage -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1') -PatchStage $NewStage -LifecycleOwned
    Start-Sleep -Seconds 3
    $launched = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $testExecutable })
    if ($launched.Count -eq 0) { throw 'The styled test copy did not remain running.' }
    Write-UpdateStatus 'process-started' 'Official menu style installed and test process started; visual confirmation is pending.'
} catch {
    Write-UpdateStatus 'failed' $_.Exception.Message
    exit 1
} finally {
    if ($updateLock) {
        $updateLock.Dispose()
        Remove-Item -LiteralPath $lockFile
    }
}
