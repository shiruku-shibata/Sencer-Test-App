extends SceneTree
## BleSensorProvider と BLEブリッジ（--mock）の結合テスト。実機・bleak は不要。
##
##   godot --headless --path . -s res://tools/ble_bridge/tests/godot_ble_smoke.gd
##
## 確認すること:
##   A. 自動起動: アプリがブリッジを起動 → scan → connect → データ受信 → コマンド → 切断
##      → ブリッジ強制終了からの自動再起動 → 「ブリッジ再起動」→ shutdown でプロセスが残らない
##   B. 手動起動: 先に起動しておいたブリッジへ接続（自分では起動しない）→ shutdown 後もブリッジは残る
##   C. 失敗系: スクリプト・Python が無い / ポート使用中 / bleak 未インストール でも落ちずに理由を返す
##   S. 有線のブリッジ経由（BridgeSerialSensorProvider）: 疑似シリアルポート MOCK-COM1 で
##      scan → connect → 受信 → コマンド → 切断、BLE と同時に使っても混ざらない、ブリッジ再起動からの復帰、
##      有線の方式の選び方（SensorManager.choose_serial_mode）、pyserial が無いときの表示
## 成功で終了コード 0、失敗で 1。

const TIMEOUT_TOTAL_SEC := 120.0

var _providers: Array = []
var _failures := PackedStringArray()
var _last_tick := 0
var _readings: Dictionary = {}       ## device_id -> 受信数
var _stamps: Dictionary = {}         ## device_id -> Array[int]（受け取った timestamp_ms）
var _discovered: Array = []
var _serial_discovered: Array = []
var _conn_events: Array = []         ## [device_id, connected]


func _initialize() -> void:
	_last_tick = Time.get_ticks_msec()
	_run()


func _run() -> void:
	var started := Time.get_ticks_msec()
	_phase_sample_clock()
	await _phase_auto_launch()
	await _phase_manual_bridge()
	await _phase_failures()
	await _phase_bridge_serial()
	for p in _providers:
		p.shutdown()
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	if _failures.is_empty():
		print("\n[smoke] すべて成功（%.1f 秒）" % elapsed)
		quit(0)
	else:
		print("\n[smoke] 失敗 %d 件:" % _failures.size())
		for f in _failures:
			print("  - " + f)
		quit(1)


# --- A. 自動起動 ---------------------------------------------------------------

