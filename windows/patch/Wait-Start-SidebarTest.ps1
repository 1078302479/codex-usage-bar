param([Parameter(Mandatory = $true)][string]$CurrentExecutable)
$ErrorActionPreference = 'Stop'
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$statusFile = Join-Path $repoDirectory '.local/windows-sidebar-switch.json'
function Write-WaitStatus([string]$State, [string]$Message) {
    @{ state = $State; message = $Message; time = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
}
try {
    $currentPath = (Resolve-Path -LiteralPath $CurrentExecutable).Path
    if ([System.IO.Path]::GetFileName($currentPath) -ne 'ChatGPT.exe') { throw 'Unexpected current executable.' }
    Write-WaitStatus 'waiting-for-user-exit' 'Waiting up to 5 minutes for the user to exit the original client normally. No force termination.'
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $remaining = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $currentPath })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        Write-WaitStatus 'wait-expired' 'Original client still running; no app was started. Use Start-SidebarTest.ps1 after exiting normally.'
        exit 2
    }
    & (Join-Path $PSScriptRoot 'Start-SidebarTest.ps1')
    Start-Sleep -Seconds 3
    $expected = Join-Path $repoDirectory '.local/windows-sidebar-client/ChatGPT.exe'
    $test = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $expected })
    if ($test.Count -eq 0) { throw 'Test copy did not remain running. Inspect startup errors; original installation is unchanged.' }
    Write-WaitStatus 'process-started' 'Patched test-copy process observed; sidebar rendering requires visual confirmation.'
} catch {
    Write-WaitStatus 'failed' $_.Exception.Message
    exit 1
}
