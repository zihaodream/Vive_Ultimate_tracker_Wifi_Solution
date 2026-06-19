@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0UTK-WiFiOnly-App.ps1" -StopViveTrackerServer
pause
