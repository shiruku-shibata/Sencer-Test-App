extends "res://tests/test_case.gd"
## ThresholdAnalyzer（静止測定・試行・推奨値）のテスト。

const Dir := ThresholdRule.Direction
const Phase := ThresholdAnalyzer.Phase
const AX := SensorAxis.Id.AX
const GZ := SensorAxis.Id.GZ

var _t := 0


func before_each() -> void:
	_t = 0


func _gz(v: float) -> SensorReading:
	var r := SensorReading.new("d", _t, Vector3.ZERO, Vector3(0.0, 0.0, v))
	_t += 10
	return r


func _feed_gz(a: ThresholdAnalyzer, values: Array) -> void:
	for v in values:
		a.feed(_gz(v))


func _analyzer(axes: Array = [GZ]) -> ThresholdAnalyzer:
	var a := ThresholdAnalyzer.new()
	a.set_axes(axes)
	return a


## 静止値の列と、試行ごとの値の列から測定済みの Analyzer を作る。
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


func test_initial_state() -> void:
	var a := ThresholdAnalyzer.new()
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(a.baseline(), {})
	assert_eq(a.trials(), [])
	assert_almost_eq(a.progress(), 0.0)
	assert_false(a.has_baseline())


func test_baseline_auto_finishes_by_sample_time() -> void:
	var a := _analyzer()
	var finished: Array = []
	a.baseline_finished.connect(func(stats: Dictionary) -> void: finished.append(stats))
	a.start_baseline(100)
	assert_eq(a.phase(), Phase.BASELINE)
	_t = 5000   # 最初のサンプルの時刻が起点（0 からでなくてよい）
	for i in 10:   # 5000..5090
		a.feed(_gz(float(i)))
	assert_eq(a.phase(), Phase.BASELINE, "100ms 経過前は継続")
	assert_almost_eq(a.progress(), 0.9)
	a.feed(_gz(999.0))   # 5100: ちょうど 100ms 経過 → 終了（このサンプルは含めない）
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(finished.size(), 1)
	var s: Dictionary = a.baseline()[GZ]
	assert_eq(s["count"], 10)
	assert_almost_eq(s["mean"], 4.5)
	assert_almost_eq(s["min"], 0.0)
	assert_almost_eq(s["max"], 9.0)
	assert_almost_eq(s["stddev"], sqrt(8.25), 1e-6, "母標準偏差")
	assert_eq(finished[0], a.baseline())
	a.feed(_gz(5000.0))
	assert_almost_eq(a.baseline()[GZ]["max"], 9.0, 1e-6, "終了後のサンプルは無視")


func test_baseline_single_sample_has_zero_stddev() -> void:
	var a := _analyzer()
	a.start_baseline(1000)
	a.feed(_gz(3.0))
	a.stop()
	var s: Dictionary = a.baseline()[GZ]
	assert_eq(s["count"], 1)
	assert_almost_eq(s["stddev"], 0.0)
	assert_false(is_nan(float(s["stddev"])))


func test_baseline_stop_without_samples_keeps_previous() -> void:
	var a := _measured([1.0, 2.0, 3.0], [])
	var before := a.baseline()
	var count := [0]
	a.baseline_finished.connect(func(_s: Dictionary) -> void: count[0] += 1)
	a.start_baseline(1000)
	a.stop()
	assert_eq(count[0], 0, "サンプル0件ではシグナルを出さない")
	assert_eq(a.baseline(), before)


func test_trial_records_peaks() -> void:
	var a := _analyzer()
	var got: Array = []
	a.trial_finished.connect(func(i: int, result: Dictionary) -> void: got.append([i, result]))
	a.start_trial()
	assert_eq(a.phase(), Phase.TRIAL)
	_feed_gz(a, [0.0, 50.0, 220.0, 80.0, -60.0, 0.0])
	assert_almost_eq(a.progress(), 0.0, 1e-6, "時間指定なしの試行は進捗 0")
	a.stop()
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(got.size(), 1)
	assert_eq(got[0][0], 0)
	var r: Dictionary = a.trials()[0][GZ]
	assert_almost_eq(r["max"], 220.0)
	assert_almost_eq(r["min"], -60.0)
	assert_almost_eq(r["peak_abs"], 220.0)
	assert_eq(r["count"], 6)
	assert_eq(r["duration_ms"], 50)


