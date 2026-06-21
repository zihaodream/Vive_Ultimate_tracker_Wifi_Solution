# Vive Ultimate Tracker WiFi-only Bridge
This project lets multiple VIVE Ultimate Trackers connect directly to a normal 5GHz WiFi router without using the official receiver. 
The PC receives tracker pose data and forwards it to SteamVR / OpenVR as tracker devices. 
The goal is to reduce UTK's dependency on official connection flows and usage limits.
The current implementation can bypass the official receiver solution's 5-tracker limit, allowing UTK devices to be used more like VIVE Tracker 3.0
devices with fewer slot restrictions.

VIVE Ultimate Tracker WiFi-only 多追踪器桥接工具。
本项目可以让多台 Ultimate Tracker 不通过官方接收器，直接接入普通 5GHz WiFi 路由器，由 PC 接收 Tracker 的姿态数据，再转发到 SteamVR / OpenVR Tracker 使用。
它的目标是降低UTK对官方流程和限制的依赖。
目前已经实现突破官方接收器方案的最大5点限制，使其能像tracker3.0一样无限制使用。
理论上用户可自行优化算法和流程，也可以摆脱UTK在传统方案下的使用局限性，使其在更多领域展现出使用价值。


## 使用前必读

使用前请先阅读：

[docs/使用说明.md](docs/使用说明.md)

English guide:

[Usage Guide.md](Usage%20Guide.md)

建议使用者具备基本的网络、刷机和计算机操作知识，能够理解局域网 IP、ADB / bootloader 驱动、SteamVR driver、刷机风险和设备恢复流程。

不要在不了解流程的情况下直接刷写或启动。首次使用前请确认设备系统版本、地图扫描状态、PC 局域网 IP、WiFi 信息、SteamVR driver 状态和恢复方案。

UTK 169 刷机包请从 GitHub Release 附件下载。文件名：

```text
APQ8053_ROM_FB.zip
```

本地整理目录中的刷机包位置为：

```text
firmware_package\APQ8053_ROM_FB.zip
```


当前项目已经完成一条可用链路：

```text
VIVE Ultimate Tracker
  -> WiFi router / LAN
  -> PC UDP/TCP listener
  -> local binary pose forwarding
  -> SteamVR OpenVR driver
  -> virtual SteamVR trackers
```

## 项目状态

当前状态：可供 VR 游戏使用，实际体验已经接近 Ultimate Tracker 正常连接效果。

建议环境：

- Windows
- SteamVR
- 5GHz WiFi 路由器
- PC 和 Tracker 在同一局域网
- PC 使用固定局域网 IP
- 已安装 ADB，用于首次写入 Tracker WiFi-only 配置
- 可用的 CMake / Visual Studio C++ 环境，用于构建 OpenVR driver
- Valve OpenVR SDK，默认路径为 `external\openvr`，也可以在构建时手动指定 `OPENVR_ROOT`

## 功能

- WiFi-only 配置写入
- GUI 启动器
- 本机 IP 初始化辅助
- Tracker TCP / UDP 监听
- 姿态数据解析与转发
- 多设备自动端口映射
- SteamVR / OpenVR 虚拟 Tracker 驱动
- 低延迟二进制本地转发
- 调试日志与链路状态观测

## 目录结构

```text
app/
  GUI 和一键启动入口

scripts/
  Tracker WiFi-only 配置与恢复脚本

server/
  PC 端 keepalive / pose forwarding 服务

steamvr_driver/
  SteamVR OpenVR Tracker 驱动源码

docs/
  开发记录、链路问题记录、调试结论
```

## 快速开始

### 1. 准备网络

建议使用 5GHz 路由器。PC 和 Ultimate Tracker 需要连接到同一个局域网。

为了避免每次路由器重新分配 IP 后都要重新写入 Tracker 配置，建议给 PC 设置固定局域网 IP。GUI 中的初始化按钮会尝试读取当前 PC IP，并辅助把当前网卡配置为静态 IP。

### 2. 启动 GUI

运行：

```powershell
.\app\UTK-WiFiOnly-GUI.cmd
```

常用流程：

1. 点击 `Initialize`，读取并固定当前 PC 局域网 IP。
2. 填入路由器 WiFi SSID 和密码。
3. 填入或确认 `Local PC IP`。
4. 对每个 Tracker 执行 WiFi 写入。
5. 点击 `Start Service`。
6. 启动 SteamVR。

### 3. Tracker 接入

Tracker 写入 WiFi-only 配置后，会连接到路由器，并向 PC 的指定端口发送姿态数据。

