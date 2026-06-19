#!/usr/bin/env python3
"""Hold UTK WiFi-only TCP connections open without ViveTrackerServer."""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import signal
import socket
import struct
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO


def parse_ports(value: str) -> list[int]:
    ports: list[int] = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        ports.append(int(item, 10))
    if not ports:
        raise argparse.ArgumentTypeError("at least one port is required")
    return ports


def parse_host_port(value: str) -> tuple[str, int] | None:
    value = value.strip()
    if not value:
        return None
    if ":" not in value:
        raise argparse.ArgumentTypeError("expected HOST:PORT")
    host, port_text = value.rsplit(":", 1)
    if not host:
        raise argparse.ArgumentTypeError("missing host")
    return host, int(port_text, 10)


def parse_peer_forward_map(value: str) -> dict[str, tuple[str, int]]:
    result: dict[str, tuple[str, int]] = {}
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise argparse.ArgumentTypeError("expected PEER_IP=HOST:PORT entries")
        peer_ip, target_text = item.split("=", 1)
        target = parse_host_port(target_text)
        if not peer_ip.strip() or target is None:
            raise argparse.ArgumentTypeError("expected PEER_IP=HOST:PORT entries")
        result[peer_ip.strip()] = target
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-Bind", "--bind", default="0.0.0.0", help="address to bind")
    parser.add_argument(
        "-Ports",
        "--ports",
        type=parse_ports,
        default=parse_ports("9005,3680,8053,15680"),
        help="comma-separated TCP listen ports",
    )
    parser.add_argument(
        "--udp-pose-port",
        type=int,
        default=0,
        help="optional UDP pose listen port; 0 disables",
    )
    parser.add_argument("-Out", "--out", type=Path, help="optional ndjson event log")
    parser.add_argument(
        "-PreviewBytes",
        "--preview-bytes",
        type=int,
        default=64,
        help="hex bytes to include per receive event",
    )
    parser.add_argument(
        "-IdlePingSeconds",
        "--idle-ping-seconds",
        type=float,
        default=0,
        help="send a single NUL byte after this many idle seconds; 0 disables writes",
    )
    parser.add_argument(
        "-AckPayloads",
        "--ack-payloads",
        default="",
        help="comma-separated ASCII payloads to send once after the first receive on port 9005",
    )
    parser.add_argument(
        "--ack-on-connect",
        action="store_true",
        help="send --ack-payloads immediately when TCP 9005 connects, before waiting for tracker data",
    )
    parser.add_argument(
        "-AckSlotSize",
        "--ack-slot-size",
        type=int,
        default=128,
        help="fixed slot size for ACK frames, using 01 <len> <payload> padding",
    )
    parser.add_argument(
        "-ConsoleRecvLimit",
        "--console-recv-limit",
        type=int,
        default=-1,
        help="max recv events to print to console; -1 prints all, file logging is unchanged",
    )
    parser.add_argument(
        "-FullPayloadHex",
        "--full-payload-hex",
        action="store_true",
        help="include full recv payload_hex in the ndjson log; console still uses preview_hex",
    )
    parser.add_argument(
        "--realtime",
        action="store_true",
        help="optimize for live use: suppress per-recv logging and avoid per-event file flush",
    )
    parser.add_argument(
        "--forward-burst-mode",
        choices=("all", "latest", "paced"),
        default="all",
        help="forward every decoded frame, only the latest frame, or pace batch frames by device time",
    )
    parser.add_argument(
        "--paced-max-delay-ms",
        type=float,
        default=30.0,
        help="max future delay for --forward-burst-mode paced",
    )
    parser.add_argument(
        "--paced-target-hz",
        type=float,
        default=60.0,
        help="target local UDP send rate for --forward-burst-mode paced; 0 uses device frame spacing",
    )
    parser.add_argument(
        "--paced-backlog-collapse-ms",
        type=float,
        default=8.0,
        help="if paced output is already this far behind schedule, drop queued old frames and send only the newest",
    )
    parser.add_argument(
        "--minimal-pose-json",
        action="store_true",
        help="forward only fields needed by the OpenVR bridge",
    )
    parser.add_argument(
        "--pose-forward-format",
        choices=("json", "binary"),
        default="json",
        help="UDP pose packet format; binary is the lowest-overhead OpenVR bridge path",
    )
    parser.add_argument(
        "--pose-forward-udp",
        type=parse_host_port,
        default=None,
        metavar="HOST:PORT",
        help="forward parsed 02 25 pose-like frames as JSON UDP packets",
    )
    parser.add_argument(
        "--pose-forward-peer-ip",
        default="",
        help="only forward pose frames from this tracker IP; empty forwards all peers",
    )
    parser.add_argument(
        "--pose-forward-map",
        type=parse_peer_forward_map,
        default={},
        metavar="PEER_IP=HOST:PORT,...",
        help="forward each tracker IP to a distinct UDP target; overrides --pose-forward-udp for listed peers",
    )
    parser.add_argument(
        "--pose-forward-auto-map",
        type=parse_host_port,
        default=None,
        metavar="HOST:STARTPORT",
        help="auto-assign each new tracker IP to HOST:STARTPORT, HOST:STARTPORT+1, ...",
    )
    parser.add_argument(
        "--pose-forward-include-zero",
        action="store_true",
        help="forward 02 25 frames even when x/y/z are all zero",
    )
    parser.add_argument(
        "--ready-payloads",
        default="",
        help="experimental comma-separated ASCII payloads to send once after valid 02 25 pose frames are observed",
    )
    parser.add_argument(
        "--ready-after-valid-frames",
        type=int,
        default=30,
        help="valid 02 25 frames required before sending --ready-payloads",
    )
    parser.add_argument(
        "--control-refresh-payloads",
        default="",
        help="experimental comma-separated ASCII payloads to repeat on TCP 9005 while connected",
    )
    parser.add_argument(
        "--control-refresh-seconds",
        type=float,
        default=0,
        help="seconds between --control-refresh-payloads sends; 0 disables",
    )
    parser.add_argument(
        "--control-refresh-start-delay-seconds",
        type=float,
        default=0,
        help="delay before the first control refresh send after TCP 9005 connect",
    )
    parser.add_argument(
        "--latency-stats-seconds",
        type=float,
        default=5.0,
        help="write low-rate latency_stats summaries; 0 disables",
    )
    return parser.parse_args()


class EventLog:
    def __init__(
        self,
        path: Path | None,
        console_recv_limit: int = -1,
        flush_each_write: bool = True,
    ) -> None:
        self._file: TextIO | None = None
        self._console_recv_limit = console_recv_limit
        self._console_recv_count = 0
        self._flush_each_write = flush_each_write
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
            self._file = path.open("a", encoding="utf-8")

    def write(self, event: dict[str, object]) -> None:
        event = {"time_ns": time.time_ns(), **event}
        line = json.dumps(event, separators=(",", ":"))
        should_print = True
        if event.get("event") == "recv" and self._console_recv_limit >= 0:
            self._console_recv_count += 1
            should_print = self._console_recv_count <= self._console_recv_limit
        if should_print:
            print(line, flush=True)
        if self._file:
            self._file.write(line + "\n")
            if self._flush_each_write:
                self._file.flush()

    def close(self) -> None:
        if self._file:
            self._file.flush()
            self._file.close()


def tune_socket(sock: socket.socket) -> None:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


def build_slot(payload: str, slot_size: int) -> bytes:
    raw = payload.encode("ascii")
    if len(raw) > 255:
        raise ValueError(f"ACK payload too long: {payload!r}")
    frame = b"\x01" + bytes([len(raw)]) + raw
    if len(frame) > slot_size:
        raise ValueError(f"ACK frame larger than slot: {payload!r}")
    return frame + (b"\x00" * (slot_size - len(frame)))


