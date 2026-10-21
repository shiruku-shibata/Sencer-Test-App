extends "res://tests/test_case.gd"
## DeviceCommand（コマンドと '#' 行の解析・ファーム互換の応答）、DeviceLineLog（'#' 行の記録）、
## MockSensorProvider のコマンド応答のテスト。


func _state() -> Dictionary:
	return {"rate": 100, "sending": true}


func _emulate(line: String, state: Dictionary) -> String:
	return DeviceCommand.emulate(line, state, func() -> String: return "# model=X rate=%d" % int(state["rate"]))


# ---------------------------------------------------------------- 解析

func test_parse_fields() -> void:
	var f := DeviceCommand.parse_fields("# model=M5StickCPlus2 name=M5-Sensor-1A2B rate=100 sending=1")
	assert_eq(f["model"], "M5StickCPlus2")
	assert_eq(f["rate"], "100")
	assert_eq(f.size(), 4)
	assert_eq(DeviceCommand.parse_fields("#ok=PAUSE sending=0"), {"ok": "PAUSE", "sending": "0"})
	assert_eq(DeviceCommand.parse_fields("# hello world"), {}, "値の無い語は無視")


func test_parse_fields_matches_ble_provider() -> void:
	for text in ["# model=M5 rate=50", "# error=rate_out_of_range value=5 min=10 max=200", "#", "# a= =b c=d"]:
		assert_eq(DeviceCommand.parse_fields(text), BleSensorProvider.parse_info_fields(text), text)


func test_kind_of() -> void:
	assert_eq(DeviceCommand.kind_of("# ok=PAUSE sending=0"), DeviceCommand.KIND_OK)
	assert_eq(DeviceCommand.kind_of("# error=rate_missing min=10 max=200"), DeviceCommand.KIND_ERROR)
	assert_eq(DeviceCommand.kind_of("# event=button sending=1"), DeviceCommand.KIND_EVENT)
	assert_eq(DeviceCommand.kind_of("# model=M5StickCPlus2 rate=100"), DeviceCommand.KIND_INFO)
	assert_eq(DeviceCommand.kind_of("# something"), DeviceCommand.KIND_OTHER)


func test_settings_from() -> void:
	assert_eq(DeviceCommand.settings_from("# ok=RATE rate=50"), {"rate": 50})
	assert_eq(DeviceCommand.settings_from("# ok=PAUSE sending=0"), {"sending": false})
	assert_eq(DeviceCommand.settings_from("# model=A rate=200 sending=1"), {"rate": 200, "sending": true})
	assert_eq(DeviceCommand.settings_from("# error=rate_out_of_range value=5 min=10 max=200"), {},
			"エラー行の value は設定ではない")
	assert_eq(DeviceCommand.settings_from("# model=A rate=abc sending=2"), {}, "数値でない値は使わない")


func test_is_reply_to() -> void:
	assert_true(DeviceCommand.is_reply_to("PAUSE", "# ok=PAUSE sending=0"))
	assert_false(DeviceCommand.is_reply_to("PAUSE", "# ok=RESUME sending=1"))
	assert_true(DeviceCommand.is_reply_to("RATE 50", "# ok=RATE rate=50"))
	assert_true(DeviceCommand.is_reply_to("RATE 5", "# error=rate_out_of_range value=5 min=10 max=200"))
	assert_true(DeviceCommand.is_reply_to("INFO", "# model=M5 rate=100"))
	assert_false(DeviceCommand.is_reply_to("INFO", "# ok=PAUSE sending=0"))
	assert_false(DeviceCommand.is_reply_to("PAUSE", "# model=M5 rate=100"), "接続時の情報行は PAUSE の応答ではない")
	assert_false(DeviceCommand.is_reply_to("PAUSE", "# event=button sending=0"), "本体操作は応答ではない")
	assert_false(DeviceCommand.is_reply_to("INFO", "# error=imu_not_found"), "5秒おきのエラーは応答ではない")


func test_rate_command() -> void:
	assert_eq(DeviceCommand.rate_command(50), "RATE 50")