func test_trial_peak_abs_negative_side() -> void:
	var a := _measured([0.0, 0.0], [[0.0, -300.0, 100.0]])
	assert_almost_eq(a.trials()[0][GZ]["peak_abs"], 300.0)


func test_trial_max_duration_auto_stop() -> void:
	var a := _analyzer()
	a.start_trial(50)
	_feed_gz(a, [1.0, 2.0, 3.0])
	assert_almost_eq(a.progress(), 0.4)
	_feed_gz(a, [4.0, 5.0, 6.0, 7.0])
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(a.trial_count(), 1)
	assert_eq(a.trials()[0][GZ]["count"], 5)
	assert_almost_eq(a.trials()[0][GZ]["max"], 5.0)


func test_empty_trial_is_discarded() -> void:
	var a := _analyzer()
	var finished := [0]
	var discarded := [0]
	a.trial_finished.connect(func(_i: int, _r: Dictionary) -> void: finished[0] += 1)
	a.trial_discarded.connect(func() -> void: discarded[0] += 1)
	a.start_trial()
	a.stop()
	assert_eq(finished[0], 0)
	assert_eq(discarded[0], 1)
	assert_eq(a.trial_count(), 0)
	assert_eq(a.phase(), Phase.IDLE)


func test_trial_with_only_nan_is_discarded() -> void:
	var a := _analyzer()
	a.start_trial()
	_feed_gz(a, [NAN, INF])
	a.stop()
	assert_eq(a.trial_count(), 0)


func test_nan_values_are_skipped_in_stats() -> void:
	var a := _measured([1.0, NAN, 3.0], [[10.0, INF, -INF, 20.0]])
	assert_eq(a.baseline()[GZ]["count"], 2)
	assert_almost_eq(a.baseline()[GZ]["mean"], 2.0)
	assert_almost_eq(a.trials()[0][GZ]["max"], 20.0)
	assert_eq(a.trials()[0][GZ]["count"], 2)


func test_phase_changed_signals() -> void:
	var a := _analyzer()
	var phases: Array = []
	a.phase_changed.connect(func(p: int) -> void: phases.append(p))
	a.start_baseline(1000)
	a.feed(_gz(0.0))
	a.start_trial()       # 実行中の静止測定は確定してから試行へ
	a.feed(_gz(10.0))
	a.stop()
	assert_eq(phases, [Phase.BASELINE, Phase.IDLE, Phase.TRIAL, Phase.IDLE])
	assert_true(a.has_baseline(), "途中で試行を始めても静止測定は確定している")
	assert_eq(a.trial_count(), 1)


func test_baseline_readable_from_phase_changed() -> void:
	var a := _analyzer()
	var seen := [false]
	# ラムダが a を掴むと循環参照になるので、終わったら切断する
	var on_phase := func(p: int) -> void:
		if p == Phase.IDLE:
			seen[0] = a.has_baseline()
	a.phase_changed.connect(on_phase)
	a.start_baseline(1000)
	a.feed(_gz(1.0))
	a.stop()
	a.phase_changed.disconnect(on_phase)
	assert_true(seen[0], "IDLE に戻った時点で結果が読める")


func test_timestamp_rewind_does_not_go_negative() -> void:
	var a := _analyzer()
	a.start_baseline(100)
	a.feed(_gz(1.0))
	_t = 0   # 巻き戻り
	for i in 5:
		a.feed(_gz(1.0))
	assert_eq(a.phase(), Phase.BASELINE)
	assert_ge(a.progress(), 0.0)
	assert_eq(a.elapsed_ms(), 40, "巻き戻りは増分 0 として積算")


