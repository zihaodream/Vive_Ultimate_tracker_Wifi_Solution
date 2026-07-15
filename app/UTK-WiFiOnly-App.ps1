param(
    [ValidateSet("StartKeepalive", "ApplyWifi", "RestoreDongle", "Start", "Stop", "Restart", "Status", "Devices", "DevicesJson", "DevicesTsv", "ConfigureOnly")]
    [string]$Action = "StartKeepalive",

    [string]$AdbSerial = "",
    [string]$Ssid = "",
    [string]$Password = "",
    [string]$ServerIp = "Auto",
    [int]$PosePort = 0,
    [string]$CountryCode = "CN",
    [string]$Frequency = "0",
    [string]$Proto = "udp",

    [string]$Bind = "0.0.0.0",
    [string]$Ports = "9005,3680,8053,15680",
    [int]$UdpPosePort = 9005,
    [string]$Python = "",
    [switch]$StopViveTrackerServer,
    [int]$PreviewBytes = 4096,
    [double]$IdlePingSeconds = 0,
    [string]$AckPayloads = "ANI0,ATW,ACF50,ATS{unix},WcCN,FW2,pAS_TS180,ATM21",
    [object]$AckOnConnect = $true,
    [int]$AckSlotSize = 128,
    [int]$ConsoleRecvLimit = -1,
    [switch]$FullPayloadHex,
    [object]$Realtime = $true,
    [ValidateSet("", "all", "latest", "paced")]
    [string]$ForwardBurstMode = "paced",
    [double]$PacedMaxDelayMs = 45.0,
    [double]$PacedTargetHz = 50.0,
    [double]$PacedBacklogCollapseMs = 8.0,
    [object]$MinimalPoseJson = $true,
    [ValidateSet("json", "binary")]
    [string]$PoseForwardFormat = "binary",
    [string]$PoseForwardUdp = "",
    [string]$PoseForwardPeerIp = "",
    [string]$PoseForwardMap = "",
    [string]$PoseForwardAutoMap = "",
    [object]$PoseForwardIncludeZero = $true,
    [string]$ReadyPayloads = "",
    [int]$ReadyAfterValidFrames = 30,
    [string]$ControlRefreshPayloads = "ATM21",
    [double]$ControlRefreshSeconds = 0.0,
    [double]$ControlRefreshStartDelaySeconds = 0.0,
    [double]$LatencyStatsSeconds = 1.0,
    [switch]$EnsureFirewallRule,
    [object]$AutoPoseForward = $true,
    [object]$AutoRegisterSteamVR = $true,
    [object]$BuildSteamVRDriverIfMissing = $true,
    [int]$UdpStartPort = 5557,
    [int]$TrackerCount = 10
)

$ErrorActionPreference = "Stop"

function Convert-ToBoolean {
    param(
        [object]$Value,
        [bool]$Default
    )
    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $text = "$Value".Trim()
    if ($text -match '^\$?(true|1|yes|y)$') {
        return $true
    }
    if ($text -match '^\$?(false|0|no|n)$') {
        return $false
    }
    return [bool]::Parse($text)
}

$Realtime = Convert-ToBoolean -Value $Realtime -Default $true
$MinimalPoseJson = Convert-ToBoolean -Value $MinimalPoseJson -Default $true
$AckOnConnect = Convert-ToBoolean -Value $AckOnConnect -Default $true
$PoseForwardIncludeZero = Convert-ToBoolean -Value $PoseForwardIncludeZero -Default $true
$AutoPoseForward = Convert-ToBoolean -Value $AutoPoseForward -Default $true
$AutoRegisterSteamVR = Convert-ToBoolean -Value $AutoRegisterSteamVR -Default $true
$BuildSteamVRDriverIfMissing = Convert-ToBoolean -Value $BuildSteamVRDriverIfMissing -Default $true

