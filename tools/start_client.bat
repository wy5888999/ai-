@echo off
chcp 65001 >nul
cd /d %~dp0

REM 生成带自定义图标的快捷方式（不是 Python 图标）
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$dir='%~dp0'; $lnk=Join-Path $dir '授权工具.lnk'; $w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($lnk); $py=(Get-Command pythonw -ErrorAction SilentlyContinue); if(-not $py){$py=Get-Command python}; $s.TargetPath=$py.Source; $s.Arguments='\"'+$dir+'auth_gui.py\"'; $s.WorkingDirectory=$dir; $ico=Join-Path $dir 'assets\auth.ico'; if(Test-Path $ico){$s.IconLocation=$ico}; $s.WindowStyle=1; $s.Save(); Start-Process $lnk"

if errorlevel 1 (
  echo 快捷方式启动失败，改用直接启动...
  python auth_gui.py
  if errorlevel 1 pause
)
