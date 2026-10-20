"""Bridge のコマンド処理・データの取りまとめ・見張りのテスト（UDP を使わない）。"""

import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ble_bridge  # noqa: E402
from ble_bridge import Backend, Bridge, BridgeError  # noqa: E402


class FakeBackend(Backend):
    name = "fake"

    def __init__(self, problem=None):
        super().__init__()
        self.problem = problem
        self.connected = []
        self.sent = []
        self.fail_connect = None
        self.fail_scan = None

    def check(self):
        return self.problem

    async def scan(self, timeout, show_all):
        await asyncio.sleep(0)
        if self.fail_scan:
            raise self.fail_scan
        devices = [{"address": "A1", "name": "M5-Sensor-0001", "rssi": -40, "nus": True}]
        if show_all:
            devices.append({"address": "B2", "name": "Other", "rssi": -80, "nus": False})
        return devices

    async def connect(self, address, timeout):
        await asyncio.sleep(0)
        if self.fail_connect:
            raise self.fail_connect
        self.connected.append(address)
        return address

    async def disconnect(self, address):
        if address in self.connected:
            self.connected.remove(address)

    async def send(self, address, line):
        if address not in self.connected:
            raise BridgeError(ble_bridge.ERR_NOT_CONNECTED, "未接続")
        self.sent.append((address, line))

    def connected_addresses(self):
        return list(self.connected)


class FakeClock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


class BridgeTestBase(unittest.TestCase):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.out = []
        self.clock = FakeClock()
        self.backend = FakeBackend()
        self.bridge = self.make_bridge()

    def make_bridge(self, **kwargs):
        return Bridge(self.backend, self.out.append, clock=self.clock, **kwargs)

    def tearDown(self):
        self.loop.close()
        asyncio.set_event_loop(None)

    def settle(self):
        """spawn されたタスクを完了させる。"""
        for _ in range(10):
            self.loop.run_until_complete(asyncio.sleep(0))

    def of_type(self, kind):
        return [m for m in self.out if m.get("type") == kind]


