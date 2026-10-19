class_name LoggingService
extends RefCounted
## センサーデータをCSVとしてアプリ管理下フォルダに記録する。
## 保存先は Godot の user:// 配下に固定し、OSごとのパスの違いはエンジンに任せる。
##
## CSV の形式（軸指定あり・なし共通）:
##   1行目 "# device_id=… nickname=… axes=ax,gz"
##   2行目 "timestamp_ms,ax,gz"
##   3行目以降 選択した軸の値だけ（加速度系は小数4桁、角速度系は小数3桁）
## 軸を指定しない場合は生の6軸（P1 と同じ列）を記録する。読み戻しは LogReplay を使う。

const LOG_DIR := "user://logs"

signal recording_started(path: String)
signal recording_stopped(info: Dictionary)

## 保存先フォルダ。通常は LOG_DIR のまま（テストでは一時フォルダに差し替える）。
var log_dir: String = LOG_DIR

var _file: FileAccess = null
var _device_id := ""
var _axes: Array[int] = []
var _start_ms := 0
var _row_count := 0
var _current_path := ""


func is_recording() -> bool:
	return _file != null


func current_path() -> String:
	return _current_path


func elapsed_sec() -> float:
	if not is_recording():
		return 0.0
	return float(Time.get_ticks_msec() - _start_ms) / 1000.0


## 記録を開始する。ファイル名は「日時_ニックネーム.csv」。
## axes: 記録する軸（SensorAxis.Id の配列）。空なら生の6軸。
##   列は SensorAxis.ALL の並び順に揃え、未知の軸と重複は除く。
func start(device: SensorDevice, axes: Array = []) -> bool:
	if is_recording() or device == null:
		return false
	var selected := normalize_axes(axes)
	if not _ensure_dir(log_dir):
		push_error("ログフォルダを作成できませんでした: %s" % log_dir)
		return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var base := "%s_%s" % [stamp, _safe_name(device.display_name())]
	_current_path = log_dir.path_join(base + ".csv")
	var n := 2
	while FileAccess.file_exists(_current_path):   # 同じ秒に開始しても上書きしない
		_current_path = log_dir.path_join("%s_%d.csv" % [base, n])
		n += 1
	_file = FileAccess.open(_current_path, FileAccess.WRITE)
	if _file == null:
		push_error("ログファイルを作成できませんでした: %s" % _current_path)
		_current_path = ""
		return false
	_file.store_line("# device_id=%s nickname=%s axes=%s" % [
			device.id, device.display_name(), ",".join(SensorAxis.keys_of(selected))])
	_file.store_line(SensorReading.csv_header_for(selected))
	_axes = selected
	_device_id = device.id
	_start_ms = Time.get_ticks_msec()
	_row_count = 0
	recording_started.emit(_current_path)
	return true


## 記録中であれば1行書き込む（対象デバイス以外は無視する）。
func write(reading: SensorReading) -> void:
	if not is_recording() or reading == null or reading.device_id != _device_id:
		return
	_file.store_line(reading.to_csv_row_for(_axes))
	_row_count += 1


func stop() -> Dictionary:
	if not is_recording():
		return {}
	var info := {
		"path": _current_path,
		"rows": _row_count,
		"duration_sec": elapsed_sec(),
		"axes": _axes.duplicate(),
	}
	_file.close()
	_file = null
	_device_id = ""
	_axes = []
	recording_stopped.emit(info)
	return info


## 記録中の軸（SensorAxis.Id の配列）。記録していなければ空。
func current_axes() -> Array[int]:
	var out: Array[int] = []
	if is_recording():
		out = _axes.duplicate()
	return out


## 記録中（または直前の記録）の行数。
func row_count() -> int:
	return _row_count


## 軸指定を記録用に整える（空 → 生の6軸。未知・重複を除き SensorAxis.ALL の順に並べる）。
static func normalize_axes(axes: Array) -> Array[int]:
	var out: Array[int] = []
	for axis in SensorAxis.ALL:
		if axes.has(axis):
			out.append(axis)
	if out.is_empty():
		out = SensorAxis.RAW.duplicate()
	return out


## 記録済みログの一覧（新しい順）。
func list_logs() -> Array:
	_ensure_dir(log_dir)
	var logs: Array = []
	if not DirAccess.dir_exists_absolute(log_dir):
		return logs
	for file_name in DirAccess.get_files_at(log_dir):
		if not file_name.ends_with(".csv"):
			continue
		var path := log_dir.path_join(file_name)
		var size := 0
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			size = file.get_length()
			file.close()
		logs.append({"name": file_name, "path": path, "size": size})
	logs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] > b["name"])
	return logs


func delete_log(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## OSのファイラーで保存フォルダを開く。
static func open_log_folder() -> void:
	_ensure_dir(LOG_DIR)
	OS.shell_open(ProjectSettings.globalize_path(LOG_DIR))


static func _ensure_dir(dir_path: String) -> bool:
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	return DirAccess.make_dir_recursive_absolute(dir_path) == OK


## ファイル名に使えない文字を置き換える（パス区切り・":" は "-"、その他の記号・空白・制御文字は "_"）。
static func _safe_name(text: String) -> String:
	var s := ""
	for ch in text:
		if ch in "/\\:":
			s += "-"
		elif ch.unicode_at(0) < 0x20 or ch in "*?\"<>| ":
			s += "_"
		else:
			s += ch
	return s if not s.is_empty() else "device"
