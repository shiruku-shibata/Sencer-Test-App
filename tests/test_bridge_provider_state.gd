extends "res://tests/test_case.gd"
## BleSensorProvider / BridgeSerialSensorProvider の、ブリッジからのメッセージに対する接続状態の扱い
## （UDP もブリッジも使わず、受け取ったメッセージを直接渡す）と、手動起動コマンドの引用。

const ADDR := "AA:BB:CC:DD:EE:FF"

var _events: Array = []


func before_each() -> void:
	_events = []


func _ble() -> BleSensorProvider:
	var p := BleSensorProvider.new()
	p._state = BleSensorProvider.State.READY   # hello を受け取った後と同じ（UDP は開かない＝送信は捨てられる）
	p.connection_changed.connect(func(id: String, c: bool) -> void: _events.append([id, c]))
	return p


## 切断を押した直後に、切断を送る前のブリッジが出した pong（connected にまだその機器が入っている）が届いても、
## 接続済みに戻さない（PR #11 レビュー 未確認の懸念: 一瞬「接続 → 切断」と見えていた）。
func test_ble_stale_pong_after_close_does_not_reconnect() -> void:
	var p := _ble()
	p._handle_message({"type": "status", "address": ADDR, "connected": true, "state": "connected"})
	assert_eq(_events, [[ADDR, true]])
	p.close_device(ADDR)
	assert_eq(_events, [[ADDR, true], [ADDR, false]], "押した時点で切断扱い")
	p._handle_message({"type": "pong", "connected": [ADDR]})   # 切断前に出た pong
	p._handle_message({"type": "hello", "protocol": 1, "connected": [ADDR]})
	assert_eq(_events, [[ADDR, true], [ADDR, false]], "古い pong / hello で接続済みに戻らない")
	p._handle_message({"type": "status", "address": ADDR, "connected": false, "state": "disconnected"})
	assert_eq(_events.size(), 2, "切断完了で余計な通知は出ない")
	# 切断が終わった後なら、ブリッジが接続していると言えば（手動起動のブリッジで再接続した等）従う
	p._handle_message({"type": "pong", "connected": [ADDR]})
	assert_eq(_events[-1], [ADDR, true])
	p.shutdown()


func test_ble_reopen_after_close_works() -> void:
	var p := _ble()
	p._handle_message({"type": "status", "address": ADDR, "connected": true, "state": "connected"})
	p.close_device(ADDR)
	assert_true(p.open_device(ADDR), "切断待ちの間に接続し直してもよい")
	p._handle_message({"type": "status", "address": ADDR, "connected": true, "state": "connected"})
	assert_eq(_events[-1], [ADDR, true], "接続し直しは打ち消されない")
	p.shutdown()


func test_bridge_serial_stale_pong_after_close_does_not_reconnect() -> void:
	var host := _ble()
	var serial := BridgeSerialSensorProvider.new(host)
	var events: Array = []
	serial.connection_changed.connect(func(id: String, c: bool) -> void: events.append([id, c]))
	host._handle_message({"type": "hello", "protocol": 1, "connected": [],
			"serial": {"ready": true, "connected": []}})
	host._handle_message({"type": "status", "kind": "serial", "address": "COM5", "connected": true, "state": "connected"})
	assert_eq(events, [["COM5", true]])
	serial.close_device("COM5")
	host._handle_message({"type": "pong", "connected": [], "serial_connected": ["COM5"]})
	assert_eq(events, [["COM5", true], ["COM5", false]], "古い pong で接続済みに戻らない")
	host._handle_message({"type": "status", "kind": "serial", "address": "COM5", "connected": false, "state": "disconnected"})
	host._handle_message({"type": "pong", "connected": [], "serial_connected": ["COM5"]})
	assert_eq(events[-1], ["COM5", true], "切断完了後はブリッジの一覧に従う")
	host.shutdown()


# ------------------------------------------------------------ 手動起動コマンドの引用（PR #11 レビュー 低-1）

func test_shell_quote_quotes_shell_metacharacters() -> void:
	assert_eq(BleSensorProvider._shell_quote("/usr/bin/python3", false), "/usr/bin/python3", "普通のパスはそのまま")
	assert_eq(BleSensorProvider._shell_quote("/a/b-c_d.e/x+y=1:2,3@4%5.py", false), "/a/b-c_d.e/x+y=1:2,3@4%5.py")
	for path in ["/Users/a/R&D/ble_bridge.py", "/Users/a/$HOME/x.py", "/Users/a/p(1)/x.py",
			"/Users/a/My App/x.py", "/a;b", "/a`b`", "/a*b", "~/x.py", "/a!b", "/日本語/x.py"]:
		assert_eq(BleSensorProvider._shell_quote(path, false), "'%s'" % path, path)
	assert_eq(BleSensorProvider._shell_quote("/a/it's.py", false), "'/a/it'\\''s.py'")
	assert_eq(BleSensorProvider._shell_quote("", false), "''")
	assert_eq(BleSensorProvider._shell_quote("C:\\Program Files\\x.py", true), "\"C:\\Program Files\\x.py\"")