def iter_ascii_control_slots(data: bytes):
    cursor = 0
    while cursor + 2 <= len(data):
        if data[cursor] == 0x01:
            length = data[cursor + 1]
            end = cursor + 2 + length
            if 0 < length <= 0x7E and end <= len(data):
                raw = data[cursor + 2 : end]
                try:
                    text = raw.decode("ascii")
                except UnicodeDecodeError:
                    text = ""
                if text and all(0x20 <= ord(ch) <= 0x7E for ch in text):
                    yield text
                    cursor += 0x80 if cursor + 0x80 <= len(data) else end
                    continue
        cursor += 0x80 if cursor % 0x80 == 0 and cursor + 0x80 <= len(data) else 1


def control_command_family(command: str) -> str:
    upper = command.upper()
    if upper.startswith(("ATS", "ACF", "NAI")):
        return "settime"
    if upper.startswith(("APS", "APF", "ATM", "ATM1")):
        return "setpower"
    if upper.startswith(("ANI", "ATW", "FW", "PAS", "WC", "WH", "WS")):
        return "wifi_control"
    return "other"


class Scheme5ControlObserver:
    def __init__(self) -> None:
        self._peers: dict[str, dict[str, object]] = defaultdict(self._new_peer_state)

    @staticmethod
    def _new_peer_state() -> dict[str, object]:
        return {
            "tcp_connected": False,
            "tcp_connected_count": 0,
            "tcp_disconnect_count": 0,
            "tcp_recv_count": 0,
            "tcp_control_frames_total": 0,
            "tcp_control_commands": {},
            "tcp_control_families": {},
            "wifi_info_ready_or_not_required": False,
            "settime_sent_or_observed": False,
            "setpower_sent_or_observed": False,
            "starttracker_sent_or_observed": False,
            "udp_enabled": False,
            "udp_datagrams_total": 0,
            "udp30_packets_total": 0,
            "raw_0225_udp_packets_total": 0,
            "compact_udp25_packets_total": 0,
            "udp_heartbeat_packets_total": 0,
            "raw_0225_tcp_frames": 0,
            "raw_0225_udp_frames": 0,
            "official_udp30_frames": 0,
            "last_tcp_port": None,
            "last_packet_class": None,
            "last_control_command": None,
            "last_tcp_connect_ns": None,
            "last_tcp_recv_ns": None,
            "last_udp_pose_ns": None,
            "tcp_keepalive_gap_ms": None,
            "last_update_ns": None,
        }

    @staticmethod
    def _age_ms(state: dict[str, object], key: str, now_ns: int) -> float | None:
        value = state.get(key)
        if value is None:
            return None
        return round((now_ns - int(value)) / 1_000_000.0, 3)

    @staticmethod
    def _readiness_phase(
        state: dict[str, object],
        last_tcp_recv_age_ms: float | None,
        last_udp_pose_age_ms: float | None,
    ) -> tuple[str, str | None]:
        tcp_connected = bool(state["tcp_connected"])
        tcp_control_seen = int(state["tcp_control_frames_total"]) > 0
        settime_seen = bool(state["settime_sent_or_observed"])
        setpower_seen = bool(state["setpower_sent_or_observed"])
        wifi_seen = bool(state["wifi_info_ready_or_not_required"])
        udp_seen = bool(state["udp_enabled"])
        tcp_fresh = last_tcp_recv_age_ms is not None and last_tcp_recv_age_ms <= 2_000.0
        udp_fresh = last_udp_pose_age_ms is not None and last_udp_pose_age_ms <= 250.0

        if not tcp_connected:
            return "tcp_disconnected", "tcp_9005_not_connected"
        if not tcp_control_seen:
            return "tcp_connected_wait_control", "no_tcp_control_frames_observed"
        if not settime_seen:
            return "tcp_control_seen_wait_settime", "settime_not_observed"
        if not (setpower_seen or wifi_seen):
            return "tcp_control_seen_wait_udp_ready_edge", "setpower_or_wifi_control_not_observed"
        if udp_seen and udp_fresh:
            return "udp_pose_active", None
        if tcp_fresh and not udp_seen:
            return "tcp_alive_udp_absent", "no_udp_pose_datagrams_observed"
        if tcp_fresh and last_udp_pose_age_ms is not None and not udp_fresh:
            return "tcp_alive_udp_stale", "udp_pose_stale"
        if not tcp_fresh:
            return "tcp_control_stale", "tcp_recv_stale"
        return "tcp_control_ready_wait_udp", "udp_pose_not_fresh"

    def observe_tcp_connect(self, peer: str, port: int, now_ns: int) -> None:
        state = self._peers[peer]
        state["last_tcp_port"] = port
        state["last_update_ns"] = now_ns
        if port == 9005:
            state["tcp_connected"] = True
            state["tcp_connected_count"] = int(state["tcp_connected_count"]) + 1
            state["last_tcp_connect_ns"] = now_ns

    def observe_tcp_disconnect(self, peer: str, port: int, now_ns: int) -> None:
        state = self._peers[peer]
        state["last_update_ns"] = now_ns
        if port == 9005:
            state["tcp_connected"] = False
            state["tcp_disconnect_count"] = int(state["tcp_disconnect_count"]) + 1

    def observe_tcp_recv(self, peer: str, port: int, data: bytes, now_ns: int) -> None:
        state = self._peers[peer]
        state["last_tcp_port"] = port
        state["last_update_ns"] = now_ns
        if port != 9005:
            return
        last_tcp_recv_ns = state.get("last_tcp_recv_ns")
        if last_tcp_recv_ns is not None:
            state["tcp_keepalive_gap_ms"] = round((now_ns - int(last_tcp_recv_ns)) / 1_000_000.0, 3)
        state["last_tcp_recv_ns"] = now_ns
        state["tcp_recv_count"] = int(state["tcp_recv_count"]) + 1
        for command in iter_ascii_control_slots(data):
            self.observe_control_command(peer, command, "recv", now_ns)

    def observe_control_command(self, peer: str, command: str, direction: str, now_ns: int) -> None:
        state = self._peers[peer]
        family = control_command_family(command)
        commands = state["tcp_control_commands"]
        assert isinstance(commands, dict)
        families = state["tcp_control_families"]
        assert isinstance(families, dict)
        key = f"{direction}:{command}"
        commands[key] = int(commands.get(key, 0)) + 1
        family_key = f"{direction}:{family}"
        families[family_key] = int(families.get(family_key, 0)) + 1
        state["tcp_control_frames_total"] = int(state["tcp_control_frames_total"]) + 1
        state["last_control_command"] = command
        state["last_update_ns"] = now_ns
        if family == "settime":
            state["settime_sent_or_observed"] = True
        elif family == "setpower":
            state["setpower_sent_or_observed"] = True
        elif family == "wifi_control":
            state["wifi_info_ready_or_not_required"] = True
        if command.upper().startswith(("STARTTRACKER", "START_TRACKER")):
            state["starttracker_sent_or_observed"] = True

    def observe_pose_stats(
        self,
        peer: str,
        stats: dict[str, object],
        packet_class: str | None,
        now_ns: int,
    ) -> None:
        state = self._peers[peer]
        source_frames = stats.get("source_frames", {})
        if not isinstance(source_frames, dict):
            source_frames = {}
        state["raw_0225_tcp_frames"] = int(state["raw_0225_tcp_frames"]) + int(source_frames.get("raw_0225_tcp", 0))
        state["raw_0225_udp_frames"] = int(state["raw_0225_udp_frames"]) + int(source_frames.get("raw_0225_udp", 0))
        state["official_udp30_frames"] = int(state["official_udp30_frames"]) + int(source_frames.get("official_udp30", 0))
        if packet_class is not None:
            state["udp_datagrams_total"] = int(state["udp_datagrams_total"]) + 1
            state["last_packet_class"] = packet_class
            if packet_class == "official_udp30":
                state["udp30_packets_total"] = int(state["udp30_packets_total"]) + 1
            elif packet_class == "raw_0225":
                state["raw_0225_udp_packets_total"] = int(state["raw_0225_udp_packets_total"]) + 1
            elif packet_class == "compact_udp25":
                state["compact_udp25_packets_total"] = int(state["compact_udp25_packets_total"]) + 1
            elif packet_class == "udp_heartbeat_8":
                state["udp_heartbeat_packets_total"] = int(state["udp_heartbeat_packets_total"]) + 1
        if int(stats.get("frames", 0)) > 0 and packet_class is not None:
            state["udp_enabled"] = True
            state["last_udp_pose_ns"] = now_ns
        state["last_update_ns"] = now_ns

    def snapshots(self, now_ns: int) -> list[dict[str, object]]:
        events = []
        for peer in sorted(self._peers):
            state = self._peers[peer]
            last_update_age_ms = self._age_ms(state, "last_update_ns", now_ns)
            last_tcp_recv_age_ms = self._age_ms(state, "last_tcp_recv_ns", now_ns)
            last_udp_pose_age_ms = self._age_ms(state, "last_udp_pose_ns", now_ns)
            readiness_phase, readiness_blocker = self._readiness_phase(
                state,
                last_tcp_recv_age_ms,
                last_udp_pose_age_ms,
            )
            events.append(
                {
                    "event": "scheme5_control_state",
                    "peer": peer,
                    "properties_ready": False,
                    "hmd_ip_ready": False,
                    "readiness_phase": readiness_phase,
                    "readiness_blocker": readiness_blocker,
                    **state,
                    "last_update_age_ms": last_update_age_ms,
                    "last_tcp_recv_age_ms": last_tcp_recv_age_ms,
                    "last_udp_pose_age_ms": last_udp_pose_age_ms,
                }
            )
        return events


