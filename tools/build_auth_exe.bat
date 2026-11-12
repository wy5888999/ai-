@echo off
chcp 65001 >nul
cd /d %~dp0

echo === 打包授权工具为 exe（无黑框，双击即开窗口）===
python -m pip install -q pyinstaller pillow
if errorlevel 1 (
  echo pip 安装失败
  pause
  exit /b 1
)

REM 清理旧产物
if exist build rmdir /s /q build
if exist dist\授权工具 rmdir /s /q dist\授权工具
if exist "dist\授权工具.exe" del /f /q "dist\授权工具.exe"
if exist AuthTool.spec del /f /q AuthTool.spec

set ICON_ARG=
if exist assets\auth.ico set ICON_ARG=--icon assets\auth.ico

python -m PyInstaller --noconfirm --clean --windowed --onefile ^
  --name "授权工具" ^
  %ICON_ARG% ^
  --hidden-import auth_permission ^
  --collect-all tkinter ^
  --add-data "assets;assets" ^
  auth_gui.py

if errorlevel 1 (
  echo 打包失败
  pause
  exit /b 1
)

REM 分发包：exe + data 配置（客户可改服务器地址）
mkdir "dist\授权工具_分发" 2>nul
copy /y "dist\授权工具.exe" "dist\授权工具_分发\授权工具.exe" >nul
mkdir "dist\授权工具_分发\data" 2>nul
if exist "data\client_config.json" (
  copy /y "data\client_config.json" "dist\授权工具_分发\data\client_config.json" >nul
) else (
  copy /y "data\client_config.dist.json" "dist\授权工具_分发\data\client_config.json" >nul
)
copy /y "客户使用说明.txt" "dist\授权工具_分发\客户使用说明.txt" >nul 2>nul

echo.
echo 完成: dist\授权工具_分发\授权工具.exe
echo 请把「授权工具_分发」整个文件夹发给客户。
echo 打包前请把 config.json 的 client_server_url 改成你的公网地址，
echo 或让客户在窗口「服务器」栏填写 http://你的IP:8787
echo.
pause
