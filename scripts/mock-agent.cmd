@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-agent.ps1" %*
