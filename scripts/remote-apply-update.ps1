param(
  [Parameter(Mandatory = $true)]
  [string] $Commit,

  [string] $Root = "D:\Agent\lark-agent-bridge-migration-20260719-175640\lark-agent-bridge"
)

$ErrorActionPreference = "Stop"
$repository = "https://raw.githubusercontent.com/1Teddy23/lark-codex-agent-bridge"
$logPath = Join-Path $Root "runtime\logs\remote-update.log"
$files = @(
  "claw/server.ts",
  "scripts/codex-agent-adapter.js",
  "scripts/codex-agent-adapter.ps1"
)

function Write-UpdateLog([string] $message) {
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -LiteralPath $logPath -Value "$timestamp $message" -Encoding utf8
}

try {
  if (-not (Test-Path -LiteralPath $Root)) {
    throw "Bridge root does not exist: $Root"
  }

  New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
  Write-UpdateLog "Starting update from commit $Commit"

  foreach ($relativePath in $files) {
    $targetPath = Join-Path $Root $relativePath
    $temporaryPath = "$targetPath.update-$Commit"
    $sourceUrl = "$repository/$Commit/$relativePath"

    Invoke-WebRequest -Uri $sourceUrl -OutFile $temporaryPath -UseBasicParsing
    if ((Get-Item -LiteralPath $temporaryPath).Length -eq 0) {
      throw "Downloaded file is empty: $relativePath"
    }
    Copy-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
    Remove-Item -LiteralPath $temporaryPath -Force
  }

  schtasks.exe /End /TN "LarkAgentBridge" | Out-Null
  Start-Sleep -Seconds 2
  schtasks.exe /Run /TN "LarkAgentBridge" | Out-Null
  Write-UpdateLog "Update completed and LarkAgentBridge restarted"
} catch {
  Write-UpdateLog "Update failed: $($_.Exception.Message)"
  throw
}
