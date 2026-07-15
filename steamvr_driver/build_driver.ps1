param(
    [string]$BuildDir = "$PSScriptRoot\build",
    [string]$OpenVrRoot = "$PSScriptRoot\..\external\openvr",
    [switch]$Release = $true
)

$ErrorActionPreference = "Stop"

$openVrHeader = Join-Path $OpenVrRoot "headers\openvr_driver.h"
if (-not (Test-Path -LiteralPath $openVrHeader)) {
    throw "OpenVR SDK header was not found: $openVrHeader. Put the Valve OpenVR SDK under external\openvr, or rerun with -OpenVrRoot <path-to-openvr>."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}

$cmake = "cmake"
if ($vsPath) {
    $vsCmake = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $vsCmake) {
        $cmake = $vsCmake
    }
}

$config = if ($Release) { "Release" } else { "Debug" }

if ($vsPath) {
    $devCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
    cmd /c "call `"$devCmd`" -arch=x64 -host_arch=x64 && `"$cmake`" -S `"$PSScriptRoot`" -B `"$BuildDir`" -A x64 -DOPENVR_ROOT=`"$OpenVrRoot`" && `"$cmake`" --build `"$BuildDir`" --config $config"
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }
} else {
    & $cmake -S $PSScriptRoot -B $BuildDir -A x64 -DOPENVR_ROOT="$OpenVrRoot"
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed with exit code $LASTEXITCODE"
    }
    & $cmake --build $BuildDir --config $config
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }
}

$package = Join-Path $BuildDir "utk_wifi_tracker"
Write-Host "Built SteamVR driver package: $package"
