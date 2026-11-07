param([string]$SourceApp = '', [switch]$SkipShortcut)
$ErrorActionPreference = 'Stop'
$repoDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$localDirectory = Join-Path $repoDirectory '.local'
$clientDirectory = Join-Path $localDirectory 'windows-sidebar-client'
$activeStage = Join-Path $localDirectory 'windows-sidebar-active-stage.txt'
$nodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source
$manager = Join-Path $PSScriptRoot 'patch/manage.mjs'

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'node_modules/acorn/package.json'))) {
    throw 'Install the locked dependencies first: cd windows; pnpm install --frozen-lockfile'
}
if (Test-Path -LiteralPath $clientDirectory) {
    throw 'A test copy already exists. See windows/README.md for update and recovery steps.'
}
if (-not $SourceApp) {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' | Where-Object InstallLocation |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) { throw 'Codex Store package not found. Install the official client or pass -SourceApp.' }
    $SourceApp = Join-Path $package.InstallLocation 'app'
}
$SourceApp = (Resolve-Path -LiteralPath $SourceApp).ProviderPath
foreach ($relativePath in @('ChatGPT.exe', 'resources/app.asar')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceApp $relativePath) -PathType Leaf)) {
        throw "Source is not a supported Windows client directory: missing $relativePath"
    }
}
$localPrefix = $localDirectory.TrimEnd('\') + '\'
if ($SourceApp.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $localPrefix.StartsWith($SourceApp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose the original client directory outside the generated output directory.'
}

New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
$installLockPath = Join-Path $localDirectory 'windows-sidebar-launch.lock'
$installLock = [System.IO.File]::Open($installLockPath, 'CreateNew', 'ReadWrite', 'None')
try {
    if (Test-Path -LiteralPath $clientDirectory) { throw 'A test copy already exists.' }
    $stageDirectory = Join-Path $localDirectory ('windows-sidebar-stage-' + [guid]::NewGuid().ToString('N'))
    function Invoke-PatchManager([string]$Action, [string]$AppDirectory) {
        & $nodeExecutable $manager $Action $AppDirectory $stageDirectory
        if ($LASTEXITCODE -ne 0) { throw "Patch manager failed during $Action. See the error above." }
    }
    Invoke-PatchManager 'stage' $SourceApp
    & robocopy.exe $SourceApp $clientDirectory /E /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "Client copy failed (robocopy exit $LASTEXITCODE)." }
    Invoke-PatchManager 'apply' $clientDirectory
    Invoke-PatchManager 'verify' $clientDirectory
    Set-Content -LiteralPath $activeStage -Value $stageDirectory -Encoding UTF8

    if (-not $SkipShortcut) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
            $shortcutPath = Join-Path $desktop 'Codex UsageBar (Windows).lnk'
            $launcher = Join-Path $PSScriptRoot 'patch/Open-SidebarClient.ps1'
            $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -File "' + $launcher + '"'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            if ((Test-Path -LiteralPath $shortcutPath) -and $shortcut.Arguments -ne $arguments) {
                Write-Warning 'A shortcut with that name already exists. Use Open-SidebarClient.ps1 to launch this copy.'
            } else {
                $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
                $shortcut.Arguments = $arguments
                $shortcut.WorkingDirectory = $repoDirectory
                $shortcut.IconLocation = (Join-Path $clientDirectory 'ChatGPT.exe') + ',0'
                $shortcut.WindowStyle = 7
                $shortcut.Description = 'Launch the local Codex UsageBar Windows test copy'
                $shortcut.Save()
            }
        }
    }
    Write-Host 'Installed and verified. Exit the running official client, then use the shortcut or windows/patch/Open-SidebarClient.ps1.'
} finally {
    $installLock.Dispose()
    Remove-Item -LiteralPath $installLockPath
}
