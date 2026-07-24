. "$PSScriptRoot\common.ps1"

Add-BunToPath
if (Get-Command bun -ErrorAction SilentlyContinue) {
  bun --version
  Write-Host "Bun is already installed."
  exit 0
}

Write-Host "Installing Bun for current Windows user..."
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1 | iex"

Add-BunToPath
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "Bun installer finished, but bun is not visible in this PowerShell session."
  Write-Host "Open a new PowerShell window, then run scripts/setup.ps1 again."
  exit 1
}

bun --version