$appDir = $PSScriptRoot
$rootDir = Split-Path -Parent $appDir
$wifiScript = Join-Path $rootDir "scripts\ut_wifi_only_test.ps1"
$restoreDongleScript = Join-Path $rootDir "scripts\restore_receiver_mode.ps1"
$keepaliveScript = Join-Path $rootDir "server\start_utk_keepalive_service.ps1"
$steamVrDriverDir = Join-Path $rootDir "steamvr_driver"
$steamVrRegisterScript = Join-Path $steamVrDriverDir "register_driver.ps1"
$steamVrBuildScript = Join-Path $steamVrDriverDir "build_driver.ps1"
$steamVrBuildDir = Join-Path $steamVrDriverDir "build_verify"
$steamVrDriverPackage = Join-Path $steamVrBuildDir "utk_wifi_tracker"
$legacySteamVrDriverPackage = Join-Path $steamVrDriverDir "build\utk_wifi_tracker"
$stateDir = Join-Path $rootDir "backups\utk_wifi_only_app"
$pidFile = Join-Path $stateDir "keepalive_process.json"
$script:ResolvedUdpStartPort = $null

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ""
    Write-Host "== $Text =="
}

function Get-PortList {
    return @($Ports.Split(",") | ForEach-Object { [int]$_.Trim() } | Where-Object { $_ -gt 0 })
}

function Resolve-HotspotIp {
    if ($ServerIp -and $ServerIp -ne "Auto") {
        return $ServerIp
    }

    $allIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" })

    $defaultHotspot = $allIps | Where-Object { $_.IPAddress -eq "192.168.137.1" } | Select-Object -First 1
    if ($defaultHotspot) {
        return $defaultHotspot.IPAddress
    }

    $hotspotAlias = $allIps |
        Where-Object { $_.InterfaceAlias -match "Hotspot|Wi-Fi Direct|Local Area Connection" } |
        Select-Object -First 1
    if ($hotspotAlias) {
        return $hotspotAlias.IPAddress
    }

    $private137 = $allIps | Where-Object { $_.IPAddress -like "192.168.137.*" } | Select-Object -First 1
    if ($private137) {
        return $private137.IPAddress
    }

    throw "Could not auto-detect the Windows hotspot IP. Turn on Mobile Hotspot first, or pass -ServerIp <ip>."
}

function Resolve-AdbSerial {
    if ($AdbSerial) {
        return $AdbSerial
    }

    $adbOutput = @(& adb devices 2>$null)
    $devices = @()
    foreach ($line in $adbOutput) {
        if ($line -match '^(\S+)\s+device$') {
            $devices += $matches[1]
        }
    }

    if ($devices.Count -eq 1) {
        return $devices[0]
    }
    if ($devices.Count -gt 1) {
        throw "Multiple ADB devices are connected: $($devices -join ', '). Rerun with -AdbSerial <serial>."
    }

    throw "No ADB device is connected. Connect the tracker over USB and confirm it appears in 'adb devices'."
}

function Resolve-PosePort {
    if ($PosePort -gt 0) {
        return $PosePort
    }
    $firstPort = Get-PortList | Select-Object -First 1
    if (-not $firstPort) {
        return 9005
    }
    return [int]$firstPort
}

function Resolve-UdpStartPort {
    if ($script:ResolvedUdpStartPort) {
        return [int]$script:ResolvedUdpStartPort
    }

    $count = $TrackerCount
    if ($count -lt 1) {
        $count = 1
    }
    if ($count -gt 16) {
        $count = 16
    }

    $occupied = @{}
    Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
        $owner = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($owner -and $owner.ProcessName -in @("vrserver", "vrmonitor", "vrcompositor")) {
            return
        }
        $occupied[[int]$_.LocalPort] = $true
    }

    for ($candidate = $UdpStartPort; $candidate -le (65535 - $count); $candidate++) {
        $ok = $true
        for ($offset = 0; $offset -lt $count; $offset++) {
            if ($occupied.ContainsKey($candidate + $offset)) {
                $ok = $false
                break
            }
        }
        if ($ok) {
            $script:ResolvedUdpStartPort = $candidate
            return $candidate
        }
    }

    throw "Could not find $count free consecutive UDP ports starting at $UdpStartPort."
}

