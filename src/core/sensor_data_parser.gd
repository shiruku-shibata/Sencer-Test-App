class_name SensorDataParser
extends RefCounted
## デバイスから届いた1行のテキストを SensorReading に変換する。
##
## 対応フォーマット:
##   CSV : "ax,ay,az,gx,gy,gz"
##   JSON: {"ax":0.0,"ay":1.0,"az":0.0,"gx":0.0,"gy":0.0,"gz":0.0}
##
## 変換できない行では null を返す（受信ノイズや起動時のログ行を無視するため）。

static func parse_line(line: String, device_id: String) -> SensorReading:
	var text := line.strip_edges()
	if text.is_empty():
		return null

	if text.begins_with("{"):
		return _parse_json(text, device_id)
	return _parse_csv(text, device_id)


static func _parse_csv(text: String, device_id: String) -> SensorReading:
	var parts := text.split(",", false)
	if parts.size() < 6:
		return null
	for p in parts:
		if not p.strip_edges().is_valid_float():
			return null
	var accel := Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	var gyro := Vector3(float(parts[3]), float(parts[4]), float(parts[5]))
	return SensorReading.new(device_id, Time.get_ticks_msec(), accel, gyro)


static func _parse_json(text: String, device_id: String) -> SensorReading:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = parsed
	if not (d.has("ax") and d.has("ay") and d.has("az")):
		return null
	var accel := Vector3(float(d.get("ax", 0.0)), float(d.get("ay", 0.0)), float(d.get("az", 0.0)))
	var gyro := Vector3(float(d.get("gx", 0.0)), float(d.get("gy", 0.0)), float(d.get("gz", 0.0)))
	return SensorReading.new(device_id, Time.get_ticks_msec(), accel, gyro)
