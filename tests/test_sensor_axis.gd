extends "res://tests/test_case.gd"
## SensorAxis（軸の定義）のテスト。


func test_all_and_raw_lists() -> void:
	assert_eq(SensorAxis.ALL.size(), 8)
	assert_eq(SensorAxis.RAW.size(), 6)
	for axis in SensorAxis.RAW:
		assert_has(SensorAxis.ALL, axis)
		assert_false(SensorAxis.is_magnitude(axis))


func test_key_roundtrip_for_all_axes() -> void:
	var seen: Dictionary = {}
	for axis in SensorAxis.ALL:
		var k := SensorAxis.key(axis)
		assert_false(k.is_empty(), "軸 %d のキーが空" % axis)
		assert_false(seen.has(k), "キー %s が重複" % k)
		seen[k] = true
		assert_eq(SensorAxis.from_key(k), axis, "キー %s の往復" % k)


func test_keys_are_fixed() -> void:
	# 保存形式なので変わってはいけない
	assert_eq(SensorAxis.keys_of(SensorAxis.ALL),
			PackedStringArray(["ax", "ay", "az", "gx", "gy", "gz", "amag", "gmag"]))


func test_unknown_key_and_axis() -> void:
	assert_eq(SensorAxis.from_key("xyz"), -1)
	assert_eq(SensorAxis.from_key(""), -1)
	assert_eq(SensorAxis.key(99), "")
	assert_eq(SensorAxis.label(99), "?")


func test_value_of_each_axis() -> void:
	var r := SensorReading.new("d", 0, Vector3(0.1, -0.2, 0.3), Vector3(10.0, -20.0, 30.0))
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.AX), 0.1)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.AY), -0.2)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.AZ), 0.3)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.GX), 10.0)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.GY), -20.0)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.GZ), 30.0)


func test_magnitude_values() -> void:
	var r := SensorReading.new("d", 0, Vector3(3.0, 4.0, 0.0), Vector3(1.0, 2.0, 2.0))
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.ACCEL_MAG), 5.0)
	assert_almost_eq(SensorAxis.value_of(r, SensorAxis.Id.GYRO_MAG), 3.0)
	assert_almost_eq(r.magnitude(), 5.0)


func test_unit_and_kind() -> void:
	assert_eq(SensorAxis.unit(SensorAxis.Id.AX), "G")
	assert_eq(SensorAxis.unit(SensorAxis.Id.ACCEL_MAG), "G")
	assert_eq(SensorAxis.unit(SensorAxis.Id.GZ), "deg/s")
	assert_eq(SensorAxis.unit(SensorAxis.Id.GYRO_MAG), "deg/s")
	assert_true(SensorAxis.is_magnitude(SensorAxis.Id.GYRO_MAG))
	assert_true(SensorAxis.is_accel(SensorAxis.Id.AZ))
	assert_false(SensorAxis.is_accel(SensorAxis.Id.GX))
	assert_gt(SensorAxis.default_range(SensorAxis.Id.GX), SensorAxis.default_range(SensorAxis.Id.AX))
