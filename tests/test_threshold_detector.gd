extends "res://tests/test_case.gd"
## ThresholdDetector（判定器）のテスト。

const Dir := ThresholdRule.Direction
const AX := SensorAxis.Id.AX
const AY := SensorAxis.Id.AY
const GZ := SensorAxis.Id.GZ

var _t := 0


func before_each() -> void:
	_t = 0


## ax / gz を指定したサンプル（時刻は 10ms ずつ進む）。
func _r(ax: float, gz: float = 0.0, ts: int = -1) -> SensorReading:
	if ts >= 0:
		_t = ts
	var r := SensorReading.new("d", _t, Vector3(ax, 0.0, 0.0), Vector3(0.0, 0.0, gz))
	_t += 10
	return r


func _detector(rules: Array, combine: int = ThresholdDetector.Combine.ANY, window: int = 1) -> ThresholdDetector:
	var d := ThresholdDetector.new()
	d.configure(rules, combine, window)
	return d


## ax の値の列を流して、feed が true になった位置の一覧を返す。
func _fire_indices(d: ThresholdDetector, values: Array) -> Array:
	var out: Array = []
	for i in values.size():
		if d.feed(_r(values[i])):
			out.append(i)
	return out


func test_empty_rules_never_fire() -> void:
	var d := _detector([])
	for v in [0.0, 100.0, -100.0]:
		assert_false(d.feed(_r(v, v)))
	assert_false(d.is_active())
	assert_eq(d.trigger_count, 0)


func test_fires_once_on_rising_edge() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0)])
	assert_eq(_fire_indices(d, [0.0, 1.2, 1.5, 1.3, 0.2, 0.1, 2.0, 0.0]), [1, 6])
	assert_eq(d.trigger_count, 2)


func test_hysteresis_prevents_chattering() -> void:
	# しきい値 1.0 付近で揺れる波形
	var wave := [0.0, 1.1, 0.95, 1.05, 0.9, 1.08, 0.75, 1.02, 0.5, 1.1, 0.0]
	var with_h := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.3, 0)])
	assert_eq(_fire_indices(with_h, wave), [1, 9], "ヒステリシスあり: 0.7 を下回るまで解除しない")
	var without_h := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0)])
	assert_eq(_fire_indices(without_h, wave), [1, 3, 5, 7, 9], "ヒステリシスなしだとチャタリングする")


func test_refractory_suppresses_quick_retrigger() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 200)])
	assert_true(d.feed(_r(2.0, 0.0, 1000)), "1回目")
	assert_false(d.feed(_r(0.0, 0.0, 1050)))
	assert_false(d.feed(_r(2.0, 0.0, 1100)), "100ms 後の立ち上がりは不応期で捨てる")
	assert_false(d.feed(_r(2.0, 0.0, 1250)), "条件が続いていても遅れて発火しない")
	assert_false(d.feed(_r(0.0, 0.0, 1260)))
	assert_true(d.feed(_r(2.0, 0.0, 1300)), "300ms 後は判定する")
	assert_eq(d.trigger_count, 2)
	assert_eq(d.last_fire_ms(), 1300)


func test_refractory_boundary_is_exclusive() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 200)])
	assert_true(d.feed(_r(2.0, 0.0, 0)))
	assert_false(d.feed(_r(0.0, 0.0, 100)))
	assert_false(d.feed(_r(2.0, 0.0, 199)))
	assert_false(d.feed(_r(0.0, 0.0, 199)))
	assert_true(d.feed(_r(2.0, 0.0, 200)), "ちょうど refractory_ms 経過で判定できる")


func test_refractory_uses_max_of_enabled_rules() -> void:
	var d := _detector([
		ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 100),
		ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 500),
	])
	assert_eq(d.effective_refractory_ms(), 500)
	d.rules[1].enabled = false
	assert_eq(d.effective_refractory_ms(), 100)


func test_timestamp_rewind_clears_refractory() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 1000)])
	assert_true(d.feed(_r(2.0, 0.0, 5000)))
	assert_false(d.feed(_r(0.0, 0.0, 5010)))
	assert_true(d.feed(_r(2.0, 0.0, 20)), "時刻が巻き戻ったら不応期を解除する")