PC 端服务会监听这些数据，解析后转发到本地 SteamVR driver 使用的 UDP 端口。多台 Tracker 会自动映射到连续端口，例如：

```text
127.0.0.1:5557
127.0.0.1:5558
127.0.0.1:5559
...
```

SteamVR driver 会把这些输入注册为虚拟 Tracker。

## 当前推荐运行策略

推荐使用普通路由器模式：

```text
Tracker -> 5GHz router -> PC -> SteamVR
```

当前默认策略：

- 使用 UDP pose 输入
- 本地使用 binary UTKP 转发
- paced 50 Hz 输出
- 默认不周期发送 `ATM21`
- 启动握手中保留必要控制包

测试中发现，周期性发送 `ATM21` 虽然可能延长连接活跃状态，但会在部分设备上触发 7-10 秒左右的短暂 `status=3` 丢追。因此当前默认关闭周期性 `ATM21` refresh。

## 已知限制

- 这是非官方实现，不保证适配所有固件版本。
- WiFi-only 模式下，设备长时间未被使用时可能会进入待机或休眠。
- 路由器质量、5GHz 信道、无线干扰会影响稳定性。
- 首次配置需要 ADB。
- 当前主要面向 Windows + SteamVR。


本项目只发布社区自写的脚本、服务端代码、OpenVR driver 代码和必要配置。

## 免责声明

本项目是非官方社区项目，与 HTC、VIVE、Valve、SteamVR 官方无关，也未获得其认可、授权或支持。

使用本项目可能影响设备网络配置、追踪状态、SteamVR 驱动状态或设备行为，也可能因为刷写、配置错误、版本不匹配、误操作或未知兼容性问题造成设备异常、无法连接、无法恢复、数据丢失、设备损坏等严重后果。

请务必先阅读使用说明，并确认自己理解每一步操作的含义。不阅读说明、跳过准备步骤、使用错误版本、写入错误 WiFi / IP 配置、误用调试功能或自行修改参数导致的任何后果，均由使用者自行承担。

本项目不提供任何形式的保证，包括但不限于可用性、稳定性、兼容性、安全性、适销性或特定用途适用性。

## 许可说明

本项目不是 MIT / Apache / GPL 等标准开源许可证项目，而是源码可见的非商业项目。

允许：

- 个人从本 GitHub 仓库下载源码
- 个人非商业使用
- 个人学习、研究和本地修改
- 个人在自己的设备上编译和运行

该项目禁止任何商业或以牟利为目的的行为，包括但不限制：

- 商业使用
- 销售、出租、收费部署或收费维护
- 将本项目集成进商业产品、商业服务或付费整合包

下列行为请先取得作者授权：

- 重新分发、转载、搬运、镜像发布
- 二次打包发布
- 基于本项目发布修改版或衍生版本

如果你希望转载、分发、集成，请先联系作者取得授权。

## 仓库地址

GitHub:

```text
https://github.com/zihaodream/Vive-Ultimate-Tracker-WiFi-only-
```

---

# English Version

## VIVE Ultimate Tracker WiFi-only Multi-tracker Bridge

This project lets multiple VIVE Ultimate Trackers connect directly to a normal
5GHz WiFi router without using the official receiver. The PC receives tracker
pose data and forwards it to SteamVR / OpenVR as tracker devices.

The goal is to reduce UTK's dependency on official connection flows and usage
limits. The current implementation can bypass the official receiver solution's
5-tracker limit, allowing UTK devices to be used more like VIVE Tracker 3.0
devices with fewer slot restrictions.

## Must Read Before Use

Please read the usage guide before using this project:

[Chinese Usage Guide](docs/使用说明.md)

[English Usage Guide](Usage%20Guide.md)

Users are expected to have basic networking, flashing, and computer operation
knowledge, including LAN IPs, ADB / bootloader drivers, SteamVR drivers,
flashing risks, and device recovery procedures.

Do not flash or start anything before understanding the flow. Before first use,
confirm the device system version, map scan state, PC LAN IP, WiFi information,
SteamVR driver state, and recovery plan.

UTK 169 firmware package should be downloaded from GitHub Release attachments:

```text
APQ8053_ROM_FB.zip
```

Local organized firmware package path:

```text
firmware_package\APQ8053_ROM_FB.zip
```

## Current Chain

```text
VIVE Ultimate Tracker
  -> WiFi router / LAN
  -> PC UDP/TCP listener
  -> local binary pose forwarding
  -> SteamVR OpenVR driver
  -> virtual SteamVR trackers
```

