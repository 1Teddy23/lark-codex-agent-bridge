. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
$configDir = Join-Path $root "config"
$envPath = Join-Path $configDir "bridge.env"
$examplePath = Join-Path $configDir "bridge.env.example"
$projectsPath = Join-Path $root "projects.json"
$projectsExamplePath = Join-Path $root "projects.json.example"
$clawDir = Join-Path $root "claw"
$runtimeDir = Join-Path $root "runtime"
$logsDir = Join-Path $runtimeDir "logs"
$inboxDir = Join-Path $root "inbox"

if (-not (Test-Path -LiteralPath $envPath)) {
  Copy-Item -LiteralPath $examplePath -Destination $envPath
  Write-Host "Created config/bridge.env from example. Fill it before starting the bridge."
}

if (-not (Test-Path -LiteralPath $projectsPath)) {
  if (-not (Test-Path -LiteralPath $projectsExamplePath)) {
    throw "Missing projects.json.example."
  }
  $runtimeForward = $runtimeDir.Replace("\", "/")
  $projectsTemplate = Get-Content -LiteralPath $projectsExamplePath -Raw -Encoding UTF8
  [System.IO.File]::WriteAllText(
    $projectsPath,
    $projectsTemplate.Replace("__BRIDGE_RUNTIME__", $runtimeForward),
    [System.Text.UTF8Encoding]::new($false)
  )
  Write-Host "Created projects.json for the local runtime workspace."
}

New-Item -ItemType Directory -Force -Path $runtimeDir, $logsDir, (Join-Path $runtimeDir "inbox"), (Join-Path $runtimeDir ".cursor\rules") | Out-Null

$envMap = Read-BridgeEnv -EnvPath $envPath
Write-ClawEnv -Env $envMap -TargetPath (Join-Path $clawDir ".env")

Add-BunToPath
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "Bun is not installed. Run: powershell -ExecutionPolicy Bypass -File scripts/install-bun.ps1"
  exit 1
}

if (-not (Get-Command agent -ErrorAction SilentlyContinue) -and (-not $envMap.ContainsKey("AGENT_BIN") -or $envMap["AGENT_BIN"] -eq "agent")) {
  Write-Host "Warning: Cursor Agent CLI 'agent' was not found in PATH."
  Write-Host "Set AGENT_BIN in config/bridge.env to the full path of your Agent CLI."
}

Push-Location $clawDir
try {
  bun install
} finally {
  Pop-Location
}

Write-Host "Setup complete."
