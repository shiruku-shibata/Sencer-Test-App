extends "res://tests/test_case.gd"
## ThresholdRule（1軸ぶんのしきい値ルール）のテスト。

const Dir := ThresholdRule.Direction


func test_defaults() -> void:
	var r := ThresholdRule.new()
	assert_true(r.enabled)
	assert_eq(r.direction, Dir.ABSOLUTE)
	assert_almost_eq(r.threshold, 0.0)
	assert_almost_eq(r.hysteresis, 0.0)
	assert_eq(r.refractory_ms, 200)


func test_positive_exceeds_and_released() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.GZ, 100.0, Dir.POSITIVE, 20.0)
	assert_true(r.exceeds(100.0), "ちょうどしきい値は判定に入る")
	assert_true(r.exceeds(150.0))
	assert_false(r.exceeds(99.9))
	assert_false(r.exceeds(-500.0), "逆向きは判定しない")
	assert_false(r.released(90.0), "ヒステリシス内では解除しない")
	assert_false(r.released(80.0), "ちょうど戻った位置はまだ解除しない")
	assert_true(r.released(79.9))
	assert_true(r.released(-500.0))


func test_negative_exceeds_and_released() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.AX, -1.5, Dir.NEGATIVE, 0.5)
	assert_true(r.exceeds(-1.5))
	assert_true(r.exceeds(-3.0))
	assert_false(r.exceeds(-1.4))
	assert_false(r.exceeds(3.0), "逆向きは判定しない")
	assert_false(r.released(-1.2))
	assert_false(r.released(-1.0))
	assert_true(r.released(-0.9))


func test_absolute_exceeds_and_released() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.GX, 200.0, Dir.ABSOLUTE, 50.0)
	assert_true(r.exceeds(200.0))
	assert_true(r.exceeds(-200.0))
	assert_true(r.exceeds(-350.0))
	assert_false(r.exceeds(199.0))
	assert_false(r.exceeds(-199.0))
	assert_false(r.released(-160.0))
	assert_true(r.released(149.0))
	assert_true(r.released(-149.0))


func test_absolute_with_negative_threshold_uses_magnitude() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.GX, -200.0, Dir.ABSOLUTE)
	assert_true(r.exceeds(250.0))
	assert_true(r.exceeds(-250.0))
	assert_false(r.exceeds(100.0))


func test_zero_hysteresis_is_complementary() -> void:
	for d in [Dir.POSITIVE, Dir.NEGATIVE, Dir.ABSOLUTE]:
		var r := ThresholdRule.new(SensorAxis.Id.AX, 1.0 if d != Dir.NEGATIVE else -1.0, d, 0.0)
		for v in [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0]:
			assert_ne(r.exceeds(v), r.released(v), "向き %d 値 %s" % [d, v])


func test_negative_hysteresis_treated_as_zero() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.AX, 1.0, Dir.POSITIVE, -0.5)
	assert_true(r.released(0.99))
	assert_eq(r.release_line_values().size(), 0)


func test_nan_never_exceeds_nor_releases() -> void:
	for d in [Dir.POSITIVE, Dir.NEGATIVE, Dir.ABSOLUTE]:
		var r := ThresholdRule.new(SensorAxis.Id.AX, 1.0, d)
		assert_false(r.exceeds(NAN))
		assert_false(r.released(NAN))


func test_line_values() -> void:
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, 1.5, Dir.POSITIVE).line_values(),
			PackedFloat32Array([1.5]))
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, -1.5, Dir.NEGATIVE).line_values(),
			PackedFloat32Array([-1.5]))
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, 1.5, Dir.ABSOLUTE).line_values(),
			PackedFloat32Array([1.5, -1.5]))
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, -1.5, Dir.ABSOLUTE).line_values(),
			PackedFloat32Array([1.5, -1.5]), "ABSOLUTE は符号に関係なく ±")


func test_release_line_values() -> void:
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, 1.5, Dir.POSITIVE, 0.5).release_line_values(),
			PackedFloat32Array([1.0]))
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, -1.5, Dir.NEGATIVE, 0.5).release_line_values(),
			PackedFloat32Array([-1.0]))
	assert_eq(ThresholdRule.new(SensorAxis.Id.AX, 1.5, Dir.ABSOLUTE, 0.5).release_line_values(),
			PackedFloat32Array([1.0, -1.0]))


func test_dict_roundtrip_all_directions_and_axes() -> void:
	for axis in SensorAxis.ALL:
		for d in [Dir.POSITIVE, Dir.NEGATIVE, Dir.ABSOLUTE]:
			var r := ThresholdRule.new(axis, -12.25 if d == Dir.NEGATIVE else 12.25, d, 3.5, 350)
			r.enabled = (axis % 2 == 0)
			var r2 := ThresholdRule.from_dict(r.to_dict())
			assert_not_null(r2)
			if r2 == null:
				continue
			assert_eq(r2.axis, axis)
			assert_eq(r2.direction, d)
			assert_almost_eq(r2.threshold, r.threshold)
			assert_almost_eq(r2.hysteresis, 3.5)
			assert_eq(r2.refractory_ms, 350)
			assert_eq(r2.enabled, r.enabled)


