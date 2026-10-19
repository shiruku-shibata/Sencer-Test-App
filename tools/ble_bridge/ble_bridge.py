#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""センサーテストアプリ用 BLE ブリッジ。

M5 デバイス（Nordic UART Service で CSV 行を送るファームウェア）と BLE で通信し、
受け取った行をローカル UDP でアプリ（Godot）へ中継する常駐プロセス。

    M5デバイス --BLE(NUS)--> このブリッジ --UDP(127.0.0.1)--> アプリ

- アプリ → ブリッジ: 127.0.0.1:47811（--port）へ JSON 1個 = UDP 1データグラム
- ブリッジ → アプリ: 直近にコマンドを送ってきたアドレス（既定 127.0.0.1:47810, --app-port）
- プロトコルの詳細は README.md を参照。

依存は bleak（MIT）だけで、使うときに遅延 import する。
--mock を付けると bleak も実機も無しで、疑似デバイス2台が動く。

Python 3.9 以上で動くように書いている（macOS 標準の /usr/bin/python3 が 3.9 のため）。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import random
import socket
import sys
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

VERSION = "1.0.0"
PROTOCOL_VERSION = 1

HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 47811   # ブリッジが待ち受けるポート
DEFAULT_APP_PORT = 47810      # アプリが待ち受けるポート

# Nordic UART Service（firmware と共通の契約。docs/DESIGN_P2.md 5.6）
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"   # PC → デバイス（Write）
NUS_TX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"   # デバイス → PC（Notify）
NAME_PREFIX = "M5-Sensor-"

MAX_LINES_PER_PACKET = 64      # 1データグラムに詰める最大行数（UDPサイズを抑える）
MAX_LINE_LENGTH = 512          # これを超える「行」は壊れたデータとして捨てる
MAX_PENDING_LINES = 4000       # アプリが受け取れないときに溜めすぎない上限（1台あたり）
MAX_COMMAND_LENGTH = 64        # デバイスへ送るコマンド1行の上限（ファームの kMaxCommandLength と同じ）

# --mock の疑似デバイスが真似る実機ファームの仕様（firmware/m5stick_sender/README.md「コマンド」）
MOCK_FIRMWARE_VERSION = "mock"
MOCK_RATE_MIN = 10
MOCK_RATE_MAX = 200
MOCK_COMMANDS = "PAUSE,RESUME,RATE,INFO"

BLEAK_INSTALL_HINT = (
    "bleak がインストールされていません。"
    "macOS / Linux は tools/ble_bridge/setup.sh、Windows は tools/ble_bridge/setup.bat を実行してください"
    "（手動なら: python3 -m pip install -r tools/ble_bridge/requirements.txt）。"
)

# エラーの種類（アプリ側はこのコードで対処方法の文言を選ぶ）
ERR_BLEAK_MISSING = "bleak_missing"
ERR_BLUETOOTH_OFF = "bluetooth_off"
ERR_UNAUTHORIZED = "unauthorized"
ERR_NO_ADAPTER = "no_adapter"
ERR_SCAN_FAILED = "scan_failed"
ERR_CONNECT_FAILED = "connect_failed"
ERR_NOT_CONNECTED = "not_connected"
ERR_SEND_FAILED = "send_failed"
ERR_LINK_LOST = "link_lost"
ERR_BAD_REQUEST = "bad_request"