class CommandTest(BridgeTestBase):
    def test_hello(self):
        self.bridge.handle({"cmd": "hello"})
        hello = self.of_type("hello")[0]
        self.assertEqual(hello["protocol"], ble_bridge.PROTOCOL_VERSION)
        self.assertEqual(hello["backend"], "fake")
        self.assertTrue(hello["ready"])
        self.assertEqual(hello["pid"], os.getpid())

    def test_hello_reports_missing_bleak(self):
        self.backend.problem = BridgeError(ble_bridge.ERR_BLEAK_MISSING, ble_bridge.BLEAK_INSTALL_HINT)
        self.bridge.handle({"cmd": "hello"})
        hello = self.of_type("hello")[0]
        self.assertFalse(hello["ready"])
        self.assertEqual(hello["error"], "bleak_missing")
        self.assertIn("setup.sh", hello["message"])

    def test_ping_returns_connected(self):
        self.backend.connected = ["A1"]
        self.bridge.handle({"cmd": "ping"})
        self.assertEqual(self.of_type("pong")[0]["connected"], ["A1"])

    def test_scan_filters_by_default(self):
        self.bridge.handle({"cmd": "scan"})
        self.settle()
        self.assertEqual(len(self.of_type("scanning")), 1)
        devices = self.of_type("devices")[0]["devices"]
        self.assertEqual([d["address"] for d in devices], ["A1"])

    def test_scan_all(self):
        self.bridge.handle({"cmd": "scan", "all": True})
        self.settle()
        self.assertEqual(len(self.of_type("devices")[0]["devices"]), 2)

    def test_scan_error_is_reported_not_raised(self):
        self.backend.fail_scan = RuntimeError("Bluetooth device is turned off")
        self.bridge.handle({"cmd": "scan"})
        self.settle()
        devices = self.of_type("devices")[0]
        self.assertEqual(devices["devices"], [])
        self.assertEqual(devices["error"], ble_bridge.ERR_BLUETOOTH_OFF)
        self.assertTrue(self.of_type("log"))

    def test_scan_missing_bleak(self):
        self.backend.fail_scan = BridgeError(ble_bridge.ERR_BLEAK_MISSING, "missing")
        self.bridge.handle({"cmd": "scan"})
        self.settle()
        self.assertEqual(self.of_type("devices")[0]["error"], "bleak_missing")

    def test_connect_then_disconnect(self):
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        states = [(m["state"], m["connected"]) for m in self.of_type("status")]
        self.assertEqual(states, [("connecting", False), ("connected", True)])
        self.bridge.handle({"cmd": "disconnect", "address": "A1"})
        self.settle()
        last = self.of_type("status")[-1]
        self.assertEqual((last["address"], last["connected"], last["state"]), ("A1", False, "disconnected"))
        self.assertNotIn("error", last)
        self.assertEqual(self.backend.connected, [])

    def test_connect_failure_reports_error(self):
        self.backend.fail_connect = asyncio.TimeoutError()
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        last = self.of_type("status")[-1]
        self.assertFalse(last["connected"])
        self.assertEqual(last["error"], ble_bridge.ERR_CONNECT_FAILED)
        self.assertIn("タイムアウト", last["message"])

    def test_connect_without_address(self):
        self.bridge.handle({"cmd": "connect"})
        self.settle()
        self.assertEqual(self.of_type("status"), [])
        self.assertEqual(self.of_type("log")[0]["level"], "warn")

    def test_send(self):
        self.backend.connected = ["A1"]
        self.bridge.handle({"cmd": "send", "address": "A1", "line": "RATE 50\n"})
        self.settle()
        self.assertEqual(self.backend.sent, [("A1", "RATE 50")])

    def test_send_rejects_bad_lines(self):
        self.backend.connected = ["A1"]
        self.bridge.handle({"cmd": "send", "address": "A1", "line": "A\nB"})
        self.bridge.handle({"cmd": "send", "address": "A1", "line": "X" * 200})
        self.bridge.handle({"cmd": "send", "address": "A1", "line": ""})
        self.settle()
        self.assertEqual(self.backend.sent, [])
        self.assertEqual(len(self.of_type("log")), 3)

    def test_send_to_unconnected_logs_error(self):
        self.bridge.handle({"cmd": "send", "address": "ZZ", "line": "PAUSE"})
        self.settle()
        self.assertEqual(self.of_type("log")[0]["level"], "error")

    def test_unknown_and_broken_input(self):
        self.bridge.handle_datagram(b"{not json")
        self.bridge.handle_datagram(b"[1,2]")
        self.bridge.handle({"cmd": "dance"})
        self.assertEqual(len(self.of_type("log")), 3)

    def test_quit(self):
        self.bridge.handle({"cmd": "quit"})
        self.assertTrue(self.bridge.stopping)

    def test_bye_disconnects_but_keeps_running(self):
        self.backend.connected = ["A1", "A2"]
        self.bridge.handle({"cmd": "bye"})
        self.settle()
        self.assertEqual(self.backend.connected, [])
        self.assertFalse(self.bridge.stopping)
        self.assertIsNone(self.bridge.last_contact)


class DataTest(BridgeTestBase):
    def test_data_is_assembled_and_batched(self):
        self.bridge.on_device_data("A1", b"1,2,3,")
        self.bridge.on_device_data("A1", b"4,5,6\n7,8")
        self.assertEqual(self.bridge.flush(), 1)
        self.bridge.on_device_data("A1", b",9,1,2,3\n")
        self.bridge.flush()
        data = self.of_type("data")
        self.assertEqual(data[0], {"type": "data", "address": "A1", "kind": "ble", "lines": ["1,2,3,4,5,6"]})
        self.assertEqual(data[1]["lines"], ["7,8,9,1,2,3"])

    def test_flush_without_data_sends_nothing(self):
        self.assertEqual(self.bridge.flush(), 0)
        self.assertEqual(self.out, [])

    def test_large_batches_are_split(self):
        payload = b"".join(b"%d,0,0,0,0,0\n" % i for i in range(150))
        self.bridge.on_device_data("A1", payload)
        self.bridge.flush()
        data = self.of_type("data")
        self.assertEqual([len(d["lines"]) for d in data], [64, 64, 22])
        for d in data:
            self.assertLess(len(json.dumps(d)), 8192)

    def test_devices_are_kept_separate(self):
        self.bridge.on_device_data("A1", b"a1-")
        self.bridge.on_device_data("B2", b"b2\n")
        self.bridge.on_device_data("A1", b"x\n")
        self.bridge.flush()
        by_addr = {d["address"]: d["lines"] for d in self.of_type("data")}
        self.assertEqual(by_addr, {"A1": ["a1-x"], "B2": ["b2"]})

    def test_pending_is_bounded(self):
        payload = b"".join(b"%d\n" % i for i in range(ble_bridge.MAX_PENDING_LINES + 100))
        self.bridge.on_device_data("A1", payload)
        self.assertEqual(len(self.bridge.pending["A1"]), ble_bridge.MAX_PENDING_LINES)
        self.assertEqual(self.bridge.pending["A1"][0], "100")

    def test_link_lost(self):
        self.bridge.on_device_data("A1", b"1,2,3,4,5,6\npartial")
        self.bridge.on_device_disconnected("A1", "接続が切れました")
        status = self.of_type("status")[-1]
        self.assertEqual(status["error"], ble_bridge.ERR_LINK_LOST)
        self.assertFalse(status["connected"])
        # 切断前に届いていた完全な行は送られ、未完の行は捨てられる
        self.assertEqual(self.of_type("data")[0]["lines"], ["1,2,3,4,5,6"])
        self.assertNotIn("A1", self.bridge.assemblers)


