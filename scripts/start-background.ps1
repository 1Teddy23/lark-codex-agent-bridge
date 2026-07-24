. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
$startScript = Join-Path $root "scripts\start.ps1"
$logPath = Join-Path $root "runtime\logs\feishu-cursor.log"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null

$args = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$startScript`""
)

Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $root -WindowStyle Hidden
Write-Host "Started in background. Log: $logPath"
