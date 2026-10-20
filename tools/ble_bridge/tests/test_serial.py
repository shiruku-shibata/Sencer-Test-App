"""USB シリアル受信（kind="serial"）のテスト。pyserial も実機も不要。

- Bridge の振り分け（BLE とシリアルが混ざらない、kind の付与、bye で両方切断）
- SerialBackend（pyserial の代わりに偽モジュールを差し込む）
- --mock の疑似シリアルポート MOCK-COM1 と UDP で往復
"""

import asyncio
import os
import subprocess
import sys
import threading
import time
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ble_bridge  # noqa: E402
from ble_bridge import Bridge, BridgeError, KIND_BLE, KIND_SERIAL  # noqa: E402

from test_bridge_commands import FakeBackend, FakeClock  # noqa: E402
from test_udp_mock import BRIDGE, UdpClient, free_udp_port  # noqa: E402


class FakeSerialBackend(FakeBackend):
    name = "fake-serial"
    kind = KIND_SERIAL

    async def scan(self, timeout, show_all):
        await asyncio.sleep(0)
        return [{"address": "COM3", "name": "USB-SERIAL CH340 (COM3)", "rssi": 0, "usb": True,
                 "likely_m5": True}]


class BridgeSerialRoutingTest(unittest.TestCase):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.out = []
        self.ble = FakeBackend()
        self.serial = FakeSerialBackend()
        self.bridge = Bridge(self.ble, self.out.append, serial_backend=self.serial, clock=FakeClock())

    def tearDown(self):
        self.loop.close()
        asyncio.set_event_loop(None)

    def settle(self):
        for _ in range(10):
            self.loop.run_until_complete(asyncio.sleep(0))

    def of_type(self, kind):
        return [m for m in self.out if m.get("type") == kind]

    def test_hello_reports_serial(self):
        self.bridge.handle({"cmd": "hello"})
        hello = self.of_type("hello")[0]
        self.assertEqual(hello["serial"], {"ready": True, "backend": "fake-serial", "connected": []})
        self.assertTrue(hello["ready"], "BLE の状態はこれまでどおり")

    def test_hello_reports_missing_pyserial_without_affecting_ble(self):
        self.serial.problem = BridgeError(ble_bridge.ERR_PYSERIAL_MISSING, ble_bridge.PYSERIAL_INSTALL_HINT)
        self.bridge.handle({"cmd": "hello"})
        hello = self.of_type("hello")[0]
        self.assertFalse(hello["serial"]["ready"])
        self.assertEqual(hello["serial"]["error"], "pyserial_missing")
        self.assertIn("setup.bat", hello["serial"]["message"])
        self.assertTrue(hello["ready"])

    def test_scan_by_kind(self):
        self.bridge.handle({"cmd": "scan", "kind": "serial"})
        self.settle()
        devices = self.of_type("devices")
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]["kind"], "serial")
        self.assertEqual(devices[0]["devices"][0]["address"], "COM3")
        self.bridge.handle({"cmd": "scan"})   # kind 省略は BLE
        self.settle()
        self.assertEqual(self.of_type("devices")[1]["kind"], "ble")

    def test_connect_send_data_disconnect_are_routed(self):
        self.bridge.handle({"cmd": "connect", "kind": "serial", "address": "COM3"})
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.assertEqual(self.serial.connected, ["COM3"])
        self.assertEqual(self.ble.connected, ["A1"])
        statuses = {(m["address"], m["kind"], m["state"]) for m in self.of_type("status")}
        self.assertIn(("COM3", "serial", "connected"), statuses)
        self.assertIn(("A1", "ble", "connected"), statuses)

        # kind を省略しても、接続中のアドレスなら正しい方へ送られる
        self.bridge.handle({"cmd": "send", "address": "COM3", "line": "PAUSE"})
        self.settle()
        self.assertEqual(self.serial.sent, [("COM3", "PAUSE")])
        self.assertEqual(self.ble.sent, [])

        self.bridge.on_device_data("COM3", b"1,2,3,4,5,6\n")
        self.bridge.on_device_data("A1", b"6,5,4,3,2,1\n")
        self.bridge.flush()
        kinds = {m["address"]: m["kind"] for m in self.of_type("data")}
        self.assertEqual(kinds, {"COM3": "serial", "A1": "ble"})

        self.bridge.handle({"cmd": "ping"})
        pong = self.of_type("pong")[0]
        self.assertEqual(pong["connected"], ["A1"], "connected は BLE だけ（古いアプリとの互換）")
        self.assertEqual(pong["serial_connected"], ["COM3"])

        self.bridge.handle({"cmd": "disconnect", "address": "COM3"})
        self.settle()
        self.assertEqual(self.serial.connected, [])
        self.assertEqual(self.ble.connected, ["A1"])
        last = self.of_type("status")[-1]
        self.assertEqual((last["address"], last["kind"], last["state"]), ("COM3", "serial", "disconnected"))

    def test_link_lost_has_kind(self):
        self.bridge.handle({"cmd": "connect", "kind": "serial", "address": "COM3"})
        self.settle()
        self.bridge.on_device_disconnected("COM3", "ケーブルが抜かれた")
        last = self.of_type("status")[-1]
        self.assertEqual((last["kind"], last["error"]), ("serial", "link_lost"))
        self.assertNotIn("COM3", self.bridge.kinds)

    def test_bye_disconnects_both_kinds(self):
        self.bridge.handle({"cmd": "connect", "kind": "serial", "address": "COM3"})
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.bridge.handle({"cmd": "bye"})
        self.settle()
        self.assertEqual((self.serial.connected, self.ble.connected), ([], []))

    def test_serial_disabled(self):
        out = []
        bridge = Bridge(FakeBackend(), out.append, clock=FakeClock())
        bridge.handle({"cmd": "hello"})
        self.assertIsNone(out[0]["serial"])
        bridge.handle({"cmd": "scan", "kind": "serial"})
        bridge.handle({"cmd": "connect", "kind": "serial", "address": "COM3"})
        devices = [m for m in out if m["type"] == "devices"][0]
        self.assertEqual((devices["kind"], devices["error"]), ("serial", "unsupported"))
        status = [m for m in out if m["type"] == "status"][0]
        self.assertEqual((status["kind"], status["error"], status["connected"]), ("serial", "unsupported", False))


