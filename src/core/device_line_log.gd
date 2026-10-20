class_name DeviceLineLog
extends RefCounted
## デバイスから届いた '#' 行（情報行・コマンド応答・イベント・エラー）を、デバイスごとに覚えておく。
## SensorProvider が1つずつ持ち、UI（デバイス操作）が「送ったコマンドの後に届いた行」を探すのに使う。
##
##   info(id)      直近の情報行（model= を含む行）
##   reply(id)     直近のその他の '#' 行（# ok=… / # error=… / # event=…）
##   lines(id)     直近 MAX_LINES 行の履歴 [{"seq": int, "text": String}]（古い順）
##   settings(id)  行から分かった現在の設定 {"rate": int, "sending": bool}（分かった項目だけ）
##   last_seq()    最後に記録した行の通し番号（コマンド送信前に控えておき、それより新しい行を応答とみなす）

const MAX_LINES := 20

var _seq := 0
var _entries: Dictionary = {}   ## device_id -> {"info": String, "reply": String, "lines": Array, "settings": Dictionary}


## 1行記録する。'#' で始まらない行は無視する。
func record(device_id: String, line: String) -> void:
	var text := line.replace("\r", "").replace(char(0xFEFF), "").strip_edges()
	if not text.begins_with("#"):
		return
	var entry := _entry(device_id)
	_seq += 1
	if DeviceCommand.kind_of(text) == DeviceCommand.KIND_INFO:
		entry["info"] = text
	else:
		entry["reply"] = text
	var lines: Array = entry["lines"]
	lines.append({"seq": _seq, "text": text})
	while lines.size() > MAX_LINES:
		lines.pop_front()
	var settings: Dictionary = entry["settings"]
	settings.merge(DeviceCommand.settings_from(text), true)


func last_seq() -> int:
	return _seq


func info(device_id: String) -> String:
	return str(_entries.get(device_id, {}).get("info", ""))


func reply(device_id: String) -> String:
	return str(_entries.get(device_id, {}).get("reply", ""))


## 直近の行の履歴（古い順）。返り値を書き換えても内部には影響しない。
func lines(device_id: String) -> Array:
	if not _entries.has(device_id):
		return []
	return (_entries[device_id]["lines"] as Array).duplicate(true)


func settings(device_id: String) -> Dictionary:
	if not _entries.has(device_id):
		return {}
	return (_entries[device_id]["settings"] as Dictionary).duplicate()


## そのデバイスについて覚えていることを消す（通し番号は戻さない）。
func clear(device_id: String) -> void:
	_entries.erase(device_id)


func _entry(device_id: String) -> Dictionary:
	if not _entries.has(device_id):
		_entries[device_id] = {"info": "", "reply": "", "lines": [], "settings": {}}
	return _entries[device_id]