def iter_0225_frames_from_stream(buffer: bytearray, data: bytes):
    buffer.extend(data)
    while True:
        start = buffer.find(b"\x02\x25")
        if start < 0:
            # Keep one byte in case the next recv starts with 0x25.
            del buffer[:-1]
            return
        if start > 0:
            del buffer[:start]
        if len(buffer) < 128:
            return
        frame = bytes(buffer[:128])
        del buffer[:128]
        yield frame


def official_udp30_to_0225_frame(packet: bytes) -> bytes | None:
    """Convert the official 0x30 UDP wrapper into the existing inner pose frame."""
    if len(packet) != 0x80 or len(packet) <= 0x2A or packet[5] != 0x30:
        return None
    frame = bytearray(0x80)
    frame[0:2] = b"\x02\x25"
    frame[2] = packet[6]
    frame[3] = packet[7]
    frame[4:0x2A] = packet[8:0x2E]
    return bytes(frame)


def compact_udp25_to_0225_frame(packet: bytes) -> bytes | None:
    """Convert the 43-byte device-side UDP 0x25 compact pose into a 02 25 frame."""
    if len(packet) != 43 or packet[5] != 0x25:
        return None
    frame = bytearray(0x80)
    frame[0] = 0x02
    frame[1:39] = packet[5:43]
    return bytes(frame)


def classify_pose_packet(data: bytes) -> str:
    if len(data) >= 2 and data[0:2] == b"\x02\x25":
        return "raw_0225"
    if official_udp30_to_0225_frame(data) is not None:
        return "official_udp30"
    if compact_udp25_to_0225_frame(data) is not None:
        return "compact_udp25"
    if len(data) == 8 and data[4:6] == b"\x00\x02":
        return "udp_heartbeat_8"
    return "unknown"


def iter_pose_frames_from_datagram(data: bytes):
    converted = official_udp30_to_0225_frame(data)
    if converted is not None:
        yield converted, "official_udp30"
        return
    converted = compact_udp25_to_0225_frame(data)
    if converted is not None:
        yield converted, "compact_udp25"
        return
    cursor = 0
    while True:
        start = data.find(b"\x02\x25", cursor)
        if start < 0:
            return
        if start + 128 <= len(data):
            yield data[start : start + 128], "raw_0225_udp"
            cursor = start + 128
        else:
            return


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * pct)]


def half_float(frame: bytes, offset: int) -> float:
    return struct.unpack("<e", frame[offset : offset + 2])[0]


def quat_norm(q: tuple[float, float, float, float]) -> float:
    return sum(v * v for v in q) ** 0.5


def status_name_from_nibble(status_nibble: int) -> str:
    if status_nibble in (0x02, 0x04):
        return "valid_position"
    if status_nibble == 0x03:
        return "invalid_position"
    return "unknown"


def flags_label(flags: int) -> str:
    if flags == 0x80:
        return "normal_stream"
    if flags == 0x81:
        return "peripheral_status_bit0_invalid_observed"
    if flags == 0x30:
        return "checkpoint_internal_0x60"
    if flags == 0x31:
        return "checkpoint_internal_0x62"
    return "unknown"


def parse_pose_frame(
    frame: bytes,
    event_time_ns: int,
    peer: str,
    device_time_ticks: int,
    minimal_payload: bool,
) -> dict[str, object] | None:
    x, y, z = struct.unpack("<fff", frame[4:16])
    q = (
        half_float(frame, 16),
        half_float(frame, 18),
        half_float(frame, 20),
        half_float(frame, 22),
    )
    h24 = half_float(frame, 24)
    h26 = half_float(frame, 26)
    h28 = half_float(frame, 28)
    h30 = half_float(frame, 30)
    h32 = half_float(frame, 32)
    h34 = half_float(frame, 34)
    u36 = struct.unpack("<H", frame[36:38])[0]
    u38 = struct.unpack("<H", frame[38:40])[0]
    u38_lo = u38 & 0xFF
    status_nibble = u38_lo & 0x0F
    payload: dict[str, object] = {
        "time_ns": event_time_ns,
        "seq": frame[2],
        "x": x,
        "y": y,
        "z": z,
        "qx": q[0],
        "qy": q[1],
        "qz": q[2],
        "qw": q[3],
        "vx_raw": h24,
        "vy_raw": h26,
        "vz_raw": h28,
        "wx_raw": h30,
        "wy_raw": h32,
        "wz_raw": h34,
        "device_time": u36,
        "device_time_ticks": device_time_ticks,
        "pose_status": status_nibble,
    }
    if minimal_payload:
        return payload

    u38_hi = (u38 >> 8) & 0xFF
    flags = frame[3]
    flags_bit7 = (flags >> 7) & 1
    flags_bit6 = (flags >> 6) & 1
    flags_low6 = flags & 0x3F
    state_u40 = struct.unpack("<H", frame[40:42])[0]
    position_valid_by_tail38 = status_nibble in (0x02, 0x04)
    position_invalid_by_tail38 = status_nibble == 0x03
    payload.update(
        {
            "source": "utk_9005_0225",
            "peer": peer,
            "qnorm": quat_norm(q),
            "flags": flags,
            "peripheral_flag_raw": flags,
            "flags_label": flags_label(flags),
            "flags_bit7_peripheral_status": bool(flags_bit7),
            "flags_bit6_internal": bool(flags_bit6),
            "flags_low6": flags_low6,
            "flags_internal_value": flags_low6 * 2 if not flags_bit7 else None,
            "tail36_raw": u36,
            "tail38_raw": u38,
            "tail38_hi": u38_hi,
            "tail38_hi_raw": u38_hi,
            "tail38_lo": u38_lo,
            "tail38_status_byte": u38_lo,
            "tail38_status_hi_nibble": (u38_lo >> 4) & 0x0F,
            "pose_timestamp_index": u36,
            "position_valid_by_tail38": position_valid_by_tail38,
            "body_state_raw": state_u40,
            "status_nibble": status_nibble,
            "pose_status_raw": u38_lo,
            "status_name": status_name_from_nibble(status_nibble),
            "position_invalid_by_tail38": position_invalid_by_tail38,
            "u36": u36,
            "device_time_u16": u36,
            "u38": u38,
            "u38_hi": u38_hi,
            "u38_lo": u38_lo,
            "state_u40": state_u40,
            "h24": h24,
            "h26": h26,
            "h28": h28,
            "h30": h30,
            "h32": h32,
            "h34": h34,
            "u40": state_u40,
        }
    )
    return payload