# ---------------------------------------------------------------- ファーム互換の応答

func test_emulate_ok_replies() -> void:
	var s := _state()
	assert_eq(_emulate("PAUSE", s), "# ok=PAUSE sending=0")
	assert_false(s["sending"])
	assert_eq(_emulate("resume", s), "# ok=RESUME sending=1", "大文字小文字は区別しない")
	assert_true(s["sending"])
	assert_eq(_emulate("  RATE 50 ", s), "# ok=RATE rate=50", "前後の空白は無視")
	assert_eq(s["rate"], 50)
	assert_eq(_emulate("INFO", s), "# model=X rate=50")
	assert_eq(_emulate("RATE 10", s), "# ok=RATE rate=10", "下限")
	assert_eq(_emulate("RATE 200", s), "# ok=RATE rate=200", "上限")


func test_emulate_errors_match_firmware() -> void:
	var s := _state()
	assert_eq(_emulate("RATE 5", s), "# error=rate_out_of_range value=5 min=10 max=200")
	assert_eq(_emulate("RATE 201", s), "# error=rate_out_of_range value=201 min=10 max=200")
	assert_eq(_emulate("RATE 12345678", s), "# error=rate_out_of_range value=999999 min=10 max=200")
	assert_eq(_emulate("RATE", s), "# error=rate_missing min=10 max=200")
	for bad in ["-50", "+50", "50.5", "0x20", "abc"]:
		assert_eq(_emulate("RATE " + bad, s), "# error=rate_not_number min=10 max=200", bad)
	assert_eq(_emulate("RATE 50 60", s), "# error=unexpected_argument commands=PAUSE,RESUME,RATE,INFO")
	assert_eq(_emulate("PAUSE now", s), "# error=unexpected_argument commands=PAUSE,RESUME,RATE,INFO")
	assert_eq(_emulate("JUMP", s), "# error=unknown_command commands=PAUSE,RESUME,RATE,INFO")
	assert_eq(_emulate("X".repeat(65), s), "# error=line_too_long max=64")
	assert_eq(s, _state(), "エラーでは設定は変わらない")
	assert_eq(_emulate("", s), "", "空行は応答なし")
	assert_eq(_emulate("# comment", s), "", "# 行は応答なし")


# ---------------------------------------------------------------- DeviceLineLog

func test_line_log_records_and_classifies() -> void:
	var log_ := DeviceLineLog.new()
	assert_eq(log_.last_seq(), 0)
	log_.record("d1", "0.1,0.2,0.3,1,2,3")
	assert_eq(log_.last_seq(), 0, "'#' 以外は記録しない")
	log_.record("d1", "# model=M5 rate=100 sending=1\r")
	log_.record("d1", "# ok=RATE rate=50")
	log_.record("d2", "# error=imu_not_found")
	assert_eq(log_.info("d1"), "# model=M5 rate=100 sending=1")
	assert_eq(log_.reply("d1"), "# ok=RATE rate=50")
	assert_eq(log_.settings("d1"), {"rate": 50, "sending": true}, "新しい行の値で上書き")
	assert_eq(log_.reply("d2"), "# error=imu_not_found")
	assert_eq(log_.last_seq(), 3)
	var lines := log_.lines("d1")
	assert_eq(lines.size(), 2)
	assert_eq(lines[1], {"seq": 2, "text": "# ok=RATE rate=50"})
	assert_eq(log_.info("none"), "")
	assert_eq(log_.lines("none"), [])
	assert_eq(log_.settings("none"), {})


func test_line_log_limits_history_and_clear() -> void:
	var log_ := DeviceLineLog.new()
	for i in DeviceLineLog.MAX_LINES + 5:
		log_.record("d", "# event=button sending=%d" % (i % 2))
	var lines := log_.lines("d")
	assert_eq(lines.size(), DeviceLineLog.MAX_LINES)
	assert_eq(int(lines[-1]["seq"]), DeviceLineLog.MAX_LINES + 5)
	lines.clear()
	assert_eq(log_.lines("d").size(), DeviceLineLog.MAX_LINES, "返り値を変えても内部は変わらない")
	log_.clear("d")
	assert_eq(log_.lines("d"), [])
	assert_eq(log_.last_seq(), DeviceLineLog.MAX_LINES + 5, "通し番号は戻さない")