func _phase_auto_launch() -> void:
	print("[smoke] A. 自動起動")
	var p := _make_provider(47830, 47831)
	p.bridge_args = PackedStringArray(["--mock"])

	var initial := p.scan()
	_check(initial.is_empty(), "A: 最初の scan() は即座に（空の）既知リストを返す")
	_check(p.is_scanning(), "A: scan() 直後はスキャン中表示になる")
	_check(await _wait(func() -> bool: return _discovered.size() >= 2, 20.0),
			"A: devices_discovered で疑似デバイス2台が届く（状態: %s）" % p.status_text())
	_check(p.is_ready() and p.is_bridge_owned(), "A: 自動起動したブリッジを使っている")
	var owned_pid := p.bridge_pid()
	_check(owned_pid > 0 and OS.is_process_running(owned_pid), "A: ブリッジのプロセスが動いている")
	print("[smoke]   状態: " + p.status_text())

	var address := ""
	for d: SensorDevice in _discovered:
		_check(d.mode == SensorDevice.Mode.BLE, "A: 方式は BLE")
		_check(d.label.begins_with("M5-Sensor-MOCK"), "A: 広告名が label に入る (%s)" % d.label)
		_check(d.rssi < 0, "A: RSSI が入る (%d)" % d.rssi)
		if d.label == "M5-Sensor-MOCK1":
			address = d.id
	_check(not address.is_empty(), "A: MOCK1 が見つかる")
	_check(not p.is_scanning(), "A: 結果到着後はスキャン中でない")

	_check(p.open_device(address), "A: open_device が受け付けられる")
	_check(p.is_connecting(address), "A: 接続処理中になる")
	_check(await _wait(func() -> bool: return _connected(address), 10.0), "A: 接続できる")
	_check(await _wait(func() -> bool: return int(_readings.get(address, 0)) >= 100, 10.0),
			"A: データを受信できる（%d 件）" % int(_readings.get(address, 0)))
	_check(p.device_info(address).begins_with("# model=MOCK"), "A: 情報行を覚えている")
	_check_stamps(address, 5.0, 20.0, "A: 100Hz")

	# PAUSE / RESUME
	_check(p.send_command(address, "PAUSE"), "A: send_command(PAUSE)")
	await _pump(0.4)
	var before := int(_readings.get(address, 0))
	await _pump(0.6)
	_check(int(_readings.get(address, 0)) - before <= 2, "A: PAUSE で止まる")
	_check(p.device_reply(address) == "# ok=PAUSE sending=0",
			"A: コマンド応答を device_reply で取れる: " + p.device_reply(address))
	_check(p.device_info(address).begins_with("# model=MOCK"),
			"A: device_info は応答行で上書きされない: " + p.device_info(address))
	_check(p.send_command(address, "RESUME"), "A: send_command(RESUME)")
	_check(await _wait(func() -> bool: return int(_readings.get(address, 0)) > before + 30, 5.0), "A: RESUME で再開")
	_check(not p.send_command("NO:SU:CH", "PAUSE"), "A: 未接続デバイスへの送信は false")

	# RATE 50 にすると、付く時刻の間隔も約 20ms になる
	_check(p.send_command(address, "RATE 50"), "A: send_command(RATE 50)")
	_check(await _wait(func() -> bool: return p.device_reply(address) == "# ok=RATE rate=50", 3.0),
			"A: RATE の応答: " + p.device_reply(address))
	_stamps.erase(address)
	await _pump(1.5)
	_check_stamps(address, 15.0, 30.0, "A: 50Hz")
	_check(p.send_command(address, "RATE 5"), "A: 範囲外の RATE も送れる")
	_check(await _wait(func() -> bool: return p.device_reply(address).begins_with("# error=rate_out_of_range"), 3.0),
			"A: 範囲外の RATE はエラー応答: " + p.device_reply(address))
	p.send_command(address, "RATE 100")

	# 切断
	p.close_device(address)
	_check(not _connected(address), "A: close_device ですぐ切断扱いになる")
	await _pump(0.5)
	var after_close := int(_readings.get(address, 0))
	await _pump(0.3)
	_check(int(_readings.get(address, 0)) == after_close, "A: 切断後はデータが来ない")

	# 接続したままブリッジが落ちた場合: 切断を知らせ、自動で起動し直す
	_check(p.open_device(address), "A: 再接続を要求")
	_check(await _wait(func() -> bool: return _connected(address), 10.0), "A: 再接続できる")
	_crash(owned_pid)
	_check(await _wait(func() -> bool: return not _connected(address), 10.0), "A: ブリッジが落ちたら切断になる")
	_check(await _wait(func() -> bool: return p.is_ready() and p.bridge_pid() != owned_pid, 20.0),
			"A: ブリッジが自動で再起動する（状態: %s）" % p.status_text())
	var second_pid := p.bridge_pid()

	# 「ブリッジ再起動」ボタン
	p.restart_bridge()
	_check(not OS.is_process_running(second_pid), "A: restart_bridge で古いブリッジが止まる")
	_check(await _wait(func() -> bool: return p.is_ready() and p.bridge_pid() != second_pid, 20.0),
			"A: restart_bridge で新しいブリッジが起動する")
	var third_pid := p.bridge_pid()
	_check(p.open_device(address), "A: 再起動後に接続を要求")
	_check(await _wait(func() -> bool: return _connected(address), 10.0), "A: 再起動後も接続できる")

	# 終了処理
	p.shutdown()
	p.shutdown()   # 2回目も安全
	_check(not OS.is_process_running(third_pid), "A: shutdown 後にブリッジのプロセスが残らない")
	_check(not p.open_device(address), "A: shutdown 後は接続できない")
	_providers.erase(p)
	_check(_port_free(47830), "A: shutdown でアプリ側の UDP ポートが解放される")
	await _pump(0.3)
	_check(_port_free_for_bridge(47831), "A: ブリッジ側の UDP ポートも解放される")


# --- B. 手動起動 ---------------------------------------------------------------

