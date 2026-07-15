@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0UTK-WiFiOnly-App.ps1" -StopViveTrackerServer -UdpPosePort 9005 -AckOnConnect:$true -PreviewBytes 4096 -FullPayloadHex -Realtime:$false -ForwardBurstMode all -MinimalPoseJson:$false
pause