function Write-SteamVRDriverSettings {
    param([Parameter(Mandatory = $true)][int]$StartPort)

    $count = $TrackerCount
    if ($count -lt 1) {
        $count = 1
    }
    if ($count -gt 16) {
        $count = 16
    }

    $settingsTargets = @(
        (Join-Path $steamVrDriverDir "resources\settings\default.vrsettings"),
        (Join-Path $steamVrDriverPackage "resources\settings\default.vrsettings")
    )

    foreach ($target in $settingsTargets) {
        $dir = Split-Path -Parent $target
        if (Test-Path $dir) {
            if (Test-Path $target) {
                $settings = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
            } else {
                $settings = [pscustomobject]@{}
            }
            if (-not $settings.PSObject.Properties["driver_utk_wifi_tracker"]) {
                $settings | Add-Member -MemberType NoteProperty -Name "driver_utk_wifi_tracker" -Value ([pscustomobject]@{})
            }
            $driverSettings = $settings.driver_utk_wifi_tracker
            $desired = [ordered]@{
                enable = $true
                udp_bind_host = "127.0.0.1"
                udp_port = $StartPort
                tracker_count = $count
                stale_timeout_seconds = 2.0
            }
            foreach ($entry in $desired.GetEnumerator()) {
                if ($driverSettings.PSObject.Properties[$entry.Key]) {
                    $driverSettings.($entry.Key) = $entry.Value
                } else {
                    $driverSettings | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
                }
            }
            $settings | ConvertTo-Json -Depth 6 | Set-Content -Encoding ASCII -Path $target
            Write-Host "SteamVR driver settings: $target"
        }
    }
}

function Get-PowerShellExe {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }
    return "powershell.exe"
}

function Join-ProcessArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return (($Arguments | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') {
            '"' + ($text -replace '"', '\"') + '"'
        } else {
            $text
        }
    }) -join " ")
}

function Get-KeepaliveState {
    if (-not (Test-Path $pidFile)) {
        return $null
    }
    try {
        return Get-Content $pidFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-KeepaliveProcess {
    $state = Get-KeepaliveState
    if ($state -and $state.pid) {
        $stateProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.pid)" -ErrorAction SilentlyContinue
        if ($stateProcess -and $stateProcess.CommandLine -like "*utk_keepalive_server.py*") {
            return Get-Process -Id ([int]$stateProcess.ProcessId) -ErrorAction SilentlyContinue
        }
    }

    $fallback = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*utk_keepalive_server.py*" -and $_.Name -match "python" } |
        Select-Object -First 1
    if ($fallback) {
        return Get-Process -Id ([int]$fallback.ProcessId) -ErrorAction SilentlyContinue
    }
    return $null
}

function Show-KeepaliveStatus {
    Write-Section "Keepalive process"
    $state = Get-KeepaliveState
    $process = Get-KeepaliveProcess
    if ($process) {
        Write-Host "Running PID: $($process.Id)"
        if ($state) {
            Write-Host "Started: $($state.started)"
            Write-Host "Stdout:  $($state.stdout)"
            Write-Host "Stderr:  $($state.stderr)"
        }
    } else {
        Write-Host "Not running."
        if ($state) {
            Write-Host "Last PID: $($state.pid)"
            Write-Host "Stdout:   $($state.stdout)"
            Write-Host "Stderr:   $($state.stderr)"
        }
    }

    Write-Section "Tracker sockets"
    $portList = Get-PortList
    $connections = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalPort -in $portList -or
            $_.RemotePort -in $portList -or
            $_.RemoteAddress -like "192.168.137.*"
        } |
        Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess

    if ($connections) {
        $connections | Format-Table -AutoSize
    } else {
        Write-Host "No matching sockets."
    }
}

function Get-CurrentKeepaliveProcessInfo {
    $process = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*utk_keepalive_server.py*" -and $_.Name -match "python" } |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1
    if (-not $process) {
        return $null
    }

    $info = [ordered]@{
        Out = $null
        AutoMap = $null
    }
    $commandLine = [string]$process.CommandLine
    if ($commandLine -match '--out\s+("([^"]+)"|(\S+))') {
        $info.Out = if ($matches[2]) { $matches[2] } else { $matches[3] }
    }
    if ($commandLine -match '--pose-forward-auto-map\s+("([^"]+)"|(\S+))') {
        $info.AutoMap = if ($matches[2]) { $matches[2] } else { $matches[3] }
    }
    return [pscustomobject]$info
}

