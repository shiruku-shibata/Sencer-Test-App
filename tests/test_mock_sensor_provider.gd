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


## 時刻を自由に進められる MockSensorProvider（now[0] が「実時間」）と、受け取ったサンプルの配列。
func _fake_clock_provider(now: Array, got: Array) -> MockSensorProvider:
	var p := MockSensorProvider.new()
	p.time_source = func() -> int: return now[0]
	p.reading_received.connect(func(r: SensorReading) -> void: got.append(r))
	return p


func _timestamps(readings: Array) -> Array:
	var out: Array = []
	for r in readings:
		out.append(r.timestamp_ms)
	return out


func test_samples_in_one_poll_have_distinct_timestamps() -> void:
	# 以前は1回の poll で出したサンプルがすべて同じ時刻（Time.get_ticks_msec）になっていた
	var now := [5000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	p.poll(0.05)
	assert_eq(_timestamps(got), [4960, 4970, 4980, 4990, 5000], "10ms 刻みで、最後のサンプルが実時間")
	assert_eq(p.clock_ms(), 5000)


func test_timestamps_continue_across_polls() -> void:
	var now := [1000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	for i in 30:
		now[0] += 16                # 約 60fps のフレーム
		p.poll(0.016)
	var ts := _timestamps(got)
	assert_ge(float(ts.size()), 47.0)
	for i in range(1, ts.size()):
		assert_eq(ts[i] - ts[i - 1], 10, "サンプル %d の間隔" % i)
	assert_lt(absf(float(ts[-1] - now[0])), float(MockSensorProvider.RESYNC_MS), "実時間に追従している")


func test_resyncs_after_long_stall_without_burst() -> void:
	var now := [1000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	p.poll(0.02)
	got.clear()
	now[0] += 10000              # 10 秒止まっていた（ウィンドウのドラッグ等）
	p.poll(10.0)
	assert_eq(got.size(), MockSensorProvider.MAX_SAMPLES_PER_POLL, "まとめて 1000 件は出さない")
	var ts := _timestamps(got)
	assert_eq(ts[-1], now[0], "最後のサンプルが実時間にそろう")
	for i in range(1, ts.size()):
		assert_eq(ts[i] - ts[i - 1], 10)
	assert_gt(float(ts[0]), 1020.0, "途切れの後から再開（巻き戻らない）")


func test_never_goes_backwards() -> void:
	var now := [50000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	p.poll(0.03)
	now[0] = 100                 # 時刻源が巻き戻っても
	p.poll(0.03)
	now[0] = 20000
	p.poll(0.03)
	var ts := _timestamps(got)
	for i in range(1, ts.size()):
		assert_gt(float(ts[i]), float(ts[i - 1]), "単調増加 %d" % i)


func test_reopen_continues_clock() -> void:
	var now := [1000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	p.poll(0.03)
	var last: int = got[-1].timestamp_ms
	p.close_device("demo-01")
	now[0] += 5000
	p.poll(1.0)                  # 閉じている間は何も出さない
	p.open_device("demo-01")
	got.clear()
	p.poll(0.02)
	assert_gt(float(got[0].timestamp_ms), float(last))
	assert_eq(got[-1].timestamp_ms, now[0], "開き直したら実時間に合わせ直す")


func test_two_devices_share_tick_times() -> void:
	var now := [3000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	p.open_device("demo-02")
	p.poll(0.03)
	var per_device: Dictionary = {}
	for r in got:
		if not per_device.has(r.device_id):
			per_device[r.device_id] = []
		per_device[r.device_id].append(r.timestamp_ms)
	assert_eq(per_device["demo-01"], [2980, 2990, 3000])
	assert_eq(per_device["demo-02"], [2980, 2990, 3000])


func test_default_time_source_is_engine_clock() -> void:
	var p := MockSensorProvider.new()
	var got: Array = []
	p.reading_received.connect(func(r: SensorReading) -> void: got.append(r))
	p.open_device("demo-01")
	var before := Time.get_ticks_msec()
	p.poll(0.03)
	assert_eq(got.size(), 3)
	assert_le(float(got[-1].timestamp_ms), float(Time.get_ticks_msec()))
	assert_ge(float(got[-1].timestamp_ms), float(before))


func test_baseline_finishes_by_virtual_time_even_with_large_frames() -> void:
	# 1フレームで 10 サンプルずつ届く（重いフレーム）状況でも、静止測定が予定どおり 3 秒で終わる。
	# 以前は1フレーム内のサンプルが同時刻だったため、フレームの粒度でしか時間が進まなかった。
	var now := [10000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	var a := ThresholdAnalyzer.new()
	a.set_axes([SensorAxis.Id.GX])
	p.reading_received.connect(a.feed)
	p.open_device("demo-01")
	a.start_baseline(3000)
	var polls := 0
	while a.phase() == ThresholdAnalyzer.Phase.BASELINE and polls < 1000:
		now[0] += 100
		p.poll(0.1)
		polls += 1
	assert_true(a.has_baseline())
	assert_eq(a.baseline()[SensorAxis.Id.GX]["count"], 300, "100Hz × 3 秒ちょうど")
	p.reading_received.disconnect(a.feed)


# ------------------------------------------------------------ デモの振り（PR #11 レビュー 中-4）

## gZ が level 以上になった区間の開始時刻（＝振りの開始）の一覧。
func _swing_starts(readings: Array, level: float = 60.0) -> Array:
	var starts: Array = []
	var inside := false
	for r: SensorReading in readings:
		var over := r.gyro.z >= level
		if over and not inside:
			starts.append(r.timestamp_ms)
		inside = over
	return starts


func _run_demo(p: MockSensorProvider, now: Array, ms: int) -> void:
	for _i in ms / 10:
		now[0] += 10
		p.poll(0.01)


## 以前は 1 サンプルごとに 1.2% の確率でランダムに跳ねていた（静止測定にも入り、品質が「重なり」になる）。
func test_demo_swings_on_a_fixed_rhythm_and_is_quiet_between() -> void:
	var now := [1000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	_run_demo(p, now, 20000)
	var starts := _swing_starts(got)
	assert_ge(float(starts.size()), 5.0, "20 秒で 5 回以上振る")
	for i in range(1, starts.size()):
		assert_almost_eq(float(int(starts[i]) - int(starts[i - 1])),
				float(MockSensorProvider.DEMO_GESTURE_PERIOD_MS), 30.0, "一定のリズム（%d 回目）" % i)
	var rest_peak := 0.0
	var swing_peak := 0.0
	for r: SensorReading in got:
		var near_swing := false
		for s in starts:
			if r.timestamp_ms >= int(s) - 100 and r.timestamp_ms < int(s) + MockSensorProvider.DEMO_GESTURE_MS + 50:
				near_swing = true
		if near_swing:
			swing_peak = maxf(swing_peak, r.gyro.z)
		else:
			rest_peak = maxf(rest_peak, absf(r.gyro.z))
	assert_lt(rest_peak, 10.0, "振っていない間の gZ は小さなノイズだけ")
	assert_gt(swing_peak, 200.0, "振りの gZ は大きい")


func test_hold_still_and_gesture_soon() -> void:
	var now := [1000]
	var got: Array = []
	var p := _fake_clock_provider(now, got)
	p.open_device("demo-01")
	_run_demo(p, now, 1500)   # 最初の振り（約 2 秒後）の直前
	p.hold_still(3500)
	got.clear()
	_run_demo(p, now, 3500)
	assert_eq(_swing_starts(got), [], "hold_still の間は振らない")
	got.clear()
	var called_at: int = p.clock_ms()
	p.gesture_soon(400)       # 振らない期間が終わってから呼ぶ
	_run_demo(p, now, 1000)
	var starts := _swing_starts(got)
	assert_eq(starts.size(), 1, "gesture_soon で 1 回振る")
	if starts.size() == 1:
		assert_almost_eq(float(int(starts[0]) - called_at), 400.0, 80.0, "約 400ms 後に振り始める")
