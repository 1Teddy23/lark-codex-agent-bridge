$patterns = @("lark-agent-bridge", "run start.ts")
$matches = Get-CimInstance Win32_Process |
  Where-Object {
    if (-not $_.CommandLine -or $_.CommandLine -match "Win32_Process") { return $false }
    if ($_.CommandLine -match "scripts\\status\.ps1|scripts\\stop\.ps1") { return $false }
    if ($_.Name -notmatch "bun|powershell") { return $false }
    foreach ($pattern in $patterns) {
      if ($_.CommandLine -like "*$pattern*") { return $true }
    }
    return $false
  }

if (-not $matches) {
  Write-Host "Bridge is not running."
  exit 0
}

foreach ($proc in $matches) {
  Write-Host "Stopping PID $($proc.ProcessId) $($proc.Name)"
  Stop-Process -Id $proc.ProcessId -Force
}