class EarlyNotifyBackend(FakeBackend):
    """start_notify の直後（connect() が戻る前）に最初の通知が届く実機の順序を再現する。"""

    def __init__(self, first_chunk, stale_chunk=None):
        super().__init__()
        self.first_chunk = first_chunk
        self.stale_chunk = stale_chunk

    async def connect(self, address, timeout):
        self.connected.append(address)
        self._emit_data(address, self.first_chunk)
        return address


class ConnectOrderTest(BridgeTestBase):
    """PR #3 レビュー指摘: 接続直後の通知が行組み立てバッファの作り直しで消えないこと。"""

    def test_first_notification_during_connect_is_kept(self):
        self.backend = EarlyNotifyBackend(b"# model=M5StickCPlus2 name=M5-Sen")
        self.bridge = self.make_bridge()
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.bridge.on_device_data("A1", b"sor-1A2B rate=100\n0.0123,0.9811,-0.021")
        self.bridge.on_device_data("A1", b"0,1.250,-0.500,0.125\n")
        self.bridge.flush()
        lines = [line for m in self.of_type("data") for line in m["lines"]]
        self.assertEqual(lines, ["# model=M5StickCPlus2 name=M5-Sensor-1A2B rate=100",
                                 "0.0123,0.9811,-0.0210,1.250,-0.500,0.125"])

    def test_previous_session_fragment_is_discarded(self):
        # 前の接続で組み立て途中だったバイトは、次の接続に持ち越さない
        self.bridge.on_device_data("A1", b"12.5,0.0")
        self.backend = EarlyNotifyBackend(b"1,2,3,4,5,6\n")
        self.bridge.backend = self.bridge.backends[ble_bridge.KIND_BLE] = self.backend
        self.backend.on_data = self.bridge.on_device_data
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.bridge.flush()
        lines = [line for m in self.of_type("data") for line in m["lines"]]
        self.assertEqual(lines, ["1,2,3,4,5,6"])

    def test_data_is_not_sent_before_connected_status(self):
        self.backend = EarlyNotifyBackend(b"1,2,3,4,5,6\n")
        self.bridge = self.make_bridge()
        sent_during_connect = []
        original = self.backend.connect

        async def connect_and_flush(address, timeout):
            result = await original(address, timeout)
            sent_during_connect.append(self.bridge.flush())
            return result

        self.backend.connect = connect_and_flush
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.assertEqual(sent_during_connect, [0])
        self.bridge.flush()
        kinds = [(m["type"], m.get("state")) for m in self.out if m["type"] in ("status", "data")]
        self.assertEqual(kinds, [("status", "connecting"), ("status", "connected"), ("data", None)])

    def test_failed_connect_drops_buffers(self):
        self.backend.fail_connect = RuntimeError("boom")
        self.bridge.on_device_data("A1", b"partial")
        self.bridge.handle({"cmd": "connect", "address": "A1"})
        self.settle()
        self.assertNotIn("A1", self.bridge.assemblers)
        self.assertNotIn("A1", self.bridge.pending)


