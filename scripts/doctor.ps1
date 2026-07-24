. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
$envPath = Join-Path $root "config\bridge.env"
$clawEnvPath = Join-Path $root "claw\.env"
$projectsPath = Join-Path $root "projects.json"
$clawPackage = Join-Path $root "claw\package.json"
$runtimeDir = Join-Path $root "runtime"

Add-BunToPath
$envMap = Read-BridgeEnv -EnvPath $envPath

function Show-Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = "")
  $mark = if ($Ok) { "OK " } else { "NO " }
  Write-Host "$mark $Name $Detail"
}

Show-Check "bridge root" (Test-Path -LiteralPath $root) $root
Show-Check "claw package" (Test-Path -LiteralPath $clawPackage) $clawPackage
Show-Check "config/bridge.env" (Test-Path -LiteralPath $envPath) $envPath
Show-Check "projects.json" (Test-Path -LiteralPath $projectsPath) $projectsPath
Show-Check "runtime" (Test-Path -LiteralPath $runtimeDir) $runtimeDir
$bunCmd = Get-Command bun -ErrorAction SilentlyContinue
$bunDetail = if ($bunCmd) { (bun --version) } else { "missing" }
Show-Check "bun" ([bool]$bunCmd) $bunDetail

$agentBin = if ($envMap.ContainsKey("AGENT_BIN") -and $envMap["AGENT_BIN"]) { $envMap["AGENT_BIN"] } else { "agent" }
$agentFound = $false
if ($agentBin -ne "agent" -and (Test-Path -LiteralPath $agentBin)) {
  $agentFound = $true
} elseif (Get-Command $agentBin -ErrorAction SilentlyContinue) {
  $agentFound = $true
}
Show-Check "agent cli" $agentFound $agentBin

$usesCodexAdapter = $agentBin -match "codex-agent-adapter"

$cursorKey = if ($envMap.ContainsKey("CURSOR_API_KEY")) { $envMap["CURSOR_API_KEY"] } else { "" }
$feishuAppId = if ($envMap.ContainsKey("FEISHU_APP_ID")) { $envMap["FEISHU_APP_ID"] } else { "" }
$feishuSecret = if ($envMap.ContainsKey("FEISHU_APP_SECRET")) { $envMap["FEISHU_APP_SECRET"] } else { "" }
if ($usesCodexAdapter) {
  Show-Check "CURSOR_API_KEY not needed" $true "Codex CLI auth is used"
} else {
  Show-Check "CURSOR_API_KEY filled" (-not (Test-Placeholder $cursorKey)) ""
}
Show-Check "FEISHU_APP_ID filled" (-not (Test-Placeholder $feishuAppId)) ""
Show-Check "FEISHU_APP_SECRET filled" (-not (Test-Placeholder $feishuSecret)) ""
Show-Check "claw/.env generated" (Test-Path -LiteralPath $clawEnvPath) $clawEnvPath

Write-Host ""
Write-Host "Next:"
Write-Host "  1. Fill config/bridge.env"
Write-Host "  2. Run scripts/setup.ps1"
Write-Host "  3. Run scripts/start.ps1"