function Get-KeepaliveLogFiles {
    $paths = New-Object System.Collections.Generic.List[string]
    $current = Get-CurrentKeepaliveProcessInfo
    if ($current -and $current.Out -and (Test-Path -LiteralPath $current.Out) -and (Get-Item -LiteralPath $current.Out).Length -gt 0) {
        [void]$paths.Add([string]$current.Out)
    }

    return @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-TrackerDeviceRows {
    $devices = @{}
    $peerOrder = New-Object System.Collections.Generic.List[string]
    $onlineIps = New-Object System.Collections.Generic.HashSet[string]
    $onlinePeerPorts = @{}
    $state = Get-KeepaliveState
    $current = Get-CurrentKeepaliveProcessInfo
    $autoMapStartPort = $null
    if ($current -and $current.AutoMap -and "$($current.AutoMap)" -match ':(\d+)$') {
        $autoMapStartPort = [int]$matches[1]
    } elseif ($state -and $state.pose_forward_auto_map -and "$($state.pose_forward_auto_map)" -match ':(\d+)$') {
        $autoMapStartPort = [int]$matches[1]
    }

    function Get-OrCreateDevice {
        param([Parameter(Mandatory = $true)][string]$Peer)
        if (-not $Peer) {
            return $null
        }
        $ip = ($Peer -split ":", 2)[0]
        if (-not $devices.ContainsKey($ip)) {
            $devices[$ip] = [ordered]@{
                IP = $ip
                PeerPorts = New-Object System.Collections.Generic.HashSet[string]
                TcpLocalPort = $null
                SteamVRUdpPort = $null
                State = "seen"
                TrackerSN = ""
                DeviceSN = ""
                Hardware = ""
                Firmware = ""
                LastPoseAgeMs = $null
                LastRecvAgeMs = $null
                PoseStatus = ""
                LastCommand = ""
            }
            [void]$peerOrder.Add($ip)
        }
        if ($Peer -match ':(\d+)$') {
            [void]$devices[$ip].PeerPorts.Add($matches[1])
        }
        return $devices[$ip]
    }

    Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in (Get-PortList) -and $_.RemoteAddress -match '^\d+\.\d+\.\d+\.\d+$' -and $_.State -eq "Established" } |
        ForEach-Object {
            $ip = [string]$_.RemoteAddress
            [void]$onlineIps.Add($ip)
            if (-not $onlinePeerPorts.ContainsKey($ip)) {
                $onlinePeerPorts[$ip] = New-Object System.Collections.Generic.HashSet[string]
            }
            [void]$onlinePeerPorts[$ip].Add([string]$_.RemotePort)
            $device = Get-OrCreateDevice -Peer ("{0}:{1}" -f $ip, $_.RemotePort)
            if ($device) {
                if ([int]$_.LocalPort -eq 9005) {
                    $device.TcpLocalPort = 9005
                    $device.State = "tcp_established"
                } elseif (-not $device.TcpLocalPort) {
                    $device.TcpLocalPort = [int]$_.LocalPort
                }
            }
        }

    foreach ($logPath in @(Get-KeepaliveLogFiles)) {
        foreach ($line in (Get-Content -LiteralPath $logPath -Tail 800 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $event = $line | ConvertFrom-Json
            } catch {
                continue
            }
            if (-not $event.peer) {
                continue
            }
            $device = Get-OrCreateDevice -Peer ([string]$event.peer)
            if (-not $device) {
                continue
            }
            if ($event.event -eq "scheme5_control_state") {
                $hasControlCommands = $false
                if ($event.tcp_control_commands) {
                    $hasControlCommands = @($event.tcp_control_commands.PSObject.Properties).Count -gt 0
                }
                if ($event.last_tcp_port -and ([int]$event.last_tcp_port -eq 9005 -or $hasControlCommands)) {
                    $device.TcpLocalPort = [int]$event.last_tcp_port
                } elseif ($event.last_tcp_port -and -not $device.TcpLocalPort) {
                    $device.TcpLocalPort = [int]$event.last_tcp_port
                }
                if ($event.readiness_phase) { $device.State = [string]$event.readiness_phase }
                if ($null -ne $event.last_udp_pose_age_ms) { $device.LastPoseAgeMs = [double]$event.last_udp_pose_age_ms }
                if ($null -ne $event.last_tcp_recv_age_ms) { $device.LastRecvAgeMs = [double]$event.last_tcp_recv_age_ms }
                if ($event.last_control_command) { $device.LastCommand = [string]$event.last_control_command }
                if ($hasControlCommands) {
                    foreach ($property in $event.tcp_control_commands.PSObject.Properties) {
                        $name = $property.Name
                        if ($name -match '^recv:NADS(.+)$') { $device.TrackerSN = $matches[1] }
                        elseif ($name -match '^recv:NASS(.+)$') { $device.DeviceSN = $matches[1] }
                        elseif ($name -match '^recv:NAPI(.+)$') { $device.Hardware = $matches[1] }
                        elseif ($name -match '^recv:NAV(.+)$') { $device.Firmware = $matches[1] }
                    }
                }
            } elseif ($event.event -eq "latency_stats") {
                if ($null -ne $event.last_recv_age_ms) { $device.LastPoseAgeMs = [double]$event.last_recv_age_ms }
                if ($event.pose_status_counts) {
                    $pairs = @()
                    foreach ($property in $event.pose_status_counts.PSObject.Properties) {
                        $pairs += "$($property.Name):$($property.Value)"
                    }
                    $device.PoseStatus = $pairs -join ","
                }
                if ([int]$event.valid_frame_count -gt 0) {
                    $device.State = "udp_pose_active"
                }
            }
        }
    }

    $index = 0
    $activeIps = if ($onlineIps.Count -gt 0) { @($peerOrder | Where-Object { $onlineIps.Contains($_) }) } else { @($peerOrder) }
    $rows = foreach ($ip in $activeIps) {
        $device = $devices[$ip]
        if ($onlineIps.Contains($ip) -and ($device.State -ne "udp_pose_active")) {
            $device.State = "tcp_established"
            if ($null -eq $device.LastPoseAgeMs) {
                $device.LastPoseAgeMs = 0
            }
        }
        if ($autoMapStartPort -ne $null) {
            $device.SteamVRUdpPort = $autoMapStartPort + $index
        }
        $index += 1
        [pscustomobject]@{
            IP = $device.IP
            PeerPort = if ($onlinePeerPorts.ContainsKey($ip)) { (($onlinePeerPorts[$ip] | Sort-Object) -join ",") } else { (($device.PeerPorts | Sort-Object) -join ",") }
            TcpPort = $device.TcpLocalPort
            SteamVRUdpPort = $device.SteamVRUdpPort
            State = $device.State
            TrackerSN = $device.TrackerSN
            DeviceSN = $device.DeviceSN
            Hardware = $device.Hardware
            Firmware = $device.Firmware
            LastPoseAgeMs = $device.LastPoseAgeMs
            LastRecvAgeMs = $device.LastRecvAgeMs
            PoseStatus = $device.PoseStatus
            LastCommand = $device.LastCommand
        }
    }
    return @($rows)
}