class MockFirmwareFormatTest(unittest.TestCase):
    """--mock の応答が実機ファーム（firmware/m5stick_sender README「コマンド」）と同じ形式であること。"""

    def setUp(self):
        self.dev = ble_bridge.MockDevice("AA", "M5-Sensor-MOCK1", -50, seed=1)
        self.dev.connected = True

    def test_ok_replies(self):
        self.assertEqual(self.dev.handle_command("PAUSE"), "# ok=PAUSE sending=0")
        self.assertTrue(self.dev.paused)
        self.assertEqual(self.dev.handle_command("resume\r\n"), "# ok=RESUME sending=1")
        self.assertFalse(self.dev.paused)
        self.assertEqual(self.dev.handle_command("  rate 50  "), "# ok=RATE rate=50")
        self.assertEqual(self.dev.rate, 50)

    def test_info_line(self):
        info = self.dev.handle_command("INFO")
        self.assertEqual(
            info,
            "# model=MOCK name=M5-Sensor-MOCK1 rate=100 ble=1 fw=mock imu=MOCK sending=1 connected=1 "
            "drop_usb=0 drop_ble=0")
        keys = [part.split("=")[0] for part in info[2:].split()]
        self.assertEqual(keys, ["model", "name", "rate", "ble", "fw", "imu", "sending", "connected",
                                "drop_usb", "drop_ble"])

    def test_error_replies(self):
        cases = {
            "RATE 5": "# error=rate_out_of_range value=5 min=10 max=200",
            "RATE 99999999": "# error=rate_out_of_range value=999999 min=10 max=200",
            "RATE": "# error=rate_missing min=10 max=200",
            "RATE -50": "# error=rate_not_number min=10 max=200",
            "RATE 50.5": "# error=rate_not_number min=10 max=200",
            "RATE 50 60": "# error=unexpected_argument commands=PAUSE,RESUME,RATE,INFO",
            "PAUSE now": "# error=unexpected_argument commands=PAUSE,RESUME,RATE,INFO",
            "DANCE": "# error=unknown_command commands=PAUSE,RESUME,RATE,INFO",
            "X" * 65: "# error=line_too_long max=64",
        }
        for command, expected in cases.items():
            self.assertEqual(self.dev.handle_command(command), expected, command)
        self.assertEqual(self.dev.rate, 100, "範囲外の RATE ではレートを変えない")
        self.assertFalse(self.dev.paused)

    def test_ignored_lines(self):
        self.assertIsNone(self.dev.handle_command(""))
        self.assertIsNone(self.dev.handle_command("   "))
        self.assertIsNone(self.dev.handle_command("# comment"))


class WatchdogTest(BridgeTestBase):
    def test_not_armed_before_first_contact(self):
        bridge = self.make_bridge(idle_timeout=10, managed=True)
        self.clock.now += 1000
        bridge.check_watchdog()
        self.assertFalse(bridge.stopping)

    def test_managed_bridge_exits_after_idle(self):
        bridge = self.make_bridge(idle_timeout=10, managed=True)
        bridge.handle({"cmd": "ping"})
        self.clock.now += 9
        bridge.check_watchdog()
        self.assertFalse(bridge.stopping)
        bridge.handle({"cmd": "ping"})
        self.clock.now += 9
        bridge.check_watchdog()
        self.assertFalse(bridge.stopping)
        self.clock.now += 2
        bridge.check_watchdog()
        self.assertTrue(bridge.stopping)

    def test_manual_bridge_disconnects_but_stays(self):
        bridge = self.make_bridge(idle_timeout=10, managed=False)
        self.backend.connected = ["A1"]
        bridge.handle({"cmd": "ping"})
        self.clock.now += 11
        bridge.check_watchdog()
        self.settle()
        self.assertFalse(bridge.stopping)
        self.assertEqual(self.backend.connected, [])
        self.assertIsNone(bridge.last_contact)

    def test_idle_timeout_zero_disables(self):
        bridge = self.make_bridge(idle_timeout=0, managed=True)
        bridge.handle({"cmd": "ping"})
        self.clock.now += 10000
        bridge.check_watchdog()
        self.assertFalse(bridge.stopping)

    def test_dead_parent_stops_bridge(self):
        bridge = self.make_bridge(managed=True, parent_pid=2 ** 22 + 12345)
        bridge.check_watchdog()
        self.assertTrue(bridge.stopping)

    def test_live_parent_keeps_bridge(self):
        bridge = self.make_bridge(managed=True, parent_pid=os.getpid())
        bridge.check_watchdog()
        self.assertFalse(bridge.stopping)


class BleakBackendWithoutBleakTest(unittest.TestCase):
    def test_missing_bleak_gives_install_hint(self):
        backend = ble_bridge.BleakBackend()
        backend._import_error = ble_bridge.BLEAK_INSTALL_HINT + "（詳細: No module named 'bleak'）"
        problem = backend.check()
        self.assertIsNotNone(problem)
        self.assertEqual(problem.code, ble_bridge.ERR_BLEAK_MISSING)
        self.assertIn("setup.sh", problem.message)
        self.assertIn("setup.bat", problem.message)


if __name__ == "__main__":
    unittest.main()