@dataclass
class PeerTimeMapper:
    """Track a peer's wrapped 16-bit device time and estimate PC pose time."""

    reset_count: int = 0
    rejected_sample_count: int = 0
    pose_time_outlier_count: int = 0
    last_peer: str = ""
    last_u16: int | None = None
    unwrapped_ticks: int = 0
    last_anchor_ticks: int | None = None
    last_anchor_time_ns: int | None = None
    ns_per_tick: float = 10_000.0
    last_rejected_reason: str = ""

    def reset_for_peer(self, peer: str) -> None:
        if self.last_peer == peer:
            return
        if self.last_peer:
            self.reset_count += 1
        self.last_peer = peer
        self.last_u16 = None
        self.unwrapped_ticks = 0
        self.last_anchor_ticks = None
        self.last_anchor_time_ns = None
        self.ns_per_tick = 10_000.0
        self.last_rejected_reason = "peer_changed"

    def unwrap(self, value: int) -> int:
        value &= 0xFFFF
        if self.last_u16 is None:
            self.last_u16 = value
            self.unwrapped_ticks = value
            return self.unwrapped_ticks
        delta = (value - self.last_u16) & 0xFFFF
        if delta > 0x8000:
            delta -= 0x10000
        self.unwrapped_ticks += delta
        self.last_u16 = value
        return self.unwrapped_ticks

    def update_anchor(self, latest_ticks: int, recv_time_ns: int) -> None:
        self.last_rejected_reason = ""
        if self.last_anchor_ticks is not None and self.last_anchor_time_ns is not None:
            tick_delta = latest_ticks - self.last_anchor_ticks
            time_delta_ns = recv_time_ns - self.last_anchor_time_ns
            if time_delta_ns > 500_000_000:
                self.reset_count += 1
                self.last_anchor_ticks = latest_ticks
                self.last_anchor_time_ns = recv_time_ns
                self.last_rejected_reason = "long_gap_reset"
                return
            if tick_delta > 0 and 1_000_000 <= time_delta_ns <= 250_000_000:
                sample_ns_per_tick = time_delta_ns / tick_delta
                if 5_000.0 <= sample_ns_per_tick <= 20_000.0:
                    self.ns_per_tick = (self.ns_per_tick * 0.90) + (sample_ns_per_tick * 0.10)
                else:
                    self.rejected_sample_count += 1
                    self.last_rejected_reason = "bad_ns_per_tick"
            elif tick_delta <= 0 or time_delta_ns < 0:
                self.rejected_sample_count += 1
                self.last_rejected_reason = "non_monotonic_anchor"
        self.last_anchor_ticks = latest_ticks
        self.last_anchor_time_ns = recv_time_ns

    def estimate_pose_time_ns(self, ticks: int, latest_ticks: int, recv_time_ns: int) -> int:
        age_ticks = max(0, latest_ticks - ticks)
        estimated_ns = int(round(recv_time_ns - (age_ticks * self.ns_per_tick)))
        age_ns = recv_time_ns - estimated_ns
        if age_ns < -10_000_000 or age_ns > 120_000_000:
            self.pose_time_outlier_count += 1
            self.last_rejected_reason = "pose_age_outlier"
            clamped_age_ns = min(max(age_ns, 0), 120_000_000)
            return recv_time_ns - clamped_age_ns
        return estimated_ns

    def counters_snapshot(self) -> dict[str, object]:
        return {
            "time_mapper_reset_count": self.reset_count,
            "time_mapper_rejected_sample_count": self.rejected_sample_count,
            "pose_time_outlier_count": self.pose_time_outlier_count,
            "device_time_ns_per_tick": round(self.ns_per_tick, 3),
            "time_mapper_last_rejected_reason": self.last_rejected_reason or None,
        }