function Show-TrackerDevices {
    Write-Section "Tracker devices"
    $rows = @(Get-TrackerDeviceRows)
    if ($rows.Count -eq 0) {
        Write-Host "No tracker devices found in the latest keepalive log yet."
        return
    }
    $rows | Format-Table -AutoSize
}

function Stop-Keepalive {
    Write-Section "Stopping keepalive"
    $processIds = New-Object System.Collections.Generic.HashSet[int]
    $process = Get-KeepaliveProcess
    if ($process) {
        [void]$processIds.Add([int]$process.Id)
    }

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*utk_keepalive_server.py*" } |
        ForEach-Object { [void]$processIds.Add([int]$_.ProcessId) }

    if ($processIds.Count -gt 0) {
        foreach ($processId in $processIds) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped PID $processId."
        }
    } else {
        Write-Host "Keepalive was not running."
    }
    if (Test-Path $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force
    }
}

function Register-SteamVRDriver {
    if (-not $AutoRegisterSteamVR) {
        return
    }

    Write-Section "SteamVR driver"
    $udpPort = Resolve-UdpStartPort
    Write-Host "Auto-selected SteamVR UDP port range: $udpPort-$($udpPort + $TrackerCount - 1)"
    Write-SteamVRDriverSettings -StartPort $udpPort

    $dll = Join-Path $steamVrDriverPackage "bin\win64\driver_utk_wifi_tracker.dll"
    $providerSource = Join-Path $steamVrDriverDir "src\device_provider.cpp"
    $openVrHeader = Join-Path $rootDir "external\openvr\headers\openvr_driver.h"
    $driverNeedsBuild = -not (Test-Path $dll)
    if ((Test-Path $dll) -and (Test-Path $providerSource)) {
        $driverNeedsBuild = (Get-Item $providerSource).LastWriteTime -gt (Get-Item $dll).LastWriteTime
    }
    if ($driverNeedsBuild -and $BuildSteamVRDriverIfMissing -and (Test-Path $steamVrBuildScript)) {
        if (Test-Path -LiteralPath $openVrHeader) {
            Write-Host "Building SteamVR driver package..."
            & (Get-PowerShellExe) -ExecutionPolicy Bypass -File $steamVrBuildScript -BuildDir $steamVrBuildDir
            Write-SteamVRDriverSettings -StartPort $udpPort
        } else {
            Write-Warning "OpenVR SDK is missing, so SteamVR driver build was skipped: $openVrHeader"
        }
    }

    if (-not (Test-Path $dll)) {
        Write-Warning "SteamVR driver DLL is missing, so auto-registration was skipped: $dll"
        return
    }
    if (-not (Test-Path $steamVrRegisterScript)) {
        Write-Warning "SteamVR register script is missing: $steamVrRegisterScript"
        return
    }

    try {
        $vrpathreg = $null
        $openvrPath = Join-Path $env:LOCALAPPDATA "openvr\openvrpaths.vrpath"
        if (Test-Path $openvrPath) {
            try {
                $vrpaths = Get-Content -LiteralPath $openvrPath -Raw | ConvertFrom-Json
                if ($vrpaths.runtime -and $vrpaths.runtime.Count -gt 0) {
                    $candidate = Join-Path $vrpaths.runtime[0] "bin\win64\vrpathreg.exe"
                    if (Test-Path $candidate) {
                        $vrpathreg = $candidate
                    }
                }
            } catch {
                $vrpathreg = $null
            }
        }
        if ($vrpathreg -and (Test-Path $legacySteamVrDriverPackage)) {
            & $vrpathreg removedriver $legacySteamVrDriverPackage | Out-Null
        }
        & (Get-PowerShellExe) -ExecutionPolicy Bypass -File $steamVrRegisterScript -DriverPackage $steamVrDriverPackage
    } catch {
        Write-Warning "SteamVR driver registration failed: $($_.Exception.Message)"
    }
}

