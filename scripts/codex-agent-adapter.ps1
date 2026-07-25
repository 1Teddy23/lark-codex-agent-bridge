$ErrorActionPreference = "Stop"

function Write-JsonLine {
  param([hashtable]$Object)
  $Object | ConvertTo-Json -Compress -Depth 16
  [Console]::Out.Flush()
}

function Quote-ProcessArgument {
  param([AllowNull()][string]$Argument)

  if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
  if ($Argument -notmatch '[\s"]') { return $Argument }

  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $backslashes = 0

  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes++
      continue
    }

    if ($char -eq '"') {
      if ($backslashes -gt 0) {
        [void]$builder.Append('\' * ($backslashes * 2))
        $backslashes = 0
      }
      [void]$builder.Append('\"')
      continue
    }

    if ($backslashes -gt 0) {
      [void]$builder.Append('\' * $backslashes)
      $backslashes = 0
    }
    [void]$builder.Append($char)
  }

  if ($backslashes -gt 0) {
    [void]$builder.Append('\' * ($backslashes * 2))
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Join-ProcessArguments {
  param([string[]]$Arguments)
  return (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " ")
}

function Find-CodexBin {
  $candidates = @()
  if ($env:CODEX_BIN) { $candidates += $env:CODEX_BIN }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe"),
    (Join-Path $env:USERPROFILE ".codex\.sandbox-bin\codex.exe"),
    "codex"
  )

  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "Codex CLI was not found. Set CODEX_BIN or install Codex CLI."
}

$workspace = (Get-Location).Path
$model = ""
$resumeId = ""
$promptParts = @()

for ($i = 0; $i -lt $args.Count; $i++) {
  $arg = [string]$args[$i]
  switch ($arg) {
    "--workspace" {
      if ($i + 1 -lt $args.Count) { $workspace = [string]$args[++$i] }
      continue
    }
    "--model" {
      if ($i + 1 -lt $args.Count) { $model = [string]$args[++$i] }
      continue
    }
    "--resume" {
      if ($i + 1 -lt $args.Count) { $resumeId = [string]$args[++$i] }
      continue
    }
    "--" {
      if ($i + 1 -lt $args.Count) {
        $promptParts = @($args[($i + 1)..($args.Count - 1)])
      }
      break
    }
    default {
      continue
    }
  }
}

$prompt = ($promptParts | ForEach-Object { [string]$_ }) -join " "
if (-not $prompt) {
  $prompt = ($args | ForEach-Object { [string]$_ }) -join " "
}

$codexBin = Find-CodexBin
$runId = [guid]::NewGuid().ToString("N")
$tempDir = Join-Path ([IO.Path]::GetTempPath()) "lark-agent-codex"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$eventsPath = Join-Path $tempDir "$runId.events.jsonl"
$stderrPath = Join-Path $tempDir "$runId.stderr.log"
$lastPath = Join-Path $tempDir "$runId.last.txt"

$threadId = ""
$assistantText = ""
$stderrText = ""
$codexErrorText = ""
$exitCode = 1

function Get-SessionId {
  if ($script:threadId) { return $script:threadId }
  return $script:runId
}

function Write-ToolEvent {
  param(
    [string]$Subtype,
    [string]$Command,
    [string]$Output,
    [int]$ExitCode
  )

  $tool = @{
    args = @{
      command = $Command
    }
  }

  if ($Subtype -eq "completed") {
    $brief = ""
    if ($Output) { $brief = $Output.Trim() }
    if (-not $brief) { $brief = "exit code $ExitCode" }
    if ($brief.Length -gt 1200) { $brief = $brief.Substring(0, 1200) }
    $tool.result = @{
      success = @{
        content = $brief
      }
    }
  }

  Write-JsonLine @{
    type = "tool_call"
    subtype = $Subtype
    session_id = (Get-SessionId)
    tool_call = @{
      shellToolCall = $tool
    }
  }
}

function Write-AssistantText {
  param([string]$Text)

  if (-not $Text) { return }
  $script:assistantText += $Text
  Write-JsonLine @{
    type = "assistant"
    session_id = (Get-SessionId)
    message = @{
      role = "assistant"
      content = @(
        @{
          type = "text"
          text = $Text
        }
      )
    }
  }
}

function Process-CodexLine {
  param([string]$Line)

  $trimmed = $Line.Trim()
  if (-not $trimmed.StartsWith("{")) { return }

  try {
    $event = $trimmed | ConvertFrom-Json
  } catch {
    return
  }

  if ($event.type -eq "thread.started" -and $event.thread_id) {
    $script:threadId = [string]$event.thread_id
    Write-JsonLine @{
      type = "thinking"
      session_id = (Get-SessionId)
      text = "codex thread started"
    }
    return
  }

  if ($event.type -eq "turn.started") {
    Write-JsonLine @{
      type = "thinking"
      session_id = (Get-SessionId)
      text = "codex turn started"
    }
    return
  }

  if (($event.type -eq "item.started" -or $event.type -eq "item.completed") -and $event.item) {
    $item = $event.item

    if ($item.type -eq "agent_message" -and $event.type -eq "item.completed" -and $item.text) {
      Write-AssistantText ([string]$item.text)
      return
    }

    if ($item.type -eq "command_execution") {
      $command = if ($item.command) { [string]$item.command } else { "command" }
      if ($event.type -eq "item.started") {
        Write-ToolEvent -Subtype "started" -Command $command -Output "" -ExitCode 0
      } else {
        $output = if ($item.aggregated_output) { [string]$item.aggregated_output } else { "" }
        $code = if ($null -ne $item.exit_code) { [int]$item.exit_code } else { 0 }
        Write-ToolEvent -Subtype "completed" -Command $command -Output $output -ExitCode $code
      }
      return
    }

    if ([string]$item.type -match "tool|mcp|web") {
      $name = if ($item.name) { [string]$item.name } elseif ($item.type) { [string]$item.type } else { "tool" }
      if ($event.type -eq "item.started") {
        Write-ToolEvent -Subtype "started" -Command $name -Output "" -ExitCode 0
      } else {
        $output = if ($item.output) { [string]$item.output } elseif ($item.result) { [string]$item.result } else { "" }
        Write-ToolEvent -Subtype "completed" -Command $name -Output $output -ExitCode 0
      }
      return
    }

    if ($item.type -eq "reasoning" -and $item.summary) {
      Write-JsonLine @{
        type = "thinking"
        session_id = (Get-SessionId)
        text = [string]$item.summary
      }
      return
    }
  }

  if ($event.type -eq "error") {
    # Do not let --output-last-message turn a failed Codex turn into a normal
    # assistant reply when the child process exits.
    $script:codexErrorText = if ($event.message) { [string]$event.message } else { $trimmed }
  }
}

Write-JsonLine @{
  type = "thinking"
  session_id = (Get-SessionId)
  text = "codex exec started"
}

$commonArgs = @(
  "--json",
  "--output-last-message", $lastPath,
  "--skip-git-repo-check",
  "--dangerously-bypass-approvals-and-sandbox"
)

if ($model -and $model -ne "auto") {
  $commonArgs += @("--model", $model)
}

$resumeLooksValid = $resumeId -match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
if ($resumeLooksValid) {
  $codexArgs = @("exec", "resume") + $commonArgs + @($resumeId, $prompt)
} else {
  $codexArgs = @("exec") + $commonArgs + @("--cd", $workspace, "--", $prompt)
}

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $codexBin
$psi.Arguments = Join-ProcessArguments $codexArgs
$psi.WorkingDirectory = $workspace
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8

$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
$stderrBuilder = [Text.StringBuilder]::new()
$errorHandler = [Diagnostics.DataReceivedEventHandler]{
  param($sender, $eventArgs)
  if ($null -ne $eventArgs.Data) {
    [void]$stderrBuilder.AppendLine($eventArgs.Data)
  }
}
$process.add_ErrorDataReceived($errorHandler)

try {
  [void]$process.Start()
  $process.BeginErrorReadLine()

  while (-not $process.StandardOutput.EndOfStream) {
    $line = $process.StandardOutput.ReadLine()
    if ($null -eq $line) { break }
    Add-Content -LiteralPath $eventsPath -Value $line -Encoding UTF8
    Process-CodexLine $line
  }

  $process.WaitForExit()
  $exitCode = $process.ExitCode
} finally {
  if ($process -and -not $process.HasExited) {
    try { $process.Kill() } catch {}
  }
  $process.remove_ErrorDataReceived($errorHandler)
  $stderrText = $stderrBuilder.ToString().Trim()
  if ($stderrText) {
    [IO.File]::WriteAllText($stderrPath, $stderrText, [Text.Encoding]::UTF8)
  }
}

if ($codexErrorText) {
  Write-JsonLine @{
    type = "result"
    subtype = "error"
    session_id = (Get-SessionId)
    error = $codexErrorText
  }
  if ($env:CODEX_ADAPTER_KEEP_LOGS -ne "1") {
    Remove-Item -LiteralPath $eventsPath, $stderrPath, $lastPath -ErrorAction SilentlyContinue
  }
  exit 0
}

if (-not $assistantText -and (Test-Path -LiteralPath $lastPath)) {
  Write-AssistantText ([IO.File]::ReadAllText($lastPath).Trim())
}

$sessionId = Get-SessionId

if ($exitCode -ne 0 -and -not $assistantText) {
  $message = if ($stderrText) { $stderrText } else { "Codex CLI exited with code $exitCode" }
  Write-JsonLine @{
    type = "result"
    subtype = "error"
    session_id = $sessionId
    error = $message
  }
  exit 0
}

if (-not $assistantText) {
  $assistantText = if ($stderrText) { $stderrText } else { "(no output)" }
  Write-AssistantText $assistantText
}

Write-JsonLine @{
  type = "result"
  session_id = $sessionId
  result = $assistantText
}

if ($env:CODEX_ADAPTER_KEEP_LOGS -ne "1") {
  Remove-Item -LiteralPath $eventsPath, $stderrPath, $lastPath -ErrorAction SilentlyContinue
}
