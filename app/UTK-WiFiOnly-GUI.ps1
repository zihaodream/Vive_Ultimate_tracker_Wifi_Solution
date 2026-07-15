Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$appScript = Join-Path $PSScriptRoot "UTK-WiFiOnly-App.ps1"

function Convert-PrefixLengthToMask {
    param([Parameter(Mandatory = $true)][int]$PrefixLength)

    $mask = [uint32]0
    for ($i = 0; $i -lt $PrefixLength; $i++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $i))
    }
    $bytes = [BitConverter]::GetBytes($mask)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-PreferredIPv4Info {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) {
        throw "No active IPv4 default route was found."
    }

    $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1
    if (-not $ip) {
        throw "No usable IPv4 address was found on the default-route adapter."
    }

    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses)
    if (-not $dns -or $dns.Count -eq 0) {
        $dns = @($route.NextHop)
    }

    return [pscustomobject]@{
        InterfaceIndex = [int]$route.InterfaceIndex
        InterfaceAlias = $adapter.Name
        IPAddress = $ip.IPAddress
        PrefixLength = [int]$ip.PrefixLength
        SubnetMask = Convert-PrefixLengthToMask -PrefixLength ([int]$ip.PrefixLength)
        Gateway = $route.NextHop
        DnsServers = @($dns | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Start-StaticIpAdmin {
    param([Parameter(Mandatory = $true)]$Info)

    $dnsLiteral = "@(" + (($Info.DnsServers | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ",") + ")"
    $adminScript = @"
`$ErrorActionPreference = "Stop"
`$alias = '$($Info.InterfaceAlias -replace "'", "''")'
`$ip = '$($Info.IPAddress)'
`$mask = '$($Info.SubnetMask)'
`$gateway = '$($Info.Gateway)'
`$dns = $dnsLiteral
netsh interface ip set address name="`$alias" static `$ip `$mask `$gateway 1
if (`$dns.Count -gt 0) {
    `$primaryDns = `$dns[0]
    netsh interface ip set dns name="`$alias" static `$primaryDns primary
    for (`$i = 1; `$i -lt `$dns.Count; `$i++) {
        `$dnsServer = `$dns[`$i]
        `$dnsIndex = `$i + 1
        netsh interface ip add dns name="`$alias" `$dnsServer index=`$dnsIndex
    }
}
Write-Host "Static IP applied to `${alias}: `$ip / `$mask gateway `$gateway"
Start-Sleep -Seconds 2
"@

    $tempScript = Join-Path $env:TEMP ("utk_static_ip_init_{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $tempScript -Value $adminScript -Encoding ASCII
    Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $tempScript
    ) | Out-Null
}

function Start-AppProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExtraArgs,
        [switch]$Visible
    )

    $argsList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $appScript
    ) + $ExtraArgs

    $style = if ($Visible) { "Normal" } else { "Hidden" }
    $argumentText = (($argsList | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') {
            '"' + ($text -replace '"', '\"') + '"'
        } else {
            $text
        }
    }) -join " ")
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentText -WindowStyle $style | Out-Null
}

function Get-TrackerDevices {
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appScript -Action DevicesTsv 2>$null)
    if (-not $output -or $output.Count -lt 2) {
        return @()
    }
    $headers = @($output[0] -split "`t")
    $items = @()
    foreach ($line in @($output | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = @($line -split "`t", $headers.Count)
        $item = [ordered]@{}
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $value = if ($i -lt $parts.Count) { $parts[$i] } else { "" }
            $item[$headers[$i]] = $value
        }
        $items += [pscustomobject]$item
    }
    return $items
}

function Invoke-TrackerPowerOff {
    param([string]$Ip = "all")

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect("127.0.0.1", 19005, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(1200)) {
            throw "Control API is not available. Restart Start Service once to enable remote power control."
        }
        $client.EndConnect($connect)
        $stream = $client.GetStream()
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream, $utf8NoBom)
        $target = if ([string]::IsNullOrWhiteSpace($Ip)) { "all" } else { $Ip }
        $payload = @{ action = "power_off"; ip = $target } | ConvertTo-Json -Compress
        $writer.WriteLine($payload)
        $line = $reader.ReadLine()
        if (-not $line) {
            throw "No response from control API."
        }
        $response = $line | ConvertFrom-Json
        if (-not $response.ok) {
            throw "Power command failed: $($response.error)"
        }
        return "Power off sent to: $(@($response.sent) -join ', ')"
    } finally {
        if ($client) {
            $client.Close()
        }
    }
}

