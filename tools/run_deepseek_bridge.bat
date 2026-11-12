@echo off
cd /d "%~dp0"
setlocal EnableExtensions
set "PY="

echo ========================================
echo  DeepSeek bridge for MT5
echo  Keep this window OPEN while trading
echo ========================================
echo.

if not exist "ai_signal_bridge.py" (
  echo [ERROR] ai_signal_bridge.py not found in this folder.
  goto FAIL
)

REM Prefer "py -3" launcher, then python/python3
where py >nul 2>&1
if not errorlevel 1 (
  py -3 -c "import sys" >nul 2>&1
  if not errorlevel 1 set "PY=py -3"
)

if not defined PY (
  where python >nul 2>&1
  if not errorlevel 1 (
    python -c "import sys" >nul 2>&1
    if not errorlevel 1 set "PY=python"
  )
)

if not defined PY (
  where python3 >nul 2>&1
  if not errorlevel 1 (
    python3 -c "import sys" >nul 2>&1
    if not errorlevel 1 set "PY=python3"
  )
)

if not defined PY (
  echo [ERROR] Python 3 is NOT installed or not in PATH.
  echo.
  echo Ask the user to do this:
  echo   1. Open https://www.python.org/downloads/
  echo   2. Install Python 3.x
  echo   3. CHECK the box: Add python.exe to PATH
  echo   4. Close this window, open a NEW one, run this bat again
  echo.
  echo Note: Windows Store "python" stub does NOT work. Real install required.
  goto FAIL
)

if not exist "data\deepseek_config.json" (
  echo [WARN] data\deepseek_config.json missing. Fill api_key first.
  echo.
)

echo Using: %PY%
echo Starting bridge... DO NOT close this window.
echo.
%PY% ai_signal_bridge.py %*
set "EC=%ERRORLEVEL%"
echo.
echo Bridge stopped. exit code=%EC%
if not "%EC%"=="0" goto FAIL
goto END

:FAIL
echo.
echo ========== FAILED ==========
echo Fix the error above, then double-click this bat again.
echo Window will stay open. Press any key only after you read the error.
echo ============================
pause
exit /b 1

:END
pause
endlocal