func test_any_combination() -> void:
	var d := _detector([
		ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0),
		ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0),
	], ThresholdDetector.Combine.ANY)
	assert_true(d.feed(_r(2.0, 0.0)), "ax だけで判定")
	assert_false(d.feed(_r(2.0, 200.0)), "判定中に別軸が来ても再判定しない")
	assert_false(d.feed(_r(0.0, 200.0)), "gz がまだ判定中")
	assert_false(d.feed(_r(0.0, 0.0)))
	assert_true(d.feed(_r(0.0, 200.0)), "gz だけで判定")


func test_all_combination() -> void:
	var d := _detector([
		ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0),
		ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0),
	], ThresholdDetector.Combine.ALL)
	assert_false(d.feed(_r(2.0, 0.0)), "ax だけでは判定しない")
	assert_true(d.axis_active(AX))
	assert_false(d.axis_active(GZ))
	assert_false(d.is_active())
	assert_true(d.feed(_r(2.0, 200.0)), "両方そろったら判定")
	assert_true(d.is_active())
	assert_false(d.feed(_r(0.0, 200.0)))
	assert_false(d.is_active())
	assert_true(d.feed(_r(2.0, 200.0)), "再び両方そろった")


func test_all_with_disabled_rule_uses_only_enabled() -> void:
	var off := ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0)
	off.enabled = false
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0), off], ThresholdDetector.Combine.ALL)
	assert_true(d.feed(_r(2.0, 0.0)), "無効なルールは ALL の条件に含めない")


func test_disabled_rules_are_ignored() -> void:
	var r := ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0)
	r.enabled = false
	var d := _detector([r])
	assert_false(d.feed(_r(5.0)))
	assert_false(d.axis_active(AX))
	r.enabled = true
	assert_true(d.feed(_r(5.0)), "有効にすれば次のサンプルから判定する")
	r.enabled = false
	assert_false(d.feed(_r(5.0)))
	assert_false(d.is_active(), "無効にしたルールのラッチは解除される")


func test_smoothing_suppresses_single_spike() -> void:
	var spike := [0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0]
	var raw := _detector([ThresholdRule.new(AX, 1.5, Dir.POSITIVE, 0.0, 0)], ThresholdDetector.Combine.ANY, 1)
	assert_eq(_fire_indices(raw, spike), [3])
	var smooth := _detector([ThresholdRule.new(AX, 1.5, Dir.POSITIVE, 0.0, 0)], ThresholdDetector.Combine.ANY, 3)
	assert_eq(_fire_indices(smooth, spike), [], "3 サンプル平均で 1.0 になり判定しない")
	assert_almost_eq(smooth.last_value(AX), 0.0)


func test_smoothing_detects_sustained_motion() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.5, Dir.POSITIVE, 0.0, 0)], ThresholdDetector.Combine.ANY, 3)
	assert_eq(_fire_indices(d, [0.0, 2.0, 2.0, 2.0, 2.0]), [3], "3 サンプル平均が 1.5 を超えた時点")
	assert_almost_eq(d.last_value(AX), 2.0)


func test_smoothing_window_setter() -> void:
	var d := ThresholdDetector.new()
	d.smoothing_window = 0
	assert_eq(d.smoothing_window, 1)
	d.configure([ThresholdRule.new(AX, 1.5, Dir.POSITIVE, 0.0, 0)], ThresholdDetector.Combine.ANY, 4)
	assert_eq(d.smoothing_window, 4)


func test_negative_and_absolute_rules() -> void:
	var neg := _detector([ThresholdRule.new(AX, -1.0, Dir.NEGATIVE, 0.2, 0)])
	assert_eq(_fire_indices(neg, [0.0, 2.0, -1.2, -0.9, -1.1, 0.0, -1.5]), [2, 6])
	var abs_d := _detector([ThresholdRule.new(AX, 1.0, Dir.ABSOLUTE, 0.2, 0)])
	assert_eq(_fire_indices(abs_d, [0.0, 1.2, 0.0, -1.2, -0.9, -1.3, 0.1, 1.0]), [1, 3, 7])