function Ensure-Firewall {
    if (-not $EnsureFirewallRule) {
        return
    }

    Write-Section "Firewall"
    $ruleName = "UTK WiFi-only ports $Ports"
    $existingTcp = Get-NetFirewallRule -DisplayName "$ruleName TCP" -ErrorAction SilentlyContinue
    $existingUdp = if ($UdpPosePort -gt 0) { Get-NetFirewallRule -DisplayName "$ruleName UDP $UdpPosePort" -ErrorAction SilentlyContinue } else { $true }
    if ($existingTcp -and $existingUdp) {
        Write-Host "Firewall rule already exists: $ruleName"
        return
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning "Run this app as Administrator to create the firewall rule automatically. Continuing without changing firewall."
        return
    }

    if (-not $existingTcp) {
        New-NetFirewallRule -DisplayName "$ruleName TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Ports -Profile Any | Out-Null
    }
    if ($UdpPosePort -gt 0 -and -not $existingUdp) {
        New-NetFirewallRule -DisplayName "$ruleName UDP $UdpPosePort" -Direction Inbound -Action Allow -Protocol UDP -LocalPort $UdpPosePort -Profile Any | Out-Null
    }
    Write-Host "Created firewall rule: $ruleName"
}

function Start-Keepalive {
    $existing = Get-KeepaliveProcess
    if ($existing) {
        Write-Section "Keepalive"
        Write-Host "Already running PID $($existing.Id). Reusing it."
        return
    }

    if (-not (Test-Path $keepaliveScript)) {
        throw "Missing keepalive script: $keepaliveScript"
    }

    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $stdout = Join-Path $stateDir "keepalive_$timestamp.stdout.log"
    $stderr = Join-Path $stateDir "keepalive_$timestamp.stderr.log"

    $ps = Get-PowerShellExe
    $effectivePoseForwardAutoMap = $PoseForwardAutoMap
    if ($AutoPoseForward -and -not $PoseForwardUdp -and -not $PoseForwardMap -and -not $effectivePoseForwardAutoMap) {
        $effectivePoseForwardAutoMap = "127.0.0.1:$(Resolve-UdpStartPort)"
    }

    $argsList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $keepaliveScript,
        "-Bind", $Bind,
        "-Ports", $Ports,
        "-UdpPosePort", $UdpPosePort,
        "-OutDir", (Join-Path $rootDir "backups"),
        "-PreviewBytes", $PreviewBytes,
        "-IdlePingSeconds", $IdlePingSeconds,
        "-AckSlotSize", $AckSlotSize,
        "-ConsoleRecvLimit", $ConsoleRecvLimit,
        "-LatencyStatsSeconds", $LatencyStatsSeconds,
        "-PacedMaxDelayMs", $PacedMaxDelayMs,
        "-PacedTargetHz", $PacedTargetHz,
        "-PacedBacklogCollapseMs", $PacedBacklogCollapseMs,
        "-PoseForwardFormat", $PoseForwardFormat
    )

    if ($Python) {
        $argsList += @("-Python", $Python)
    }
    if ($StopViveTrackerServer) {
        $argsList += "-StopViveTrackerServer"
    }
    if ($AckPayloads) {
        $effectiveAckPayloads = $AckPayloads.Replace("{unix}", [string][int][double]::Parse((Get-Date -UFormat %s)))
        $argsList += @("-AckPayloads", $AckPayloads)
        $argsList[-1] = $effectiveAckPayloads
    }
    if ($AckOnConnect) {
        $argsList += "-AckOnConnect"
    }
    if ($FullPayloadHex) {
        $argsList += "-FullPayloadHex"
    }
    if ($Realtime) {
        $argsList += "-Realtime"
    }
    if ($ForwardBurstMode) {
        $argsList += @("-ForwardBurstMode", $ForwardBurstMode)
    }
    if ($MinimalPoseJson) {
        $argsList += "-MinimalPoseJson"
    }
    if ($PoseForwardUdp) {
        $argsList += @("-PoseForwardUdp", $PoseForwardUdp)
    }
    if ($PoseForwardPeerIp) {
        $argsList += @("-PoseForwardPeerIp", $PoseForwardPeerIp)
    }
    if ($PoseForwardMap) {
        $argsList += @("-PoseForwardMap", $PoseForwardMap)
    }
    if ($effectivePoseForwardAutoMap) {
        $argsList += @("-PoseForwardAutoMap", $effectivePoseForwardAutoMap)
    }
    if ($PoseForwardIncludeZero) {
        $argsList += "-PoseForwardIncludeZero"
    }
    if ($ReadyPayloads) {
        $argsList += @("-ReadyPayloads", $ReadyPayloads, "-ReadyAfterValidFrames", $ReadyAfterValidFrames)
    }
    if ($ControlRefreshPayloads -and $ControlRefreshSeconds -gt 0) {
        $effectiveControlRefreshPayloads = $ControlRefreshPayloads.Replace("{unix}", [string][int][double]::Parse((Get-Date -UFormat %s)))
        $argsList += @(
            "-ControlRefreshPayloads", $effectiveControlRefreshPayloads,
            "-ControlRefreshSeconds", $ControlRefreshSeconds,
            "-ControlRefreshStartDelaySeconds", $ControlRefreshStartDelaySeconds
        )
    }

    Write-Section "Starting keepalive"
    Write-Host "PowerShell: $ps"
    Write-Host "Stdout:     $stdout"
    Write-Host "Stderr:     $stderr"

    $process = Start-Process -FilePath $ps -ArgumentList (Join-ProcessArguments -Arguments $argsList) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $state = [ordered]@{
        pid = $process.Id
        started = (Get-Date).ToString("s")
        stdout = $stdout
        stderr = $stderr
        ports = $Ports
        pose_forward_auto_map = $effectivePoseForwardAutoMap
        control_refresh_payloads = $ControlRefreshPayloads
        control_refresh_seconds = $ControlRefreshSeconds
        control_refresh_start_delay_seconds = $ControlRefreshStartDelaySeconds
        tracker_count = $TrackerCount
        script = $keepaliveScript
    }
    $state | ConvertTo-Json | Set-Content -Encoding ASCII -Path $pidFile

    Start-Sleep -Seconds 2
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
        throw "Keepalive process exited early. Check $stderr and $stdout."
    }

    $listening = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in (Get-PortList) -and $_.State -eq "Listen" }
    if ($listening) {
        Write-Host "Listening ports:"
        $listening | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    } else {
        Write-Warning "Keepalive is running, but no tracker ports are listening yet. Check logs if the device cannot connect."
    }
}

