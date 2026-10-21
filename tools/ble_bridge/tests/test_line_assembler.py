"""LineAssembler（通知の断片を改行で行に組み立てる）のテスト。"""

import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ble_bridge  # noqa: E402
from ble_bridge import LineAssembler, MockDevice  # noqa: E402


class LineAssemblerTest(unittest.TestCase):
    def test_single_complete_line(self):
        a = LineAssembler()
        self.assertEqual(a.feed(b"1,2,3,4,5,6\n"), ["1,2,3,4,5,6"])
        self.assertEqual(a.pending(), b"")

    def test_line_split_across_notifications(self):
        a = LineAssembler()
        self.assertEqual(a.feed(b"0.01,0.9"), [])
        self.assertEqual(a.feed(b"8,0.02,1"), [])
        self.assertEqual(a.feed(b".0,2.0,3.0\n0.5"), ["0.01,0.98,0.02,1.0,2.0,3.0"])
        self.assertEqual(a.pending(), b"0.5")

    def test_multiple_lines_in_one_notification(self):
        a = LineAssembler()
        self.assertEqual(a.feed(b"a\nb\nc\n"), ["a", "b", "c"])

    def test_crlf_and_blank_lines(self):
        a = LineAssembler()
        self.assertEqual(a.feed(b"x\r\n\r\n\ny\r\n"), ["x", "y"])

    def test_info_lines_are_passed_through(self):
        # '#' で始まる情報行はブリッジでは捨てず、アプリ側の判断に任せる
        a = LineAssembler()
        self.assertEqual(a.feed(b"# model=M5StickCPlus2 rate=100\n"), ["# model=M5StickCPlus2 rate=100"])

    def test_invalid_utf8_does_not_raise(self):
        a = LineAssembler()
        lines = a.feed(b"\xff\xfe1,2\n")
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].endswith("1,2"))

    def test_overlong_garbage_is_dropped(self):
        a = LineAssembler(max_line=16)
        self.assertEqual(a.feed(b"x" * 40), [])
        self.assertEqual(a.pending(), b"")
        self.assertEqual(a.feed(b"ok\n"), ["ok"])
        self.assertEqual(a.dropped, 1)

    def test_overlong_line_with_newline_is_dropped(self):
        a = LineAssembler(max_line=8)
        self.assertEqual(a.feed(b"0123456789\nshort\n"), ["short"])

    def test_reset(self):
        a = LineAssembler()
        a.feed(b"partial")
        a.reset()
        self.assertEqual(a.feed(b"next\n"), ["next"])

    def test_random_fragmentation_roundtrip(self):
        rng = random.Random(1234)
        expected = ["%d,%d,%d,%d,%d,%d" % tuple(rng.randint(-999, 999) for _ in range(6))
                    for _ in range(300)]
        stream = ("\n".join(expected) + "\n").encode()
        a = LineAssembler()
        got = []
        pos = 0
        while pos < len(stream):
            size = rng.randint(1, 23)
            got.extend(a.feed(stream[pos:pos + size]))
            pos += size
        self.assertEqual(got, expected)


class MockDeviceSplitTest(unittest.TestCase):
    def test_mock_notifications_split_lines_but_reassemble(self):
        dev = MockDevice("AA", "M5-Sensor-MOCK1", -50, seed=7)
        a = LineAssembler()
        produced = []
        received = []
        split_seen = False
        for _ in range(50):
            batch = [dev.make_line() for _ in range(2)]
            produced.extend(batch)
            for chunk in dev.split_notifications(("\n".join(batch) + "\n").encode()):
                if not chunk.endswith(b"\n"):
                    split_seen = True
                received.extend(a.feed(chunk))
        # 持ち越し分を出し切る
        for chunk in dev.split_notifications(b""):
            received.extend(a.feed(chunk))
        received.extend(a.feed(dev._pending))
        self.assertTrue(split_seen, "mock は行を通知の境界で分割するはず")
        self.assertEqual(received, produced)
        for line in received:
            self.assertEqual(len(line.split(",")), 6)
            [float(v) for v in line.split(",")]

    def test_mock_rate_affects_phase_step(self):
        dev = MockDevice("AA", "M5-Sensor-MOCK1", -50, seed=1)
        dev.rate = 200
        dev.make_line()
        self.assertAlmostEqual(dev._phase, 0.03)


class ClassifyErrorTest(unittest.TestCase):
    def test_classify(self):
        c = ble_bridge.classify_ble_error
        self.assertEqual(c(Exception("BLE is not authorized - check macOS privacy settings"), "x").code,
                         ble_bridge.ERR_UNAUTHORIZED)
        self.assertEqual(c(Exception("Bluetooth device is turned off"), "x").code,
                         ble_bridge.ERR_BLUETOOTH_OFF)
        self.assertEqual(c(Exception("No Bluetooth adapters found."), "x").code,
                         ble_bridge.ERR_NO_ADAPTER)
        self.assertEqual(c(Exception("something else"), "scan_failed").code, "scan_failed")


if __name__ == "__main__":
    unittest.main()
