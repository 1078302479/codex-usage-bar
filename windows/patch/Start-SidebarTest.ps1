param([string]$PatchStage = '', [switch]$VerifyOnly, [switch]$LifecycleOwned)
$ErrorActionPreference = 'Stop'
if (-not $VerifyOnly -and -not $LifecycleOwned) {
    & (Join-Path $PSScriptRoot 'Open-SidebarClient.ps1') -PatchStage $PatchStage
    return
}
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testDirectory = Join-Path $repoDirectory '.local/windows-sidebar-client'
$stageDirectory = Join-Path $repoDirectory '.local/windows-sidebar-v1'
$activeStageFile = Join-Path $repoDirectory '.local/windows-sidebar-active-stage.txt'
if ($PatchStage) {
    $stageDirectory = (Resolve-Path -LiteralPath $PatchStage).Path
} elseif (Test-Path -LiteralPath $activeStageFile) {
    $stageDirectory = (Resolve-Path -LiteralPath (Get-Content -LiteralPath $activeStageFile -Raw).Trim()).Path
}
$executable = Join-Path $testDirectory 'ChatGPT.exe'

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'The complete patched test copy has not been prepared.'
}

# Never kill the user's current client or copy an authenticated user profile.
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if ($nodeCommand) {
    $nodeExecutable = $nodeCommand.Source
} else {
    $nodeExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
    if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) {
        throw 'Node.js 20+ is required to verify the test copy before launch.'
    }
}

& $nodeExecutable (Join-Path $PSScriptRoot 'manage.mjs') verify $testDirectory $stageDirectory
if ($LASTEXITCODE -ne 0) { throw 'Test copy verification failed; refusing to launch.' }
if ($VerifyOnly) { return }

$activeClient = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue
if ($activeClient) {
    throw 'Save your work and exit the current ChatGPT/Codex desktop client before starting the test copy. No process was stopped.'
}

Write-Host 'Starting the local sidebar test copy. The official Store installation is unchanged.'
Write-Host 'This experimental executable has a modified signature. If Windows blocks it, stop; do not disable system protection.'
# This is the visible interactive app requested by the user, not a background helper.
Start-Process -FilePath $executable -WorkingDirectory $testDirectory
