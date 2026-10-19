extends "res://tests/test_case.gd"
## LogReplay（CSV の読み戻し）のテスト。

const P1_CSV := """# device_id=/dev/cu.usbserial-1 nickname=右手
timestamp_ms,ax,ay,az,gx,gy,gz
1000,0.0100,0.9800,0.0200,1.500,-2.000,3.000
1010,0.0200,0.9700,0.0300,2.500,-3.000,4.000
"""


func test_p1_format() -> void:
	var rs := LogReplay.parse_csv_text(P1_CSV)
	assert_eq(rs.size(), 2)
	assert_eq(rs[0].device_id, "/dev/cu.usbserial-1", "情報行の device_id を使う")
	assert_eq(rs[0].timestamp_ms, 1000)
	assert_almost_eq(rs[0].accel.y, 0.98)
	assert_almost_eq(rs[1].gyro.z, 4.0)
	assert_almost_eq(rs[1].gyro.y, -3.0)


func test_axis_subset_format_fills_missing_with_zero() -> void:
	var rs := LogReplay.parse_csv_text("# device_id=d axes=gz,ax\ntimestamp_ms,gz,ax\n5,100.5,0.25\n")
	assert_eq(rs.size(), 1)
	assert_almost_eq(rs[0].gyro.z, 100.5, 1e-6, "列の順番は自由")
	assert_almost_eq(rs[0].accel.x, 0.25)
	assert_eq(rs[0].accel.y, 0.0)
	assert_eq(rs[0].gyro.x, 0.0)


func test_magnitude_columns_are_ignored() -> void:
	var rs := LogReplay.parse_csv_text("timestamp_ms,ax,amag,gmag\n0,0.5,99,99\n")
	assert_eq(rs.size(), 1)
	assert_almost_eq(rs[0].accel.x, 0.5)
	assert_almost_eq(rs[0].accel.length(), 0.5, 1e-6, "合成値は元の軸から再計算される")


func test_crlf_bom_and_blank_lines() -> void:
	var text := "﻿# device_id=w\r\ntimestamp_ms,ax,ay,az,gx,gy,gz\r\n\r\n10,1,2,3,4,5,6\r\n  \r\n20,1,2,3,4,5,6\r\n"
	var rs := LogReplay.parse_csv_text(text)
	assert_eq(rs.size(), 2)
	assert_eq(rs[0].device_id, "w")
	assert_almost_eq(rs[1].gyro.z, 6.0)


func test_bad_rows_are_skipped_and_short_rows_padded() -> void:
	var text := "timestamp_ms,ax,ay,az\n10,1,2,3\n20,abc,2,3\n30,1\n40,nan,0,0\n50,1,2,3,999\n"
	var rs := LogReplay.parse_csv_text(text)
	assert_eq(rs.size(), 3)
	assert_eq(rs[0].timestamp_ms, 10)
	assert_eq(rs[1].timestamp_ms, 30)
	assert_almost_eq(rs[1].accel.y, 0.0, 1e-6, "足りない列は 0")
	assert_eq(rs[2].timestamp_ms, 50, "余分な列は無視")


func test_no_header_assumes_p1_order() -> void:
	var rs := LogReplay.parse_csv_text("100,1,2,3,4,5,6\n")
	assert_eq(rs.size(), 1)
	assert_eq(rs[0].timestamp_ms, 100)
	assert_almost_eq(rs[0].gyro.x, 4.0)


func test_missing_timestamp_column_uses_row_index() -> void:
	var rs := LogReplay.parse_csv_text("ax,gz\n0.1,10\n0.2,20\n0.3,30\n")
	assert_eq(rs.size(), 3)
	assert_eq(rs[0].timestamp_ms, 0)
	assert_eq(rs[2].timestamp_ms, 20, "100Hz 相当（10ms 間隔）")


func test_header_is_case_and_space_insensitive() -> void:
	var rs := LogReplay.parse_csv_text("Timestamp_ms, AX , GZ\n7,0.5,-9\n")
	assert_eq(rs[0].timestamp_ms, 7)
	assert_almost_eq(rs[0].gyro.z, -9.0)


func test_empty_and_comment_only() -> void:
	assert_eq(LogReplay.parse_csv_text("").size(), 0)
	assert_eq(LogReplay.parse_csv_text("# only\n# info\n").size(), 0)
	assert_eq(LogReplay.parse_csv_text("timestamp_ms,ax\n").size(), 0)


func test_load_csv_and_axes_in_from_files() -> void:
	var dir := make_temp_dir()
	var p1 := dir.path_join("p1.csv")
	var sub := dir.path_join("sub.csv")
	write_text(p1, P1_CSV)
	write_text(sub, "# device_id=x axes=gz,gmag\ntimestamp_ms,gz,gmag\n0,1,1\n")
	assert_eq(LogReplay.load_csv(p1).size(), 2)
	assert_eq(LogReplay.axes_in(p1), SensorAxis.RAW)
	assert_eq(LogReplay.axes_in(sub), [SensorAxis.Id.GZ, SensorAxis.Id.GYRO_MAG] as Array[int],
			"合成列も「含まれる軸」として返す")
	var no_id := dir.path_join("no_id.csv")
	write_text(no_id, "timestamp_ms,ax\n0,1\n")
	assert_eq(LogReplay.load_csv(no_id)[0].device_id, "no_id", "情報行が無ければファイル名")


func test_missing_file() -> void:
	assert_eq(LogReplay.load_csv("user://__no_such_dir__/a.csv").size(), 0)
	assert_eq(LogReplay.axes_in("user://__no_such_dir__/a.csv").size(), 0)


func test_returns_typed_array() -> void:
	var rs: Array[SensorReading] = LogReplay.parse_csv_text(P1_CSV)
	assert_eq(rs.get_typed_class_name(), &"RefCounted")
	assert_eq(rs.get_typed_script(), SensorReading)