func test_remove_and_clear() -> void:
	var a := _measured([0.0, 1.0], [[100.0], [200.0], [300.0]])
	assert_eq(a.trial_count(), 3)
	a.remove_trial(1)
	assert_eq(a.trial_count(), 2)
	assert_almost_eq(a.trials()[1][GZ]["max"], 300.0)
	a.remove_trial(10)   # 範囲外は無視
	a.remove_trial(-1)
	assert_eq(a.trial_count(), 2)
	a.clear_trials()
	assert_eq(a.trial_count(), 0)
	assert_true(a.has_baseline(), "clear_trials は静止測定を残す")
	a.clear_all()
	assert_false(a.has_baseline())


func test_clear_all_aborts_running_phase() -> void:
	var a := _analyzer()
	var finished := [0]
	a.trial_finished.connect(func(_i: int, _r: Dictionary) -> void: finished[0] += 1)
	a.start_trial()
	_feed_gz(a, [1.0, 2.0])
	a.clear_all()
	assert_eq(a.phase(), Phase.IDLE)
	assert_eq(finished[0], 0)
	assert_eq(a.trial_count(), 0)


func test_results_are_copies() -> void:
	var a := _measured([0.0, 1.0], [[100.0]])
	var b := a.baseline()
	b[GZ]["max"] = 999.0
	var t := a.trials()
	t[0][GZ]["max"] = 999.0
	t.clear()
	assert_almost_eq(a.baseline()[GZ]["max"], 1.0)
	assert_almost_eq(a.trials()[0][GZ]["max"], 100.0)


func test_set_axes_clears_results_only_when_changed() -> void:
	var a := _measured([0.0, 1.0], [[100.0]])
	a.set_axes([GZ])
	assert_eq(a.trial_count(), 1, "同じ軸なら消さない")
	a.set_axes([GZ, AX])
	assert_eq(a.trial_count(), 0)
	assert_false(a.has_baseline())
	assert_eq(a.axes, [GZ, AX] as Array[int])


func test_set_axes_filters_invalid_and_duplicates() -> void:
	var a := ThresholdAnalyzer.new()
	a.set_axes([GZ, 99, -1, GZ, "ax", AX])
	assert_eq(a.axes, [GZ, AX] as Array[int])


func test_set_axes_aborts_running_phase() -> void:
	var a := _analyzer()
	a.start_baseline(1000)
	a.feed(_gz(1.0))
	a.set_axes([AX])
	assert_eq(a.phase(), Phase.IDLE)
	assert_false(a.has_baseline())


func test_multiple_axes_have_separate_stats() -> void:
	var a := _analyzer([AX, GZ])
	a.start_trial()
	a.feed(SensorReading.new("d", 0, Vector3(1.5, 0, 0), Vector3(0, 0, -100)))
	a.feed(SensorReading.new("d", 10, Vector3(-0.5, 0, 0), Vector3(0, 0, 300)))
	a.stop()
	var r: Dictionary = a.trials()[0]
	assert_almost_eq(r[AX]["max"], 1.5)
	assert_almost_eq(r[AX]["min"], -0.5)
	assert_almost_eq(r[GZ]["max"], 300.0)
	assert_almost_eq(r[GZ]["min"], -100.0)
	assert_false(r.has(SensorAxis.Id.AY), "対象外の軸は記録しない")


func test_smoothing_is_applied_to_analysis() -> void:
	var a := _analyzer()
	a.smoothing_window = 3
	a.start_trial()
	_feed_gz(a, [0.0, 0.0, 300.0, 0.0, 0.0])
	a.stop()
	assert_almost_eq(a.trials()[0][GZ]["max"], 100.0, 1e-4, "3 サンプル平均でピークが 1/3")
	a.smoothing_window = 1
	a.start_trial()
	_feed_gz(a, [0.0, 0.0, 300.0, 0.0, 0.0])
	a.stop()
	assert_almost_eq(a.trials()[1][GZ]["max"], 300.0)


# ------------------------------------------------------------ recommend

