param([Parameter(Mandatory = $true)][string]$CurrentExecutable)

$ErrorActionPreference = 'Stop'
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testDirectory = Join-Path $repoDirectory '.local/windows-sidebar-client'
$statusFile = Join-Path $repoDirectory '.local/windows-sidebar-switch.json'
$testExecutable = Join-Path $testDirectory 'ChatGPT.exe'

function Write-SwitchStatus([string]$State, [string]$Message) {
    @{ state = $State; message = $Message; time = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
}

try {
    $resolvedCurrent = (Resolve-Path -LiteralPath $CurrentExecutable).Path
    if ([System.IO.Path]::GetFileName($resolvedCurrent) -ne 'ChatGPT.exe') {
        throw 'Unexpected current-client executable; refusing to close unrelated processes.'
    }
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1') -VerifyOnly

    $currentProcesses = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $resolvedCurrent })
    $windows = @($currentProcesses | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($windows.Count -ne 1) { throw 'Expected one current-client window. No processes were stopped.' }
    Write-SwitchStatus 'closing' 'Requesting normal window close; no force termination.'
    if (-not $windows[0].CloseMainWindow()) { throw 'Client did not accept a normal close request.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 400
        $stillRunning = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $resolvedCurrent })
    } while ($stillRunning.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($stillRunning.Count -gt 0) {
        Write-SwitchStatus 'needs-exit' 'The current client is still running (possibly in tray or waiting for confirmation). Exit it normally, then run Start-SidebarTest.ps1. No process was forcibly stopped.'
        exit 2
    }

    Write-SwitchStatus 'starting' 'Starting the patched test copy; original installation is unchanged.'
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1')
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $runningTest = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $testExecutable })
    } while ($runningTest.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($runningTest.Count -eq 0) { throw 'No running test-copy process was observed. Keep the original installation; inspect startup errors before retrying.' }
    Write-SwitchStatus 'process-started' 'Patched test-copy process observed. Sidebar rendering still requires visual confirmation.'
} catch {
    Write-SwitchStatus 'failed' $_.Exception.Message
    exit 1
}