function Show-DevicesWindow {
    $devicesForm = New-Object System.Windows.Forms.Form
    $devicesForm.Text = "Connected UTK Devices"
    $devicesForm.StartPosition = "CenterParent"
    $devicesForm.Size = New-Object System.Drawing.Size(980, 500)
    $devicesForm.MinimumSize = New-Object System.Drawing.Size(860, 390)
    $devicesForm.Font = $font
    $devicesForm.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = "Connected trackers"
    $headerLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
    $headerLabel.Location = New-Object System.Drawing.Point(14, 12)
    $headerLabel.Size = New-Object System.Drawing.Size(260, 26)
    $devicesForm.Controls.Add($headerLabel)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Select one tracker for single-device actions."
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(94, 103, 115)
    $hintLabel.Location = New-Object System.Drawing.Point(280, 16)
    $hintLabel.Size = New-Object System.Drawing.Size(390, 22)
    $devicesForm.Controls.Add($hintLabel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(14, 46)
    $grid.Size = New-Object System.Drawing.Size(710, 350)
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = "FixedSingle"
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(232, 237, 244)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(35, 42, 52)
    foreach ($column in @("IP", "PeerPort", "TcpPort", "SteamVRUdpPort", "State", "TrackerSN", "DeviceSN", "Firmware", "LastPoseAgeMs", "PoseStatus")) {
        [void]$grid.Columns.Add($column, $column)
    }
    $devicesForm.Controls.Add($grid)

    $sidePanel = New-Object System.Windows.Forms.Panel
    $sidePanel.Location = New-Object System.Drawing.Point(742, 46)
    $sidePanel.Size = New-Object System.Drawing.Size(210, 350)
    $sidePanel.Anchor = "Top,Bottom,Right"
    $sidePanel.BackColor = [System.Drawing.Color]::White
    $sidePanel.BorderStyle = "FixedSingle"
    $devicesForm.Controls.Add($sidePanel)

    $actionsLabel = New-Object System.Windows.Forms.Label
    $actionsLabel.Text = "Device actions"
    $actionsLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $actionsLabel.Location = New-Object System.Drawing.Point(14, 14)
    $actionsLabel.Size = New-Object System.Drawing.Size(170, 24)
    $sidePanel.Controls.Add($actionsLabel)

    $selectedLabel = New-Object System.Windows.Forms.Label
    $selectedLabel.Text = "Selected: none"
    $selectedLabel.Location = New-Object System.Drawing.Point(14, 50)
    $selectedLabel.Size = New-Object System.Drawing.Size(180, 42)
    $selectedLabel.ForeColor = [System.Drawing.Color]::FromArgb(72, 81, 94)
    $sidePanel.Controls.Add($selectedLabel)

    $powerOneButton = New-Object System.Windows.Forms.Button
    $powerOneButton.Text = "Power Off Selected"
    $powerOneButton.Location = New-Object System.Drawing.Point(14, 106)
    $powerOneButton.Size = New-Object System.Drawing.Size(180, 34)
    $sidePanel.Controls.Add($powerOneButton)

    $sideNote = New-Object System.Windows.Forms.Label
    $sideNote.Text = "This sends APF once through the running keepalive service."
    $sideNote.Location = New-Object System.Drawing.Point(14, 154)
    $sideNote.Size = New-Object System.Drawing.Size(180, 70)
    $sideNote.ForeColor = [System.Drawing.Color]::FromArgb(94, 103, 115)
    $sidePanel.Controls.Add($sideNote)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.Location = New-Object System.Drawing.Point(14, 412)
    $refreshButton.Size = New-Object System.Drawing.Size(95, 30)
    $refreshButton.Anchor = "Bottom,Left"
    $devicesForm.Controls.Add($refreshButton)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(120, 418)
    $statusLabel.Size = New-Object System.Drawing.Size(520, 24)
    $statusLabel.Anchor = "Bottom,Left,Right"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(72, 81, 94)
    $devicesForm.Controls.Add($statusLabel)

    $powerAllButton = New-Object System.Windows.Forms.Button
    $powerAllButton.Text = "Power Off All"
    $powerAllButton.Location = New-Object System.Drawing.Point(742, 412)
    $powerAllButton.Size = New-Object System.Drawing.Size(100, 30)
    $powerAllButton.Anchor = "Bottom,Right"
    $devicesForm.Controls.Add($powerAllButton)

    $closeDevicesButton = New-Object System.Windows.Forms.Button
    $closeDevicesButton.Text = "Close"
    $closeDevicesButton.Location = New-Object System.Drawing.Point(852, 412)
    $closeDevicesButton.Size = New-Object System.Drawing.Size(95, 30)
    $closeDevicesButton.Anchor = "Bottom,Right"
    $devicesForm.Controls.Add($closeDevicesButton)

    function Get-SelectedTrackerIp {
        if ($grid.SelectedRows.Count -le 0) {
            return ""
        }
        return [string]$grid.SelectedRows[0].Cells["IP"].Value
    }

    function Update-SelectedLabel {
        $ip = Get-SelectedTrackerIp
        if ($ip) {
            $selectedLabel.Text = "Selected:`r`n$ip"
        } else {
            $selectedLabel.Text = "Selected: none"
        }
    }

    function Refresh-DeviceGrid {
        try {
            $rows = @(Get-TrackerDevices)
            $grid.Rows.Clear()
            foreach ($row in $rows) {
                $rowIndex = $grid.Rows.Add()
                $values = @(
                    [string]$row.IP,
                    [string]$row.PeerPort,
                    [string]$row.TcpPort,
                    [string]$row.SteamVRUdpPort,
                    [string]$row.State,
                    [string]$row.TrackerSN,
                    [string]$row.DeviceSN,
                    [string]$row.Firmware,
                    [string]$row.LastPoseAgeMs,
                    [string]$row.PoseStatus
                )
                for ($i = 0; $i -lt $values.Count; $i++) {
                    $grid.Rows[$rowIndex].Cells[$i].Value = $values[$i]
                }
            }
            if ($grid.Rows.Count -gt 0) {
                $grid.Rows[0].Selected = $true
            }
            Update-SelectedLabel
            $statusLabel.Text = "Found $($rows.Count) tracker device(s). Last refresh: $(Get-Date -Format 'HH:mm:ss')"
        } catch {
            $statusLabel.Text = "Refresh failed: $($_.Exception.Message)"
        }
    }

    $refreshButton.Add_Click({ Refresh-DeviceGrid })
    $grid.Add_SelectionChanged({ Update-SelectedLabel })
    $powerOneButton.Add_Click({
        $ip = Get-SelectedTrackerIp
        if (-not $ip) {
            [System.Windows.Forms.MessageBox]::Show("Select a tracker first.", "No tracker selected", "OK", "Information") | Out-Null
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show("Power off tracker $ip?", "Confirm power off", "YesNo", "Warning")
        if ($answer -ne "Yes") {
            return
        }
        try {
            $statusLabel.Text = Invoke-TrackerPowerOff -Ip $ip
            Start-Sleep -Milliseconds 200
            Refresh-DeviceGrid
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $powerAllButton.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show("Power off all connected trackers?", "Confirm power off all", "YesNo", "Warning")
        if ($answer -ne "Yes") {
            return
        }
        try {
            $statusLabel.Text = Invoke-TrackerPowerOff -Ip "all"
            Start-Sleep -Milliseconds 200
            Refresh-DeviceGrid
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $closeDevicesButton.Add_Click({ $devicesForm.Close() })
    Refresh-DeviceGrid
    [void]$devicesForm.ShowDialog($form)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "UTK WiFi-only One Click"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(700, 500)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Font = $font

$title = New-Object System.Windows.Forms.Label
$title.Text = "VIVE Ultimate Tracker WiFi-only"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(390, 28)
$form.Controls.Add($title)

$devicesButton = New-Object System.Windows.Forms.Button
$devicesButton.Text = "Devices"
$devicesButton.Location = New-Object System.Drawing.Point(580, 18)
$devicesButton.Size = New-Object System.Drawing.Size(84, 28)
$form.Controls.Add($devicesButton)

$ssidLabel = New-Object System.Windows.Forms.Label
$ssidLabel.Text = "Hotspot SSID"
$ssidLabel.Location = New-Object System.Drawing.Point(24, 68)
$ssidLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($ssidLabel)

$ssidBox = New-Object System.Windows.Forms.TextBox
$ssidBox.Text = ""
$ssidBox.Location = New-Object System.Drawing.Point(160, 66)
$ssidBox.Size = New-Object System.Drawing.Size(300, 24)
$form.Controls.Add($ssidBox)

$passwordLabel = New-Object System.Windows.Forms.Label
$passwordLabel.Text = "Hotspot Password"
$passwordLabel.Location = New-Object System.Drawing.Point(24, 106)
$passwordLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($passwordLabel)

$passwordBox = New-Object System.Windows.Forms.TextBox
$passwordBox.Text = ""
$passwordBox.UseSystemPasswordChar = $true
$passwordBox.Location = New-Object System.Drawing.Point(160, 104)
$passwordBox.Size = New-Object System.Drawing.Size(300, 24)
$form.Controls.Add($passwordBox)

$serverIpLabel = New-Object System.Windows.Forms.Label
$serverIpLabel.Text = "Local PC IP"
$serverIpLabel.Location = New-Object System.Drawing.Point(24, 144)
$serverIpLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($serverIpLabel)

$serverIpBox = New-Object System.Windows.Forms.TextBox
$serverIpBox.Text = ""
$serverIpBox.Location = New-Object System.Drawing.Point(160, 142)
$serverIpBox.Size = New-Object System.Drawing.Size(180, 24)
$form.Controls.Add($serverIpBox)

$initButton = New-Object System.Windows.Forms.Button
$initButton.Text = "Initialize"
$initButton.Location = New-Object System.Drawing.Point(350, 140)
$initButton.Size = New-Object System.Drawing.Size(110, 28)
$form.Controls.Add($initButton)

$steamvrCheck = New-Object System.Windows.Forms.CheckBox
$steamvrCheck.Text = "Auto-register SteamVR driver"
$steamvrCheck.Checked = $true
$steamvrCheck.Location = New-Object System.Drawing.Point(160, 184)
$steamvrCheck.Size = New-Object System.Drawing.Size(210, 24)
$form.Controls.Add($steamvrCheck)

$firewallCheck = New-Object System.Windows.Forms.CheckBox
$firewallCheck.Text = "Try to add firewall rule"
$firewallCheck.Checked = $false
$firewallCheck.Location = New-Object System.Drawing.Point(160, 214)
$firewallCheck.Size = New-Object System.Drawing.Size(210, 24)
$form.Controls.Add($firewallCheck)

$debugModeCheck = New-Object System.Windows.Forms.CheckBox
$debugModeCheck.Text = "Debug mode"
$debugModeCheck.Checked = $false
$debugModeCheck.Location = New-Object System.Drawing.Point(370, 214)
$debugModeCheck.Size = New-Object System.Drawing.Size(120, 24)
$form.Controls.Add($debugModeCheck)

$trackerLabel = New-Object System.Windows.Forms.Label
$trackerLabel.Text = "Reserved UTK slots"
$trackerLabel.Location = New-Object System.Drawing.Point(24, 248)
$trackerLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($trackerLabel)

$trackerCountBox = New-Object System.Windows.Forms.NumericUpDown
$trackerCountBox.Minimum = 1
$trackerCountBox.Maximum = 16
$trackerCountBox.Value = 10
$trackerCountBox.Location = New-Object System.Drawing.Point(160, 246)
$trackerCountBox.Size = New-Object System.Drawing.Size(80, 24)
$form.Controls.Add($trackerCountBox)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Location = New-Object System.Drawing.Point(24, 290)
$statusBox.Size = New-Object System.Drawing.Size(632, 82)
$statusBox.Text = "Normal mode starts compact UDP with ACK-on-connect and paced 50 Hz binary UTKP. Periodic ATM21 refresh is disabled because it can trigger lost-tracking flashes."
$form.Controls.Add($statusBox)

$serviceButton = New-Object System.Windows.Forms.Button
$serviceButton.Text = "Start Service"
$serviceButton.Location = New-Object System.Drawing.Point(24, 412)
$serviceButton.Size = New-Object System.Drawing.Size(112, 30)
$form.Controls.Add($serviceButton)

$flashButton = New-Object System.Windows.Forms.Button
$flashButton.Text = "Flash WiFi"
$flashButton.Location = New-Object System.Drawing.Point(146, 412)
$flashButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($flashButton)

$dongleButton = New-Object System.Windows.Forms.Button
$dongleButton.Text = "Dongle Mode"
$dongleButton.Location = New-Object System.Drawing.Point(256, 412)
$dongleButton.Size = New-Object System.Drawing.Size(112, 30)
$form.Controls.Add($dongleButton)

$statusButton = New-Object System.Windows.Forms.Button
$statusButton.Text = "Status"
$statusButton.Location = New-Object System.Drawing.Point(378, 412)
$statusButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($statusButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(488, 412)
$stopButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($stopButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(588, 412)
$closeButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($closeButton)

try {
    $initialInfo = Get-PreferredIPv4Info
    $serverIpBox.Text = $initialInfo.IPAddress
    $statusBox.Text = "Detected local PC IP $($initialInfo.IPAddress) on $($initialInfo.InterfaceAlias). Click Initialize to lock it as static before flashing WiFi."
} catch {
    $statusBox.Text = "Could not auto-detect local PC IP. Enter it manually or click Initialize after connecting the PC to the router."
}

$initButton.Add_Click({
    try {
        $info = Get-PreferredIPv4Info
        $serverIpBox.Text = $info.IPAddress
        Start-StaticIpAdmin -Info $info
        $statusBox.Text = "Admin static-IP setup requested for $($info.InterfaceAlias): $($info.IPAddress). Approve UAC, then use Flash WiFi to burn this IP into the tracker."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Initialize failed", "OK", "Error") | Out-Null
        $statusBox.Text = "Initialize failed: $($_.Exception.Message)"
    }
})

$serviceButton.Add_Click({
    $argsList = @(
        "-Action", "StartKeepalive",
        "-TrackerCount", ([string][int]$trackerCountBox.Value),
        "-StopViveTrackerServer",
        "-UdpPosePort", "9005",
        "-AckOnConnect:`$true",
        "-ForwardBurstMode", "paced",
        "-PacedTargetHz", "50",
        "-PacedMaxDelayMs", "45",
        "-PoseForwardFormat", "binary",
        "-PoseForwardIncludeZero:`$true",
        "-ControlRefreshPayloads", "ATM21",
        "-ControlRefreshSeconds", "0",
        "-ControlRefreshStartDelaySeconds", "0",
        "-LatencyStatsSeconds", "1"
    )
    if (-not $steamvrCheck.Checked) {
        $argsList += "-AutoRegisterSteamVR:`$false"
    }
    if ($firewallCheck.Checked) {
        $argsList += "-EnsureFirewallRule"
    }
    if ($debugModeCheck.Checked) {
        $argsList += @(
            "-Realtime:`$false",
            "-ForwardBurstMode", "all",
            "-PoseForwardFormat", "json",
            "-MinimalPoseJson:`$false",
            "-FullPayloadHex",
            "-PreviewBytes", "4096"
        )
    }

    Start-AppProcess -ExtraArgs $argsList -Visible
    if ($debugModeCheck.Checked) {
        $statusBox.Text = "Debug service start requested. This is heavier and intended for captures."
    } else {
        $statusBox.Text = "Normal service start requested without periodic ATM21 refresh. Keep this running first, then let the tracker connect to WiFi."
    }
})

$flashButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($ssidBox.Text) -or [string]::IsNullOrWhiteSpace($passwordBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter hotspot SSID and password.", "Missing info", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($serverIpBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please initialize or enter Local PC IP before flashing WiFi.", "Missing IP", "OK", "Warning") | Out-Null
        return
    }

    $argsList = @(
        "-Action", "ApplyWifi",
        "-Ssid", $ssidBox.Text,
        "-Password", $passwordBox.Text,
        "-ServerIp", $serverIpBox.Text,
        "-Proto", "udp",
        "-Frequency", "0"
    )

    Start-AppProcess -ExtraArgs $argsList -Visible
    $statusBox.Text = "WiFi-only flash requested with ServerIp=$($serverIpBox.Text), UDP props, and full-scan frequency. Use this only when needed."
})

$dongleButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "RestoreDongle") -Visible
    $statusBox.Text = "Dongle mode restore requested. After it finishes, the tracker should be visible to VIVE Hub through the official receiver path."
})

$statusButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Status") -Visible
})

$devicesButton.Add_Click({
    Show-DevicesWindow
})

$stopButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Stop") -Visible
    $statusBox.Text = "Stop command sent."
})

$closeButton.Add_Click({
    $form.Close()
})

[void]$form.ShowDialog()