## Project Status

Current state: usable for VR games. The real experience is already close to a
normal Ultimate Tracker connection.

Recommended environment:

- Windows
- SteamVR
- 5GHz WiFi router
- PC and tracker on the same LAN
- Fixed LAN IP for the PC
- ADB installed for first-time tracker WiFi-only configuration
- CMake / Visual Studio C++ environment for building the OpenVR driver
- Valve OpenVR SDK, default path `external\openvr`, or manually specify
  `OPENVR_ROOT` during build

## Features

- WiFi-only configuration writing
- GUI launcher
- Local PC IP initialization helper
- Tracker TCP / UDP listener
- Pose data parsing and forwarding
- Automatic multi-device port mapping
- SteamVR / OpenVR virtual tracker driver
- Low-latency local binary forwarding
- Debug logs and link status observation

## Quick Start

### 1. Prepare the Network

Use a 5GHz router. The PC and Ultimate Trackers must be connected to the same
LAN.

To avoid rewriting tracker configuration whenever the router changes the PC IP,
set a fixed LAN IP for the PC. The GUI `Initialize` button will try to read the
current PC IP and help configure the current adapter as a static IP.

### 2. Start the GUI

Run:

```powershell
.\app\UTK-WiFiOnly-GUI.cmd
```

Common flow:

1. Click `Initialize` to read and fix the current PC LAN IP.
2. Enter the router WiFi SSID and password.
3. Enter or confirm `Local PC IP`.
4. Flash WiFi configuration for each tracker.
5. Click `Start Service`.
6. Start SteamVR.

### 3. Connect Trackers

After WiFi-only configuration is written, the tracker connects to the router
and sends pose data to the specified PC port.

The PC service listens for that data, parses it, and forwards it to local UDP
ports used by the SteamVR driver. Multiple trackers are mapped automatically to
consecutive ports, for example:

```text
127.0.0.1:5557
127.0.0.1:5558
127.0.0.1:5559
...
```

The SteamVR driver registers these inputs as virtual trackers.

## Recommended Runtime Strategy

Recommended link:

```text
Tracker -> 5GHz router -> PC -> SteamVR
```

Current defaults:

- UDP pose input
- Local binary UTKP forwarding
- Paced 50 Hz output
- Periodic `ATM21` disabled by default
- Required control packets kept in startup handshake

Testing showed that periodic `ATM21` may keep the connection more active, but
on some devices it can trigger a short `status=3` lost-tracking period of about
7-10 seconds. Therefore periodic `ATM21` refresh is disabled by default.

## Known Limitations

- This is an unofficial implementation and is not guaranteed to support every
  firmware version.
- In WiFi-only mode, the device may enter standby or sleep if unused for a long
  time.
- Router quality, 5GHz channel, and wireless interference affect stability.
- First-time configuration requires ADB.
- The project is mainly for Windows + SteamVR.

This project only publishes community-written scripts, service code, OpenVR
driver code, and required configuration.

## Disclaimer

This is an unofficial community project. It is not affiliated with HTC, VIVE,
Valve, or SteamVR, and is not approved, authorized, or supported by them.

Using this project may affect device network configuration, tracking state,
SteamVR driver state, or device behavior. Flashing, wrong configuration,
version mismatch, misuse, or unknown compatibility issues may cause device
abnormalities, connection failure, failed recovery, data loss, device damage,
or other serious consequences.

Read the usage guide first and make sure you understand each operation. Any
consequence caused by skipping instructions, using the wrong version, writing
wrong WiFi / IP configuration, misusing debug functions, or modifying
parameters is your own responsibility.

This project provides no warranty of any kind, including availability,
stability, compatibility, safety, merchantability, or fitness for a particular
purpose.

## License Notice

This project is not licensed under standard open-source licenses such as MIT,
Apache, or GPL. It is a source-visible non-commercial project.

Allowed:

- Personal download from this GitHub repository
- Personal non-commercial use
- Personal study, research, and local modification
- Personal compilation and execution on your own devices

Commercial or profit-oriented use is prohibited, including but not limited to:

- Commercial use
- Selling, renting, paid deployment, or paid maintenance
- Integrating this project into commercial products, commercial services, or
  paid bundles

The following actions require author permission first:

- Redistribution, reposting, mirroring, or republishing
- Secondary packaged releases
- Publishing modified or derivative versions based on this project

If you want to repost, distribute, or integrate this project, contact the author
first for permission.

## Repository

GitHub:

```text
https://github.com/zihaodream/Vive-Ultimate-Tracker-WiFi-only-
```