func _phase_manual_bridge() -> void:
	print("[smoke] B. 手動起動のブリッジへ接続")
	_reset_events()
	var p := _make_provider(47840, 47841)
	var script := p.find_bridge_script()
	var python := p.find_python(script.get_base_dir())
	_check(not script.is_empty() and not python.is_empty(), "B: スクリプトと Python が見つかる")
	var args := PackedStringArray(python.get("args", PackedStringArray()))
	args.append_array(PackedStringArray([script, "--mock", "--port", "47841", "--app-port", "47840"]))
	# ターミナルから起動したのと同じ状態（--parent-pid なし）
	var manual_pid := OS.create_process(str(python["path"]), args)
	_check(manual_pid > 0, "B: ブリッジを手動起動")
	await _pump(1.5)

	p.scan()
	_check(await _wait(func() -> bool: return _discovered.size() >= 2, 15.0),
			"B: 手動起動のブリッジでスキャンできる（状態: %s）" % p.status_text())
	_check(not p.is_bridge_owned(), "B: 自分ではブリッジを起動していない")
	_check(p.bridge_pid() == manual_pid, "B: 手動起動したブリッジ（pid %d）を使っている: %d" % [manual_pid, p.bridge_pid()])
	_check(p.status_text().contains("手動起動"), "B: 状態に手動起動と出る")
	var address := ""
	for d: SensorDevice in _discovered:
		if d.label == "M5-Sensor-MOCK2":
			address = d.id
	_check(p.open_device(address), "B: open_device")
	_check(await _wait(func() -> bool: return int(_readings.get(address, 0)) >= 50, 10.0), "B: データを受信できる")
	p.close_device(address)
	await _pump(0.3)

	_check(p.manual_command().contains("ble_bridge.py"), "B: 手動起動コマンドを表示できる: " + p.manual_command())

	p.shutdown()
	_providers.erase(p)
	await _pump(1.0)
	_check(OS.is_process_running(manual_pid), "B: shutdown 後も手動起動のブリッジは残る（bye のみ）")

	# 手動起動モード（自動起動しない）でも同じブリッジにつながる
	_reset_events()
	var q := _make_provider(47840, 47841)
	q.use_manual_bridge()
	_check(await _wait(func() -> bool: return q.is_ready(), 5.0), "B: use_manual_bridge で手動ブリッジにつながる")
	_check(q.is_manual_mode() and not q.is_bridge_owned(), "B: 手動モード")
	q.scan()
	_check(await _wait(func() -> bool: return _discovered.size() >= 2, 10.0), "B: 手動モードでスキャン")
	_crash(manual_pid)
	_check(await _wait(func() -> bool: return q.state() == BleSensorProvider.State.WAITING_MANUAL, 10.0),
			"B: 手動ブリッジが居なくなると待機に戻る（自動起動しない）: %s" % q.status_text())
	q.shutdown()
	_providers.erase(q)


# --- C. 失敗系 -----------------------------------------------------------------

