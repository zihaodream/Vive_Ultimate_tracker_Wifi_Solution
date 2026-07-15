param(
    [string]$AdbSerial = "",
    [string]$Ssid = "",
    [string]$Password = "",
    [string]$ServerIp = "",
    [int]$PosePort = 9005,
    [string]$CountryCode = "CN",
    [string]$Frequency = "0",
    [string]$Proto = "udp",
    [string]$Mode = "1",
    [switch]$OfficialUdpProps
)

$ErrorActionPreference = "Stop"

# Current baseline: tracker joins the router 5 GHz SSID and connects back to
# the PC LAN address on UDP 9005. Frequency 0 lets the device scan the SSID,
# which is safer when the router channel is set to Auto.
$adb = "adb"
$adbArgs = @()
if ($AdbSerial) {
    $adbArgs += "-s"
    $adbArgs += $AdbSerial
}
$props = [ordered]@{
    "persist.horusd.wifi.only.cc"    = $CountryCode
    "persist.horusd.wifi.only.freq"  = $Frequency
    "persist.horusd.wifi.only.ssid"  = $Ssid
    "persist.horusd.wifi.only.pw"    = $Password
    "persist.horusd.wifi.only.passwd" = $Password
    "persist.horusd.wifi.only.ip"    = $ServerIp
    "persist.horusd.wifi.only.port"  = [string]$PosePort
    "persist.horusd.wifi.only.proto" = $Proto
    "persist.horusd.wifi.only.mode"  = $Mode
}

if ($OfficialUdpProps -or $Proto -eq "udp") {
    $props["persist.wifi.only.proto"] = $Proto
    $props["persist.horusd.timeout.recover"] = "0"
}

function Invoke-AdbShell {
    param([Parameter(Mandatory = $true)][string]$Command)
    & $adb @adbArgs shell "ls -l /sdcard/ >/dev/null; $Command"
}

function Assert-ServerEndpoint {
    if ($ServerIp -eq "192.168.137.1") {
        $hotspotIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq "192.168.137.1" }
        if (-not $hotspotIp) {
            throw "PC hotspot IP 192.168.137.1 is not active. Turn on Windows Mobile Hotspot named '$Ssid' first, then rerun this script."
        }
        return
    }

    $serverAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $ServerIp }
    if (-not $serverAddress) {
        throw "ServerIp $ServerIp is not active on this PC. Connect the PC to the router LAN or pass the current PC LAN IP with -ServerIp."
    }
}

Assert-ServerEndpoint

Write-Host "== Device =="
& $adb @adbArgs devices

Write-Host "`n== Writing WiFi-only properties =="
foreach ($entry in $props.GetEnumerator()) {
    Write-Host "$($entry.Key)=$($entry.Value)"
    Invoke-AdbShell "setprop $($entry.Key) '$($entry.Value)'"
}

Write-Host "`n== Current properties =="
$propNames = ($props.Keys | ForEach-Object { "echo $_=`$(getprop $_)" }) -join "; "
Invoke-AdbShell $propNames

Write-Host "`n== Restarting horusd/wifid if init services exist =="
Invoke-AdbShell "setprop ctl.restart wifid; setprop ctl.restart horusd; sleep 2; getprop init.svc.wifid; getprop init.svc.horusd"

Write-Host "`n== Recent horusd/wifi logs =="
Invoke-AdbShell "logcat -d -t 300 | grep -iE 'horusd|wifi_only|pose_sock|device_id|CONNECTED|CONNECTING|UNKNOWN ACTION|tracker|wifid' | tail -n 120"