func test_to_dict_uses_string_keys() -> void:
	var d := ThresholdRule.new(SensorAxis.Id.GZ, 180.0, Dir.POSITIVE, 30.0, 250).to_dict()
	assert_eq(d["axis"], "gz")
	assert_eq(d["direction"], "positive")
	assert_eq(d["threshold"], 180.0)
	assert_eq(d["refractory_ms"], 250)


func test_dict_survives_json() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.ACCEL_MAG, 2.25, Dir.POSITIVE, 0.4, 120)
	var parsed: Variant = JSON.parse_string(JSON.stringify(r.to_dict()))
	var r2 := ThresholdRule.from_dict(parsed)
	assert_not_null(r2)
	assert_eq(r2.axis, SensorAxis.Id.ACCEL_MAG)
	assert_eq(r2.refractory_ms, 120)
	assert_eq(typeof(r2.refractory_ms), TYPE_INT)


func test_from_dict_accepts_enum_numbers() -> void:
	var r := ThresholdRule.from_dict({"axis": SensorAxis.Id.GY, "direction": Dir.NEGATIVE, "threshold": -5})
	assert_not_null(r)
	assert_eq(r.axis, SensorAxis.Id.GY)
	assert_eq(r.direction, Dir.NEGATIVE)
	assert_almost_eq(r.threshold, -5.0)


func test_from_dict_rejects_invalid() -> void:
	assert_null(ThresholdRule.from_dict({}), "軸なし")
	assert_null(ThresholdRule.from_dict({"axis": "xyz"}), "未知の軸")
	assert_null(ThresholdRule.from_dict({"axis": 99}), "範囲外の軸番号")
	assert_null(ThresholdRule.from_dict({"axis": 1.5}), "小数の軸番号")
	assert_null(ThresholdRule.from_dict({"axis": "gz", "direction": "up"}), "未知の向き")
	assert_null(ThresholdRule.from_dict({"axis": "gz", "threshold": "abc"}), "数値でないしきい値")
	assert_null(ThresholdRule.from_dict({"axis": "gz", "hysteresis": [1]}), "数値でないヒステリシス")


func test_from_dict_defaults_and_sanitizing() -> void:
	var r := ThresholdRule.from_dict({"axis": "ax", "hysteresis": -3.0, "refractory_ms": -10, "enabled": "yes"})
	assert_not_null(r)
	assert_eq(r.direction, Dir.ABSOLUTE)
	assert_almost_eq(r.hysteresis, 0.0)
	assert_eq(r.refractory_ms, 0)
	assert_true(r.enabled, "bool でない enabled は既定値 true")


func test_to_dict_replaces_non_finite() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.AX, NAN, Dir.POSITIVE, INF)
	var d := r.to_dict()
	assert_eq(d["threshold"], 0.0)
	assert_eq(d["hysteresis"], 0.0)
	assert_contains(JSON.stringify(d), "\"threshold\":0")


func test_direction_label_and_keys() -> void:
	assert_eq(ThresholdRule.direction_label(Dir.POSITIVE), "＋方向")
	assert_eq(ThresholdRule.direction_label(Dir.NEGATIVE), "−方向")
	assert_eq(ThresholdRule.direction_label(Dir.ABSOLUTE), "絶対値")
	assert_eq(ThresholdRule.direction_label(42), "?")
	for d in [Dir.POSITIVE, Dir.NEGATIVE, Dir.ABSOLUTE]:
		assert_eq(ThresholdRule.direction_from_key(ThresholdRule.direction_key(d)), d)
	assert_eq(ThresholdRule.direction_from_key("sideways"), -1)


func test_copy_is_independent() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.GZ, 10.0, Dir.POSITIVE, 1.0, 300)
	r.enabled = false
	var c := r.copy()
	assert_eq(c.to_dict(), r.to_dict())
	c.threshold = 99.0
	assert_almost_eq(r.threshold, 10.0)


func test_summary() -> void:
	assert_contains(ThresholdRule.new(SensorAxis.Id.GZ, 180.0, Dir.POSITIVE).summary(), "ジャイロ Z")
	assert_contains(ThresholdRule.new(SensorAxis.Id.GZ, 180.0, Dir.POSITIVE).summary(), "≥")
	assert_contains(ThresholdRule.new(SensorAxis.Id.AX, -1.0, Dir.NEGATIVE).summary(), "≤")
	assert_contains(ThresholdRule.new(SensorAxis.Id.AX, 1.0, Dir.ABSOLUTE).summary(), "|加速度 X|")