func test_recommend_positive_good() -> void:
	# 静止: 平均 0, σ = 1（-1, 1 の繰り返し）→ noise = max(1, 0 + 4) = 4
	var rest: Array = []
	for i in 100:
		rest.append(-1.0 if i % 2 == 0 else 1.0)
	var a := _measured(rest, [[0.0, 120.0, 0.0], [0.0, 200.0, 0.0], [0.0, 160.0, 0.0]])
	var rec := a.recommend(GZ, Dir.POSITIVE, 0.5)
	assert_almost_eq(rec["noise_level"], 4.0)
	assert_almost_eq(rec["weakest_peak"], 120.0)
	assert_almost_eq(rec["margin"], 116.0)
	assert_almost_eq(rec["threshold"], 62.0)
	assert_eq(rec["quality"], "good")
	# hysteresis = margin × 25% = 29、上限 (62 − 0) × 50% = 31 → 29
	assert_almost_eq(rec["hysteresis"], 29.0)
	assert_almost_eq(rec["baseline_level"], 0.0)
	assert_eq(rec["direction"], Dir.POSITIVE)


func test_recommend_ratio_endpoints_and_clamp() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, 100.0]])
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE, 0.0)["threshold"], 4.0, 1e-4, "ratio 0 = ノイズ上限")
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE, 1.0)["threshold"], 100.0, 1e-4, "ratio 1 = 最弱ピーク")
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE, 5.0)["threshold"], 100.0, 1e-4, "1 を超える ratio は 1")
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE, -2.0)["threshold"], 4.0, 1e-4, "負の ratio は 0")
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE, NAN)["threshold"], 52.0, 1e-4, "NaN は 0.5")


func test_recommend_noise_uses_static_max_when_larger() -> void:
	# 1回だけ大きく揺れた静止データ: max(12) > 平均 + 4σ
	var rest: Array = []
	for i in 99:
		rest.append(0.0)
	rest.append(12.0)
	var a := _measured(rest, [[100.0]])
	var b: Dictionary = a.baseline()[GZ]
	assert_lt(float(b["mean"]) + 4.0 * float(b["stddev"]), 12.0, "前提: 4σ より最大値が大きい")
	assert_almost_eq(a.recommend(GZ, Dir.POSITIVE)["noise_level"], 12.0)


func test_recommend_overlap() -> void:
	var a := _measured([-10.0, 10.0, -10.0, 10.0], [[0.0, 30.0, 0.0]])
	var rec := a.recommend(GZ, Dir.POSITIVE)
	assert_almost_eq(rec["noise_level"], 40.0)
	assert_le(rec["margin"], 0.0)
	assert_eq(rec["quality"], "overlap")
	assert_almost_eq(rec["hysteresis"], 0.0)


func test_recommend_tight_by_noise_width() -> void:
	# noise = 4（ノイズ幅 4）, weakest = 7 → margin 3 < 4 → tight
	var a := _measured([-1.0, 1.0], [[7.0], [9.0]])
	var rec := a.recommend(GZ, Dir.POSITIVE)
	assert_almost_eq(rec["margin"], 3.0)
	assert_eq(rec["quality"], "tight")


func test_recommend_tight_boundary_with_offset_baseline() -> void:
	# 静止の平均 100、σ 1 → noise 104（ノイズ幅 4）
	assert_eq(_measured([99.0, 101.0], [[109.0]]).recommend(GZ, Dir.POSITIVE)["quality"], "good",
			"margin 5 >= ノイズ幅 4")
	assert_eq(_measured([99.0, 101.0], [[107.0]]).recommend(GZ, Dir.POSITIVE)["quality"], "tight",
			"margin 3 < ノイズ幅 4（= 振れ幅 7 の半分未満）")
	# 静止ノイズが完全に 0 なら、わずかな差でも good
	var b := _measured([100.0, 100.0, 100.0], [[100.5]])
	var rec := b.recommend(GZ, Dir.POSITIVE)
	assert_almost_eq(rec["noise_level"], 100.0)
	assert_eq(rec["quality"], "good")
	# noise = max(10, 1 + 4×3) = 13 > 11 → overlap
	var c := _measured([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 10.0], [[11.0]])
	assert_eq(c.recommend(GZ, Dir.POSITIVE)["quality"], "overlap")


