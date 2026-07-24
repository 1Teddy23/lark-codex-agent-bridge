. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
$envPath = Join-Path $root "config\bridge.env"
$clawDir = Join-Path $root "claw"
$runtimeDir = Join-Path $root "runtime"
$logPath = Join-Path $runtimeDir "logs\feishu-cursor.log"

if (-not (Test-Path -LiteralPath $envPath)) {
  throw "Missing config/bridge.env. Run scripts/setup.ps1 first."
}

$envMap = Read-BridgeEnv -EnvPath $envPath
Write-ClawEnv -Env $envMap -TargetPath (Join-Path $clawDir ".env")

Add-BunToPath
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  throw "Bun is missing. Run scripts/install-bun.ps1 first."
}

foreach ($key in @("AGENT_BIN", "CODEX_BIN", "CODEX_AGENT_TIMEOUT_MS")) {
  if ($envMap.ContainsKey($key) -and $envMap[$key]) {
    Set-Item -Path "Env:$key" -Value $envMap[$key]
  }
}

if (-not $env:HOME -or $env:HOME -like "*Cadence*") {
  $env:HOME = $env:USERPROFILE
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null

function Write-BridgeLog {
  param([string]$Message)
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}" -f (Get-Date), $Message, [Environment]::NewLine
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::AppendAllText($logPath, $line, $utf8NoBom)
}

Write-Host "Starting Lark Agent Bridge..."
Write-Host "Root:  $root"
Write-Host "Claw:  $clawDir"
Write-Host "Log:   $logPath"
Write-Host "Agent: $env:AGENT_BIN"
Write-Host ""

Push-Location $clawDir
try {
  while ($true) {
    Write-BridgeLog "[Bridge] Starting bun process"
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $exitCode = -1
    try {
      # cmd redirects Bun's UTF-8 byte stream without PowerShell re-encoding
      # Chinese log output on Windows.
      $bunPath = (Get-Command bun -ErrorAction Stop).Source
      $commandLine = "`"$bunPath`" run start.ts >> `"$logPath`" 2>&1"
      & cmd.exe /d /c $commandLine
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    Write-Host "[Bridge] bun exited with code $exitCode; restarting in 5s..."
    Write-BridgeLog "[Bridge] bun exited with code $exitCode; restarting in 5s"
    Start-Sleep -Seconds 5
  }
} finally {
  Pop-Location
}
