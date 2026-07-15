param(
    [string]$AdbSerial = "",
    [switch]$KeepWifiOnlyEndpoint,
    [switch]$RestartDevice
)

$ErrorActionPreference = "Stop"

$adb = "adb"
$adbArgs = @()
if ($AdbSerial) {
    $adbArgs += "-s"
    $adbArgs += $AdbSerial
}
$wifiOnlyProps = @(
    "persist.vbp.host_name",
    "persist.horusd.wifi.only.cc",
    "persist.horusd.wifi.only.freq",
    "persist.horusd.wifi.only.ssid",
    "persist.horusd.wifi.only.pw",
    "persist.horusd.wifi.only.passwd",
    "persist.horusd.wifi.only.ip",
    "persist.horusd.wifi.only.port",
    "persist.horusd.wifi.only.proto",
    "persist.horusd.wifi.only.mode",
    "persist.wifi.only.proto",
    "persist.horusd.timeout.recover",
    "persist.tracking.mode.wifipose",
    "persist.tracking.mode.6dof"
)

$receiverModeProps = [ordered]@{
    "persist.horusd.wifi.only.mode" = "0"
    "persist.horusd.wifi.only.freq" = "0"
    "persist.horusd.timeout.recover" = "0"
    "persist.wifi.only.proto" = "udp"
    "persist.tracking.mode.wifipose" = "0"
}

$endpointProps = @(
    "persist.vbp.host_name",
    "persist.horusd.wifi.only.ssid",
    "persist.horusd.wifi.only.pw",
    "persist.horusd.wifi.only.passwd",
    "persist.horusd.wifi.only.ip",
    "persist.horusd.wifi.only.port",
    "persist.horusd.wifi.only.proto"
)

function Invoke-AdbShell {
    param([Parameter(Mandatory = $true)][string]$Command)
    & $adb @adbArgs shell "ls -l /sdcard/ >/dev/null; $Command"
}

function Show-WifiOnlyProps {
    foreach ($prop in $wifiOnlyProps) {
        Invoke-AdbShell "echo $prop=`$(getprop $prop)"
    }
}

Write-Host "== Device =="
& $adb @adbArgs devices

Write-Host "`n== Before =="
Show-WifiOnlyProps

Write-Host "`n== Stopping tracking services =="
Invoke-AdbShell "setprop ctl.stop horusd; setprop ctl.stop wifid; sleep 1; echo wifid=`$(getprop init.svc.wifid); echo horusd=`$(getprop init.svc.horusd)"

Write-Host "`n== Writing receiver-mode properties =="
foreach ($entry in $receiverModeProps.GetEnumerator()) {
    Write-Host "$($entry.Key)=$($entry.Value)"
    Invoke-AdbShell "setprop $($entry.Key) '$($entry.Value)'"
}

if (-not $KeepWifiOnlyEndpoint) {
    Write-Host "`n== Clearing WiFi-only endpoint properties =="
    foreach ($prop in $endpointProps) {
        Write-Host "$prop="
        Invoke-AdbShell "setprop $prop ''"
    }
} else {
    Write-Host "`n== Keeping WiFi-only endpoint properties =="
}

if ($RestartDevice) {
    Write-Host "`n== Rebooting device =="
    Invoke-AdbShell "sync; reboot"
    Write-Host "Device reboot requested. Re-run this script without -RestartDevice after it comes back if you want a final property/log snapshot."
    exit 0
}

Write-Host "`n== Starting tracking services =="
Invoke-AdbShell "setprop ctl.start wifid; sleep 1; setprop ctl.start horusd; sleep 4; echo wifid=`$(getprop init.svc.wifid); echo horusd=`$(getprop init.svc.horusd)"

Write-Host "`n== After =="
Show-WifiOnlyProps

Write-Host "`n== Recent receiver/wifi logs =="
Invoke-AdbShell "logcat -d -t 200 | grep -iE 'horusd|wifid|wifi_only|receiver|dongle|tracker|pose_sock' | tail -n 80"
