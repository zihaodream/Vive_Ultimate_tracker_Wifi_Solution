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
    Start-Process -FilePath "powershell.exe" -ArgumentList $argsList -WindowStyle $style | Out-Null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "UTK WiFi-only One Click"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(620, 500)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Font = $font

$title = New-Object System.Windows.Forms.Label
$title.Text = "VIVE Ultimate Tracker WiFi-only"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($title)

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
$statusBox.Size = New-Object System.Drawing.Size(512, 82)
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

$statusButton = New-Object System.Windows.Forms.Button
$statusButton.Text = "Status"
$statusButton.Location = New-Object System.Drawing.Point(256, 412)
$statusButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($statusButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(366, 412)
$stopButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($stopButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(466, 412)
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

$statusButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Status") -Visible
})

$stopButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Stop") -Visible
    $statusBox.Text = "Stop command sent."
})

$closeButton.Add_Click({
    $form.Close()
})

[void]$form.ShowDialog()
