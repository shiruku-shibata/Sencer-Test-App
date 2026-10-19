extends "res://tests/test_case.gd"
## ThresholdAnalyzer.cancel() / restore_measurement() と、
## ThresholdProfile.apply_measurement_to() / measurement_axes() / rule_axes() のテスト。

const Dir := ThresholdRule.Direction
const Phase := ThresholdAnalyzer.Phase
const AX := SensorAxis.Id.AX
const GY := SensorAxis.Id.GY
const GZ := SensorAxis.Id.GZ

var _t := 0


func before_each() -> void:
	_t = 0


func _feed_gz(a: ThresholdAnalyzer, values: Array) -> void:
	for v in values:
		a.feed(SensorReading.new("d", _t, Vector3.ZERO, Vector3(0.0, 0.0, v)))
		_t += 10


func _analyzer(axes: Array = [GZ]) -> ThresholdAnalyzer:
	var a := ThresholdAnalyzer.new()
	a.set_axes(axes)
	return a


func _measured(rest_values: Array, trial_values: Array) -> ThresholdAnalyzer:
	var a := _analyzer()
	a.start_baseline(100000)
	_feed_gz(a, rest_values)
	a.stop()
	for tv in trial_values:
		a.start_trial()
		_feed_gz(a, tv)
		a.stop()
	return a


# ------------------------------------------------------------ cancel

func test_cancel_discards_running_baseline_but_keeps_previous() -> void:
	var a := _measured([-1.0, 1.0], [[100.0]])
	var before := a.baseline()
	var signals: Array = []
	a.baseline_finished.connect(func(_s: Dictionary) -> void: signals.append("baseline"))
	a.trial_discarded.connect(func() -> void: signals.append("discarded"))
	a.phase_changed.connect(func(p: int) -> void: signals.append(p))
	a.start_baseline(3000)
	_feed_gz(a, [50.0, 60.0, 70.0])   # 途中で切断された想定
	a.cancel()
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(a.baseline(), before, "以前の静止測定が残る（途中の値で確定しない）")
	assert_eq(a.trial_count(), 1, "以前の試行も残る")
	assert_eq(signals, [Phase.BASELINE, Phase.IDLE], "phase_changed だけ出る")


func test_cancel_discards_running_trial() -> void:
	var a := _measured([-1.0, 1.0], [[100.0]])
	var finished := [0]
	a.trial_finished.connect(func(_i: int, _r: Dictionary) -> void: finished[0] += 1)
	a.start_trial()
	_feed_gz(a, [10.0, 20.0])
	a.cancel()
	assert_eq(finished[0], 0)
	assert_eq(a.trial_count(), 1)
	assert_almost_eq(a.progress(), 0.0)
	# 中止後に新しく測っても、捨てた分は混ざらない
	a.start_trial()
	_feed_gz(a, [0.0, 300.0])
	a.stop()
	assert_eq(a.trial_count(), 2)
	assert_eq(a.trials()[1][GZ]["count"], 2)


func test_cancel_when_idle_does_nothing() -> void:
	var a := _measured([-1.0, 1.0], [[100.0]])
	var phases: Array = []
	a.phase_changed.connect(func(p: int) -> void: phases.append(p))
	a.cancel()
	assert_eq(phases, [])
	assert_true(a.has_baseline())


# ------------------------------------------------------------ restore_measurement

func test_restore_roundtrip_gives_same_recommendation() -> void:
	var a := _measured([-1.0, 1.0, -2.0, 2.0], [[0.0, 120.0, -30.0], [0.0, 200.0], [0.0, 160.0]])
	var m := {"baseline": a.baseline(), "trials": a.trials()}
	var b := _analyzer()
	assert_true(b.restore_measurement(m))
	assert_eq(b.baseline(), a.baseline())
	assert_eq(b.trials(), a.trials())
	for d in [Dir.POSITIVE, Dir.NEGATIVE, Dir.ABSOLUTE]:
		assert_eq(b.recommend(GZ, d, 0.3), a.recommend(GZ, d, 0.3), "向き %d" % d)
	assert_eq(b.suggest_direction(GZ), a.suggest_direction(GZ))


