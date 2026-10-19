class_name LogReplay
extends RefCounted
## 記録した CSV を SensorReading の列に読み戻す（しきい値の再解析・判定の確認・テスト用）。
##
## 読める形式:
##   P1 形式    : "timestamp_ms,ax,ay,az,gx,gy,gz"（生の6軸すべて）
##   軸指定形式 : "timestamp_ms,ax,gz" のように一部の列だけ（LoggingService.start(device, axes)）
## ルール:
##   ・"#" で始まる行は情報行としてスキップ（"# device_id=…" があれば device_id に使う）
##   ・最初の「数値で始まらない行」を列名ヘッダとみなす。列の順番は自由
##   ・ヘッダに無い軸（欠けた列）は 0。合成列（amag, gmag）は元の3軸から計算できるので読み飛ばす
##     （そのため合成列だけを記録した CSV では合成値を再現できない）
##   ・timestamp_ms 列が無い場合は、行番号 × 10ms（100Hz 相当）を時刻にする
##   ・数値にできない値・NaN/INF を含む行は捨てる。CR(\r) が混ざっていてもよい

const _FALLBACK_INTERVAL_MS := 10


## CSV を読み込む。読めなければ空配列。
static func load_csv(path: String) -> Array[SensorReading]:
	if not FileAccess.file_exists(path):
		return [] as Array[SensorReading]
	var default_id := path.get_file().get_basename()
	return parse_csv_text(FileAccess.get_file_as_string(path), default_id)


## そのCSVに含まれる軸（ヘッダの列順。SensorAxis.Id の配列。合成列も含む）。読めなければ空。
static func axes_in(path: String) -> Array[int]:
	var out: Array[int] = []
	if not FileAccess.file_exists(path):
		return out
	var header := _find_header(FileAccess.get_file_as_string(path))
	for col_name in header:
		var axis := SensorAxis.from_key(col_name)
		if axis >= 0 and not out.has(axis):
			out.append(axis)
	return out


## CSV テキストを読み込む（ファイルを介さない版）。
static func parse_csv_text(text: String, default_device_id: String = "") -> Array[SensorReading]:
	var out: Array[SensorReading] = []
	var device_id := default_device_id
	var columns := PackedStringArray()      ## 列名（ヘッダ）。空 = まだヘッダが無い
	var row_index := 0
	for raw_line in text.split("\n"):
		var line := raw_line.replace("\r", "").replace("﻿", "").strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			var id := _device_id_from_info(line)
			if not id.is_empty():
				device_id = id
			continue
		var cells := line.split(",")
		if not cells[0].strip_edges().is_valid_float():
			if columns.is_empty():
				columns = _normalize_header(cells)
			continue
		if columns.is_empty():
			columns = PackedStringArray(SensorReading.csv_header().split(","))   # ヘッダ無し = P1 形式とみなす
		var reading := _row_to_reading(columns, cells, device_id, row_index)
		if reading != null:
			out.append(reading)
			row_index += 1
	return out


static func _row_to_reading(columns: PackedStringArray, cells: PackedStringArray,
		device_id: String, row_index: int) -> SensorReading:
	var accel := Vector3.ZERO
	var gyro := Vector3.ZERO
	var timestamp := row_index * _FALLBACK_INTERVAL_MS
	for i in mini(columns.size(), cells.size()):
		var cell := cells[i].strip_edges()
		if cell.is_empty():
			continue
		if not cell.is_valid_float():
			return null
		var v := cell.to_float()
		if not is_finite(v):
			return null
		match columns[i]:
			"timestamp_ms": timestamp = int(v)
			"ax": accel.x = v
			"ay": accel.y = v
			"az": accel.z = v
			"gx": gyro.x = v
			"gy": gyro.y = v
			"gz": gyro.z = v
			_: pass   # 合成列・未知の列は無視
	return SensorReading.new(device_id, timestamp, accel, gyro)


static func _normalize_header(cells: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for c in cells:
		out.append(c.strip_edges().to_lower())
	return out


static func _find_header(text: String) -> PackedStringArray:
	for raw_line in text.split("\n"):
		var line := raw_line.replace("\r", "").replace("﻿", "").strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cells := line.split(",")
		if cells[0].strip_edges().is_valid_float():
			return PackedStringArray(SensorReading.csv_header().split(","))
		return _normalize_header(cells)
	return PackedStringArray()


## "# device_id=xxx nickname=…" から device_id を取り出す（無ければ ""）。
static func _device_id_from_info(line: String) -> String:
	for token in line.substr(1).strip_edges().split(" ", false):
		if token.begins_with("device_id="):
			return token.substr("device_id=".length())
	return ""
