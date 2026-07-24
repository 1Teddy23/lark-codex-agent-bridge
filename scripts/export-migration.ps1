param(
  [string]$OutputDir = "",
  [switch]$SkipAttachments,
  [switch]$SkipCodexSkills
)

. "$PSScriptRoot\common.ps1"

$root = Get-BridgeRoot
if (-not $OutputDir) {
  $OutputDir = Join-Path $root "migration-packages"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$packageName = "lark-agent-bridge-migration-$timestamp"
$driveRoot = [System.IO.Path]::GetPathRoot($root)
$stageParent = Join-Path $driveRoot "_larkmig\$timestamp"
$stage = Join-Path $stageParent "lark-agent-bridge"
$zipPath = Join-Path $OutputDir "$packageName.zip"

$rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd("\", "/")

function Get-RelativePathFromRoot {
  param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  return $full.Substring($rootFull.Length).TrimStart("\", "/")
}

function Should-SkipRelativePath {
  param(
    [string]$RelativePath,
    [bool]$IsDirectory
  )

  $normalized = $RelativePath.Replace("/", "\")
  $segments = $normalized.Split("\", [System.StringSplitOptions]::RemoveEmptyEntries)
  foreach ($segment in $segments) {
    if ($segment -in @(".git", "node_modules", "logs", "inbox", "migration-packages")) {
      return $true
    }
  }

  if ($SkipAttachments -and $segments -contains "attachments") {
    return $true
  }

  if (-not $IsDirectory) {
    $leaf = [System.IO.Path]::GetFileName($normalized)
    if ($normalized -eq "claw\.env") { return $true }
    if ($normalized -like "runtime\.memory.sqlite*") { return $true }
    if ($leaf -like "*.log") { return $true }
  }

  return $false
}

function Copy-RootTree {
  New-Item -ItemType Directory -Force -Path $stage | Out-Null

  Get-ChildItem -LiteralPath $root -Force -Recurse | ForEach-Object {
    $rel = Get-RelativePathFromRoot -Path $_.FullName
    if (-not $rel) { return }
    if (Should-SkipRelativePath -RelativePath $rel -IsDirectory $_.PSIsContainer) { return }

    $dest = Join-Path $stage $rel
    if ($_.PSIsContainer) {
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
  }
}

function Copy-CodexSkills {
  if ($SkipCodexSkills) { return }

  $skillRoot = Join-Path $env:USERPROFILE ".codex\skills"
  if (-not (Test-Path -LiteralPath $skillRoot)) { return }

  $targetRoot = Join-Path $stage ".migration\codex-skills"
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

  foreach ($name in @("feishu-openapi", "ones", "sr-ones")) {
    $source = Join-Path $skillRoot $name
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination $targetRoot -Recurse -Force
    }
  }
}

function Write-MigrationManifest {
  $manifestDir = Join-Path $stage ".migration"
  New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null

  $manifest = [ordered]@{
    package_name = $packageName
    created_at = (Get-Date).ToString("o")
    source_root = $root
    source_root_forward = $root.Replace("\", "/")
    secrets_included = @(
      "config/bridge.env"
    )
    excluded = @(
      "claw/node_modules",
      "runtime/logs",
      "runtime/inbox",
      "root inbox",
      "runtime/.memory.sqlite*",
      "claw/.env (regenerated on install)",
      "Codex login/auth databases",
      "Git Credential Manager vault",
      "SSH keys"
    )
  }

  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestDir "manifest.json") -Encoding UTF8

  $readme = @"
# Lark Agent Bridge Migration Package

This package contains the bridge code, `config/bridge.env`, Feishu credentials, topic/session metadata, runtime rules, memories, projects, attachments, and selected custom Codex skills.

Sensitive note:

- `config/bridge.env` is included and may contain Feishu app secrets and OAuth tokens.
- Do not share this zip publicly.
- Codex login state, Git Credential Manager secrets, SSH keys, browser cookies, and Windows credential vault entries are not included.

Install on the new Windows computer:

```powershell
cd <extracted>\lark-agent-bridge
powershell -ExecutionPolicy Bypass -File .\scripts\install-migration.ps1
```

If you only want to prepare files without starting the bridge:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-migration.ps1 -NoStart
```

Before starting this copy, stop the old computer's bridge if it uses the same Feishu App ID.
"@
  Set-Content -LiteralPath (Join-Path $stage "README-MIGRATION.md") -Value $readme -Encoding UTF8
}

if (-not (Test-Path -LiteralPath (Join-Path $root "config\bridge.env"))) {
  throw "Missing config/bridge.env; cannot create a complete migration package."
}

New-Item -ItemType Directory -Force -Path $OutputDir, $stageParent | Out-Null
if (Test-Path -LiteralPath $stage) {
  Remove-Item -LiteralPath $stage -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}

Copy-RootTree
Copy-CodexSkills
Write-MigrationManifest

Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -Force

$fileCount = (Get-ChildItem -LiteralPath $stage -Recurse -Force -File | Measure-Object).Count
$sizeBytes = (Get-Item -LiteralPath $zipPath).Length

Write-Host "Migration package created:"
Write-Host "  $zipPath"
Write-Host "Files: $fileCount"
Write-Host ("Size:  {0:N2} MB" -f ($sizeBytes / 1MB))
Write-Host ""
Write-Host "This zip includes config/bridge.env. Keep it private."