func _phase_failures() -> void:
	print("[smoke] C. 失敗系")
	_reset_events()

	var no_script := _make_provider(47860, 47861)
	no_script.bridge_script_path = "/nonexistent/ble_bridge.py"
	no_script.scan()
	_check(await _wait(func() -> bool: return not no_script.is_available(), 5.0), "C: スクリプトが無ければ利用不可")
	_check(no_script.unavailable_reason().contains("見つかりません"), "C: 理由: " + no_script.unavailable_reason())
	_check(no_script.scan().is_empty(), "C: 利用不可でも scan() は落ちない")
	_check(not no_script.open_device("X"), "C: 利用不可なら open_device は false")

	var no_python := _make_provider(47862, 47863)
	no_python.python_path = "/nonexistent/python3"
	no_python.scan()
	_check(await _wait(func() -> bool: return not no_python.is_available(), 5.0), "C: Python が無ければ利用不可")
	_check(no_python.status_text().contains("Python"), "C: 理由: " + no_python.status_text())

	var blocker := PacketPeerUDP.new()
	blocker.bind(47864, "127.0.0.1")
	var busy := _make_provider(47864, 47865)
	busy.scan()
	_check(not busy.is_available() and busy.status_text().contains("47864"),
			"C: ポート使用中なら理由を出す: " + busy.status_text())
	blocker.close()

	# ブリッジ側のポートを hello に答えない別のプログラムが使っている
	var squatter := PacketPeerUDP.new()
	squatter.bind(47869, "127.0.0.1")
	var squatted := _make_provider(47868, 47869)
	squatted.scan()
	_check(await _wait(func() -> bool: return not squatted.is_available(), 5.0)
			and squatted.status_text().contains("別のプログラム"),
			"C: ブリッジのポートが他で使用中なら理由を出す: " + squatted.status_text())
	squatter.close()
	squatted.restart_bridge()
	_check(await _wait(func() -> bool: return squatted.is_ready(), 15.0),
			"C: ポートが空いたら「ブリッジ再起動」で使えるようになる: " + squatted.status_text())
	squatted.shutdown()
	_providers.erase(squatted)

	# bleak が入っていない Python（macOS 標準の /usr/bin/python3 を想定）で実機モードを起動
	if FileAccess.file_exists("/usr/bin/python3"):
		var nobleak := _make_provider(47866, 47867)
		nobleak.python_path = "/usr/bin/python3"
		nobleak.scan()
		await _wait(func() -> bool: return nobleak.is_ready(), 15.0)
		var has_bleak := OS.execute("/usr/bin/python3", ["-c", "import bleak"]) == 0
		if has_bleak:
			print("[smoke]   (/usr/bin/python3 に bleak があるため bleak 未インストールの確認は省略)")
		else:
			_check(nobleak.is_ready(), "C: bleak が無くてもブリッジ自体は起動する")
			_check(not nobleak.is_available(), "C: bleak が無ければ利用不可")
			_check(nobleak.status_text().contains("bleak 未インストール"), "C: 対処を表示: " + nobleak.status_text())
		var pid := nobleak.bridge_pid()
		nobleak.shutdown()
		_providers.erase(nobleak)
		_check(pid <= 0 or not OS.is_process_running(pid), "C: shutdown でプロセスが残らない")

	for p in [no_script, no_python, busy]:
		p.shutdown()
		_providers.erase(p)


# --- 補助 -----------------------------------------------------------------------

# --- S. 有線のブリッジ経由 ---------------------------------------------------------

