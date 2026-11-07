param(
    [Parameter(Mandatory)][string]$Compiler,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.1.1'
)
$ErrorActionPreference = 'Stop'
$windowsDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repoDirectory = Split-Path -Parent $windowsDirectory
$compilerPath = (Resolve-Path -LiteralPath $Compiler).ProviderPath
$packageDir = (New-Item -ItemType Directory -Path (Join-Path $repoDirectory '.local/windows-package') -Force).FullName
$nodeVersion = '22.22.3'
$nodeArchive = Join-Path $packageDir "node-v$nodeVersion-win-x64.zip"
$nodeSha256 = '6c8d54f635feff4df76c2ca80f45332eb2ff57d25226edce36592e51a177ee33'
if (-not (Test-Path -LiteralPath $nodeArchive)) {
    & curl.exe -fsSL --retry 2 --output $nodeArchive "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-win-x64.zip"
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $nodeArchive -ErrorAction SilentlyContinue
        throw 'Node.js archive download failed.'
    }
}
if ((Get-FileHash -LiteralPath $nodeArchive).Hash -ne $nodeSha256) {
    throw "Node.js checksum mismatch. Inspect or remove $nodeArchive before retrying."
}

$work = (New-Item -ItemType Directory -Path (Join-Path $packageDir ([guid]::NewGuid().ToString('N')))).FullName
try {
    Expand-Archive -LiteralPath $nodeArchive -DestinationPath $work
    $nodeDist = Join-Path $work "node-v$nodeVersion-win-x64"
    $payload = Join-Path $work 'payload'
    $payloadWindows = Join-Path $payload 'windows'
    $payloadPatch = Join-Path $payloadWindows 'patch'
    $runtime = Join-Path $payloadWindows 'runtime'
    $acorn = Join-Path $payloadWindows 'node_modules/acorn'
    New-Item -ItemType Directory -Path $payloadPatch, $runtime, $acorn | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoDirectory 'LICENSE'), (Join-Path $repoDirectory 'NOTICE') -Destination $payload
    Copy-Item -LiteralPath (Join-Path $windowsDirectory 'Install-Sidebar.ps1') -Destination $payloadWindows
    Get-ChildItem -LiteralPath (Join-Path $windowsDirectory 'patch') -Filter *.mjs -File |
        Copy-Item -Destination $payloadPatch
    foreach ($script in @('Open-SidebarClient.ps1', 'Start-SidebarTest.ps1', 'Resolve-SidebarNode.ps1', 'Check-SidebarUpdate.ps1')) {
        Copy-Item -LiteralPath (Join-Path $windowsDirectory "patch/$script") -Destination $payloadPatch
    }
    Copy-Item -LiteralPath (Join-Path $nodeDist 'node.exe'), (Join-Path $nodeDist 'LICENSE') -Destination $runtime
    foreach ($file in @('package.json', 'LICENSE', 'dist')) {
        Copy-Item -LiteralPath (Join-Path $windowsDirectory "node_modules/acorn/$file") -Destination $acorn -Recurse
    }
    & $compilerPath "/DAppVersion=$Version" "/DPayloadDir=$payload" "/O$packageDir" (Join-Path $PSScriptRoot 'CodexUsageBar.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
    $setup = Join-Path $packageDir 'CodexUsageBar-Windows-x64-Setup.exe'
    $hash = (Get-FileHash -LiteralPath $setup).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$setup.sha256" -Encoding Ascii -Value "$hash  CodexUsageBar-Windows-x64-Setup.exe"
    Write-Host "Installer: $setup"
} finally {
    $resolvedWork = (Resolve-Path -LiteralPath $work).ProviderPath
    if ((Split-Path -Parent $resolvedWork) -eq $packageDir -and (Split-Path -Leaf $resolvedWork) -match '^[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}