# --- SerialBackend（偽の pyserial モジュールで確認） ---------------------------------

class FakePortInfo:
    def __init__(self, device, description, vid):
        self.device = device
        self.description = description
        self.vid = vid


class FakeSerialPort:
    instances = []

    def __init__(self):
        self.port = None
        self.baudrate = None
        self.timeout = None
        self.write_timeout = None
        self.opened = False
        self.written = b""
        self.incoming = []
        self.fail = None
        self.lock = threading.Lock()
        FakeSerialPort.instances.append(self)

    def open(self):
        if self.port == "BUSY":
            raise OSError("Access is denied")
        self.opened = True

    def reset_input_buffer(self):
        pass

    @property
    def in_waiting(self):
        with self.lock:
            if self.fail:
                raise self.fail
            return sum(len(c) for c in self.incoming)

    def read(self, size):
        with self.lock:
            if self.fail:
                raise self.fail
            if not self.incoming:
                pass
            else:
                return self.incoming.pop(0)
        time.sleep(self.timeout or 0.01)
        return b""

    def write(self, data):
        self.written += data

    def flush(self):
        pass

    def close(self):
        self.opened = False


def fake_serial_module(ports):
    return types.SimpleNamespace(
        Serial=FakeSerialPort,
        tools=types.SimpleNamespace(list_ports=types.SimpleNamespace(comports=lambda: list(ports))),
    )


class SerialBackendTest(unittest.TestCase):
    def setUp(self):
        FakeSerialPort.instances = []
        self.backend = ble_bridge.SerialBackend()
        self.backend._serial = fake_serial_module([
            FakePortInfo("COM1", "通信ポート (COM1)", None),               # 内蔵（USB でない）
            FakePortInfo("COM7", "USB Serial Device (COM7)", 0x2341),      # USB だが M5 でよく使う VID ではない
            FakePortInfo("COM3", "USB-SERIAL CH340 (COM3)", 0x1A86),
            FakePortInfo("/dev/cu.Bluetooth-Incoming-Port", "n/a", 0x0001),
        ])
        self.received = []
        self.lost = []
        self.backend.on_data = lambda a, d: self.received.append((a, d))
        self.backend.on_disconnected = lambda a, r: self.lost.append((a, r))

    def run_async(self, coro):
        return asyncio.new_event_loop().run_until_complete(coro)

    def test_missing_pyserial(self):
        backend = ble_bridge.SerialBackend()
        backend._import_error = ble_bridge.PYSERIAL_INSTALL_HINT + "（詳細: No module named 'serial'）"
        problem = backend.check()
        self.assertEqual(problem.code, ble_bridge.ERR_PYSERIAL_MISSING)
        self.assertIn("setup.sh", problem.message)

    def test_scan_lists_usb_ports_m5_first(self):
        devices = self.run_async(self.backend.scan(1.0, False))
        self.assertEqual([d["address"] for d in devices], ["COM3", "COM7"])
        self.assertTrue(devices[0]["likely_m5"])
        self.assertFalse(devices[1]["likely_m5"])
        self.assertEqual(devices[0]["name"], "USB-SERIAL CH340 (COM3)")
        everything = self.run_async(self.backend.scan(1.0, True))
        self.assertEqual(len(everything), 4)

    def test_connect_read_write_disconnect(self):
        async def scenario():
            await self.backend.connect("COM3", 5.0)
            port = FakeSerialPort.instances[-1]
            self.assertEqual((port.port, port.baudrate, port.opened), ("COM3", 115200, True))
            with port.lock:
                port.incoming.extend([b"1,2,3,", b"4,5,6\n"])
            for _ in range(100):
                await asyncio.sleep(0.01)
                if len(self.received) >= 2:
                    break
            await self.backend.send("COM3", "RATE 50")
            self.assertEqual(port.written, b"RATE 50\n")
            self.assertEqual(self.backend.connected_addresses(), ["COM3"])
            await self.backend.disconnect("COM3")
            self.assertFalse(port.opened)
            self.assertEqual(self.backend.connected_addresses(), [])

        self.run_async(scenario())
        self.assertEqual(b"".join(d for _, d in self.received), b"1,2,3,4,5,6\n")
        self.assertEqual(self.lost, [], "自分から切断したときは link_lost にしない")

    def test_unplugged_port_reports_lost(self):
        async def scenario():
            await self.backend.connect("COM3", 5.0)
            port = FakeSerialPort.instances[-1]
            with port.lock:
                port.fail = OSError("device disconnected")
            for _ in range(100):
                await asyncio.sleep(0.01)
                if self.lost:
                    break

        self.run_async(scenario())
        self.assertEqual(len(self.lost), 1)
        self.assertEqual(self.lost[0][0], "COM3")
        self.assertIn("切断", self.lost[0][1])
        self.assertEqual(self.backend.connected_addresses(), [])

    def test_busy_port(self):
        with self.assertRaises(BridgeError) as ctx:
            self.run_async(self.backend.connect("BUSY", 5.0))
        self.assertEqual(ctx.exception.code, ble_bridge.ERR_CONNECT_FAILED)
        self.assertIn("他のアプリ", ctx.exception.message)

    def test_send_to_unopened_port(self):
        with self.assertRaises(BridgeError) as ctx:
            self.run_async(self.backend.send("COM9", "PAUSE"))
        self.assertEqual(ctx.exception.code, ble_bridge.ERR_NOT_CONNECTED)


