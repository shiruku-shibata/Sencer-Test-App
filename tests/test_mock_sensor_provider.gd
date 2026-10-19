extends "res://tests/test_case.gd"
## MockSensorProvider（デモデバイス）の基本動作のテスト。


func before_each() -> void:
	seed(12345)


func test_mode_and_availability() -> void:
	var p := MockSensorProvider.new()
	assert_eq(p.get_mode(), SensorDevice.Mode.MOCK)
	assert_true(p.is_available())
	assert_eq(p.unavailable_reason(), "")


func test_scan_lists_demo_devices() -> void:
	var p := MockSensorProvider.new()
	var changed := [0]
	p.device_list_changed.connect(func() -> void: changed[0] += 1)
	var devices := p.scan()
	assert_eq(devices.size(), MockSensorProvider.DEVICE_IDS.size())
	for d in devices:
		assert_true(d is SensorDevice)
		assert_eq(d.mode, SensorDevice.Mode.MOCK)
		assert_false(d.connected)
	assert_eq(changed[0], 1)


func test_open_and_close() -> void:
	var p := MockSensorProvider.new()
	var events: Array = []
	p.connection_changed.connect(func(id: String, c: bool) -> void: events.append([id, c]))
	assert_false(p.open_device("nope"), "存在しないデバイス")
	assert_true(p.open_device("demo-01"))
	assert_true(p.scan()[0].connected)
	p.close_device("demo-01")
	assert_false(p.scan()[0].connected)
	assert_eq(events, [["demo-01", true], ["demo-01", false]])


func test_poll_emits_readings_at_100hz() -> void:
	var p := MockSensorProvider.new()
	var got: Array = []
	p.reading_received.connect(func(r: SensorReading) -> void: got.append(r))
	p.poll(0.5)
	assert_eq(got.size(), 0, "未接続なら何も出さない")
	p.open_device("demo-01")
	p.poll(0.105)
	assert_ge(float(got.size()), 9.0)
	assert_le(float(got.size()), 11.0)
	for r in got:
		assert_eq(r.device_id, "demo-01")
		assert_true(is_finite(r.accel.x) and is_finite(r.gyro.z))
		assert_lt(absf(r.accel.y - 0.98), 1.0, "Y 軸に重力 1G 前後")


func test_poll_emits_for_each_open_device() -> void:
	var p := MockSensorProvider.new()
	var ids: Dictionary = {}
	p.reading_received.connect(func(r: SensorReading) -> void: ids[r.device_id] = true)
	p.open_device("demo-01")
	p.open_device("demo-02")
	p.poll(0.05)
	assert_eq(ids.size(), 2)
	p.close_device("demo-01")
	ids.clear()
	p.poll(0.05)
	assert_eq(ids.keys(), ["demo-02"])


func test_mock_data_works_with_analyzer() -> void:
	# デモデータでも一連の解析が回る（受け入れ条件1の下地）
	var p := MockSensorProvider.new()
	var a := ThresholdAnalyzer.new()
	a.set_axes([SensorAxis.Id.GX])
	p.reading_received.connect(a.feed)
	p.open_device("demo-01")
	a.start_baseline(200)
	# モックの timestamp_ms は実時間（Time.get_ticks_msec）なので、実際に時間を進める
	for _i in 60:
		p.poll(0.01)
		OS.delay_msec(5)
	assert_true(a.has_baseline(), "受信サンプルの時刻で静止測定が終わる")
	p.reading_received.disconnect(a.feed)
