param(
    [string]$DriverPackage = "$PSScriptRoot\build\utk_wifi_tracker"
)

$ErrorActionPreference = "Stop"

function Add-CandidatePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ($Path -and (Test-Path $Path) -and -not $List.Contains($Path)) {
        [void]$List.Add($Path)
    }
}

function Get-SteamInstallRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    Add-CandidatePath $roots $env:STEAM
    Add-CandidatePath $roots $env:SteamPath
    Add-CandidatePath $roots "D:\Steam"
    Add-CandidatePath $roots "C:\Program Files (x86)\Steam"
    Add-CandidatePath $roots "C:\Program Files\Steam"

    $registryKeys = @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )
    foreach ($key in $registryKeys) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        Add-CandidatePath $roots $props.SteamPath
        Add-CandidatePath $roots $props.InstallPath
    }

    return $roots
}

function Get-SteamVrCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()
    Add-CandidatePath $candidates $env:STEAMVR_PATH
    Add-CandidatePath $candidates $env:VR_OVERRIDE

    foreach ($steamRoot in Get-SteamInstallRoots) {
        Add-CandidatePath $candidates (Join-Path $steamRoot "steamapps\common\SteamVR")
        $libraryFile = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        if (Test-Path $libraryFile) {
            $content = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction SilentlyContinue
            foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $libraryRoot = $match.Groups[1].Value -replace "\\\\", "\"
                Add-CandidatePath $candidates (Join-Path $libraryRoot "steamapps\common\SteamVR")
            }
        }
    }

    return $candidates
}

$vrpathreg = $null
$command = Get-Command vrpathreg.exe -ErrorAction SilentlyContinue
if ($command) {
    $vrpathreg = $command.Source
}
if (-not $vrpathreg) {
    foreach ($candidate in Get-SteamVrCandidates) {
        $path = Join-Path $candidate "bin\win64\vrpathreg.exe"
        if (Test-Path $path) {
            $vrpathreg = $path
            break
        }
    }
}

if (-not $vrpathreg) {
    throw "Could not find SteamVR bin\win64\vrpathreg.exe"
}

if (-not (Test-Path (Join-Path $DriverPackage "driver.vrdrivermanifest"))) {
    throw "Driver package is missing driver.vrdrivermanifest: $DriverPackage"
}

if (-not (Test-Path (Join-Path $DriverPackage "bin\win64\driver_utk_wifi_tracker.dll"))) {
    throw "Driver package is missing bin\win64\driver_utk_wifi_tracker.dll: $DriverPackage"
}

& $vrpathreg adddriver (Resolve-Path $DriverPackage)
if ($LASTEXITCODE -ne 0) {
    throw "vrpathreg adddriver failed with exit code $LASTEXITCODE"
}
Write-Host "Registered SteamVR driver package: $DriverPackage"