func test_same_axis_two_directions_any() -> void:
	# gz を ＋方向・−方向の2ルールで見る（どちらに振っても判定）
	var d := _detector([
		ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0),
		ThresholdRule.new(GZ, -100.0, Dir.NEGATIVE, 0.0, 0),
	], ThresholdDetector.Combine.ANY, 2)
	var fires := 0
	for gz in [0.0, 300.0, 300.0, 0.0, 0.0, -300.0, -300.0, 0.0, 0.0]:
		if d.feed(_r(0.0, gz)):
			fires += 1
	assert_eq(fires, 2)
	# 平滑化は軸ごと1回: 同じ軸を2ルールで使っても値は二重に push されない
	assert_almost_eq(d.last_value(GZ), 0.0)


func test_fired_signal_carries_values() -> void:
	var d := _detector([
		ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0),
		ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0),
	])
	var got: Array = []
	d.fired.connect(func(ts: int, values: Dictionary) -> void: got.append([ts, values]))
	d.feed(_r(0.0, 0.0, 500))
	d.feed(_r(2.5, 40.0))
	assert_eq(got.size(), 1)
	assert_eq(got[0][0], 510)
	assert_almost_eq(float(got[0][1][AX]), 2.5)
	assert_almost_eq(float(got[0][1][GZ]), 40.0)


func test_reset_clears_state_and_count() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 1000)], ThresholdDetector.Combine.ANY, 2)
	d.feed(_r(3.0))
	d.feed(_r(3.0))
	assert_eq(d.trigger_count, 1)
	assert_true(d.is_active())
	d.reset()
	assert_eq(d.trigger_count, 0)
	assert_false(d.is_active())
	assert_false(d.axis_active(AX))
	assert_almost_eq(d.last_value(AX), 0.0)
	assert_eq(d.last_fire_ms(), -1)
	assert_true(d.feed(_r(3.0)), "reset 後は不応期も解除")
	assert_eq(d.rules.size(), 1, "ルールは残る")


func test_rules_are_live_references() -> void:
	var r := ThresholdRule.new(AX, 5.0, Dir.POSITIVE, 0.0, 0)
	var d := _detector([r])
	assert_false(d.feed(_r(2.0)))
	r.threshold = 1.0   # UI でドラッグして変更した想定
	assert_true(d.feed(_r(2.0)))


func test_rules_array_modified_directly() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0)])
	d.feed(_r(0.0))
	d.rules.append(ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0))
	assert_true(d.feed(_r(0.0, 200.0)), "後から追加したルールも判定する")
	assert_true(d.axis_active(GZ))


func test_configure_ignores_non_rules_and_bad_combine() -> void:
	var d := ThresholdDetector.new()
	d.configure([ThresholdRule.new(AX, 1.0, Dir.POSITIVE), "x", null, 3], 99, 1)
	assert_eq(d.rules.size(), 1)
	assert_eq(d.combine, ThresholdDetector.Combine.ANY)


func test_nan_sample_keeps_state() -> void:
	var d := _detector([ThresholdRule.new(AX, 1.0, Dir.POSITIVE, 0.0, 0)])
	assert_true(d.feed(_r(2.0)))
	assert_false(d.feed(SensorReading.new("d", 100, Vector3(NAN, 0, 0), Vector3.ZERO)))
	assert_true(d.is_active(), "NaN では解除しない")
	assert_almost_eq(d.last_value(AX), 2.0)
	assert_false(d.feed(null))


func test_magnitude_axis_rule() -> void:
	var d := _detector([ThresholdRule.new(SensorAxis.Id.ACCEL_MAG, 2.0, Dir.POSITIVE, 0.0, 0)])
	assert_false(d.feed(SensorReading.new("d", 0, Vector3(0, 0, 1), Vector3.ZERO)))
	assert_true(d.feed(SensorReading.new("d", 10, Vector3(1.5, 1.5, 1.0), Vector3.ZERO)))


func test_combine_keys_and_labels() -> void:
	for c in [ThresholdDetector.Combine.ANY, ThresholdDetector.Combine.ALL]:
		assert_eq(ThresholdDetector.combine_from_key(ThresholdDetector.combine_key(c)), c)
		assert_ne(ThresholdDetector.combine_label(c), "?")
	assert_eq(ThresholdDetector.combine_from_key("most"), -1)
	assert_eq(ThresholdDetector.combine_key(ThresholdDetector.Combine.ALL), "all")
	# AY を使わない警告回避ではなく、未使用の軸は判定に影響しないことの確認
	var d := _detector([ThresholdRule.new(AY, 1.0, Dir.POSITIVE, 0.0, 0)])
	assert_false(d.feed(_r(5.0, 500.0)))
