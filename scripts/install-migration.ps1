param(
  [switch]$NoStart,
  [switch]$SkipCodexSkills
)

. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
$rootForward = $root.Replace("\", "/")
$envPath = Join-Path $root "config\bridge.env"
$projectsPath = Join-Path $root "projects.json"
$manifestPath = Join-Path $root ".migration\manifest.json"

function Set-BridgeEnvValue {
  param(
    [string]$Path,
    [string]$Key,
    [string]$Value
  )

  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
  }

  $found = $false
  $updated = foreach ($line in $lines) {
    if ($line -match "^\s*$([regex]::Escape($Key))\s*=") {
      $found = $true
      "$Key=$Value"
    } else {
      $line
    }
  }

  if (-not $found) {
    $updated += "$Key=$Value"
  }

  Set-Content -LiteralPath $Path -Value ($updated -join "`n") -Encoding UTF8
}

function Rewrite-TextFilePath {
  param(
    [string]$Path,
    [string]$OldText,
    [string]$NewText
  )
  if (-not $OldText -or -not (Test-Path -LiteralPath $Path)) { return }
  $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $content = $content.Replace($OldText, $NewText)
  Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

Write-Host "Installing Lark Agent Bridge migration package..."
Write-Host "Root: $root"

if (-not (Test-Path -LiteralPath $envPath)) {
  throw "Missing config/bridge.env in migration package."
}

$sourceRoot = ""
$sourceRootForward = ""
if (Test-Path -LiteralPath $manifestPath) {
  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceRoot = [string]$manifest.source_root
    $sourceRootForward = [string]$manifest.source_root_forward
  } catch {
    Write-Host "Warning: could not read migration manifest: $($_.Exception.Message)"
  }
}

$rewriteFiles = @(
  (Join-Path $root "config\bridge.env"),
  (Join-Path $root "projects.json"),
  (Join-Path $root "claw\.sessions.json"),
  (Join-Path $root "claw\.topics.json")
)
foreach ($file in $rewriteFiles) {
  Rewrite-TextFilePath -Path $file -OldText $sourceRoot -NewText $root
  Rewrite-TextFilePath -Path $file -OldText $sourceRootForward -NewText $rootForward
}

Set-BridgeEnvValue -Path $envPath -Key "AGENT_BIN" -Value "$rootForward/scripts/codex-agent-adapter.cmd"
$envMap = Read-BridgeEnv -EnvPath $envPath
if (-not $envMap.ContainsKey("CODEX_AGENT_TIMEOUT_MS") -or -not $envMap["CODEX_AGENT_TIMEOUT_MS"]) {
  Set-BridgeEnvValue -Path $envPath -Key "CODEX_AGENT_TIMEOUT_MS" -Value "0"
}

if (Test-Path -LiteralPath $projectsPath) {
  $projects = Get-Content -LiteralPath $projectsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($projects.projects.PSObject.Properties["local"]) {
    $projects.projects.local.path = "$rootForward/runtime"
  }
  if (-not $projects.default_project) {
    $projects | Add-Member -NotePropertyName "default_project" -NotePropertyValue "local" -Force
  }
  $projects | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $projectsPath -Encoding UTF8
}

if (-not $SkipCodexSkills) {
  $skillSource = Join-Path $root ".migration\codex-skills"
  if (Test-Path -LiteralPath $skillSource) {
    $skillTarget = Join-Path $env:USERPROFILE ".codex\skills"
    New-Item -ItemType Directory -Force -Path $skillTarget | Out-Null
    Get-ChildItem -LiteralPath $skillSource -Directory -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $skillTarget -Recurse -Force
      Write-Host "Installed Codex skill: $($_.Name)"
    }
  }
}

Add-BunToPath
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "Bun is missing; running scripts/install-bun.ps1..."
  & (Join-Path $root "scripts\install-bun.ps1")
  Add-BunToPath
}

& (Join-Path $root "scripts\setup.ps1")
& (Join-Path $root "scripts\doctor.ps1")

if (-not $NoStart) {
  & (Join-Path $root "scripts\start-background.ps1")
  Start-Sleep -Seconds 5
  & (Join-Path $root "scripts\status.ps1")
} else {
  Write-Host "Skipped start because -NoStart was provided."
}

Write-Host ""
Write-Host "Migration install complete."
Write-Host "If Codex CLI is not logged in on this computer, open Codex once or run the local Codex login flow, then send /状态 in Feishu."