function Configure-WifiOnly {
    if (-not (Test-Path $wifiScript)) {
        throw "Missing WiFi-only script: $wifiScript"
    }

    Write-Section "Configuring device WiFi-only"
    $effectiveServerIp = Resolve-HotspotIp
    $effectivePosePort = Resolve-PosePort
    $effectiveAdbSerial = Resolve-AdbSerial
    Write-Host "Hotspot IP: $effectiveServerIp"
    Write-Host "Pose TCP port: $effectivePosePort"
    Write-Host "ADB serial: $effectiveAdbSerial"
    $argsList = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $wifiScript,
        "-AdbSerial", $effectiveAdbSerial,
        "-Ssid", $Ssid,
        "-Password", $Password,
        "-ServerIp", $effectiveServerIp,
        "-PosePort", $effectivePosePort,
        "-CountryCode", $CountryCode,
        "-Frequency", $Frequency,
        "-Proto", $Proto,
        "-Mode", "1"
    )
    & (Get-PowerShellExe) @argsList
}

function Restore-DongleMode {
    if (-not (Test-Path $restoreDongleScript)) {
        throw "Missing dongle restore script: $restoreDongleScript"
    }

    Write-Section "Restoring official dongle mode"
    if ($AdbSerial) {
        Write-Host "ADB serial: $AdbSerial"
    } else {
        Write-Host "ADB serial: auto/default adb target"
    }
    Write-Host "This disables WiFi-only mode and clears the WiFi-only endpoint props without wiping userdata."
    $argsList = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $restoreDongleScript
    )
    if ($AdbSerial) {
        $argsList += @("-AdbSerial", $AdbSerial)
    }
    & (Get-PowerShellExe) @argsList
}

