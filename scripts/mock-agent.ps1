$prompt = ""
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -eq "--" -and $i + 1 -lt $args.Count) {
    $prompt = $args[$i + 1]
    break
  }
}

if (-not $prompt) {
  $prompt = "(empty prompt)"
}

$sessionId = "mock-" + [guid]::NewGuid().ToString("N").Substring(0, 12)

function Write-JsonLine {
  param([hashtable]$Object)
  $Object | ConvertTo-Json -Compress -Depth 8
}

Write-JsonLine @{
  type = "thinking"
  session_id = $sessionId
  text = "mock agent received prompt"
}
Start-Sleep -Milliseconds 200

$response = "Mock Agent OK. I received: " + $prompt
Write-JsonLine @{
  type = "assistant"
  session_id = $sessionId
  message = @{
    role = "assistant"
    content = @(
      @{
        type = "text"
        text = $response
      }
    )
  }
}
Write-JsonLine @{
  type = "result"
  session_id = $sessionId
  result = $response
}
