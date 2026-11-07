$bundledNode = Join-Path $PSScriptRoot '../runtime/node.exe'
if (Test-Path -LiteralPath $bundledNode -PathType Leaf) { return $bundledNode }
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if ($nodeCommand) { return $nodeCommand.Source }
$workspaceNode = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
if (Test-Path -LiteralPath $workspaceNode -PathType Leaf) { return $workspaceNode }
throw 'Node.js 22+ is required when running from source.'
