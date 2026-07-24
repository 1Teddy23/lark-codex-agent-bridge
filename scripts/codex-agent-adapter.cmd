@echo off
set "BUN_BIN=%USERPROFILE%\.bun\bin\bun.exe"
if exist "%BUN_BIN%" (
  "%BUN_BIN%" "%~dp0codex-agent-adapter.js" %*
) else (
  bun "%~dp0codex-agent-adapter.js" %*
)
