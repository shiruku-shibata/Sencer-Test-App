extends "res://tests/test_case.gd"
## SensorDataParser（受信1行 → SensorReading）のテスト。


func _parse(line: String) -> SensorReading:
	return SensorDataParser.parse_line(line, "dev")


func test_csv() -> void:
	var r := _parse("0.01,0.98,-0.02,1.5,-2.25,300")
	assert_not_null(r)
	assert_eq(r.device_id, "dev")
	assert_almost_eq(r.accel.y, 0.98)
	assert_almost_eq(r.accel.z, -0.02)
	assert_almost_eq(r.gyro.y, -2.25)
	assert_almost_eq(r.gyro.z, 300.0)
	assert_gt(float(r.timestamp_ms), -1.0)


func test_csv_with_spaces_and_extra_columns() -> void:
	var r := _parse(" 1 , 2 ,3,4,5,6,7")
	assert_not_null(r, "7列目以降は無視")
	assert_almost_eq(r.accel.x, 1.0)
	assert_almost_eq(r.gyro.z, 6.0)


func test_csv_scientific_notation() -> void:
	var r := _parse("1e-3,0,0,0,0,2.5E2")
	assert_not_null(r)
	assert_almost_eq(r.accel.x, 0.001)
	assert_almost_eq(r.gyro.z, 250.0)


func test_cr_is_tolerated() -> void:
	assert_not_null(_parse("1,2,3,4,5,6\r"))
	assert_not_null(_parse("1,2,3,4,5,6\r\n"))
	assert_not_null(_parse("1,2,3\r,4,5,6"), "途中の CR も除く")
	assert_not_null(_parse("﻿1,2,3,4,5,6"), "BOM")


func test_info_lines_are_null() -> void:
	assert_null(_parse("# model=M5StickCPlus2 rate=100"))
	assert_null(_parse("#1,2,3,4,5,6"), "数値が並んでいても # 行は情報")
	assert_null(_parse("  # indented info"))
	assert_null(_parse("#\r"))
	assert_true(SensorDataParser.is_info_line("# x"))
	assert_false(SensorDataParser.is_info_line("1,2,3,4,5,6"))


func test_garbage_is_null() -> void:
	for line in ["", "   ", "\r", "hello", "1,2,3", "1,2,3,4,5", "1,2,x,4,5,6", "a,b,c,d,e,f",
			"nan,0,0,0,0,0", "inf,0,0,0,0,0", "ets Jun  8 2016 00:22:57", ",,,,,", "{", "}", "[1,2,3,4,5,6]"]:
		assert_null(_parse(line), "「%s」" % line.c_escape())


func test_json_full() -> void:
	var r := _parse("{\"ax\":0.1,\"ay\":0.2,\"az\":0.3,\"gx\":4,\"gy\":5,\"gz\":6}")
	assert_not_null(r)
	assert_almost_eq(r.accel.z, 0.3)
	assert_almost_eq(r.gyro.x, 4.0)


func test_json_partial_axes() -> void:
	var r := _parse("{\"gz\":1.0}")
	assert_not_null(r, "一部の軸だけでも受け付ける")
	assert_almost_eq(r.gyro.z, 1.0)
	assert_eq(r.accel, Vector3.ZERO)
	var r2 := _parse("{\"ax\": -0.5, \"t\": 123}")
	assert_not_null(r2, "知らないキーは無視")
	assert_almost_eq(r2.accel.x, -0.5)


func test_json_string_numbers() -> void:
	var r := _parse("{\"gz\":\"12.5\"}")
	assert_not_null(r)
	assert_almost_eq(r.gyro.z, 12.5)


func test_json_invalid() -> void:
	for line in ["{}", "{\"type\":\"info\"}", "{\"gz\":\"abc\"}", "{\"gz\":null}", "{\"gz\":[1]}",
			"{\"gz\":true}", "{bad json", "{\"ax\":1", "{\"ax\":1}garbage"]:
		assert_null(_parse(line), line)


func test_json_with_cr() -> void:
	assert_not_null(_parse("{\"ax\":1}\r"))


# --- 入れ子の JSON（Beer-fw 形式） ---------------------------------------------

func test_nested_accel_json_beer_fw() -> void:
	var r := _parse('{"node":0,"mac":"00:4B:12:A2:4C:5D","seq":6,"t":4641,"accel":{"x":-0.0176,"y":0.0101,"z":0.9781}}')
	assert_not_null(r, "Beer-fw ゲートウェイの行を読める")
	assert_almost_eq(r.accel.x, -0.0176)
	assert_almost_eq(r.accel.y, 0.0101)
	assert_almost_eq(r.accel.z, 0.9781)
	assert_eq(r.gyro, Vector3.ZERO, "ジャイロが無ければ 0")
	assert_eq(r.source_node, 0)
	assert_eq(r.source_mac, "00:4B:12:A2:4C:5D")


func test_nested_json_with_extra_fields_and_gyro() -> void:
	var r := _parse('{"node":1,"mac":"64:B7:08:85:64:54","seq":12,"rx":1,"accel":{"x":0.1,"y":0.2,"z":0.3},"gyro":{"x":10,"y":-20,"z":30},"drink":{"armed":0},"battery":{"level":1}}')
	assert_not_null(r)
	assert_almost_eq(r.accel.z, 0.3)
	assert_almost_eq(r.gyro.y, -20.0)
	assert_eq(r.source_node, 1)


func test_nested_json_without_node_has_no_source() -> void:
	var r := _parse('{"accel":{"x":0,"y":0,"z":1}}')
	assert_not_null(r)
	assert_eq(r.source_node, -1)


func test_nested_json_rejects_bad_values() -> void:
	assert_null(_parse('{"accel":{"x":"abc","y":0,"z":1}}'), "数値でない")
	assert_null(_parse('{"accel":[0,0,1]}'), "accel がオブジェクトでない")
	assert_null(_parse('{"node":1,"battery":{"level":1}}'), "加速度もジャイロも無い行")