class BridgeError(Exception):
    """アプリへ返すべきエラー。code は上の ERR_* のいずれか。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def classify_ble_error(exc: BaseException, default_code: str) -> BridgeError:
    """bleak / OS の例外を、アプリが対処を表示できるエラーコードに分類する。"""
    if isinstance(exc, BridgeError):
        return exc
    text = "%s: %s" % (type(exc).__name__, exc)
    lower = text.lower()
    if "not authorized" in lower or "unauthorized" in lower or "permission" in lower:
        code = ERR_UNAUTHORIZED
    elif "turned off" in lower or "powered off" in lower or "poweredoff" in lower:
        code = ERR_BLUETOOTH_OFF
    elif "no bluetooth adapter" in lower or ("adapter" in lower and "not found" in lower):
        code = ERR_NO_ADAPTER
    elif isinstance(exc, asyncio.TimeoutError):
        code = default_code
        text = "タイムアウトしました（デバイスの電源・距離を確認してください）"
    else:
        code = default_code
    return BridgeError(code, text)


# ---------------------------------------------------------------------------
# 行の組み立て
# ---------------------------------------------------------------------------

class LineAssembler:
    """BLE 通知のバイト列を改行で区切り、完全な行だけを取り出す。

    1通知に複数行が入っていたり、1行が複数通知に分かれて届いたりするため、
    未完の行は次の通知まで持ち越す。
    """

    def __init__(self, max_line: int = MAX_LINE_LENGTH) -> None:
        self._buffer = bytearray()
        self._max_line = max_line
        self.dropped = 0   # 長すぎて捨てた行の数（診断用）

    def feed(self, data: bytes) -> List[str]:
        self._buffer.extend(data)
        lines: List[str] = []
        while True:
            index = self._buffer.find(b"\n")
            if index < 0:
                break
            raw = bytes(self._buffer[:index])
            del self._buffer[: index + 1]
            if len(raw) > self._max_line:
                self.dropped += 1
                continue
            text = raw.decode("utf-8", errors="replace").strip()
            if text:
                lines.append(text)
        # 改行が来ないまま溜まり続ける場合は壊れたデータとして捨てる
        if len(self._buffer) > self._max_line:
            self._buffer.clear()
            self.dropped += 1
        return lines

    def pending(self) -> bytes:
        return bytes(self._buffer)

    def reset(self) -> None:
        self._buffer.clear()


# ---------------------------------------------------------------------------
# BLE バックエンド（実機 = bleak / 疑似 = mock）
# ---------------------------------------------------------------------------

DataCallback = Callable[[str, bytes], None]
DisconnectCallback = Callable[[str, str], None]


class Backend:
    """BLE 操作の共通インターフェース。"""

    name = "base"

    def __init__(self) -> None:
        self.on_data: Optional[DataCallback] = None              # (address, bytes)
        self.on_disconnected: Optional[DisconnectCallback] = None  # (address, reason)

    def check(self) -> Optional[BridgeError]:
        """使える状態なら None、使えないなら理由を返す。"""
        return None

    async def scan(self, timeout: float, show_all: bool) -> List[Dict[str, Any]]:
        raise NotImplementedError

    async def connect(self, address: str, timeout: float) -> str:
        """接続し、正規化したアドレスを返す。"""
        raise NotImplementedError

    async def disconnect(self, address: str) -> None:
        raise NotImplementedError

    async def send(self, address: str, line: str) -> None:
        raise NotImplementedError

    def connected_addresses(self) -> List[str]:
        return []

    async def close(self) -> None:
        for address in list(self.connected_addresses()):
            try:
                await self.disconnect(address)
            except Exception:  # 終了処理なので失敗しても続ける
                pass

    def _emit_data(self, address: str, data: bytes) -> None:
        if self.on_data is not None:
            self.on_data(address, data)

    def _emit_disconnected(self, address: str, reason: str) -> None:
        if self.on_disconnected is not None:
            self.on_disconnected(address, reason)


def _find_key(mapping: Dict[str, Any], address: str) -> Optional[str]:
    """アドレスを大文字小文字を区別せずに探す（MAC表記の揺れ対策）。"""
    if address in mapping:
        return address
    lower = address.lower()
    for key in mapping:
        if key.lower() == lower:
            return key
    return None


class BleakBackend(Backend):
    """bleak を使う実機用バックエンド。bleak は初めて必要になったときに import する。"""

    name = "bleak"

    def __init__(self) -> None:
        super().__init__()
        self._bleak: Any = None
        self._import_error: Optional[str] = None
        self._clients: Dict[str, Any] = {}       # address -> BleakClient
        self._seen: Dict[str, Any] = {}          # address -> BLEDevice（直近スキャン）
        self._write_response: Dict[str, bool] = {}
        self._closing: set = set()               # 自分から切断中のアドレス

    def _load(self) -> Any:
        if self._bleak is None and self._import_error is None:
            try:
                import bleak  # noqa: F401  （遅延 import）
                self._bleak = bleak
            except Exception as exc:  # ImportError 以外（依存の壊れ）もまとめて扱う
                self._import_error = "%s（詳細: %s）" % (BLEAK_INSTALL_HINT, exc)
        if self._bleak is None:
            raise BridgeError(ERR_BLEAK_MISSING, self._import_error or BLEAK_INSTALL_HINT)
        return self._bleak

    def check(self) -> Optional[BridgeError]:
        try:
            self._load()
        except BridgeError as err:
            return err
        return None

    def bleak_version(self) -> str:
        try:
            from importlib import metadata
            return metadata.version("bleak")
        except Exception:
            return "?"

    async def scan(self, timeout: float, show_all: bool) -> List[Dict[str, Any]]:
        bleak = self._load()
        try:
            found = await bleak.BleakScanner.discover(timeout=timeout, return_adv=True)
        except Exception as exc:
            raise classify_ble_error(exc, ERR_SCAN_FAILED)
        devices: List[Dict[str, Any]] = []
        for _key, (device, adv) in found.items():
            name = adv.local_name or device.name or ""
            uuids = [str(u).lower() for u in (adv.service_uuids or [])]
            is_target = NUS_SERVICE_UUID in uuids or name.startswith(NAME_PREFIX)
            if not show_all and not is_target:
                continue
            self._seen[device.address] = device
            devices.append({
                "address": device.address,
                "name": name,
                "rssi": int(adv.rssi) if adv.rssi is not None else 0,
                "nus": NUS_SERVICE_UUID in uuids,
            })
        devices.sort(key=lambda d: -d["rssi"])
        return devices

    async def connect(self, address: str, timeout: float) -> str:
        bleak = self._load()
        key = _find_key(self._clients, address)
        if key is not None and self._clients[key].is_connected:
            return key
        seen_key = _find_key(self._seen, address)
        target = self._seen[seen_key] if seen_key is not None else address
        address = seen_key or address

        def on_disconnect(_client: Any) -> None:
            self._clients.pop(address, None)
            if address in self._closing:
                return
            self._emit_disconnected(address, "接続が切れました（電源・距離を確認してください）")

        client = bleak.BleakClient(target, disconnected_callback=on_disconnect, timeout=timeout)
        try:
            await client.connect()
        except Exception as exc:
            raise classify_ble_error(exc, ERR_CONNECT_FAILED)

        try:
            await client.start_notify(
                NUS_TX_UUID, lambda _sender, data: self._emit_data(address, bytes(data))
            )
        except Exception as exc:
            self._closing.add(address)
            try:
                await client.disconnect()
            finally:
                self._closing.discard(address)
            raise BridgeError(
                ERR_CONNECT_FAILED,
                "Nordic UART Service の通知を開始できません（対応ファームウェアか確認してください）: %s" % exc,
            )

        rx = None
        try:
            rx = client.services.get_characteristic(NUS_RX_UUID)
        except Exception:
            rx = None
        props = list(getattr(rx, "properties", []) or [])
        self._write_response[address] = "write-without-response" not in props
        self._clients[address] = client
        return address

    async def disconnect(self, address: str) -> None:
        key = _find_key(self._clients, address)
        if key is None:
            return
        client = self._clients.pop(key)
        self._closing.add(key)
        try:
            await client.disconnect()
        finally:
            self._closing.discard(key)

    async def send(self, address: str, line: str) -> None:
        key = _find_key(self._clients, address)
        if key is None:
            raise BridgeError(ERR_NOT_CONNECTED, "未接続のデバイスです: %s" % address)
        client = self._clients[key]
        payload = (line.rstrip("\r\n") + "\n").encode("utf-8")
        try:
            await client.write_gatt_char(
                NUS_RX_UUID, payload, response=self._write_response.get(key, True)
            )
        except Exception as exc:
            raise classify_ble_error(exc, ERR_SEND_FAILED)

    def connected_addresses(self) -> List[str]:
        return [a for a, c in self._clients.items() if getattr(c, "is_connected", False)]


class MockDevice:
    """疑似 M5 デバイス1台。100Hz で CSV 行を作り、わざと細切れの通知にして届ける。"""

    def __init__(self, address: str, name: str, rssi: int, nus: bool = True, seed: int = 0) -> None:
        self.address = address
        self.name = name
        self.rssi = rssi
        self.nus = nus
        self.rate = 100
        self.paused = False
        self.connected = False
        self.task: Optional[asyncio.Task] = None
        self.outbox: List[str] = []   # 次の送信で先に出す応答・情報行
        self._rng = random.Random(seed)
        self._phase = 0.0
        self._pending = b""

    def make_line(self) -> str:
        """src/core/mock_sensor_provider.gd と同じ考え方の波形＋ときどきピーク。"""
        rng = self._rng
        self._phase += 0.06 * (100.0 / self.rate)
        p = self._phase
        spike = rng.uniform(0.6, 2.2) if rng.random() < 0.012 else 0.0
        ax = math.sin(p) * 0.25 + rng.uniform(-0.04, 0.04) + spike
        ay = 0.98 + math.sin(p * 0.7) * 0.12 + rng.uniform(-0.03, 0.03)
        az = math.cos(p * 1.3) * 0.18 + rng.uniform(-0.035, 0.035) - spike * 0.4
        gx = math.sin(p * 1.8) * 60.0 + rng.uniform(-7.0, 7.0) + spike * 120.0
        gy = math.cos(p * 1.1) * 45.0 + rng.uniform(-6.0, 6.0)
        gz = math.sin(p * 0.5) * 30.0 + rng.uniform(-5.0, 5.0)
        return "%.4f,%.4f,%.4f,%.3f,%.3f,%.3f" % (ax, ay, az, gx, gy, gz)

    def info_line(self) -> str:
        """実機ファーム（sender_core の formatInfoLine）と同じ項目の情報行。"""
        return ("# model=MOCK name=%s rate=%d ble=1 fw=%s imu=MOCK sending=%d connected=%d "
                "drop_usb=0 drop_ble=0" % (self.name, self.rate, MOCK_FIRMWARE_VERSION,
                                           0 if self.paused else 1, 1 if self.connected else 0))

    def handle_command(self, line: str) -> Optional[str]:
        """実機ファームと同じ規則でコマンドを解釈し、応答行（改行なし）を返す。応答なしは None。

        firmware/m5stick_sender の README「コマンド」「エラー行」と同じ形式:
          # ok=PAUSE sending=0 / # ok=RESUME sending=1 / # ok=RATE rate=50 / INFO は情報行
          # error=rate_out_of_range value=5 min=10 max=200 など
        """
        if len(line.rstrip("\r\n")) > MAX_COMMAND_LENGTH:
            return "# error=line_too_long max=%d" % MAX_COMMAND_LENGTH
        text = line.strip()
        if not text or text.startswith("#"):
            return None   # 空行・コメント行は無視（応答なし）
        tokens = text.split()
        command = tokens[0].upper()
        if command == "RATE":
            if len(tokens) < 2:
                return "# error=rate_missing min=%d max=%d" % (MOCK_RATE_MIN, MOCK_RATE_MAX)
            if len(tokens) > 2:
                return "# error=unexpected_argument commands=%s" % MOCK_COMMANDS
            arg = tokens[1]
            if not arg or any(c not in "0123456789" for c in arg):
                return "# error=rate_not_number min=%d max=%d" % (MOCK_RATE_MIN, MOCK_RATE_MAX)
            value = min(int(arg), 999999)
            if value < MOCK_RATE_MIN or value > MOCK_RATE_MAX:
                return "# error=rate_out_of_range value=%d min=%d max=%d" % (
                    value, MOCK_RATE_MIN, MOCK_RATE_MAX)
            self.rate = value
            return "# ok=RATE rate=%d" % self.rate
        if command not in ("PAUSE", "RESUME", "INFO"):
            return "# error=unknown_command commands=%s" % MOCK_COMMANDS
        if len(tokens) > 1:
            return "# error=unexpected_argument commands=%s" % MOCK_COMMANDS
        if command == "PAUSE":
            self.paused = True
            return "# ok=PAUSE sending=0"
        if command == "RESUME":
            self.paused = False
            return "# ok=RESUME sending=1"
        return self.info_line()

    def queue_line(self, text: str) -> None:
        """応答・情報行を送信待ちに入れる（サンプル行と同じ流れで、行の途中に割り込まないように送る）。"""
        self.outbox.append(text)

    def take_outbox(self) -> List[str]:
        lines, self.outbox = self.outbox, []
        return lines

    def split_notifications(self, data: bytes) -> List[bytes]:
        """BLE の通知（MTU 20 バイト前後）を真似て、行の途中で区切った断片にする。

        末尾の数バイトは次回へ持ち越すので、行が通知の境界をまたぐことが必ず起きる。
        """
        data = self._pending + data
        keep = self._rng.randint(0, min(len(data), 15))
        send, self._pending = data[: len(data) - keep], data[len(data) - keep:]
        chunks: List[bytes] = []
        pos = 0
        while pos < len(send):
            size = self._rng.randint(5, 40)
            chunks.append(send[pos: pos + size])
            pos += size
        return chunks


class MockBackend(Backend):
    """bleak 無しで動く疑似バックエンド。開発・テスト・デモ用。"""

    name = "mock"
    TICK_SEC = 0.02

    def __init__(self, seed: Optional[int] = None) -> None:
        super().__init__()
        base = seed if seed is not None else int(time.time())
        self.devices: Dict[str, MockDevice] = {
            "AA:BB:CC:00:00:01": MockDevice("AA:BB:CC:00:00:01", "M5-Sensor-MOCK1", -48, seed=base + 1),
            "AA:BB:CC:00:00:02": MockDevice("AA:BB:CC:00:00:02", "M5-Sensor-MOCK2", -63, seed=base + 2),
            # NUS を持たない無関係な機器（--all のときだけ見える。接続は失敗する）
            "AA:BB:CC:00:00:99": MockDevice("AA:BB:CC:00:00:99", "Other-Headphones", -77, nus=False,
                                            seed=base + 3),
        }

    async def scan(self, timeout: float, show_all: bool) -> List[Dict[str, Any]]:
        await asyncio.sleep(min(timeout, 0.5))
        result = []
        for dev in self.devices.values():
            if not show_all and not (dev.nus or dev.name.startswith(NAME_PREFIX)):
                continue
            result.append({
                "address": dev.address,
                "name": dev.name,
                "rssi": dev.rssi + random.randint(-4, 4),
                "nus": dev.nus,
            })
        return result

    def _get(self, address: str) -> MockDevice:
        key = _find_key(self.devices, address)
        if key is None:
            raise BridgeError(ERR_CONNECT_FAILED, "デバイスが見つかりません: %s" % address)
        return self.devices[key]

    async def connect(self, address: str, timeout: float) -> str:
        dev = self._get(address)
        if dev.connected:
            return dev.address
        await asyncio.sleep(0.2)
        if not dev.nus:
            raise BridgeError(ERR_CONNECT_FAILED,
                              "Nordic UART Service がありません（センサー用ファームウェアではない機器です）")
        dev.connected = True
        dev.paused = False
        dev.outbox = []
        dev._pending = b""   # 実機と同じく、接続のたびに送信待ちを捨てる
        # 実機は購読が始まると最初に情報行を送る
        dev.queue_line(dev.info_line())
        dev.task = asyncio.ensure_future(self._stream(dev))
        return dev.address

    async def _stream(self, dev: MockDevice) -> None:
        carry = 0.0
        last = time.monotonic()
        try:
            while dev.connected:
                await asyncio.sleep(self.TICK_SEC)
                now = time.monotonic()
                elapsed, last = now - last, now
                lines = dev.take_outbox()
                if not dev.paused:
                    carry += elapsed * dev.rate
                    count = int(carry)
                    carry -= count
                    lines.extend(dev.make_line() for _ in range(count))
                else:
                    carry = 0.0
                data = "".join(line + "\n" for line in lines).encode()
                if not data and not dev._pending:
                    continue
                for chunk in dev.split_notifications(data):
                    self._emit_data(dev.address, chunk)
        except asyncio.CancelledError:
            pass

    async def disconnect(self, address: str) -> None:
        key = _find_key(self.devices, address)
        if key is None:
            return
        self._stop(self.devices[key])

    def _stop(self, dev: MockDevice) -> None:
        dev.connected = False
        if dev.task is not None:
            dev.task.cancel()
            dev.task = None

    async def send(self, address: str, line: str) -> None:
        key = _find_key(self.devices, address)
        if key is None or not self.devices[key].connected:
            raise BridgeError(ERR_NOT_CONNECTED, "未接続のデバイスです: %s" % address)
        dev = self.devices[key]
        if line.strip().upper() == "MOCK_DROP":
            # テスト用（mock だけのコマンド）: 電波が途切れたことにする
            self._stop(dev)
            self._emit_disconnected(dev.address, "接続が切れました（mock: MOCK_DROP）")
            return
        reply = dev.handle_command(line)
        if reply is not None:
            dev.queue_line(reply)

    def connected_addresses(self) -> List[str]:
        return [d.address for d in self.devices.values() if d.connected]


# ---------------------------------------------------------------------------
# ブリッジ本体（コマンド処理・データの取りまとめ・見張り）
# ---------------------------------------------------------------------------

SendFunc = Callable[[Dict[str, Any]], None]


class Bridge:
    """アプリからのコマンドを処理し、デバイスのデータをまとめてアプリへ送る。

    UDP の送受信そのものは持たず、send 関数を受け取るだけなので単体テストしやすい。
    """

    def __init__(
        self,
        backend: Backend,
        send: SendFunc,
        *,
        flush_interval: float = 0.02,
        idle_timeout: float = 10.0,
        managed: bool = False,
        parent_pid: Optional[int] = None,
        scan_timeout: float = 4.0,
        connect_timeout: float = 15.0,
        show_all: bool = False,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.backend = backend
        self.send = send
        self.flush_interval = flush_interval
        self.idle_timeout = idle_timeout
        self.managed = managed
        self.parent_pid = parent_pid
        self.scan_timeout = scan_timeout
        self.connect_timeout = connect_timeout
        self.show_all = show_all
        self.clock = clock

        self.assemblers: Dict[str, LineAssembler] = {}
        self.pending: Dict[str, List[str]] = {}
        self.last_contact: Optional[float] = None   # 最後にアプリから何か届いた時刻
        self.stopping = False
        self.stop_reason = ""
        self._tasks: set = set()
        self._scan_task: Optional[asyncio.Future] = None
        self._connecting: set = set()

        backend.on_data = self.on_device_data
        backend.on_disconnected = self.on_device_disconnected

    # --- 送信ヘルパー -------------------------------------------------------

    def emit(self, message: Dict[str, Any]) -> None:
        try:
            self.send(message)
        except Exception as exc:  # 送れなくても落ちない
            print("[ble_bridge] 送信に失敗: %s" % exc, file=sys.stderr)

    def log(self, level: str, message: str) -> None:
        print("[ble_bridge] %s: %s" % (level, message), file=sys.stderr)
        self.emit({"type": "log", "level": level, "message": message})

    def status(self, address: str, connected: bool, state: str,
               error: Optional[BridgeError] = None) -> None:
        msg: Dict[str, Any] = {"type": "status", "address": address,
                               "connected": connected, "state": state}
        if error is not None:
            msg["error"] = error.code
            msg["message"] = error.message
        self.emit(msg)

    def hello_message(self) -> Dict[str, Any]:
        msg: Dict[str, Any] = {
            "type": "hello",
            "version": VERSION,
            "protocol": PROTOCOL_VERSION,
            "backend": self.backend.name,
            "pid": os.getpid(),
            "managed": self.managed,
            "connected": self.backend.connected_addresses(),
            "ready": True,
        }
        problem = self.backend.check()
        if problem is not None:
            msg["ready"] = False
            msg["error"] = problem.code
            msg["message"] = problem.message
        return msg

    # --- コマンド処理 -------------------------------------------------------

    def handle_datagram(self, data: bytes) -> None:
        """UDP で届いた1データグラムを処理する。壊れた JSON でも落ちない。"""
        self.last_contact = self.clock()
        try:
            message = json.loads(data.decode("utf-8"))
        except Exception:
            self.log("warn", "JSON として読めないデータを受信しました")
            return
        if not isinstance(message, dict):
            self.log("warn", "JSON オブジェクトではないデータを受信しました")
            return
        self.handle(message)

    def handle(self, message: Dict[str, Any]) -> None:
        self.last_contact = self.clock()
        cmd = str(message.get("cmd", message.get("type", ""))).lower()
        address = str(message.get("address", ""))

        if cmd == "hello":
            self.emit(self.hello_message())
        elif cmd == "ping":
            self.emit({"type": "pong", "connected": self.backend.connected_addresses(),
                       "scanning": self.is_scanning()})
        elif cmd == "scan":
            timeout = _as_float(message.get("timeout"), self.scan_timeout, 1.0, 30.0)
            show_all = bool(message.get("all", self.show_all))
            self.start_scan(timeout, show_all)
        elif cmd == "connect":
            if not address:
                self.log("warn", "connect に address がありません")
                return
            self._spawn(self._connect(address))
        elif cmd == "disconnect":
            if not address:
                self.log("warn", "disconnect に address がありません")
                return
            self._spawn(self._disconnect(address))
        elif cmd == "send":
            line = str(message.get("line", ""))
            self._spawn(self._send_line(address, line))
        elif cmd == "bye":
            # アプリ終了時（手動起動のブリッジ）: デバイスは切断し、次のアプリを待つ
            self._spawn(self._disconnect_all("アプリが終了しました"))
            self.last_contact = None
        elif cmd == "quit":
            self.request_stop("アプリから quit を受信")
        else:
            self.log("warn", "不明なコマンドです: %s" % cmd)

    def is_scanning(self) -> bool:
        return self._scan_task is not None and not self._scan_task.done()

    def start_scan(self, timeout: float, show_all: bool) -> None:
        if self.is_scanning():
            return   # 実行中のスキャン結果がそのまま返る
        self._scan_task = self._spawn(self._scan(timeout, show_all))

    async def _scan(self, timeout: float, show_all: bool) -> None:
        self.emit({"type": "scanning", "active": True, "timeout": timeout})
        try:
            devices = await self.backend.scan(timeout, show_all)
            self.emit({"type": "devices", "devices": devices, "all": show_all})
        except Exception as exc:
            err = classify_ble_error(exc, ERR_SCAN_FAILED)
            self.log("error", "スキャンに失敗しました: %s" % err.message)
            self.emit({"type": "devices", "devices": [], "all": show_all,
                       "error": err.code, "message": err.message})

    async def _connect(self, address: str) -> None:
        if address in self._connecting:
            return
        self._connecting.add(address)
        self.status(address, False, "connecting")
        # 行の組み立てバッファは接続「前」に空にする。backend.connect() の中で通知の購読
        # （start_notify）が始まり、戻る前に最初の通知（情報行）が届くことがあるため、
        # 接続後に作り直すと組み立て途中の行が消えてしまう。
        self.assemblers.pop(address, None)
        self.pending.pop(address, None)
        try:
            real = await self.backend.connect(address, self.connect_timeout)
            self.assemblers.setdefault(real, LineAssembler())
            self.pending.setdefault(real, [])
            self.status(real, True, "connected")
            self.log("info", "接続しました: %s" % real)
        except Exception as exc:
            err = classify_ble_error(exc, ERR_CONNECT_FAILED)
            self.assemblers.pop(address, None)
            self.pending.pop(address, None)
            self.status(address, False, "disconnected", err)
            self.log("error", "接続に失敗しました: %s: %s" % (address, err.message))
        finally:
            self._connecting.discard(address)

    async def _disconnect(self, address: str) -> None:
        try:
            await self.backend.disconnect(address)
        except Exception as exc:
            self.log("warn", "切断処理でエラー（切断扱いにします）: %s" % exc)
        self.flush()
        self.assemblers.pop(address, None)
        self.pending.pop(address, None)
        self.status(address, False, "disconnected")

    async def _disconnect_all(self, reason: str) -> None:
        addresses = self.backend.connected_addresses()
        if addresses:
            self.log("info", "%s。%d 台を切断します" % (reason, len(addresses)))
        for address in addresses:
            await self._disconnect(address)

    async def _send_line(self, address: str, line: str) -> None:
        clean = line.strip()
        if not clean or len(clean) > MAX_COMMAND_LENGTH or "\n" in clean or "\r" in clean:
            self.log("warn", "送信できないコマンドです: %r" % line)
            return
        try:
            await self.backend.send(address, clean)
        except Exception as exc:
            err = classify_ble_error(exc, ERR_SEND_FAILED)
            self.log("error", "コマンド送信に失敗しました: %s: %s" % (address, err.message))

    # --- デバイスからの通知 ---------------------------------------------------

    def on_device_data(self, address: str, data: bytes) -> None:
        assembler = self.assemblers.get(address)
        if assembler is None:
            assembler = self.assemblers[address] = LineAssembler()
        lines = assembler.feed(data)
        if not lines:
            return
        queue = self.pending.setdefault(address, [])
        queue.extend(lines)
        if len(queue) > MAX_PENDING_LINES:
            del queue[: len(queue) - MAX_PENDING_LINES]

    def on_device_disconnected(self, address: str, reason: str) -> None:
        self.flush()
        self.assemblers.pop(address, None)
        self.pending.pop(address, None)
        self.status(address, False, "disconnected", BridgeError(ERR_LINK_LOST, reason))
        self.log("warn", "%s: %s" % (address, reason))

    def flush(self) -> int:
        """溜まった行をまとめて送る。送ったデータグラム数を返す。"""
        sent = 0
        for address, queue in self.pending.items():
            if address in self._connecting:
                continue   # 接続完了（status connected）より先にデータを送らない（アプリが捨ててしまう）
            while queue:
                chunk = queue[:MAX_LINES_PER_PACKET]
                del queue[:MAX_LINES_PER_PACKET]
                self.emit({"type": "data", "address": address, "lines": chunk})
                sent += 1
        return sent

    # --- 見張りと終了 -------------------------------------------------------

    def request_stop(self, reason: str) -> None:
        if not self.stopping:
            self.stopping = True
            self.stop_reason = reason
            print("[ble_bridge] 終了します: %s" % reason, file=sys.stderr)

    def check_watchdog(self) -> None:
        """孤児プロセスにならないための見張り。run() から定期的に呼ぶ。"""
        if self.parent_pid and not pid_alive(self.parent_pid):
            self.request_stop("起動元のアプリ（pid %d）が終了しました" % self.parent_pid)
            return
        if self.idle_timeout <= 0 or self.last_contact is None:
            return
        if self.clock() - self.last_contact < self.idle_timeout:
            return
        if self.managed:
            self.request_stop("アプリから %.0f 秒間応答がありません" % self.idle_timeout)
        else:
            # 手動起動: 終了はせず、デバイスを手放して次のアプリを待つ
            self.last_contact = None
            print("[ble_bridge] アプリからの応答が途絶えました。デバイスを切断して待機します",
                  file=sys.stderr)
            self._spawn(self._disconnect_all("アプリからの応答が途絶えました"))

    async def run(self) -> None:
        next_watch = 0.0
        while not self.stopping:
            await asyncio.sleep(self.flush_interval)
            self.flush()
            now = self.clock()
            if now >= next_watch:
                next_watch = now + 0.5
                self.check_watchdog()
        self.flush()

    async def shutdown(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        try:
            await asyncio.wait_for(self.backend.close(), timeout=5.0)
        except Exception:
            pass

    def _spawn(self, coro: Any) -> asyncio.Future:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task


def _as_float(value: Any, default: float, low: float, high: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, number))


def pid_alive(pid: int) -> bool:
    """プロセスが生きているか。Windows では os.kill(pid, 0) が使えないので API を使う。"""
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        process_query_limited_information = 0x1000
        still_active = 259
        handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
        if not handle:
            # アクセス拒否（ERROR_ACCESS_DENIED=5）は「存在する」とみなす
            return ctypes.GetLastError() == 5  # type: ignore[attr-defined]
        try:
            code = wintypes.DWORD()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return True
            return code.value == still_active
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


# ---------------------------------------------------------------------------
# UDP の入出力
# ---------------------------------------------------------------------------

class UdpEndpoint:
    """UDP ソケットを専用スレッドで受信する。

    asyncio のデータグラム機能は Windows で ICMP（ポート到達不能）を受けると
    受信が止まることがあるため、素のソケット＋スレッドで扱う。
    """

    def __init__(self, listen_port: int, app_port: int) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if os.name == "nt":
            # 他プロセスが同じポートを横取りできないようにする
            exclusive = getattr(socket, "SO_EXCLUSIVEADDRUSE", None)
            if exclusive is not None:
                self.sock.setsockopt(socket.SOL_SOCKET, exclusive, 1)
        self.sock.bind((HOST, listen_port))
        self.sock.settimeout(0.25)
        self.reply_to: Tuple[str, int] = (HOST, app_port)
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self, loop: asyncio.AbstractEventLoop, handler: Callable[[bytes], None]) -> None:
        def reader() -> None:
            while not self._stop.is_set():
                try:
                    data, addr = self.sock.recvfrom(65535)
                except socket.timeout:
                    continue
                except ConnectionResetError:
                    continue   # Windows: 相手が居ないときの ICMP。無視して受信を続ける
                except OSError:
                    if self._stop.is_set():
                        break
                    continue
                # 返信先は「最後にコマンドを送ってきた相手」（ローカルのみ受け付ける）
                if addr[0] != HOST:
                    continue
                self.reply_to = (addr[0], addr[1])
                try:
                    loop.call_soon_threadsafe(handler, data)
                except RuntimeError:
                    break   # ループが閉じた
        self._thread = threading.Thread(target=reader, name="udp-reader", daemon=True)
        self._thread.start()

    def send(self, message: Dict[str, Any]) -> None:
        data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        try:
            self.sock.sendto(data, self.reply_to)
        except OSError:
            pass   # アプリがまだ居ない／もう居ない

    def close(self) -> None:
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        if self._thread is not None:
            self._thread.join(timeout=1.0)


# ---------------------------------------------------------------------------
# エントリーポイント
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="センサーテストアプリ用 BLE ブリッジ（BLE ⇔ ローカルUDP）",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_LISTEN_PORT,
                        help="ブリッジが待ち受ける UDP ポート（既定 %(default)s）")
    parser.add_argument("--app-port", type=int, default=DEFAULT_APP_PORT,
                        help="アプリの UDP ポート（既定 %(default)s）")
    parser.add_argument("--mock", action="store_true",
                        help="bleak を使わず疑似デバイス2台で動かす（開発・テスト用）")
    parser.add_argument("--all", action="store_true",
                        help="スキャン結果を M5 センサーに絞らない（全 BLE 機器を返す）")
    parser.add_argument("--scan-timeout", type=float, default=4.0,
                        help="スキャン時間の既定値（秒）")
    parser.add_argument("--idle-timeout", type=float, default=10.0,
                        help="アプリから何も届かない時間がこれを超えたら終了（自動起動時）／"
                             "デバイスを切断（手動起動時）。0 で無効")
    parser.add_argument("--parent-pid", type=int, default=0,
                        help="起動元アプリの pid。指定すると自動起動モードになり、アプリが終了したら一緒に終了する")
    parser.add_argument("--flush-ms", type=int, default=20,
                        help="データをまとめて送る間隔（ミリ秒）")
    parser.add_argument("--scan-once", action="store_true",
                        help="UDP を使わず、1回スキャンして結果を表示して終了する（動作確認用）")
    parser.add_argument("--version", action="version", version="ble_bridge " + VERSION)
    return parser


async def serve(args: argparse.Namespace, backend: Backend) -> int:
    try:
        endpoint = UdpEndpoint(args.port, args.app_port)
    except OSError as exc:
        print("[ble_bridge] UDP ポート %d を開けません（すでにブリッジが起動している可能性があります）: %s"
              % (args.port, exc), file=sys.stderr)
        return 2

    managed = args.parent_pid > 0
    bridge = Bridge(
        backend,
        endpoint.send,
        flush_interval=max(0.005, args.flush_ms / 1000.0),
        idle_timeout=args.idle_timeout,
        managed=managed,
        parent_pid=args.parent_pid or None,
        scan_timeout=args.scan_timeout,
        show_all=args.all,
    )
    loop = asyncio.get_running_loop()
    endpoint.start(loop, bridge.handle_datagram)

    problem = backend.check()
    print("[ble_bridge] v%s 起動（backend=%s, 待受 %s:%d, アプリ %s:%d, %s）"
          % (VERSION, backend.name, HOST, args.port, HOST, args.app_port,
             "自動起動" if managed else "手動起動"), file=sys.stderr)
    if problem is not None:
        print("[ble_bridge] 注意: %s" % problem.message, file=sys.stderr)

    # 起動を知らせる（アプリが先に待っていればすぐ気づける）
    bridge.emit(bridge.hello_message())
    try:
        await bridge.run()
    finally:
        await bridge.shutdown()
        bridge.emit({"type": "bye", "reason": bridge.stop_reason})
        endpoint.close()
    return 0


async def scan_once(args: argparse.Namespace, backend: Backend) -> int:
    problem = backend.check()
    if problem is not None:
        print(problem.message, file=sys.stderr)
        return 1
    try:
        devices = await backend.scan(args.scan_timeout, args.all)
    except Exception as exc:
        err = classify_ble_error(exc, ERR_SCAN_FAILED)
        print("スキャンに失敗しました [%s]: %s" % (err.code, err.message), file=sys.stderr)
        return 1
    print("%d 台見つかりました%s" % (len(devices), "" if args.all else "（M5センサーのみ。全機器は --all）"))
    for d in devices:
        print("  %-40s %-24s RSSI %4d %s" % (d["address"], d["name"] or "(名前なし)", d["rssi"],
                                            "NUS" if d.get("nus") else ""))
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    backend: Backend = MockBackend() if args.mock else BleakBackend()
    try:
        if args.scan_once:
            return asyncio.run(scan_once(args, backend))
        return asyncio.run(serve(args, backend))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
