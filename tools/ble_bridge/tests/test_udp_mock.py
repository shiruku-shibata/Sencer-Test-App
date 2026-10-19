"""--mock で起動したブリッジと、実際に UDP で往復する結合テスト。"""

import json
import os
import socket
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(os.path.dirname(HERE), "ble_bridge.py")
MOCK1 = "AA:BB:CC:00:00:01"
MOCK2 = "AA:BB:CC:00:00:02"


def free_udp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class UdpClient:
    """アプリ側の代わり。"""

    def __init__(self, bridge_port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        self.port = self.sock.getsockname()[1]
        self.bridge_port = bridge_port
        self.received = []

    def send(self, message):
        self.sock.sendto(json.dumps(message).encode(), ("127.0.0.1", self.bridge_port))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            self.received.append(json.loads(data.decode("utf-8")))

    def wait_for(self, predicate, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            for m in self.received:
                if predicate(m):
                    return m
            self.pump(0.05)
        return None

    def take(self, kind):
        found = [m for m in self.received if m.get("type") == kind]
        self.received = [m for m in self.received if m.get("type") != kind]
        return found

    def close(self):
        self.sock.close()


class MockBridgeUdpTest(unittest.TestCase):
    def start_bridge(self, *extra):
        self.bridge_port = free_udp_port()
        self.client = UdpClient(self.bridge_port)
        self.proc = subprocess.Popen(
            [sys.executable, BRIDGE, "--mock", "--port", str(self.bridge_port),
             "--app-port", str(self.client.port)] + list(extra),
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        hello = None
        end = time.time() + 10
        while hello is None and time.time() < end:
            self.client.send({"cmd": "hello"})
            hello = self.client.wait_for(lambda m: m.get("type") == "hello", timeout=0.3)
        self.assertIsNotNone(hello, "ブリッジが hello に応答しない")
        self.client.take("hello")
        return hello

    def tearDown(self):
        proc = getattr(self, "proc", None)
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(5)
        if proc is not None and proc.stderr is not None:
            proc.stderr.close()
        client = getattr(self, "client", None)
        if client is not None:
            client.close()

    def lines_for(self, address):
        lines = []
        for m in self.client.take("data"):
            if m["address"] == address:
                lines.extend(m["lines"])
            else:
                self.client.received.append(m)
        return lines

    def test_full_session(self):
        self.start_bridge()

        # scan（既定は M5 センサーだけ）
        self.client.send({"cmd": "scan", "timeout": 1})
        devices = self.client.wait_for(lambda m: m.get("type") == "devices")
        self.assertIsNotNone(devices)
        names = sorted(d["name"] for d in devices["devices"])
        self.assertEqual(names, ["M5-Sensor-MOCK1", "M5-Sensor-MOCK2"])
        self.client.take("devices")

        # --all 相当
        self.client.send({"cmd": "scan", "timeout": 1, "all": True})
        devices = self.client.wait_for(lambda m: m.get("type") == "devices")
        self.assertEqual(len(devices["devices"]), 3)
        self.client.take("devices")

        # 2台同時に接続
        self.client.send({"cmd": "connect", "address": MOCK1})
        self.client.send({"cmd": "connect", "address": MOCK2})
        for address in (MOCK1, MOCK2):
            ok = self.client.wait_for(lambda m, a=address: m.get("type") == "status"
                                      and m["address"] == a and m["connected"])
            self.assertIsNotNone(ok, "接続できない: %s" % address)

        self.client.pump(1.0)
        lines1 = self.lines_for(MOCK1)
        lines2 = self.lines_for(MOCK2)
        self.assertTrue(lines1[0].startswith("# model=MOCK name=M5-Sensor-MOCK1 rate=100 ble=1"),
                        "購読直後の最初の行は情報行: %r" % lines1[:1])
        csv1 = [line for line in lines1 if not line.startswith("#")]
        self.assertGreater(len(csv1), 50, "100Hz 前後で届くはず")
        self.assertGreater(len(lines2), 50)
        for line in csv1:
            values = [float(v) for v in line.split(",")]
            self.assertEqual(len(values), 6)

        # PAUSE で止まり、RESUME で再開する
        self.client.send({"cmd": "send", "address": MOCK1, "line": "PAUSE"})
        self.client.pump(0.3)
        # 応答は実機ファームと同じ形式で、サンプル行の途中に割り込まず1行として届く
        self.assertIn("# ok=PAUSE sending=0", self.lines_for(MOCK1))
        self.client.pump(0.5)
        paused = [line for line in self.lines_for(MOCK1) if not line.startswith("#")]
        self.assertEqual(paused, [])
        self.client.send({"cmd": "send", "address": MOCK1, "line": "RESUME"})
        self.client.pump(0.5)
        self.assertGreater(len(self.lines_for(MOCK1)), 10)

        # RATE で頻度が変わる
        self.client.send({"cmd": "send", "address": MOCK1, "line": "RATE 20"})
        self.client.pump(0.3)
        self.lines_for(MOCK1)
        self.client.pump(1.0)
        slow = [line for line in self.lines_for(MOCK1) if not line.startswith("#")]
        self.assertLess(len(slow), 40)
        self.assertGreater(len(slow), 5)

        # ping で接続中一覧が返る
        self.client.send({"cmd": "ping"})
        pong = self.client.wait_for(lambda m: m.get("type") == "pong")
        self.assertEqual(sorted(pong["connected"]), [MOCK1, MOCK2])

        # 切断検知（mock 専用コマンドで電波断を再現）
        self.client.send({"cmd": "send", "address": MOCK2, "line": "MOCK_DROP"})
        lost = self.client.wait_for(lambda m: m.get("type") == "status" and m["address"] == MOCK2
                                    and m["state"] == "disconnected")
        self.assertEqual(lost["error"], "link_lost")

        # 通常の切断
        self.client.send({"cmd": "disconnect", "address": MOCK1})
        done = self.client.wait_for(lambda m: m.get("type") == "status" and m["address"] == MOCK1
                                    and m["state"] == "disconnected")
        self.assertIsNotNone(done)

        # 不正な入力でも落ちない
        self.client.sock.sendto(b"\x00garbage", ("127.0.0.1", self.bridge_port))
        self.client.send({"cmd": "ping"})
        self.assertIsNotNone(self.client.wait_for(lambda m: m.get("type") == "log"))

        # quit で終了する
        self.client.send({"cmd": "quit"})
        self.assertEqual(self.proc.wait(5), 0)

    def test_connect_non_sensor_fails_gracefully(self):
        self.start_bridge()
        self.client.send({"cmd": "connect", "address": "AA:BB:CC:00:00:99"})
        status = self.client.wait_for(lambda m: m.get("type") == "status" and m["state"] == "disconnected")
        self.assertEqual(status["error"], "connect_failed")
        self.client.send({"cmd": "connect", "address": "NO:SU:CH"})
        status = self.client.wait_for(lambda m: m.get("type") == "status" and m["address"] == "NO:SU:CH"
                                      and m["state"] == "disconnected")
        self.assertIsNotNone(status)
        self.assertIsNone(self.proc.poll())

    def test_managed_bridge_exits_when_app_goes_silent(self):
        self.start_bridge("--parent-pid", str(os.getpid()), "--idle-timeout", "1")
        self.client.send({"cmd": "ping"})   # 最初の連絡で見張りが有効になる
        self.assertEqual(self.proc.wait(5), 0)

    def test_managed_bridge_exits_when_parent_dies(self):
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            self.start_bridge("--parent-pid", str(parent.pid), "--idle-timeout", "0")
            parent.kill()
            parent.wait(5)
            self.assertEqual(self.proc.wait(5), 0)
        finally:
            if parent.poll() is None:
                parent.kill()

    def test_manual_bridge_survives_silence(self):
        self.start_bridge("--idle-timeout", "1")
        self.client.send({"cmd": "connect", "address": MOCK1})
        self.assertIsNotNone(self.client.wait_for(lambda m: m.get("type") == "status" and m["connected"]))
        self.client.received = []
        self.client.pump(2.0)
        self.assertIsNone(self.proc.poll(), "手動起動のブリッジは終了しない")
        lost = [m for m in self.client.received if m.get("type") == "status" and not m["connected"]]
        self.assertTrue(lost, "応答が途絶えたらデバイスは切断される")

    def test_port_in_use(self):
        blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        blocker.bind(("127.0.0.1", 0))
        port = blocker.getsockname()[1]
        try:
            proc = subprocess.run(
                [sys.executable, BRIDGE, "--mock", "--port", str(port)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
            )
            self.assertEqual(proc.returncode, 2)
            self.assertIn("UDP ポート", proc.stderr.decode("utf-8"))
        finally:
            blocker.close()


class ScanOnceTest(unittest.TestCase):
    def test_scan_once_mock(self):
        proc = subprocess.run([sys.executable, BRIDGE, "--mock", "--scan-once", "--scan-timeout", "1"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("M5-Sensor-MOCK1", proc.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