func _phase_bridge_serial() -> void:
	print("[smoke] S. 有線のブリッジ経由（疑似シリアルポート）")
	_reset_events()

	# 有線の方式の選び方
	var choose := func(req: String, addon: bool, pipe: bool) -> String:
		return SensorManager.choose_serial_mode(req, addon, pipe)
	_check(choose.call("", false, true) == "pipe", "S: macOS/Linux の既定は OS 標準コマンド（pipe）")
	_check(choose.call("", false, false) == "bridge", "S: アドオンも pipe も無い（Windows）ならブリッジ経由")
	_check(choose.call("", true, true) == "addon", "S: アドオンがあれば最優先")
	_check(choose.call("bridge", true, true) == "bridge", "S: SENSOR_SERIAL_MODE=bridge で強制できる")
	_check(choose.call("pipe", false, false) == "bridge", "S: 使えない方式を指定したら自動選択に戻る")
	_check(choose.call("addon", false, true) == "pipe", "S: アドオンが無いのに addon 指定なら自動選択")

	var host := _make_provider(47880, 47881)
	host.bridge_args = PackedStringArray(["--mock"])
	var serial := _make_serial(host)
	_check(serial.get_mode() == SensorDevice.Mode.SERIAL, "S: 方式は有線（SERIAL）")

	_check(serial.scan().is_empty(), "S: 最初の scan() は即座に（空の）既知リストを返す")
	_check(serial.is_scanning(), "S: ブリッジ起動待ちの間はスキャン中")
	_check(await _wait(func() -> bool: return _find(_serial_discovered, "MOCK-COM1") != null, 20.0),
			"S: 疑似シリアルポート MOCK-COM1 が見つかる（%s）" % serial.status_text())
	var port: SensorDevice = _find(_serial_discovered, "MOCK-COM1")
	if port == null:
		host.shutdown()
		_providers.erase(host)
		_providers.erase(serial)
		return
	_check(port.mode == SensorDevice.Mode.SERIAL and port.label == "USB Single Serial (mock)",
			"S: 有線デバイスとして見える（label=%s）" % port.label)
	_check(serial.is_available() and serial.status_text().contains("準備完了"), "S: 状態: " + serial.status_text())

	# BLE も同じブリッジで同時に使える
	host.scan()
	_check(await _wait(func() -> bool: return _find(_discovered, "AA:BB:CC:00:00:01") != null, 10.0),
			"S: 同じブリッジで BLE もスキャンできる")
	_check(_find(_discovered, "MOCK-COM1") == null and _find(_serial_discovered, "AA:BB:CC:00:00:01") == null,
			"S: BLE と有線の一覧が混ざらない")

	_check(serial.open_device("MOCK-COM1"), "S: open_device")
	_check(serial.is_connecting("MOCK-COM1"), "S: 接続処理中になる")
	_check(host.open_device("AA:BB:CC:00:00:01"), "S: BLE も同時に接続")
	_check(await _wait(func() -> bool: return _connected("MOCK-COM1") and _connected("AA:BB:CC:00:00:01"), 10.0),
			"S: 有線・BLE とも接続できる")
	_check(await _wait(func() -> bool: return int(_readings.get("MOCK-COM1", 0)) >= 100, 10.0),
			"S: 有線（ブリッジ経由）でデータを受信（%d 件）" % int(_readings.get("MOCK-COM1", 0)))
	_check(int(_readings.get("AA:BB:CC:00:00:01", 0)) > 0, "S: BLE のデータも同時に届く")
	_check(not host.is_connecting("MOCK-COM1") and not host.device_info("MOCK-COM1").length(),
			"S: BLE 側は有線のポートを自分のものとして扱わない")
	_check(serial.device_info("MOCK-COM1").begins_with("# model=MOCK name=M5-Sensor-MOCK3"),
			"S: 情報行: " + serial.device_info("MOCK-COM1"))
	_check_stamps("MOCK-COM1", 5.0, 20.0, "S: 有線 100Hz")

	_check(serial.send_command("MOCK-COM1", "PAUSE"), "S: send_command(PAUSE)")
	_check(await _wait(func() -> bool: return serial.device_reply("MOCK-COM1") == "# ok=PAUSE sending=0", 3.0),
			"S: コマンド応答: " + serial.device_reply("MOCK-COM1"))
	await _pump(0.3)
	var paused_at := int(_readings.get("MOCK-COM1", 0))
	var ble_at := int(_readings.get("AA:BB:CC:00:00:01", 0))
	await _pump(0.5)
	_check(int(_readings.get("MOCK-COM1", 0)) - paused_at <= 2, "S: PAUSE で止まる")
	_check(int(_readings.get("AA:BB:CC:00:00:01", 0)) - ble_at >= 20, "S: 有線を止めても BLE は流れ続ける")
	serial.send_command("MOCK-COM1", "RESUME")

	serial.close_device("MOCK-COM1")
	_check(not _connected("MOCK-COM1"), "S: close_device ですぐ切断扱い")
	_check(_connected("AA:BB:CC:00:00:01"), "S: 有線を切断しても BLE はつながったまま")
	await _pump(0.4)
	var closed_at := int(_readings.get("MOCK-COM1", 0))
	await _pump(0.3)
	_check(int(_readings.get("MOCK-COM1", 0)) == closed_at, "S: 切断後は有線のデータが来ない")

	# 接続中にブリッジが落ちたら、有線も切断になり、ブリッジの自動再起動後にまた使える
	_check(serial.open_device("MOCK-COM1"), "S: 再接続を要求")
	_check(await _wait(func() -> bool: return _connected("MOCK-COM1"), 10.0), "S: 再接続できる")
	var old_pid := host.bridge_pid()
	_crash(old_pid)
	_check(await _wait(func() -> bool: return not _connected("MOCK-COM1"), 10.0), "S: ブリッジが落ちたら有線も切断")
	var recovered := func() -> bool:
		return host.is_ready() and host.bridge_pid() != old_pid \
				and serial.is_available() and serial.status_text().contains("準備完了")
	_check(await _wait(recovered, 20.0),
			"S: ブリッジの自動再起動後に有線も使える: " + serial.status_text())
	_check(serial.open_device("MOCK-COM1"), "S: 再起動後に接続を要求")
	_check(await _wait(func() -> bool: return _connected("MOCK-COM1"), 10.0), "S: 再起動後も接続できる")

	var pid := host.bridge_pid()
	host.shutdown()
	serial.shutdown()
	_providers.erase(host)
	_providers.erase(serial)
	_check(not OS.is_process_running(pid), "S: shutdown でブリッジのプロセスが残らない")
	_check(not serial.open_device("MOCK-COM1"), "S: shutdown 後は接続できない")

	# 古いブリッジ（hello に serial が無い）・--no-serial のときの表示
	var dummy_host := BleSensorProvider.new()
	var old := BridgeSerialSensorProvider.new(dummy_host)
	old._on_bridge_hello({"type": "hello"})
	_check(not old.is_available() and old.unavailable_reason().contains("ブリッジが古い"),
			"S: 古いブリッジなら理由を出す: " + old.unavailable_reason())
	old._on_bridge_hello({"type": "hello", "serial": null})
	_check(not old.is_available() and old.unavailable_reason().contains("--no-serial"),
			"S: --no-serial なら理由を出す: " + old.unavailable_reason())
	dummy_host.shutdown()

	# pyserial が入っていない Python（macOS 標準の /usr/bin/python3 を想定）
	if FileAccess.file_exists("/usr/bin/python3") \
			and OS.execute("/usr/bin/python3", ["-c", "import serial"]) != 0:
		_reset_events()
		var bare_host := _make_provider(47882, 47883)
		bare_host.python_path = "/usr/bin/python3"
		var bare := _make_serial(bare_host)
		bare.scan()
		_check(await _wait(func() -> bool: return bare_host.is_ready() and not bare.is_available(), 15.0),
				"S: pyserial が無ければ有線（ブリッジ経由）は利用不可")
		_check(bare.unavailable_reason().contains("pyserial 未インストール"), "S: 対処を表示: " + bare.unavailable_reason())
		_check(not bare.open_device("COM3"), "S: 利用不可なら open_device は false")
		var bare_pid := bare_host.bridge_pid()
		bare_host.shutdown()
		bare.shutdown()
		_providers.erase(bare_host)
		_providers.erase(bare)
		_check(bare_pid <= 0 or not OS.is_process_running(bare_pid), "S: shutdown でプロセスが残らない")
	else:
		print("[smoke]   (/usr/bin/python3 に pyserial があるため pyserial 未インストールの確認は省略)")