func test_restore_accepts_string_keys_from_json() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, 150.0]])
	var p := ThresholdProfile.new()
	p.set_measurement_from(a)
	var saved: Dictionary = JSON.parse_string(p.to_json())["measurement"]   # "gz" キー・数値は float
	assert_has(saved["baseline"], "gz")
	var b := _analyzer()
	assert_true(b.restore_measurement(saved))
	assert_eq(typeof(b.baseline()[GZ]["count"]), TYPE_INT)
	assert_eq(typeof(b.trials()[0][GZ]["duration_ms"]), TYPE_INT)
	assert_eq(b.recommend(GZ, Dir.POSITIVE), a.recommend(GZ, Dir.POSITIVE))


func test_restore_uses_intersection_of_axes() -> void:
	var m := {
		"baseline": {GZ: {"mean": 0.0, "stddev": 1.0, "min": -1.0, "max": 1.0, "count": 10},
				"ax": {"mean": 0.0, "stddev": 0.1, "min": -0.1, "max": 0.1, "count": 10}},
		"trials": [{GZ: {"max": 100.0, "min": -5.0, "count": 3}, "ax": {"max": 2.0, "min": 0.0, "count": 3}},
				{"ax": {"max": 2.0, "min": 0.0, "count": 3}}],
	}
	var a := _analyzer([GZ, GY])
	assert_true(a.restore_measurement(m))
	assert_eq(a.axes, [GZ, GY] as Array[int], "axes は変えない")
	assert_eq(a.baseline().keys(), [GZ], "set_axes にない ax は無視")
	assert_eq(a.trial_count(), 1, "対象の軸が無い試行は捨てる")
	assert_almost_eq(a.trials()[0][GZ]["peak_abs"], 100.0, 1e-6, "peak_abs が無ければ max/min から計算")
	assert_eq(a.trials()[0][GZ]["duration_ms"], 0)
	assert_eq(a.recommend(GY, Dir.POSITIVE)["quality"], "insufficient")
	assert_eq(a.recommend(GZ, Dir.POSITIVE)["quality"], "good")


func test_restore_replaces_current_results() -> void:
	var a := _measured([-1.0, 1.0], [[100.0], [200.0], [300.0]])
	assert_true(a.restore_measurement({"trials": [{GZ: {"max": 50.0, "min": 0.0, "count": 1}}]}))
	assert_false(a.has_baseline(), "measurement に baseline が無ければ空になる")
	assert_eq(a.trial_count(), 1)
	assert_false(a.restore_measurement({}))
	assert_eq(a.trial_count(), 0)


func test_restore_ignores_invalid_values() -> void:
	var a := _analyzer()
	var ok := a.restore_measurement({
		"baseline": {
			GZ: {"mean": NAN, "stddev": 1.0, "min": -1.0, "max": 1.0, "count": 10},
		},
		"trials": [
			{GZ: {"max": 10.0, "min": 0.0, "count": 0}},          # count 0
			{GZ: {"max": 10.0, "min": 20.0, "count": 3}},         # min > max
			{GZ: {"max": "10", "min": 0.0, "count": 3}},          # 文字列
			{GZ: {"max": 10.0, "count": 3}},                      # min なし
			{GZ: [1, 2]},
			"x",
			{GZ: {"max": 80.0, "min": -10.0, "count": 4.0, "duration_ms": 120.0, "peak_abs": INF}},
			{"zz": {"max": 1.0, "min": 0.0, "count": 1}, 1.5: {}, 99: {}},
		],
	})
	assert_true(ok)
	assert_false(a.has_baseline(), "NaN を含む静止測定は捨てる")
	assert_eq(a.trial_count(), 1)
	var r: Dictionary = a.trials()[0][GZ]
	assert_eq(r["count"], 4)
	assert_eq(r["duration_ms"], 120)
	assert_almost_eq(r["peak_abs"], 80.0, 1e-6, "INF の peak_abs は max/min から計算し直す")
	assert_false(a.restore_measurement({"baseline": "x", "trials": 3}), "型が違っても落ちない")