func test_recommend_tight_negative_and_absolute() -> void:
	var a := _measured([-1.0, 1.0], [[-7.0], [7.0]])
	assert_eq(a.recommend(GZ, Dir.NEGATIVE)["quality"], "overlap", "−側に振れていない試行がある")
	assert_eq(a.recommend(GZ, Dir.ABSOLUTE)["quality"], "tight")
	var b := _measured([-1.0, 1.0], [[-7.0], [-8.0]])
	assert_eq(b.recommend(GZ, Dir.NEGATIVE)["quality"], "tight")


func test_recommend_insufficient() -> void:
	var no_trials := _measured([-1.0, 1.0], [])
	var rec := no_trials.recommend(GZ, Dir.POSITIVE)
	assert_eq(rec["quality"], "insufficient")
	assert_almost_eq(rec["threshold"], 4.0, 1e-4, "静止測定だけならノイズ上限")
	assert_almost_eq(rec["margin"], 0.0)

	var no_base := _analyzer()
	no_base.start_trial()
	_feed_gz(no_base, [0.0, 80.0])
	no_base.stop()
	var rec2 := no_base.recommend(GZ, Dir.POSITIVE, 0.5)
	assert_eq(rec2["quality"], "insufficient")
	assert_almost_eq(rec2["threshold"], 40.0, 1e-4, "試行だけなら静止 0 とみなす")

	var one_sample := _measured([1.0], [[100.0]])
	assert_eq(one_sample.recommend(GZ, Dir.POSITIVE)["quality"], "insufficient", "静止1件では不足")

	var other_axis := _measured([-1.0, 1.0], [[100.0]])
	assert_eq(other_axis.recommend(AX, Dir.POSITIVE)["quality"], "insufficient", "測っていない軸")
	assert_eq(ThresholdAnalyzer.new().recommend(GZ, Dir.ABSOLUTE)["quality"], "insufficient")


func test_recommend_negative() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, -150.0, 40.0], [0.0, -100.0, 0.0]])
	var rec := a.recommend(GZ, Dir.NEGATIVE, 0.5)
	assert_almost_eq(rec["noise_level"], -4.0)
	assert_almost_eq(rec["weakest_peak"], -100.0)
	assert_almost_eq(rec["margin"], 96.0)
	assert_almost_eq(rec["threshold"], -52.0, 1e-4, "NEGATIVE のしきい値はマイナスの値")
	assert_eq(rec["quality"], "good")
	assert_almost_eq(rec["hysteresis"], 24.0)
	var rule := a.build_rule(GZ, Dir.NEGATIVE, 0.5)
	assert_true(rule.exceeds(-100.0))
	assert_false(rule.exceeds(-4.0))


func test_recommend_negative_with_offset_baseline() -> void:
	# az: 静止で +1G（重力）。下向きに落とすと 0 付近まで下がる
	var a := _analyzer([SensorAxis.Id.AZ])
	a.start_baseline(10000)
	for i in 50:
		a.feed(SensorReading.new("d", i * 10, Vector3(0, 0, 0.98 if i % 2 == 0 else 1.02), Vector3.ZERO))
	a.stop()
	a.start_trial()
	for v in [1.0, 0.6, 0.1, 0.5, 1.0]:
		a.feed(SensorReading.new("d", 1000, Vector3(0, 0, v), Vector3.ZERO))
	a.stop()
	var rec := a.recommend(SensorAxis.Id.AZ, Dir.NEGATIVE, 0.5)
	# noise = 1.0 − 4×0.02 = 0.92, weakest = 0.1 → threshold = 0.51（正の値でも「下回ったら」判定）
	assert_almost_eq(rec["noise_level"], 0.92)
	assert_almost_eq(rec["weakest_peak"], 0.1)
	assert_almost_eq(rec["threshold"], 0.51)
	assert_almost_eq(rec["baseline_level"], 1.0)
	assert_eq(rec["quality"], "good")
	assert_eq(a.suggest_direction(SensorAxis.Id.AZ), Dir.NEGATIVE)