func _make_serial(host: BleSensorProvider) -> BridgeSerialSensorProvider:
	var s := BridgeSerialSensorProvider.new(host)
	s.reading_received.connect(func(r: SensorReading) -> void:
		_readings[r.device_id] = int(_readings.get(r.device_id, 0)) + 1
		if not _stamps.has(r.device_id):
			_stamps[r.device_id] = []
		_stamps[r.device_id].append(r.timestamp_ms))
	s.devices_discovered.connect(func(devices: Array) -> void: _serial_discovered = devices)
	s.connection_changed.connect(func(id: String, c: bool) -> void: _conn_events.append([id, c]))
	_providers.append(s)
	return s


func _find(devices: Array, id: String) -> SensorDevice:
	for d: SensorDevice in devices:
		if d.id == id:
			return d
	return null


func _make_provider(app_port: int, bridge_port: int) -> BleSensorProvider:
	var p := BleSensorProvider.new()
	p.app_port = app_port
	p.bridge_port = bridge_port
	p.scan_timeout_sec = 1.0
	p.reading_received.connect(func(r: SensorReading) -> void:
		_readings[r.device_id] = int(_readings.get(r.device_id, 0)) + 1
		if not _stamps.has(r.device_id):
			_stamps[r.device_id] = []
		_stamps[r.device_id].append(r.timestamp_ms))
	p.devices_discovered.connect(func(devices: Array) -> void: _discovered = devices)
	p.connection_changed.connect(func(id: String, c: bool) -> void: _conn_events.append([id, c]))
	_providers.append(p)
	return p


func _reset_events() -> void:
	_serial_discovered = []
	_readings.clear()
	_stamps.clear()
	_discovered = []
	_conn_events.clear()


func _connected(address: String) -> bool:
	var state := false
	for e in _conn_events:
		if e[0] == address:
			state = e[1]
	return state


