extends "res://tests/test_case.gd"
## LoggingService（CSV 記録）のテスト。保存先は一時フォルダに差し替える。

const AX := SensorAxis.Id.AX
const GZ := SensorAxis.Id.GZ


func _logger() -> LoggingService:
	var l := LoggingService.new()
	l.log_dir = make_temp_dir()
	return l


func _device(id: String = "dev-1", nickname: String = "") -> SensorDevice:
	var d := SensorDevice.new(id, SensorDevice.Mode.MOCK)
	d.nickname = nickname
	return d


func _reading(device_id: String, ts: int) -> SensorReading:
	return SensorReading.new(device_id, ts, Vector3(0.1, -0.25, 1.0), Vector3(12.5, -3.0, 250.125))


func _lines(path: String) -> PackedStringArray:
	return FileAccess.get_file_as_string(path).strip_edges().split("\n")


func test_default_records_raw_six_axes() -> void:
	var l := _logger()
	assert_true(l.start(_device()), "既存の start(device) 呼び出しのまま使える")
	assert_eq(l.current_axes(), SensorAxis.RAW)
	l.write(_reading("dev-1", 1234))
	var info := l.stop()
	var lines := _lines(info["path"])
	assert_eq(lines.size(), 3)
	assert_eq(lines[0], "# device_id=dev-1 nickname=dev-1 axes=ax,ay,az,gx,gy,gz")
	assert_eq(lines[1], "timestamp_ms,ax,ay,az,gx,gy,gz")
	assert_eq(lines[1], SensorReading.csv_header(), "P1 と同じヘッダ")
	assert_eq(lines[2], _reading("dev-1", 1234).to_csv_row(), "P1 と同じ行")
	assert_eq(info["rows"], 1)


func test_selected_axes_only() -> void:
	var l := _logger()
	assert_true(l.start(_device("dev-1", "右手"), [GZ, AX]))
	assert_eq(l.current_axes(), [AX, GZ] as Array[int], "列は SensorAxis.ALL の順")
	l.write(_reading("dev-1", 10))
	l.write(_reading("dev-1", 20))
	var info := l.stop()
	var lines := _lines(info["path"])
	assert_eq(lines[0], "# device_id=dev-1 nickname=右手 axes=ax,gz")
	assert_eq(lines[1], "timestamp_ms,ax,gz")
	assert_eq(lines[2], "10,0.1000,250.125")
	assert_eq(lines[3], "20,0.1000,250.125")
	assert_eq(lines.size(), 4)
	assert_eq(info["axes"], [AX, GZ])


func test_magnitude_columns() -> void:
	var l := _logger()
	l.start(_device(), [SensorAxis.Id.ACCEL_MAG, SensorAxis.Id.GYRO_MAG])
	l.write(SensorReading.new("dev-1", 5, Vector3(3, 4, 0), Vector3(0, 6, 8)))
	var lines := _lines(l.stop()["path"])
	assert_eq(lines[1], "timestamp_ms,amag,gmag")
	assert_eq(lines[2], "5,5.0000,10.000")


func test_invalid_and_duplicate_axes() -> void:
	var l := _logger()
	l.start(_device(), [GZ, GZ, 99, -1])
	assert_eq(l.current_axes(), [GZ] as Array[int])
	l.stop()
	l.start(_device(), [99])
	assert_eq(l.current_axes(), SensorAxis.RAW, "有効な軸が無ければ6軸")
	l.stop()


func test_ignores_other_devices() -> void:
	var l := _logger()
	l.start(_device("dev-1"), [GZ])
	l.write(_reading("dev-2", 10))
	l.write(_reading("dev-1", 20))
	l.write(null)
	assert_eq(l.row_count(), 1)
	assert_eq(l.stop()["rows"], 1)


func test_cannot_start_twice_and_stop_when_idle() -> void:
	var l := _logger()
	assert_eq(l.stop(), {}, "記録していないときの stop は空")
	assert_true(l.start(_device()))
	assert_false(l.start(_device()), "記録中は開始できない")
	assert_false(l.start(null))
	l.stop()
	assert_false(l.is_recording())
	assert_eq(l.current_axes(), [] as Array[int])


func test_signals() -> void:
	var l := _logger()
	var started: Array = []
	var stopped: Array = []
	l.recording_started.connect(func(path: String) -> void: started.append(path))
	l.recording_stopped.connect(func(info: Dictionary) -> void: stopped.append(info))
	l.start(_device())
	l.stop()
	assert_eq(started.size(), 1)
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0]["path"], started[0])


func test_file_names_are_safe_and_unique() -> void:
	var l := _logger()
	var d := _device("AA:BB:CC:DD", "my device/1")
	l.start(d)
	var p1 := l.current_path()
	l.stop()
	l.start(d)
	var p2 := l.current_path()
	l.stop()
	assert_ne(p1, p2, "同じ秒に開始しても別ファイル")
	assert_eq(p1.get_base_dir(), l.log_dir)
	assert_not_contains(p1.get_file(), ":")
	assert_not_contains(p1.get_file(), " ")
	assert_contains(p1.get_file(), "my_device-1")


func test_list_and_delete_logs() -> void:
	var l := _logger()
	l.start(_device())
	var path := l.current_path()
	l.stop()
	write_text(l.log_dir.path_join("note.txt"), "csv 以外")
	var logs := l.list_logs()
	assert_eq(logs.size(), 1)
	assert_eq(logs[0]["path"], path)
	assert_gt(float(logs[0]["size"]), 0.0)
	l.delete_log(path)
	assert_eq(l.list_logs().size(), 0)


func test_roundtrip_with_log_replay() -> void:
	var l := _logger()
	l.start(_device("dev-9"), [AX, GZ])
	for i in 5:
		l.write(SensorReading.new("dev-9", 1000 + i * 10, Vector3(0.5 * i, 9, 9), Vector3(9, 9, -20.0 * i)))
	var path := l.current_path()
	l.stop()
	var readings := LogReplay.load_csv(path)
	assert_eq(readings.size(), 5)
	assert_eq(LogReplay.axes_in(path), [AX, GZ] as Array[int])
	for i in 5:
		assert_eq(readings[i].timestamp_ms, 1000 + i * 10)
		assert_eq(readings[i].device_id, "dev-9")
		assert_almost_eq(readings[i].accel.x, 0.5 * i)
		assert_almost_eq(readings[i].gyro.z, -20.0 * i)
		assert_almost_eq(readings[i].accel.y, 0.0, 1e-6, "記録しなかった軸は 0")