func test_base_provider_defaults() -> void:
	var p := SensorProvider.new()
	assert_eq(p.device_info("x"), "")
	assert_eq(p.device_reply("x"), "")
	assert_false(p.send_command("x", "INFO"))
	assert_not_null(p.device_line_log())


# ---------------------------------------------------------------- デモデバイス

func _count_readings(p: MockSensorProvider, seconds: float) -> Dictionary:
	var counts := {}
	var on_reading := func(r: SensorReading) -> void: counts[r.device_id] = int(counts.get(r.device_id, 0)) + 1
	p.reading_received.connect(on_reading)
	var steps := int(round(seconds / 0.05))
	for _i in steps:
		p.poll(0.05)
	p.reading_received.disconnect(on_reading)
	return counts


func test_mock_records_info_on_open() -> void:
	var p := MockSensorProvider.new()
	p.open_device("demo-01")
	assert_contains(p.device_info("demo-01"), "# model=DEMO name=demo-01 rate=100")
	assert_eq(p.device_line_log().settings("demo-01"), {"rate": 100, "sending": true})


func test_mock_send_command_requires_open_device() -> void:
	var p := MockSensorProvider.new()
	assert_false(p.send_command("demo-01", "PAUSE"), "未接続なら送れない")
	p.open_device("demo-01")
	assert_false(p.send_command("demo-01", "PAUSE\nRESUME"), "改行を含む行は送れない")
	assert_true(p.send_command("demo-01", "PAUSE"))
	p.close_device("demo-01")
	assert_false(p.send_command("demo-01", "RESUME"), "切断後は送れない")


func test_mock_pause_and_resume() -> void:
	var p := MockSensorProvider.new()
	p.open_device("demo-01")
	p.open_device("demo-02")
	assert_true(p.send_command("demo-01", "PAUSE"))
	assert_eq(p.device_reply("demo-01"), "# ok=PAUSE sending=0")
	var counts := _count_readings(p, 0.5)
	assert_eq(int(counts.get("demo-01", 0)), 0, "一時停止中は送らない")
	assert_ge(float(counts.get("demo-02", 0)), 45.0, "ほかのデバイスは送り続ける")
	assert_true(p.send_command("demo-01", "resume"))
	assert_eq(p.device_reply("demo-01"), "# ok=RESUME sending=1")
	counts = _count_readings(p, 0.5)
	assert_ge(float(counts.get("demo-01", 0)), 45.0, "再開すると送る")


func test_mock_rate_changes_sample_count() -> void:
	var p := MockSensorProvider.new()
	p.open_device("demo-01")
	assert_true(p.send_command("demo-01", "RATE 50"))
	assert_eq(p.device_reply("demo-01"), "# ok=RATE rate=50")
	assert_eq(p.device_state("demo-01")["rate"], 50)
	var counts := _count_readings(p, 1.0)
	assert_almost_eq(float(counts.get("demo-01", 0)), 50.0, 1.0, "50Hz")

	assert_true(p.send_command("demo-01", "RATE 30"))
	counts = _count_readings(p, 1.0)
	assert_almost_eq(float(counts.get("demo-01", 0)), 30.0, 1.0, "割り切れないレートでも平均は合う")

	assert_true(p.send_command("demo-01", "RATE 200"))
	assert_eq(p.device_reply("demo-01"), "# ok=RATE rate=200")
	counts = _count_readings(p, 1.0)
	assert_almost_eq(float(counts.get("demo-01", 0)), 100.0, 1.0, "デモは 100Hz で頭打ち")


