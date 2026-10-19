class_name SensorDataParser
extends RefCounted
## デバイスから届いた1行のテキストを SensorReading に変換する。
##
## 対応フォーマット:
##   CSV : "ax,ay,az,gx,gy,gz"（7列目以降は無視）
##   JSON: {"ax":0.0,"ay":1.0,"az":0.0,"gx":0.0,"gy":0.0,"gz":0.0}
##         一部の軸だけ（例 {"gz":1.0}）でもよい。欠けた軸は 0。6軸のどれも無ければ変換しない。
##
## 変換できない行では null を返す（受信ノイズや起動時のログ行を無視するため）。
## "#" で始まる行はデバイスからの情報行（例 "# model=M5StickCPlus2 rate=100"）なので必ず null。
## 改行コード CR(\r) や先頭の BOM が混ざっていても読める。NaN / INF を含む行は捨てる。

const _JSON_KEYS := ["ax", "ay", "az", "gx", "gy", "gz"]


static func parse_line(line: String, device_id: String) -> SensorReading:
	var text := line.replace("\r", "").replace("﻿", "").strip_edges()
	if text.is_empty() or text.begins_with("#"):
		return null

	if text.begins_with("{"):
		return _parse_json(text, device_id)
	return _parse_csv(text, device_id)


## 情報行（"#" で始まる行）か。
static func is_info_line(line: String) -> bool:
	return line.replace("﻿", "").strip_edges().begins_with("#")


static func _parse_csv(text: String, device_id: String) -> SensorReading:
	var parts := text.split(",", false)
	if parts.size() < 6:
		return null
	var values := PackedFloat64Array()
	for p in parts:
		var s := p.strip_edges()
		if not s.is_valid_float():
			return null
		var v := s.to_float()
		if not is_finite(v):
			return null
		values.append(v)
	var accel := Vector3(values[0], values[1], values[2])
	var gyro := Vector3(values[3], values[4], values[5])
	return SensorReading.new(device_id, Time.get_ticks_msec(), accel, gyro)


static func _parse_json(text: String, device_id: String) -> SensorReading:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	if typeof(json.data) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = json.data
	var v := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var found := 0
	for i in _JSON_KEYS.size():
		if not d.has(_JSON_KEYS[i]):
			continue
		var raw: Variant = d[_JSON_KEYS[i]]
		var f := 0.0
		match typeof(raw):
			TYPE_INT, TYPE_FLOAT:
				f = float(raw)
			TYPE_STRING:
				if not String(raw).strip_edges().is_valid_float():
					return null
				f = String(raw).strip_edges().to_float()
			_:
				return null
		if not is_finite(f):
			return null
		v[i] = f
		found += 1
	if found == 0:
		return null
	return SensorReading.new(device_id, Time.get_ticks_msec(),
			Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]))
