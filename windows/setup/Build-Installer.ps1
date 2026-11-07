param(
    [Parameter(Mandatory)][string]$Compiler,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.1.2',
    [string]$SignTool,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$SigningThumbprint,
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
$windowsDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repoDirectory = Split-Path -Parent $windowsDirectory
$compilerPath = (Resolve-Path -LiteralPath $Compiler).ProviderPath
$packageDir = (New-Item -ItemType Directory -Path (Join-Path $repoDirectory '.local/windows-package') -Force).FullName
if ([bool]$SignTool -ne [bool]$SigningThumbprint) { throw 'Provide both SignTool and SigningThumbprint to sign the installer.' }
$outputDir = $packageDir
if ($SmokeTest) { $outputDir = (New-Item -ItemType Directory -Path (Join-Path $packageDir 'smoke') -Force).FullName }
$csc = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
function Assert-PublisherSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $SigningThumbprint) {
        throw "Publisher signature verification failed for $Path."
    }
}
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
    Get-ChildItem -LiteralPath (Join-Path $windowsDirectory 'patch') -Filter *.mjs -File |
        Copy-Item -Destination $payloadPatch
    Copy-Item -LiteralPath (Join-Path $nodeDist 'node.exe'), (Join-Path $nodeDist 'LICENSE') -Destination $runtime
    foreach ($file in @('package.json', 'LICENSE', 'dist')) {
        Copy-Item -LiteralPath (Join-Path $windowsDirectory "node_modules/acorn/$file") -Destination $acorn -Recurse
    }
    $launcher = Join-Path $payload 'CodexUsageBar.exe'
    $cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll', "/out:$launcher")
    & $csc @cscArgs (Join-Path $PSScriptRoot 'CodexUsageBar.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Windows launcher compilation failed.' }
    $options = @("/DAppVersion=$Version", "/DPayloadDir=$payload", "/O$outputDir")
    if ($SmokeTest) { $options += '/DSmokeTest' }
    if ($SignTool) {
        $signer = (Resolve-Path -LiteralPath $SignTool).ProviderPath
        $signArgs = @('sign', '/sha1', $SigningThumbprint, '/fd', 'SHA256',
            '/tr', 'https://timestamp.digicert.com', '/td', 'SHA256')
        & $signer @signArgs $launcher
        if ($LASTEXITCODE -ne 0) { throw 'Launcher Authenticode signing failed.' }
        Assert-PublisherSignature $launcher
        $options += '/DEnableSigning', ('/Susagebar=$q' + $signer + '$q ' + ($signArgs -join ' ') + ' $f')
    }
    & $compilerPath @options (Join-Path $PSScriptRoot 'CodexUsageBar.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
    $setup = Join-Path $outputDir 'CodexUsageBar-Windows-x64-Setup.exe'
    if ($SignTool) { Assert-PublisherSignature $setup }
    $hash = (Get-FileHash -LiteralPath $setup).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$setup.sha256" -Encoding Ascii -Value "$hash  CodexUsageBar-Windows-x64-Setup.exe"
    Write-Host "Installer: $setup"
} finally {
    $resolvedWork = (Resolve-Path -LiteralPath $work).ProviderPath
    if ((Split-Path -Parent $resolvedWork) -eq $packageDir -and (Split-Path -Leaf $resolvedWork) -match '^[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}
