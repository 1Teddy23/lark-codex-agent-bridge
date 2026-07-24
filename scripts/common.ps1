$ErrorActionPreference = "Stop"

function Get-BridgeRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

function Read-BridgeEnv {
  param([string]$EnvPath)
  $result = @{}
  if (-not (Test-Path -LiteralPath $EnvPath)) {
    return $result
  }
  foreach ($line in Get-Content -LiteralPath $EnvPath -Encoding UTF8) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
    $idx = $trimmed.IndexOf("=")
    if ($idx -lt 0) { continue }
    $key = $trimmed.Substring(0, $idx).Trim()
    $value = $trimmed.Substring($idx + 1).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $result[$key] = $value
  }
  return $result
}

function Write-ClawEnv {
  param(
    [hashtable]$Env,
    [string]$TargetPath
  )
  $keys = @(
    "CURSOR_API_KEY",
    "FEISHU_APP_ID",
    "FEISHU_APP_SECRET",
    "FEISHU_USER_ACCESS_TOKEN",
    "FEISHU_REFRESH_TOKEN",
    "CURSOR_MODEL",
    "CODEX_AGENT_TIMEOUT_MS",
    "VOLC_STT_APP_ID",
    "VOLC_STT_ACCESS_TOKEN",
    "VOLC_EMBEDDING_API_KEY",
    "VOLC_EMBEDDING_MODEL"
  )
  $lines = @("# Generated from config/bridge.env by scripts/setup.ps1 or scripts/start.ps1")
  foreach ($key in $keys) {
    $value = ""
    if ($Env.ContainsKey($key)) { $value = [string]$Env[$key] }
    $lines += "$key=$value"
  }
  Set-Content -LiteralPath $TargetPath -Value ($lines -join "`n") -Encoding UTF8
}

function Add-BunToPath {
  $candidates = @(
    (Join-Path $env:USERPROFILE ".bun\bin"),
    (Join-Path $env:LOCALAPPDATA "bun\bin")
  )
  foreach ($candidate in $candidates) {
    if ((Test-Path -LiteralPath $candidate) -and ($env:PATH -notlike "*$candidate*")) {
      $env:PATH = "$candidate;$env:PATH"
    }
  }
}

function Test-Placeholder {
  param([string]$Value)
  if (-not $Value) { return $true }
  return $Value -match "^(cli_)?x{5,}|your_|key_your|xxx"
}
