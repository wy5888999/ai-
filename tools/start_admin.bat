@echo off
cd /d %~dp0
pip install -r requirements.txt -q
python admin_server.py
pause