func test_recommend_absolute() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, 200.0, -50.0], [0.0, -250.0, 30.0], [0.0, 180.0, 0.0]])
	var rec := a.recommend(GZ, Dir.ABSOLUTE, 0.5)
	assert_almost_eq(rec["noise_level"], 4.0)
	assert_almost_eq(rec["weakest_peak"], 180.0)
	assert_almost_eq(rec["threshold"], 92.0)
	assert_eq(rec["quality"], "good")
	var rule := a.build_rule(GZ, Dir.ABSOLUTE)
	assert_true(rule.exceeds(-180.0))
	assert_true(rule.exceeds(180.0))


func test_recommend_absolute_with_offset_baseline() -> void:
	# 静止が −50 付近に偏っている（例: 傾けて持っている）→ 絶対値のノイズ上限は 50 + 4σ 側
	var a := _measured([-51.0, -49.0], [[300.0]])
	var rec := a.recommend(GZ, Dir.ABSOLUTE)
	assert_almost_eq(rec["noise_level"], 54.0)
	assert_almost_eq(rec["baseline_level"], 50.0)


func test_hysteresis_capped_to_keep_release_above_baseline() -> void:
	# ratio 0 のとき threshold = noise。ヒステリシスは (threshold − 静止平均) × 50% 以下
	var a := _measured([-1.0, 1.0], [[0.0, 400.0]])
	var rec := a.recommend(GZ, Dir.POSITIVE, 0.0)
	assert_almost_eq(rec["threshold"], 4.0)
	assert_almost_eq(rec["hysteresis"], 2.0)
	var release_point := float(rec["threshold"]) - float(rec["hysteresis"])
	assert_gt(release_point, float(rec["baseline_level"]), "解除点は静止平均より上")


func test_build_rule() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, 120.0]])
	var r := a.build_rule(GZ, Dir.POSITIVE, 0.25)
	var rec := a.recommend(GZ, Dir.POSITIVE, 0.25)
	assert_eq(r.axis, GZ)
	assert_eq(r.direction, Dir.POSITIVE)
	assert_almost_eq(r.threshold, rec["threshold"])
	assert_almost_eq(r.hysteresis, rec["hysteresis"])
	assert_true(r.enabled)
	assert_eq(r.refractory_ms, ThresholdRule.DEFAULT_REFRACTORY_MS)


func test_recommend_unknown_direction_falls_back_to_absolute() -> void:
	var a := _measured([-1.0, 1.0], [[0.0, -120.0]])
	assert_eq(a.recommend(GZ, 42)["direction"], Dir.ABSOLUTE)


# ------------------------------------------------------------ suggest_direction

func test_suggest_direction() -> void:
	var rest := [-1.0, 1.0]
	assert_eq(_measured(rest, [[0.0, 200.0, -30.0], [150.0, -20.0]]).suggest_direction(GZ), Dir.POSITIVE)
	assert_eq(_measured(rest, [[0.0, -200.0, 30.0], [-150.0, 40.0]]).suggest_direction(GZ), Dir.NEGATIVE)
	assert_eq(_measured(rest, [[200.0, -180.0]]).suggest_direction(GZ), Dir.ABSOLUTE, "両側に大きく振れる")
	assert_eq(_measured(rest, [[200.0, -10.0], [-200.0, 10.0]]).suggest_direction(GZ), Dir.ABSOLUTE,
			"試行ごとに向きが違う")
	assert_eq(_measured(rest, []).suggest_direction(GZ), Dir.ABSOLUTE, "試行なし")
	assert_eq(_measured(rest, [[0.0, 0.0]]).suggest_direction(GZ), Dir.ABSOLUTE, "振れていない")


func test_suggest_direction_relative_to_baseline_mean() -> void:
	# 静止平均 100 から 60 まで下がる（値はずっとプラス）→ NEGATIVE
	assert_eq(_measured([99.0, 101.0], [[100.0, 60.0, 98.0]]).suggest_direction(GZ), Dir.NEGATIVE)


func test_quality_label() -> void:
	for q in ["good", "tight", "overlap", "insufficient"]:
		assert_ne(ThresholdAnalyzer.quality_label(q), "?")