switch ($Action) {
    "Stop" {
        Stop-Keepalive
    }
    "Status" {
        Show-KeepaliveStatus
    }
    "Devices" {
        Show-TrackerDevices
    }
    "DevicesJson" {
        @(Get-TrackerDeviceRows) | ConvertTo-Json -Depth 5
    }
    "DevicesTsv" {
        $columns = @("IP", "PeerPort", "TcpPort", "SteamVRUdpPort", "State", "TrackerSN", "DeviceSN", "Firmware", "LastPoseAgeMs", "PoseStatus")
        $columns -join "`t"
        foreach ($row in @(Get-TrackerDeviceRows)) {
            $values = foreach ($column in $columns) {
                $text = "$($row.$column)"
                $text.Replace("`t", " ").Replace("`r", " ").Replace("`n", " ")
            }
            $values -join "`t"
        }
    }
    "Restart" {
        Stop-Keepalive
        Ensure-Firewall
        Register-SteamVRDriver
        Start-Keepalive
        Show-KeepaliveStatus
    }
    "StartKeepalive" {
        Ensure-Firewall
        Register-SteamVRDriver
        Start-Keepalive
        Show-KeepaliveStatus
    }
    "ApplyWifi" {
        Configure-WifiOnly
        Show-KeepaliveStatus
    }
    "RestoreDongle" {
        Restore-DongleMode
        Show-KeepaliveStatus
    }
    "ConfigureOnly" {
        Configure-WifiOnly
        Show-KeepaliveStatus
    }
    "Start" {
        Ensure-Firewall
        Register-SteamVRDriver
        Start-Keepalive
        Configure-WifiOnly
        Show-KeepaliveStatus
    }
}