func _poll_all() -> void:
	var now := Time.get_ticks_msec()
	var delta := (now - _last_tick) / 1000.0
	_last_tick = now
	for p in _providers:
		p.poll(delta)


func _wait(condition: Callable, timeout_sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < end:
		_poll_all()
		if condition.call():
			return true
		OS.delay_msec(5)
		await process_frame
	_poll_all()
	return condition.call()


func _pump(seconds: float) -> void:
	await _wait(func() -> bool: return false, seconds)


## ブリッジが異常終了したことにする。OS.kill() だと Godot が pid を回収してしまい
## 実際のクラッシュと条件が変わるので、外部の kill コマンドを使う。
func _crash(pid: int) -> void:
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/F", "/PID", str(pid)])
	else:
		OS.execute("kill", ["-9", str(pid)])


func _port_free(port: int) -> bool:
	var probe := PacketPeerUDP.new()
	var ok := probe.bind(port, "127.0.0.1") == OK
	probe.close()
	return ok


## ブリッジ側のポートが空いたか（Python が使っていたポートを Godot から bind してみる）。
func _port_free_for_bridge(port: int) -> bool:
	return _port_free(port)


# --- 時刻の付け方（SampleClock） -------------------------------------------------

func _phase_sample_clock() -> void:
	print("[smoke] 0. SampleClock（BLE サンプルの時刻）")
	var c := BleSensorProvider.SampleClock.new()
	_check(Array(c.stamp(2, 1000)) == [990, 1000], "0: 既定 100Hz で 10ms ずつさかのぼる")
	_check(Array(c.stamp(2, 1020)) == [1010, 1020], "0: 次のデータグラムも続けて付く")
	_check(Array(c.stamp(3, 1025)) == [1021, 1022, 1025], "0: 前の時刻と重なるときは 1ms ずつ後ろへずらす（単調増加）")
	c.set_rate_hint(50.0)
	_check(Array(c.stamp(2, 1100)) == [1080, 1100], "0: デバイスが知らせたレート（50Hz）を使う")

	# 実際の受信レート（200Hz を 20ms ごとに4個ずつ）を測って間隔を合わせる
	var m := BleSensorProvider.SampleClock.new()
	var t := 5000
	var all: Array = []
	for i in 80:
		t += 20
		all.append_array(Array(m.stamp(4, t)))
	_check(absf(m.interval_ms - 5.0) < 0.5, "0: 受信レートから間隔を推定（%.2f ms）" % m.interval_ms)
	var tail: Array = all.slice(all.size() - 8)
	_check(tail == [t - 35, t - 30, t - 25, t - 20, t - 15, t - 10, t - 5, t], "0: 推定後は 5ms 間隔: %s" % str(tail))
	var strictly := true
	for i in range(1, all.size()):
		strictly = strictly and all[i] > all[i - 1]
	_check(strictly, "0: すべて単調増加")

	# 一時停止のような長い空白をはさんでも、間隔の推定が狂わない
	t += 3000
	m.stamp(4, t)
	t += 20
	m.stamp(4, t)
	_check(absf(m.interval_ms - 5.0) < 0.5, "0: 空白の後も推定が保たれる（%.2f ms）" % m.interval_ms)


## 受け取ったサンプルの時刻が単調増加で、間隔の中央値が範囲内か。
func _check_stamps(address: String, min_ms: float, max_ms: float, label: String) -> void:
	var stamps: Array = _stamps.get(address, [])
	var increasing := stamps.size() > 10
	var diffs: Array = []
	for i in range(1, stamps.size()):
		increasing = increasing and stamps[i] > stamps[i - 1]
		diffs.append(stamps[i] - stamps[i - 1])
	diffs.sort()
	var median: float = diffs[diffs.size() / 2] if not diffs.is_empty() else 0.0
	_check(increasing, "%s: 時刻が単調増加（%d 件、同じ時刻なし）" % [label, stamps.size()])
	_check(median >= min_ms and median <= max_ms,
			"%s: 時刻の間隔の中央値 %.1f ms（%.0f〜%.0f ms）" % [label, median, min_ms, max_ms])


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[smoke]   ok  " + message)
	else:
		print("[smoke]   NG  " + message)
		_failures.append(message)
