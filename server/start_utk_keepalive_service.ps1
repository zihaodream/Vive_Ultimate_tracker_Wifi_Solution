param(
    [string]$Bind = "0.0.0.0",
    [string]$Ports = "9005,3680,8053,15680",
    [int]$UdpPosePort = 0,
    [string]$OutDir = "",
    [string]$Python = "",
    [switch]$StopViveTrackerServer,
    [int]$PreviewBytes = 64,
    [double]$IdlePingSeconds = 0,
    [string]$AckPayloads = "",
    [switch]$AckOnConnect,
    [int]$AckSlotSize = 128,
    [int]$ConsoleRecvLimit = -1,
    [switch]$FullPayloadHex,
    [switch]$Realtime,
    [ValidateSet("", "all", "latest", "paced")]
    [string]$ForwardBurstMode = "",
    [double]$PacedMaxDelayMs = 30.0,
    [double]$PacedTargetHz = 60.0,
    [double]$PacedBacklogCollapseMs = 8.0,
    [switch]$MinimalPoseJson,
    [ValidateSet("json", "binary")]
    [string]$PoseForwardFormat = "json",
    [string]$PoseForwardUdp = "",
    [string]$PoseForwardPeerIp = "",
    [string]$PoseForwardMap = "",
    [string]$PoseForwardAutoMap = "",
    [switch]$PoseForwardIncludeZero,
    [string]$ReadyPayloads = "",
    [int]$ReadyAfterValidFrames = 30,
    [string]$ControlRefreshPayloads = "",
    [double]$ControlRefreshSeconds = 0,
    [double]$ControlRefreshStartDelaySeconds = 0,
    [double]$LatencyStatsSeconds = 5.0,
    [int]$ControlApiPort = 19005
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $scriptDir "utk_keepalive_server.py"
if (-not $OutDir) {
    $OutDir = Join-Path (Split-Path -Parent $scriptDir) "backups"
}

if (-not (Test-Path $server)) {
    throw "Missing keepalive server: $server"
}

if ($StopViveTrackerServer) {
    Get-Process ViveTrackerServer -ErrorAction SilentlyContinue | Stop-Process -Force
}

if (-not $Python) {
    $bundled = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    if (Test-Path $bundled) {
        $Python = $bundled
    } else {
        $Python = "python"
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$out = Join-Path $OutDir "utk_keepalive_$timestamp.ndjson"

Write-Host "Starting UTK keepalive service without ViveTrackerServer."
Write-Host "Bind: $Bind"
Write-Host "Ports: $Ports"
if ($UdpPosePort -gt 0) {
    Write-Host "UDP pose input port: $UdpPosePort"
}
Write-Host "Log: $out"
if ($AckPayloads) {
    Write-Host "ACK payloads: $AckPayloads"
    if ($AckOnConnect) {
        Write-Host "ACK on connect: enabled"
    }
}
if ($FullPayloadHex) {
    Write-Host "Full payload hex logging: enabled"
}
if ($Realtime) {
    Write-Host "Realtime mode: enabled"
}
if ($ForwardBurstMode) {
    Write-Host "Forward burst mode: $ForwardBurstMode"
    if ($ForwardBurstMode -eq "paced") {
        Write-Host "Paced target: $PacedTargetHz Hz, max delay: $PacedMaxDelayMs ms, backlog collapse: $PacedBacklogCollapseMs ms"
    }
}
if ($MinimalPoseJson) {
    Write-Host "Minimal pose JSON: enabled"
}
Write-Host "Pose UDP format: $PoseForwardFormat"
if ($PoseForwardUdp) {
    Write-Host "Pose UDP forward: $PoseForwardUdp"
    if ($PoseForwardPeerIp) {
        Write-Host "Pose UDP forward peer filter: $PoseForwardPeerIp"
    }
    if ($PoseForwardIncludeZero) {
        Write-Host "Pose UDP forward includes zero xyz frames."
    }
}
if ($PoseForwardMap) {
    Write-Host "Pose UDP forward map: $PoseForwardMap"
}
if ($PoseForwardAutoMap) {
    Write-Host "Pose UDP forward auto-map: $PoseForwardAutoMap"
}
if ($ReadyPayloads) {
    Write-Host "Experimental ready payloads after $ReadyAfterValidFrames valid pose frames: $ReadyPayloads"
}
if ($ControlRefreshPayloads -and $ControlRefreshSeconds -gt 0) {
    Write-Host "Experimental control refresh: $ControlRefreshPayloads every $ControlRefreshSeconds seconds"
    if ($ControlRefreshStartDelaySeconds -gt 0) {
        Write-Host "Control refresh first send delay: $ControlRefreshStartDelaySeconds seconds"
    }
}
if ($LatencyStatsSeconds -gt 0) {
    Write-Host "Latency stats interval: $LatencyStatsSeconds seconds"
}
Write-Host ""
Write-Host "If a port is already occupied, close ViveTrackerServer or rerun with -StopViveTrackerServer."
Write-Host "Keep this PowerShell open while testing WiFi-only."
$argsList = @(
    $server,
    "--bind", $Bind,
    "--ports", $Ports,
    "--udp-pose-port", $UdpPosePort,
    "--out", $out,
    "--preview-bytes", $PreviewBytes,
    "--idle-ping-seconds", $IdlePingSeconds,
    "--ack-slot-size", $AckSlotSize,
    "--console-recv-limit", $ConsoleRecvLimit,
    "--latency-stats-seconds", $LatencyStatsSeconds,
    "--paced-max-delay-ms", $PacedMaxDelayMs,
    "--paced-target-hz", $PacedTargetHz,
    "--paced-backlog-collapse-ms", $PacedBacklogCollapseMs,
    "--pose-forward-format", $PoseForwardFormat
)

if ($AckPayloads) {
    $argsList += "--ack-payloads"
    $argsList += $AckPayloads
}
if ($AckOnConnect) {
    $argsList += "--ack-on-connect"
}
if ($FullPayloadHex) {
    $argsList += "--full-payload-hex"
}
if ($Realtime) {
    $argsList += "--realtime"
}
if ($ForwardBurstMode) {
    $argsList += "--forward-burst-mode"
    $argsList += $ForwardBurstMode
}
if ($MinimalPoseJson) {
    $argsList += "--minimal-pose-json"
}
if ($PoseForwardUdp) {
    $argsList += "--pose-forward-udp"
    $argsList += $PoseForwardUdp
}
if ($PoseForwardPeerIp) {
    $argsList += "--pose-forward-peer-ip"
    $argsList += $PoseForwardPeerIp
}
if ($PoseForwardMap) {
    $argsList += "--pose-forward-map"
    $argsList += $PoseForwardMap
}
if ($PoseForwardAutoMap) {
    $argsList += "--pose-forward-auto-map"
    $argsList += $PoseForwardAutoMap
}
if ($PoseForwardIncludeZero) {
    $argsList += "--pose-forward-include-zero"
}
if ($ReadyPayloads) {
    $argsList += "--ready-payloads"
    $argsList += $ReadyPayloads
    $argsList += "--ready-after-valid-frames"
    $argsList += $ReadyAfterValidFrames
}
if ($ControlRefreshPayloads) {
    $argsList += "--control-refresh-payloads"
    $argsList += $ControlRefreshPayloads
    $argsList += "--control-refresh-seconds"
    $argsList += $ControlRefreshSeconds
    $argsList += "--control-refresh-start-delay-seconds"
    $argsList += $ControlRefreshStartDelaySeconds
}
if ($ControlApiPort -gt 0) {
    $argsList += "--control-api-port"
    $argsList += $ControlApiPort
}

& $Python @argsList
