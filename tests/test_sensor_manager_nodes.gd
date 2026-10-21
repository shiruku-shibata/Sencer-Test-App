extends "res://tests/test_case.gd"
## 1本の線で複数ノードを中継する機器（Beer-fw ゲートウェイ）の振り分けのテスト。

const PORT := "/dev/cu.usbserial-TEST"

var _manager: SensorManager


func before_each() -> void:
	_manager = SensorManager.new()   # ツリーに入れない（Provider は作らない）
	var parent := SensorDevice.new(PORT, SensorDevice.Mode.SERIAL)
	parent.connected = true
	_manager.registry.upsert(parent)


func after_each() -> void:
	_manager.free()


func _reading(node: int, mac: String = "") -> SensorReading:
	var r := SensorReading.new(PORT, 1000, Vector3(0, 0, 1), Vector3.ZERO)
	r.source_node = node
	r.source_mac = mac
	return r


func test_id_helpers() -> void:
	assert_eq(SensorManager.node_device_id(PORT, 1), PORT + "#node1")
	assert_eq(SensorManager.parent_id_of(PORT + "#node1"), PORT)
	assert_eq(SensorManager.parent_id_of(PORT), PORT, "子でなければそのまま")
	assert_eq(SensorManager.parent_id_of("demo-01"), "demo-01")


func test_reading_is_routed_to_node_device() -> void:
	var received: Array = []
	_manager.reading_received.connect(func(r: SensorReading) -> void: received.append(r))
	_manager._on_reading_received(_reading(1, "64:B7:08:85:64:54"))
	var child := _manager.registry.get_device(PORT + "#node1")
	assert_not_null(child, "ノード 1 が一覧に足される")
	assert_true(child.connected, "受信したので接続中")
	assert_eq(child.mode, SensorDevice.Mode.SERIAL, "親と同じ方式")
	assert_contains(child.display_name(), "64:B7:08:85:64:54")
	assert_eq(received.size(), 1)
	assert_eq((received[0] as SensorReading).device_id, PORT + "#node1")
	assert_eq(child.sample_count, 1)


func test_nodes_are_separate_devices() -> void:
	_manager._on_reading_received(_reading(0))
	_manager._on_reading_received(_reading(1))
	_manager._on_reading_received(_reading(1))
	assert_eq(_manager.registry.get_device(PORT + "#node0").sample_count, 1)
	assert_eq(_manager.registry.get_device(PORT + "#node1").sample_count, 2)
	var ids: Array = []
	for d in _manager.registry.connected_devices():
		ids.append(d.id)
	assert_has(ids, PORT + "#node0")
	assert_has(ids, PORT + "#node1")


func test_reading_without_node_is_untouched() -> void:
	var r := SensorReading.new(PORT, 1000, Vector3(0, 0, 1), Vector3.ZERO)
	_manager._on_reading_received(r)
	assert_eq(r.device_id, PORT)
	assert_null(_manager.registry.get_device(PORT + "#node0"))


func test_parent_disconnect_disconnects_nodes() -> void:
	_manager._on_reading_received(_reading(1))
	_manager._on_connection_changed(PORT, false)
	assert_false(_manager.registry.get_device(PORT + "#node1").connected)
	# 再接続して受信すれば、また接続中になる
	_manager._on_connection_changed(PORT, true)
	_manager._on_reading_received(_reading(1))
	assert_true(_manager.registry.get_device(PORT + "#node1").connected)


func test_line_log_of_node_device_reads_parent() -> void:
	var line_log := DeviceLineLog.new()
	line_log.record(PORT, "# ok=PAUSE sending=0")
	assert_eq(line_log.reply(PORT + "#node1"), line_log.reply(PORT), "子からも親の応答が見える")
	assert_false(line_log.reply(PORT).is_empty())