# --- --mock の疑似シリアルポートと UDP で往復 ------------------------------------------

class MockSerialUdpTest(unittest.TestCase):
    def start(self, *extra):
        self.bridge_port = free_udp_port()
        self.client = UdpClient(self.bridge_port)
        self.proc = subprocess.Popen(
            [sys.executable, BRIDGE, "--mock", "--port", str(self.bridge_port),
             "--app-port", str(self.client.port)] + list(extra),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        hello = None
        end = time.time() + 10
        while hello is None and time.time() < end:
            self.client.send({"cmd": "hello"})
            hello = self.client.wait_for(lambda m: m.get("type") == "hello", timeout=0.3)
        self.assertIsNotNone(hello)
        self.client.take("hello")
        return hello

    def tearDown(self):
        if getattr(self, "proc", None) is not None and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(5)
        if getattr(self, "client", None) is not None:
            self.client.close()

    def test_mock_serial_session(self):
        hello = self.start()
        self.assertEqual(hello["serial"]["backend"], "mock")
        self.client.send({"cmd": "scan", "kind": "serial"})
        devices = self.client.wait_for(lambda m: m.get("type") == "devices")
        self.assertEqual(devices["kind"], "serial")
        self.assertEqual([d["address"] for d in devices["devices"]], ["MOCK-COM1"])

        self.client.send({"cmd": "connect", "kind": "serial", "address": "MOCK-COM1"})
        status = self.client.wait_for(lambda m: m.get("type") == "status" and m["connected"])
        self.assertEqual(status["kind"], "serial")
        self.client.pump(1.0)
        data = self.client.take("data")
        self.assertTrue(all(m["kind"] == "serial" for m in data))
        lines = [line for m in data for line in m["lines"]]
        self.assertTrue(lines[0].startswith("# model=MOCK name=M5-Sensor-MOCK3"))
        self.assertGreater(len([x for x in lines if not x.startswith("#")]), 50)

        self.client.send({"cmd": "send", "address": "MOCK-COM1", "line": "RATE 5"})
        self.client.pump(0.3)
        replies = [line for m in self.client.take("data") for line in m["lines"] if line.startswith("#")]
        self.assertIn("# error=rate_out_of_range value=5 min=10 max=200", replies)

        self.client.send({"cmd": "ping"})
        pong = self.client.wait_for(lambda m: m.get("type") == "pong")
        self.assertEqual((pong["connected"], pong["serial_connected"]), ([], ["MOCK-COM1"]))

        self.client.send({"cmd": "disconnect", "address": "MOCK-COM1"})
        done = self.client.wait_for(lambda m: m.get("type") == "status" and m["state"] == "disconnected")
        self.assertEqual(done["kind"], "serial")
        self.client.send({"cmd": "quit"})
        self.assertEqual(self.proc.wait(5), 0)

    def test_no_serial_option(self):
        hello = self.start("--no-serial")
        self.assertIsNone(hello["serial"])

    def test_scan_once_serial_mock(self):
        proc = subprocess.run([sys.executable, BRIDGE, "--mock", "--scan-once", "--serial"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("MOCK-COM1", proc.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
