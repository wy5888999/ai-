@echo off
setlocal EnableExtensions
cd /d "%~dp0AI"
title OpenAI

echo ========================================
echo  AI bridge. Keep this window open.
echo  EA input UseExternalAI = true
echo ========================================
echo.
echo Folder: %~dp0
echo Key file: %~dp0AI\data\deepseek_config.json
echo MT5 common:
echo   %APPDATA%\MetaQuotes\Terminal\Common\Files\ai
echo.

if not exist "data\deepseek_config.json" (
  echo No key file yet. Copying the template.
  copy /Y "data\deepseek_config.example.json" "data\deepseek_config.json" >nul
  echo Edit api_key in notepad, save, then close notepad.
  echo Do not rename the file and do not save as txt.
  notepad "data\deepseek_config.json"
  echo.
)

set "PY="
where py >nul 2>&1 && py -3 -c "import sys" >nul 2>&1 && set "PY=py -3"
if not defined PY where python >nul 2>&1 && python -c "import sys" >nul 2>&1 && set "PY=python"
if not defined PY where python3 >nul 2>&1 && python3 -c "import sys" >nul 2>&1 && set "PY=python3"
if not defined PY (
  echo Python 3 is not installed.
  echo Install from https://www.python.org/downloads/
  echo Tick Add python.exe to PATH, then double-click this file again.
  pause
  exit /b 1
)

echo Using %PY%
echo Installing certificate bundle...
%PY% -m pip install -q certifi
echo.
%PY% ai_signal_bridge.py
echo.
echo Bridge stopped.
pause
endlocal
