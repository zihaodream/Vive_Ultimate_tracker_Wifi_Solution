# UTK WiFi Bridge Usage Guide

This guide is for normal testing and daily use. In this document, Ultimate
Tracker is abbreviated as UTK.

## Initial Preparation

1. UTK is recommended to use system version 169. This project was developed and
   tested on that version. Other versions may have unknown issues.
2. Before using this WiFi-only solution, you must first use the official
   receiver solution and VIVE Hub to complete map scanning for each UTK. The
   current WiFi-only solution cannot scan maps.
3. If you need to restore the device to the official usage mode later, use the
   original factory firmware package or the official recovery process to flash
   the device back to a normal state.
4. This project does not provide HTC / VIVE firmware, system images, official
   receiver firmware, or VIVE Hub files.

## Firmware Package Usage

If you need to flash or restore UTK system version 169, download the firmware
package from this project's GitHub Release attachments and prepare the required
PC drivers yourself.

Release attachment name:

```text
APQ8053_ROM_FB.zip
```

Local organized firmware package path:

```text
firmware_package\APQ8053_ROM_FB.zip
```

This directory is ignored by `.gitignore` by default and will not be committed
to the source repository. When publishing, upload `APQ8053_ROM_FB.zip` as a
GitHub Release attachment.

Your PC needs:

```text
ADB driver
bootloader / fastboot driver
```

Driver installation differs between PCs and Windows environments. Search for
and install the required drivers yourself. Before flashing, confirm that the
device can be recognized correctly in both ADB mode and bootloader / fastboot
mode.

Basic flashing flow:

1. Download `APQ8053_ROM_FB.zip` from this project's GitHub Release
   attachments, or use the local `firmware_package\APQ8053_ROM_FB.zip`.
2. Extract the firmware package to a directory with an English-only path.
3. Connect the UTK to the PC.
4. Check whether the device drivers are working, and confirm that ADB /
   bootloader devices can be detected.
5. In the extracted firmware package directory, run:

```text
apq8053_flash_rom.bat
```

6. Wait for the flashing script to finish.
7. After flashing is complete, reboot the device according to the package
   prompt.

Notes:

- Flashing is risky. It may cause the device to fail to boot, fail to connect,
  lose data, or become damaged.
- Do not unplug USB, shut down the PC, or force-stop the script during flashing.
- Make sure the downloaded package matches the UTK 169 version described by
  this project.
- Firmware flashing issues are not automatically handled by this project.

## Recommended Entry Point

Use the GUI first:

```text
app\UTK-WiFiOnly-GUI.cmd
```

This opens the graphical interface used to initialize the PC IP, start the
service, and write UTK WiFi-only configuration.

## First-time Usage Flow

1. Prepare a 5GHz WiFi router.
2. Connect the PC to that router.
3. Double-click `app\UTK-WiFiOnly-GUI.cmd`.
4. Click `Initialize` in the GUI. It reads the current PC LAN IP and attempts
   to set that IP as static on the current network adapter.
5. Enter the router WiFi SSID and password.
6. Confirm that `Local PC IP` is the PC's LAN IP under that router.
7. If this is the first time SteamVR loads this project's driver, close SteamVR
   first.
8. Click `Start Service` to start the PC-side keepalive / pose bridge and
   register the SteamVR driver.
9. If the UTK has not yet been written with WiFi-only parameters, connect ADB
   and click `Flash WiFi`.
10. Start SteamVR and confirm whether the tracker appears.

For daily use, you usually only need to:

1. Double-click `app\UTK-WiFiOnly-GUI.cmd`.
2. Click `Start Service` in the GUI.
3. Turn on the UTK.
4. Watch the UTK LED state:
   - Blinking blue: not connected yet.
   - Breathing green: connected, but currently lost tracking.
   - Double-blinking green: running normally.
5. Start SteamVR.

You only need to run `Flash WiFi` again when the WiFi name, WiFi password, PC
IP changes, or after the device has been restored to official receiver mode.

## Recommended Network

Recommended link:

```text
UTK -> 5GHz WiFi router -> PC -> SteamVR
```

Recommendations:

- Use 5GHz WiFi.
- Keep the PC and UTK on the same LAN.
- Use a fixed LAN IP for the PC to avoid rewriting UTK configuration every time
  DHCP assigns a different PC IP.

## GUI Buttons

`Initialize`

Reads the current PC LAN IP, fills `Local PC IP`, and attempts to request
administrator privileges to configure the current network adapter with a static
IP.

`Start Service`

Starts the keepalive / pose bridge, automatically registers the SteamVR OpenVR
driver, and prepares to receive UTK WiFi-only pose data.

`Flash WiFi`

Writes UTK WiFi-only configuration through ADB. You only need this for first
configuration, WiFi changes, PC IP changes, or after device recovery.

`Status`

Shows current service status, listening ports, and tracker connection
information.

`Stop`

Stops the PC-side test service.

`Debug mode`

Only for packet capture, troubleshooting, and reverse analysis. Do not enable
it for normal VR use, because it increases logging volume and runtime load.

## Current Runtime Chain

Default chain:

```text
UTK compact UDP 0x25
  -> PC UDP 9005
  -> Python keepalive / pose bridge
  -> binary UTKP 127.0.0.1:5557+
  -> SteamVR OpenVR driver
  -> SteamVR Tracker
```

Default strategy:

```text
UdpPosePort:       9005
AckOnConnect:      true
ForwardBurstMode:  paced
PacedTargetHz:     50
PacedMaxDelayMs:   45
PoseForwardFormat: binary
ControlRefresh:    disabled
```

## Space Calibration

After UTK appears in SteamVR, space calibration is still required.

You can use the open-source calibration project:

[hyblocker/OpenVR-SpaceCalibrator](https://github.com/hyblocker/OpenVR-SpaceCalibrator)

## Log Locations

Runtime logs are written by default to:

```text
logs\
backups\
```

If you need to report an issue, provide these files first:

```text
backups\utk_wifi_only_app\*.stdout.log
backups\utk_wifi_only_app\*.stderr.log
logs\utk_keepalive_*.ndjson
SteamVR vrserver.txt
```

Before publicly posting logs, remove WiFi names, passwords, device serial
numbers, personal paths, and public network information.

## FAQ

### Do I need the official receiver?

The realtime tracking link does not need the official receiver. However, first
use must be completed through VIVE Hub and the official receiver for pairing,
connection, and map scanning.

### Do I need to run Flash WiFi every time?

No. You only need to rewrite configuration for first setup, WiFi changes, PC IP
changes, or after the device has been restored.

### Why is a fixed PC IP recommended?

The PC IP is written into the UTK WiFi-only configuration. If the router assigns
a new IP to the PC, the UTK will still try to connect to the old IP, causing
connection failure.

### Can this break the 5-tracker limit?

One goal of this project is to let multiple UTKs enter SteamVR through a normal
WiFi router. The current driver keeps 10 tracker slots by default, and the
internal design leaves room for more slots.

### How do I change maps?

If you need to change or rescan a map, the current solution can only use the
factory firmware package or official recovery process to restore the device to
a normal state, then use the official receiver solution and VIVE Hub to record
the map again.
