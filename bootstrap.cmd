@echo off
REM ============================================================
REM  setup_wsl launcher wrapper
REM ------------------------------------------------------------
REM  IMPORTANT: this file must stay ASCII-only.
REM  cmd.exe parses .bat/.cmd using the OEM code page (GBK on a
REM  Chinese Windows) and does NOT understand a UTF-8 BOM, so any
REM  non-ASCII byte here corrupts command parsing. All localized
REM  user-facing text lives in bootstrap.ps1 instead, which is
REM  UTF-8 with BOM and read by PowerShell.
REM
REM  Windows blocks .ps1 execution by default. This wrapper relaxes
REM  the policy for THIS invocation only (-ExecutionPolicy Bypass)
REM  and does not change machine-wide settings.
REM
REM  Usage:
REM      bootstrap.cmd                  run everything
REM      bootstrap.cmd -Plan            print the plan only
REM      bootstrap.cmd -Only 30,40      run selected stages
REM      bootstrap.cmd -Skip 50,60      skip selected stages
REM
REM  Stages that need administrator rights detect this themselves
REM  and tell you what to do, so this file does not need elevation.
REM ============================================================

setlocal
set "SCRIPT=%~dp0bootstrap.ps1"

if not exist "%SCRIPT%" (
    echo [setup_wsl] ERROR: bootstrap.ps1 not found next to this file.
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"

REM Exit codes are passed through unchanged so this can be scripted:
REM   0  success        10 needs reboot
REM   1  failure        20 needs administrator
if "%CODE%"=="10" echo [setup_wsl] A reboot is required, then run this file again.
if "%CODE%"=="20" echo [setup_wsl] Administrator rights required: right-click and run as administrator.
if "%CODE%"=="30" echo [setup_wsl] More input is required, see the messages above.

exit /b %CODE%