@dataclass
class PeerLatencyWindow:
    recv_count: int = 0
    frame_count: int = 0
    valid_frame_count: int = 0
    invalid_frame_count: int = 0
    udp_send_count: int = 0
    skipped_burst_count: int = 0
    paced_scheduled_count: int = 0
    paced_dropped_count: int = 0
    last_recv_time_ns: int | None = None
    last_udp_send_time_ns: int | None = None
    recv_intervals_ms: deque[float] = None  # type: ignore[assignment]
    udp_intervals_ms: deque[float] = None  # type: ignore[assignment]
    burst_sizes: deque[int] = None  # type: ignore[assignment]
    estimated_pose_ages_ms: deque[float] = None  # type: ignore[assignment]
    paced_delays_ms: deque[float] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        self.recv_intervals_ms = deque(maxlen=4096)
        self.udp_intervals_ms = deque(maxlen=4096)
        self.burst_sizes = deque(maxlen=4096)
        self.estimated_pose_ages_ms = deque(maxlen=4096)
        self.paced_delays_ms = deque(maxlen=4096)
        self.time_mapper_reset_count = 0
        self.time_mapper_rejected_sample_count = 0
        self.pose_time_outlier_count = 0
        self.last_time_mapper_reason: str | None = None
        self.device_time_ns_per_tick: float | None = None
        self.source_frame_counts: defaultdict[str, int] = defaultdict(int)
        self.pose_status_counts: defaultdict[str, int] = defaultdict(int)
        self.peripheral_flag_counts: defaultdict[str, int] = defaultdict(int)
        self.tail38_hi_counts: defaultdict[str, int] = defaultdict(int)

    def observe_recv(self, recv_time_ns: int, stats: dict[str, object]) -> None:
        self.recv_count += 1
        self.frame_count += int(stats.get("frames", 0))
        self.valid_frame_count += int(stats.get("valid_frames", 0))
        self.invalid_frame_count += int(stats.get("invalid_frames", 0))
        source_frames = stats.get("source_frames", {})
        if isinstance(source_frames, dict):
            for source, count in source_frames.items():
                if isinstance(source, str) and isinstance(count, int):
                    self.source_frame_counts[source] += count
        for key, counter in (
            ("pose_status_counts", self.pose_status_counts),
            ("peripheral_flag_counts", self.peripheral_flag_counts),
            ("tail38_hi_counts", self.tail38_hi_counts),
        ):
            values = stats.get(key, {})
            if isinstance(values, dict):
                for value, count in values.items():
                    if isinstance(value, str) and isinstance(count, int):
                        counter[value] += count
        self.burst_sizes.append(int(stats.get("frames", 0)))
        if self.last_recv_time_ns is not None:
            self.recv_intervals_ms.append((recv_time_ns - self.last_recv_time_ns) / 1_000_000.0)
        self.last_recv_time_ns = recv_time_ns

    def observe_udp_send(self, send_time_ns: int, estimated_pose_time_ns: int | None) -> None:
        self.udp_send_count += 1
        if self.last_udp_send_time_ns is not None:
            self.udp_intervals_ms.append((send_time_ns - self.last_udp_send_time_ns) / 1_000_000.0)
        self.last_udp_send_time_ns = send_time_ns
        if estimated_pose_time_ns is not None:
            self.estimated_pose_ages_ms.append((send_time_ns - estimated_pose_time_ns) / 1_000_000.0)

    def observe_skipped_burst(self, count: int) -> None:
        self.skipped_burst_count += count

    def observe_paced(self, scheduled: int, dropped: int, delays_ms: list[float]) -> None:
        self.paced_scheduled_count += scheduled
        self.paced_dropped_count += dropped
        self.paced_delays_ms.extend(delays_ms)

    def observe_time_mapper(self, mapper: PeerTimeMapper) -> None:
        self.time_mapper_reset_count = mapper.reset_count
        self.time_mapper_rejected_sample_count = mapper.rejected_sample_count
        self.pose_time_outlier_count = mapper.pose_time_outlier_count
        self.last_time_mapper_reason = mapper.last_rejected_reason or self.last_time_mapper_reason
        self.device_time_ns_per_tick = mapper.ns_per_tick

    def reset_window(self) -> None:
        self.recv_count = 0
        self.frame_count = 0
        self.valid_frame_count = 0
        self.invalid_frame_count = 0
        self.udp_send_count = 0
        self.skipped_burst_count = 0
        self.paced_scheduled_count = 0
        self.paced_dropped_count = 0
        self.recv_intervals_ms.clear()
        self.udp_intervals_ms.clear()
        self.burst_sizes.clear()
        self.estimated_pose_ages_ms.clear()
        self.paced_delays_ms.clear()
        self.source_frame_counts.clear()
        self.pose_status_counts.clear()
        self.peripheral_flag_counts.clear()
        self.tail38_hi_counts.clear()

    def snapshot(self, peer: str, now_ns: int, window_seconds: float) -> dict[str, object]:
        recv_intervals = list(self.recv_intervals_ms)
        udp_intervals = list(self.udp_intervals_ms)
        bursts = list(self.burst_sizes)
        pose_ages = list(self.estimated_pose_ages_ms)
        paced_delays = list(self.paced_delays_ms)
        return {
            "event": "latency_stats",
            "peer": peer,
            "window_seconds": round(window_seconds, 3),
            "recv_count": self.recv_count,
            "frame_count": self.frame_count,
            "valid_frame_count": self.valid_frame_count,
            "invalid_frame_count": self.invalid_frame_count,
            "raw_0225_tcp_frames": self.source_frame_counts.get("raw_0225_tcp", 0),
            "raw_0225_udp_frames": self.source_frame_counts.get("raw_0225_udp", 0),
            "official_udp30_frames": self.source_frame_counts.get("official_udp30", 0),
            "compact_udp25_frames": self.source_frame_counts.get("compact_udp25", 0),
            "source_frame_counts": dict(sorted(self.source_frame_counts.items())),
            "pose_status_counts": dict(sorted(self.pose_status_counts.items())),
            "peripheral_flag_counts": dict(sorted(self.peripheral_flag_counts.items())),
            "tail38_hi_counts": dict(sorted(self.tail38_hi_counts.items())),
            "udp_send_count": self.udp_send_count,
            "skipped_burst_count": self.skipped_burst_count,
            "paced_scheduled_count": self.paced_scheduled_count,
            "paced_dropped_count": self.paced_dropped_count,
            "time_mapper_reset_count": self.time_mapper_reset_count,
            "time_mapper_rejected_sample_count": self.time_mapper_rejected_sample_count,
            "pose_time_outlier_count": self.pose_time_outlier_count,
            "time_mapper_last_rejected_reason": self.last_time_mapper_reason,
            "device_time_ns_per_tick": round(self.device_time_ns_per_tick, 3)
            if self.device_time_ns_per_tick is not None
            else None,
            "recv_interval_ms_p50": round(percentile(recv_intervals, 0.50), 3) if recv_intervals else None,
            "recv_interval_ms_p90": round(percentile(recv_intervals, 0.90), 3) if recv_intervals else None,
            "recv_interval_ms_p99": round(percentile(recv_intervals, 0.99), 3) if recv_intervals else None,
            "udp_interval_ms_p50": round(percentile(udp_intervals, 0.50), 3) if udp_intervals else None,
            "udp_interval_ms_p90": round(percentile(udp_intervals, 0.90), 3) if udp_intervals else None,
            "udp_interval_ms_p99": round(percentile(udp_intervals, 0.99), 3) if udp_intervals else None,
            "frames_per_recv_p50": round(percentile([float(value) for value in bursts], 0.50), 3) if bursts else None,
            "frames_per_recv_p90": round(percentile([float(value) for value in bursts], 0.90), 3) if bursts else None,
            "frames_per_recv_max": max(bursts) if bursts else None,
            "pose_age_ms_p50": round(percentile(pose_ages, 0.50), 3) if pose_ages else None,
            "pose_age_ms_p90": round(percentile(pose_ages, 0.90), 3) if pose_ages else None,
            "pose_age_ms_p99": round(percentile(pose_ages, 0.99), 3) if pose_ages else None,
            "paced_delay_ms_p50": round(percentile(paced_delays, 0.50), 3) if paced_delays else None,
            "paced_delay_ms_p90": round(percentile(paced_delays, 0.90), 3) if paced_delays else None,
            "paced_delay_ms_p99": round(percentile(paced_delays, 0.99), 3) if paced_delays else None,
            "last_recv_age_ms": (
                round((now_ns - self.last_recv_time_ns) / 1_000_000.0, 3)
                if self.last_recv_time_ns is not None
                else None
            ),
        }