func test_mock_rate_timestamps_stay_on_grid() -> void:
	var p := MockSensorProvider.new()
	var clock := [100000]
	p.time_source = func() -> int: return clock[0]
	p.open_device("demo-01")
	p.send_command("demo-01", "RATE 50")
	var stamps: Array[int] = []
	p.reading_received.connect(func(r: SensorReading) -> void: stamps.append(r.timestamp_ms))
	for _i in 10:
		clock[0] += 50
		p.poll(0.05)
	assert_ge(float(stamps.size()), 20.0)
	for i in range(1, stamps.size()):
		assert_eq(stamps[i] - stamps[i - 1], 20, "50Hz なら 20ms 間隔")


func test_mock_errors_and_info() -> void:
	var p := MockSensorProvider.new()
	p.open_device("demo-01")
	assert_true(p.send_command("demo-01", "RATE 5"), "送信自体は成功（応答がエラー）")
	assert_eq(p.device_reply("demo-01"), "# error=rate_out_of_range value=5 min=10 max=200")
	assert_eq(p.device_state("demo-01")["rate"], 100)
	p.send_command("demo-01", "PAUSE")
	var seq := p.device_line_log().last_seq()
	assert_true(p.send_command("demo-01", "INFO"))
	assert_eq(p.device_line_log().last_seq(), seq + 1)
	assert_contains(p.device_info("demo-01"), "sending=0")
	assert_contains(p.device_info("demo-01"), "rate=100")


func test_mock_settings_survive_reconnect() -> void:
	var p := MockSensorProvider.new()
	p.open_device("demo-01")
	p.send_command("demo-01", "RATE 25")
	p.close_device("demo-01")
	p.open_device("demo-01")
	assert_contains(p.device_info("demo-01"), "rate=25", "実機と同じく、接続し直しても設定は保たれる")


# ---------------------------------------------------------------- 有線（pipe）

func test_pipe_provider_keeps_hash_lines() -> void:
	var p := PipeSerialSensorProvider.new()
	var path := ProjectSettings.globalize_path(make_temp_dir().path_join("port.stream"))
	write_text(path, "# model=M5StickCPlus2 rate=100 sending=1\n0.1,0.2,0.3,1,2,3\n# ok=RATE rate=50\n# ok=PA")
	# 受信プロセスを起動せずに、受信済みファイルだけを読ませる（pid = -1 なら生存確認をしない）
	var stream := PipeSerialSensorProvider.Stream.new()
	stream.stream_path = path
	p._streams["/dev/cu.test"] = stream
	var readings: Array = []
	p.reading_received.connect(func(r: SensorReading) -> void: readings.append(r))
	p.poll(0.0)
	p._streams.clear()
	assert_eq(readings.size(), 1, "CSV 行はこれまでどおりサンプルになる")
	assert_eq(p.device_info("/dev/cu.test"), "# model=M5StickCPlus2 rate=100 sending=1")
	assert_eq(p.device_reply("/dev/cu.test"), "# ok=RATE rate=50", "途中までの行はまだ記録しない")
	assert_eq(p.device_line_log().settings("/dev/cu.test"), {"rate": 50, "sending": true})


# ---------------------------------------------------------------- SensorManager 経由

func test_manager_routes_commands_and_forgets_on_reconnect() -> void:
	var manager := SensorManager.new()   # ツリーに入れない（_ready で有線・BLE の Provider を作らない）
	var mock := MockSensorProvider.new()
	manager._add_provider(mock)
	for device in mock.scan():
		manager.registry.upsert(device)
	assert_null(manager.device_line_log("unknown"), "知らないデバイスは null")
	assert_false(manager.send_command("demo-01", "INFO"), "未接続なら送れない")
	assert_true(manager.open_device("demo-01"))
	var line_log := manager.device_line_log("demo-01")
	assert_not_null(line_log)
	assert_true(manager.send_command("demo-01", "PAUSE"))
	assert_eq(line_log.reply("demo-01"), "# ok=PAUSE sending=0")
	manager.close_device("demo-01")
	assert_true(manager.open_device("demo-01"))
	assert_eq(line_log.reply("demo-01"), "", "接続し直すと前回の応答は忘れる")
	assert_eq(line_log.settings("demo-01"), {"rate": 100, "sending": false}, "接続後の情報行で設定が分かる")
	manager._is_shut_down = true   # free 時の shutdown で何もしないように
	manager.free()