func test_restore_cancels_running_phase() -> void:
	var a := _analyzer()
	var phases: Array = []
	var finished := [0]
	a.phase_changed.connect(func(p: int) -> void: phases.append(p))
	a.trial_finished.connect(func(_i: int, _r: Dictionary) -> void: finished[0] += 1)
	a.start_trial()
	_feed_gz(a, [500.0])
	a.restore_measurement({"trials": [{GZ: {"max": 50.0, "min": 0.0, "count": 1}}]})
	assert_eq(phases, [Phase.TRIAL, Phase.IDLE])
	assert_eq(finished[0], 0, "実行中だった試行は確定しない")
	assert_eq(a.trial_count(), 1)
	assert_almost_eq(a.trials()[0][GZ]["max"], 50.0)


func test_restore_then_continue_measuring() -> void:
	var a := _analyzer()
	a.restore_measurement({"baseline": {GZ: {"mean": 0.0, "stddev": 1.0, "min": -1.0, "max": 1.0, "count": 300}}})
	a.start_trial()
	_feed_gz(a, [0.0, 90.0, 0.0])
	a.stop()
	var rec := a.recommend(GZ, Dir.POSITIVE)
	assert_almost_eq(rec["noise_level"], 4.0)
	assert_almost_eq(rec["weakest_peak"], 90.0)
	assert_eq(rec["quality"], "good")


# ------------------------------------------------------------ ThresholdProfile 側

func test_apply_measurement_to_restores_after_save_and_load() -> void:
	var a := _analyzer()
	a.smoothing_window = 3
	a.start_baseline(100000)
	for i in 40:
		_feed_gz(a, [-2.0 if i % 2 == 0 else 2.0])
	a.stop()
	for peak in [150.0, 220.0]:
		a.start_trial()
		_feed_gz(a, [0.0, peak * 0.5, peak, peak * 0.5, 0.0])
		a.stop()
	var p := ThresholdProfile.new()
	p.smoothing_window = 3
	p.rules.append(a.build_rule(GZ, Dir.POSITIVE))
	p.set_measurement_from(a)
	var loaded := ThresholdProfile.load_file(p.save_to_dir(make_temp_dir()))
	assert_not_null(loaded)
	if loaded == null:
		return

	var b := ThresholdAnalyzer.new()
	b.set_axes(loaded.rule_axes())
	assert_true(loaded.apply_measurement_to(b))
	assert_eq(b.smoothing_window, 3, "プロファイルの平滑化に合わせる")
	# JSON を経由するので浮動小数の最後の桁だけはずれうる
	var rec_b := b.recommend(GZ, Dir.POSITIVE)
	var rec_a := a.recommend(GZ, Dir.POSITIVE)
	assert_eq(rec_b["quality"], rec_a["quality"])
	for k in ["threshold", "hysteresis", "noise_level", "weakest_peak", "margin", "baseline_level"]:
		assert_almost_eq(rec_b[k], rec_a[k], 1e-9, k)

	# 読み込み → 保存し直しても measurement が消えない（PR #5 レビュー M1 の状況）
	var resaved := ThresholdProfile.new()
	resaved.set_measurement_from(b)
	assert_eq(resaved.measurement, loaded.measurement)


func test_measurement_and_rule_axes() -> void:
	var p := ThresholdProfile.new()
	p.rules.append(ThresholdRule.new(GZ, 100.0, Dir.POSITIVE))
	p.rules.append(ThresholdRule.new(AX, 1.0, Dir.ABSOLUTE))
	var off := ThresholdRule.new(SensorAxis.Id.GYRO_MAG, 1.0, Dir.ABSOLUTE)
	off.enabled = false
	p.rules.append(off)
	p.rules.append(ThresholdRule.new(GZ, -100.0, Dir.NEGATIVE))
	assert_eq(p.rule_axes(), [AX, GZ, SensorAxis.Id.GYRO_MAG] as Array[int], "ALL の順・重複なし・無効なルールも含む")
	assert_eq(p.measurement_axes(), [] as Array[int])
	p.measurement = {"baseline": {"ax": {}}, "trials": [{GZ: {}}, {"zz": {}}, "x"]}
	assert_eq(p.measurement_axes(), [AX, GZ] as Array[int], "文字列キーも読み、未知の軸は除く")