class PoseForwarder:
    def __init__(
        self,
        target: tuple[str, int] | None,
        include_zero: bool,
        peer_ip: str = "",
        peer_targets: dict[str, tuple[str, int]] | None = None,
        auto_map_start: tuple[str, int] | None = None,
        burst_mode: str = "all",
        minimal_payload: bool = False,
        paced_max_delay_ms: float = 30.0,
        paced_target_hz: float = 60.0,
        paced_backlog_collapse_ms: float = 8.0,
        forward_format: str = "json",
    ) -> None:
        self._target = target
        self._include_zero = include_zero
        self._peer_ip = peer_ip.strip()
        self._peer_targets = peer_targets or {}
        self._auto_map_start = auto_map_start
        self._auto_assignments: dict[str, tuple[str, int]] = {}
        self._auto_next_port = auto_map_start[1] if auto_map_start else 0
        self._burst_mode = burst_mode
        self._minimal_payload = minimal_payload
        self._forward_format = forward_format
        self._paced_max_delay_ms = max(0.0, paced_max_delay_ms)
        self._paced_target_hz = max(0.0, paced_target_hz)
        self._paced_backlog_collapse_ms = max(0.0, paced_backlog_collapse_ms)
        self._paced_next_send_ns: dict[str, int] = {}
        self._sock: socket.socket | None = None
        self._time_mappers: dict[str, PeerTimeMapper] = {}
        self._latency_windows: dict[str, PeerLatencyWindow] = defaultdict(PeerLatencyWindow)
        self.forwarded = 0
        self.skipped_zero = 0
        self.skipped_burst = 0
        if target or self._peer_targets or auto_map_start:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    @property
    def enabled(self) -> bool:
        return self._sock is not None and (
            self._target is not None or bool(self._peer_targets) or self._auto_map_start is not None
        )

    def target_for_peer(self, peer: str) -> tuple[str, int] | None:
        peer_ip = peer.split(":", 1)[0]
        explicit_target = self._peer_targets.get(peer_ip)
        if explicit_target:
            return explicit_target
        if self._auto_map_start:
            assigned = self._auto_assignments.get(peer_ip)
            if assigned:
                return assigned
            target = (self._auto_map_start[0], self._auto_next_port)
            self._auto_next_port += 1
            self._auto_assignments[peer_ip] = target
            return target
        return self._target

    @staticmethod
    def parse_frame_stats(frame: bytes) -> dict[str, int]:
        u38 = struct.unpack("<H", frame[38:40])[0]
        status_nibble = (u38 & 0xFF) & 0x0F
        peripheral_flag = frame[3]
        tail38_hi = (u38 >> 8) & 0xFF
        return {
            "valid_frames": 1 if status_nibble in (0x02, 0x04) else 0,
            "invalid_frames": 1 if status_nibble == 0x03 else 0,
            "pose_status": status_nibble,
            "peripheral_flag": peripheral_flag,
            "tail38_hi": tail38_hi,
        }

    def forward_frames(
        self,
        event_time_ns: int,
        peer: str,
        frames: list[tuple[bytes, str]],
    ) -> dict[str, object]:
        stats: dict[str, object] = {
            "frames": 0,
            "valid_frames": 0,
            "invalid_frames": 0,
            "source_frames": {},
            "pose_status_counts": {},
            "peripheral_flag_counts": {},
            "tail38_hi_counts": {},
        }
        peer_ip = peer.split(":", 1)[0]
        if self._peer_ip and peer_ip != self._peer_ip:
            return stats
        if self._peer_targets and peer_ip not in self._peer_targets and not self._auto_map_start:
            return stats
        pending_payloads: list[tuple[dict[str, object], tuple[str, int], int]] = []
        latest_frame: bytes | None = None
        latest_source = ""
        latest_target: tuple[str, int] | None = None
        latest_ticks: int | None = None
        latest_skipped = 0
        time_mapper = self._time_mappers.setdefault(peer_ip, PeerTimeMapper())
        time_mapper.reset_for_peer(peer)

        for frame, source in frames:
            stats["frames"] = int(stats["frames"]) + 1
            source_frames = stats["source_frames"]
            assert isinstance(source_frames, dict)
            source_frames[source] = int(source_frames.get(source, 0)) + 1
            frame_stats = self.parse_frame_stats(frame)
            stats["valid_frames"] = int(stats["valid_frames"]) + frame_stats["valid_frames"]
            stats["invalid_frames"] = int(stats["invalid_frames"]) + frame_stats["invalid_frames"]
            for stats_key, value_key in (
                ("pose_status_counts", "pose_status"),
                ("peripheral_flag_counts", "peripheral_flag"),
                ("tail38_hi_counts", "tail38_hi"),
            ):
                counts = stats[stats_key]
                assert isinstance(counts, dict)
                value = int(frame_stats[value_key])
                label = f"0x{value:02x}"
                counts[label] = int(counts.get(label, 0)) + 1
            x, y, z = struct.unpack("<fff", frame[4:16])
            if not self._include_zero and x == 0.0 and y == 0.0 and z == 0.0:
                self.skipped_zero += 1
                continue
            u36 = struct.unpack("<H", frame[36:38])[0]
            device_time_ticks = time_mapper.unwrap(u36)
            if not self.enabled:
                continue
            target = self.target_for_peer(peer)
            assert self._sock is not None
            if target is None:
                continue
            if self._burst_mode == "latest":
                if latest_frame is not None:
                    latest_skipped += 1
                latest_frame = frame
                latest_source = source
                latest_target = target
                latest_ticks = device_time_ticks
            else:
                payload = parse_pose_frame(
                    frame,
                    event_time_ns,
                    peer,
                    device_time_ticks,
                    self._minimal_payload,
                )
                if payload is not None:
                    payload["transport_source"] = source
                    pending_payloads.append((payload, target, device_time_ticks))

        if self._burst_mode == "latest" and latest_frame is not None and latest_target is not None and latest_ticks is not None:
            payload = parse_pose_frame(
                latest_frame,
                event_time_ns,
                peer,
                latest_ticks,
                self._minimal_payload,
            )
            if payload is not None:
                payload["transport_source"] = latest_source
                pending_payloads.append((payload, latest_target, latest_ticks))

        if pending_payloads:
            latest_ticks = pending_payloads[-1][2]
            time_mapper.update_anchor(latest_ticks, event_time_ns)
            for payload, _, ticks in pending_payloads:
                payload["pc_estimated_pose_time_ns"] = time_mapper.estimate_pose_time_ns(
                    ticks, latest_ticks, event_time_ns
                )
                payload["device_time_ns_per_tick"] = round(time_mapper.ns_per_tick, 3)
            self._latency_windows[peer].observe_time_mapper(time_mapper)
            if self._burst_mode == "latest":
                skipped = latest_skipped
                self.skipped_burst += skipped
                if skipped:
                    self._latency_windows[peer].observe_skipped_burst(skipped)
                latest_payload, latest_target, _ = pending_payloads[-1]
                self.send_pose_payload(latest_payload, latest_target, peer)
            elif self._burst_mode == "paced":
                self.schedule_paced_payloads(peer, pending_payloads, time_mapper, event_time_ns)
            else:
                for payload, payload_target, _ in pending_payloads:
                    self.send_pose_payload(payload, payload_target, peer)
        return stats

    def close(self) -> None:
        if self._sock:
            self._sock.close()

    @staticmethod
    def build_binary_pose_payload(payload: dict[str, object]) -> bytes:
        return struct.pack(
            "<4sBBHHQQq13f",
            b"UTKP",
            1,
            int(payload.get("seq", 0)) & 0xFF,
            int(payload.get("pose_status", 0)) & 0xFFFF,
            int(payload.get("device_time", 0)) & 0xFFFF,
            int(payload.get("time_ns", 0)) & 0xFFFFFFFFFFFFFFFF,
            int(payload.get("pc_estimated_pose_time_ns", 0)) & 0xFFFFFFFFFFFFFFFF,
            int(payload.get("device_time_ticks", 0)),
            float(payload.get("x", 0.0)),
            float(payload.get("y", 0.0)),
            float(payload.get("z", 0.0)),
            float(payload.get("qx", 0.0)),
            float(payload.get("qy", 0.0)),
            float(payload.get("qz", 0.0)),
            float(payload.get("qw", 1.0)),
            float(payload.get("vx_raw", 0.0)),
            float(payload.get("vy_raw", 0.0)),
            float(payload.get("vz_raw", 0.0)),
            float(payload.get("wx_raw", 0.0)),
            float(payload.get("wy_raw", 0.0)),
            float(payload.get("wz_raw", 0.0)),
        )

    def send_pose_payload(self, payload: dict[str, object], target: tuple[str, int], peer: str) -> None:
        assert self._sock is not None
        if self._forward_format == "binary":
            packet = self.build_binary_pose_payload(payload)
        else:
            packet = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self._sock.sendto(packet, target)
        self.forwarded += 1
        if peer:
            self._latency_windows[peer].observe_udp_send(
                time.monotonic_ns(),
                int(payload["pc_estimated_pose_time_ns"]) if "pc_estimated_pose_time_ns" in payload else None,
            )

    def schedule_pose_payload(self, payload: dict[str, object], target: tuple[str, int], peer: str, delay_ms: float) -> None:
        if delay_ms <= 0:
            self.send_pose_payload(payload, target, peer)
            return
        loop = asyncio.get_running_loop()
        loop.call_later(delay_ms / 1000.0, self.send_pose_payload, payload, target, peer)

    def schedule_paced_payloads(
        self,
        peer: str,
        payloads: list[tuple[dict[str, object], tuple[str, int], int]],
        time_mapper: PeerTimeMapper,
        recv_time_ns: int,
    ) -> None:
        if not payloads:
            return

        target_interval_ns = 0
        if self._paced_target_hz > 0:
            target_interval_ns = int(round(1_000_000_000.0 / self._paced_target_hz))

        observed_interval_ns = 0
        if len(payloads) >= 2:
            tick_spans = [
                payloads[index][2] - payloads[index - 1][2]
                for index in range(1, len(payloads))
                if payloads[index][2] > payloads[index - 1][2]
            ]
            if tick_spans:
                observed_interval_ns = int(round(percentile([float(v) for v in tick_spans], 0.50) * time_mapper.ns_per_tick))

        interval_ns = max(target_interval_ns, observed_interval_ns, 1)
        max_delay_ns = int(round(self._paced_max_delay_ms * 1_000_000.0))
        keep_count = len(payloads)
        if max_delay_ns > 0:
            keep_count = min(keep_count, max(1, int(max_delay_ns // interval_ns) + 1))
        kept_payloads = payloads[-keep_count:]
        dropped = len(payloads) - len(kept_payloads)

        next_send_ns = self._paced_next_send_ns.get(peer, recv_time_ns)
        if next_send_ns < recv_time_ns:
            next_send_ns = recv_time_ns
        backlog_ns = max(0, next_send_ns - recv_time_ns)
        collapse_ns = int(round(self._paced_backlog_collapse_ms * 1_000_000.0))
        if collapse_ns > 0 and backlog_ns > collapse_ns:
            dropped += len(kept_payloads) - 1
            kept_payloads = kept_payloads[-1:]
            next_send_ns = recv_time_ns
        if max_delay_ns > 0 and next_send_ns - recv_time_ns > max_delay_ns:
            dropped += len(kept_payloads) - 1
            kept_payloads = kept_payloads[-1:]
            next_send_ns = recv_time_ns

        delays_ms: list[float] = []
        for payload, target, _ in kept_payloads:
            delay_ns = max(0, next_send_ns - recv_time_ns)
            if max_delay_ns > 0 and delay_ns > max_delay_ns:
                dropped += 1
                continue
            delay_ms = delay_ns / 1_000_000.0
            payload["paced_delay_ms"] = round(delay_ms, 3)
            payload["paced_target_hz"] = round(self._paced_target_hz, 3) if self._paced_target_hz > 0 else 0
            delays_ms.append(delay_ms)
            self.schedule_pose_payload(payload, target, peer, delay_ms)
            next_send_ns += interval_ns

        self._paced_next_send_ns[peer] = next_send_ns
        self._latency_windows[peer].observe_paced(len(delays_ms), dropped, delays_ms)

    def observe_recv_stats(self, peer: str, recv_time_ns: int, stats: dict[str, object]) -> None:
        if (
            int(stats.get("frames", 0)) <= 0
            and int(stats.get("valid_frames", 0)) <= 0
            and int(stats.get("invalid_frames", 0)) <= 0
        ):
            return
        self._latency_windows[peer].observe_recv(recv_time_ns, stats)

    def latency_snapshots(self, now_ns: int, window_seconds: float) -> list[dict[str, object]]:
        snapshots = []
        for peer in sorted(self._latency_windows):
            window = self._latency_windows[peer]
            snapshots.append(window.snapshot(peer, now_ns, window_seconds))
            window.reset_window()
        return snapshots

    def forward_recv(self, event_time_ns: int, peer: str, data: bytes, stream_buffer: bytearray) -> dict[str, object]:
        frames = [(frame, "raw_0225_tcp") for frame in iter_0225_frames_from_stream(stream_buffer, data)]
        return self.forward_frames(event_time_ns, peer, frames)

    def forward_datagram(self, event_time_ns: int, peer: str, data: bytes) -> dict[str, object]:
        return self.forward_frames(event_time_ns, peer, list(iter_pose_frames_from_datagram(data)))


async def idle_writer(
    writer: asyncio.StreamWriter,
    seconds: float,
    log: EventLog,
    peer: str,
    port: int,
) -> None:
    if seconds <= 0:
        return
    while True:
        await asyncio.sleep(seconds)
        writer.write(b"\x00")
        await writer.drain()
        log.write({"event": "idle_ping", "peer": peer, "port": port, "bytes": 1})


async def control_refresh_writer(
    writer: asyncio.StreamWriter,
    seconds: float,
    start_delay_seconds: float,
    payloads: list[str],
    slot_size: int,
    log: EventLog,
    control_observer: Scheme5ControlObserver,
    peer: str,
    port: int,
    preview_bytes: int,
) -> None:
    if port != 9005 or seconds <= 0 or not payloads:
        return
    if start_delay_seconds > 0:
        await asyncio.sleep(start_delay_seconds)
    while True:
        for payload in payloads:
            frame = build_slot(payload, slot_size)
            writer.write(frame)
            await writer.drain()
            control_observer.observe_control_command(peer, payload, "send_control_refresh", time.monotonic_ns())
            log.write(
                {
                    "event": "send_control_refresh",
                    "peer": peer,
                    "port": port,
                    "payload": payload,
                    "bytes": len(frame),
                    "preview_hex": frame[:preview_bytes].hex(" "),
                }
            )
        await asyncio.sleep(seconds)


async def latency_stats_writer(
    log: EventLog,
    pose_forwarder: PoseForwarder,
    control_observer: Scheme5ControlObserver,
    interval_seconds: float,
) -> None:
    if interval_seconds <= 0:
        return
    while True:
        await asyncio.sleep(interval_seconds)
        now_ns = time.monotonic_ns()
        for snapshot in pose_forwarder.latency_snapshots(now_ns, interval_seconds):
            log.write(snapshot)
        for snapshot in control_observer.snapshots(now_ns):
            log.write(snapshot)


class PoseUdpProtocol(asyncio.DatagramProtocol):
    def __init__(
        self,
        log: EventLog,
        pose_forwarder: PoseForwarder,
        control_observer: Scheme5ControlObserver,
        preview_bytes: int,
        log_recv_events: bool,
    ) -> None:
        self._log = log
        self._pose_forwarder = pose_forwarder
        self._control_observer = control_observer
        self._preview_bytes = preview_bytes
        self._log_recv_events = log_recv_events

    def datagram_received(self, data: bytes, addr) -> None:  # type: ignore[no-untyped-def]
        peer = f"{addr[0]}:{addr[1]}"
        recv_time_ns = time.monotonic_ns()
        packet_class = classify_pose_packet(data)
        if self._log_recv_events:
            self._log.write(
                {
                    "event": "udp_recv",
                    "peer": peer,
                    "bytes": len(data),
                    "packet_class": packet_class,
                    "preview_hex": data[: self._preview_bytes].hex(" "),
                }
            )
        pose_stats = self._pose_forwarder.forward_datagram(recv_time_ns, peer, data)
        self._pose_forwarder.observe_recv_stats(peer, recv_time_ns, pose_stats)
        self._control_observer.observe_pose_stats(peer, pose_stats, packet_class, recv_time_ns)


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    log: EventLog,
    preview_bytes: int,
    full_payload_hex: bool,
    idle_ping_seconds: float,
    ack_payloads: list[str],
    ack_on_connect: bool,
    ack_slot_size: int,
    ready_payloads: list[str],
    ready_after_valid_frames: int,
    control_refresh_payloads: list[str],
    control_refresh_seconds: float,
    control_refresh_start_delay_seconds: float,
    pose_forwarder: PoseForwarder,
    control_observer: Scheme5ControlObserver,
    log_recv_events: bool,
) -> None:
    sock = writer.get_extra_info("socket")
    local = writer.get_extra_info("sockname")
    remote = writer.get_extra_info("peername")
    port = int(local[1])
    peer = f"{remote[0]}:{remote[1]}"

    if sock:
        tune_socket(sock)

    connect_time_ns = time.monotonic_ns()
    control_observer.observe_tcp_connect(peer, port, connect_time_ns)
    log.write({"event": "connect", "peer": peer, "port": port})
    pinger = asyncio.create_task(idle_writer(writer, idle_ping_seconds, log, peer, port))
    refresher = asyncio.create_task(
        control_refresh_writer(
            writer,
            control_refresh_seconds,
            control_refresh_start_delay_seconds,
            control_refresh_payloads,
            ack_slot_size,
            log,
            control_observer,
            peer,
            port,
            preview_bytes,
        )
    )
    total = 0
    ack_sent = False
    ready_sent = False
    valid_pose_frames = 0
    pose_stream_buffer = bytearray()

    try:
        if port == 9005 and ack_payloads and ack_on_connect:
            for payload in ack_payloads:
                frame = build_slot(payload, ack_slot_size)
                writer.write(frame)
                await writer.drain()
                control_observer.observe_control_command(peer, payload, "send_ack_connect", time.monotonic_ns())
                log.write(
                    {
                        "event": "send_ack_connect",
                        "peer": peer,
                        "port": port,
                        "payload": payload,
                        "bytes": len(frame),
                        "preview_hex": frame[:preview_bytes].hex(" "),
                    }
                )
            ack_sent = True
        while True:
            data = await reader.read(4096)
            if not data:
                break
            total += len(data)
            event: dict[str, object] = {
                "event": "recv",
                "peer": peer,
                "port": port,
                "bytes": len(data),
                "total_bytes": total,
                "preview_hex": data[:preview_bytes].hex(" "),
            }
            if full_payload_hex:
                event["payload_hex"] = data.hex(" ")
            if log_recv_events:
                log.write(event)
            recv_time_ns = time.monotonic_ns()
            control_observer.observe_tcp_recv(peer, port, data, recv_time_ns)
            if port == 9005:
                pose_stats = pose_forwarder.forward_recv(recv_time_ns, peer, data, pose_stream_buffer)
                pose_forwarder.observe_recv_stats(peer, recv_time_ns, pose_stats)
                control_observer.observe_pose_stats(peer, pose_stats, None, recv_time_ns)
                valid_pose_frames += int(pose_stats["valid_frames"])
                if (
                    ready_payloads
                    and not ready_sent
                    and valid_pose_frames >= ready_after_valid_frames
                ):
                    for payload in ready_payloads:
                        frame = build_slot(payload, ack_slot_size)
                        writer.write(frame)
                        await writer.drain()
                        control_observer.observe_control_command(peer, payload, "send_ready", time.monotonic_ns())
                        log.write(
                            {
                                "event": "send_ready_payload",
                                "peer": peer,
                                "port": port,
                                "payload": payload,
                                "valid_pose_frames": valid_pose_frames,
                                "bytes": len(frame),
                                "preview_hex": frame[:preview_bytes].hex(" "),
                            }
                        )
                    ready_sent = True
            if port == 9005 and ack_payloads and not ack_sent:
                for payload in ack_payloads:
                    frame = build_slot(payload, ack_slot_size)
                    writer.write(frame)
                    await writer.drain()
                    control_observer.observe_control_command(peer, payload, "send_ack", time.monotonic_ns())
                    log.write(
                        {
                            "event": "send_ack",
                            "peer": peer,
                            "port": port,
                            "payload": payload,
                            "bytes": len(frame),
                            "preview_hex": frame[:preview_bytes].hex(" "),
                        }
                    )
                ack_sent = True
    except ConnectionResetError:
        log.write({"event": "reset", "peer": peer, "port": port, "total_bytes": total})
    finally:
        control_observer.observe_tcp_disconnect(peer, port, time.monotonic_ns())
        pinger.cancel()
        refresher.cancel()
        writer.close()
        await writer.wait_closed()
        log.write({"event": "disconnect", "peer": peer, "port": port, "total_bytes": total})


async def main_async() -> int:
    args = parse_args()
    log = EventLog(args.out, args.console_recv_limit, flush_each_write=not args.realtime)
    control_observer = Scheme5ControlObserver()
    pose_forwarder = PoseForwarder(
        args.pose_forward_udp,
        args.pose_forward_include_zero,
        args.pose_forward_peer_ip,
        args.pose_forward_map,
        args.pose_forward_auto_map,
        args.forward_burst_mode,
        args.minimal_pose_json,
        args.paced_max_delay_ms,
        args.paced_target_hz,
        args.paced_backlog_collapse_ms,
        args.pose_forward_format,
    )
    stop = asyncio.Event()
    latency_task = asyncio.create_task(
        latency_stats_writer(log, pose_forwarder, control_observer, args.latency_stats_seconds)
    )

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    servers: list[asyncio.Server] = []
    udp_transport: asyncio.DatagramTransport | None = None
    try:
        ack_payloads = [item.strip() for item in args.ack_payloads.split(",") if item.strip()]
        ready_payloads = [item.strip() for item in args.ready_payloads.split(",") if item.strip()]
        control_refresh_payloads = [
            item.strip() for item in args.control_refresh_payloads.split(",") if item.strip()
        ]
        if pose_forwarder.enabled:
            target_text = ""
            if args.pose_forward_udp:
                target_text = f"{args.pose_forward_udp[0]}:{args.pose_forward_udp[1]}"
            log.write(
                {
                    "event": "pose_forward_start",
                    "target": target_text,
                    "include_zero": args.pose_forward_include_zero,
                    "peer_ip": args.pose_forward_peer_ip,
                    "peer_map": {key: f"{value[0]}:{value[1]}" for key, value in args.pose_forward_map.items()},
                    "auto_map_start": (
                        f"{args.pose_forward_auto_map[0]}:{args.pose_forward_auto_map[1]}"
                        if args.pose_forward_auto_map
                        else ""
                    ),
                    "realtime": args.realtime,
                    "forward_burst_mode": args.forward_burst_mode,
                    "minimal_pose_json": args.minimal_pose_json,
                    "pose_forward_format": args.pose_forward_format,
                    "paced_max_delay_ms": args.paced_max_delay_ms,
                    "paced_target_hz": args.paced_target_hz,
                    "paced_backlog_collapse_ms": args.paced_backlog_collapse_ms,
                    "latency_stats_seconds": args.latency_stats_seconds,
                    "udp_pose_port": args.udp_pose_port,
                }
            )
        if args.udp_pose_port > 0:
            loop = asyncio.get_running_loop()
            udp_transport, _ = await loop.create_datagram_endpoint(
                lambda: PoseUdpProtocol(
                    log,
                    pose_forwarder,
                    control_observer,
                    args.preview_bytes,
                    not args.realtime,
                ),
                local_addr=(args.bind, args.udp_pose_port),
                family=socket.AF_INET,
            )
            log.write({"event": "udp_listen", "bind": args.bind, "port": args.udp_pose_port})
        for port in args.ports:
            server = await asyncio.start_server(
                lambda r, w: handle_client(
                    r,
                    w,
                    log,
                    args.preview_bytes,
                    args.full_payload_hex,
                    args.idle_ping_seconds,
                    ack_payloads,
                    args.ack_on_connect,
                    args.ack_slot_size,
                        ready_payloads,
                        args.ready_after_valid_frames,
                        control_refresh_payloads,
                        args.control_refresh_seconds,
                        args.control_refresh_start_delay_seconds,
                        pose_forwarder,
                        control_observer,
                        not args.realtime,
                    ),
                args.bind,
                port,
            )
            servers.append(server)
            log.write({"event": "listen", "bind": args.bind, "port": port})

        await stop.wait()
    finally:
        if udp_transport is not None:
            udp_transport.close()
        for server in servers:
            server.close()
            await server.wait_closed()
        if pose_forwarder.enabled:
            log.write(
                {
                    "event": "pose_forward_stop",
                    "forwarded": pose_forwarder.forwarded,
                    "skipped_zero": pose_forwarder.skipped_zero,
                    "skipped_burst": pose_forwarder.skipped_burst,
                }
            )
        latency_task.cancel()
        try:
            await latency_task
        except asyncio.CancelledError:
            pass
        pose_forwarder.close()
        log.close()
    return 0


def main() -> int:
    try:
        return asyncio.run(main_async())
    except OSError as exc:
        print(f"listen failed: {exc}", flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
