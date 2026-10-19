class_name LoggingService
extends RefCounted
## センサーデータをCSVとしてアプリ管理下フォルダに記録する。
## 保存先は Godot の user:// 配下に固定し、OSごとのパスの違いはエンジンに任せる。

const LOG_DIR := "user://logs"

signal recording_started(path: String)
signal recording_stopped(info: Dictionary)

var _file: FileAccess = null
var _device_id := ""
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
func start(device: SensorDevice) -> bool:
	if is_recording():
		return false
	_ensure_dir()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var safe_name := device.display_name().replace("/", "-").replace(" ", "_")
	_current_path = "%s/%s_%s.csv" % [LOG_DIR, stamp, safe_name]
	_file = FileAccess.open(_current_path, FileAccess.WRITE)
	if _file == null:
		push_error("ログファイルを作成できませんでした: %s" % _current_path)
		return false
	_file.store_line("# device_id=%s nickname=%s" % [device.id, device.display_name()])
	_file.store_line(SensorReading.csv_header())
	_device_id = device.id
	_start_ms = Time.get_ticks_msec()
	_row_count = 0
	recording_started.emit(_current_path)
	return true


## 記録中であれば1行書き込む（対象デバイス以外は無視する）。
func write(reading: SensorReading) -> void:
	if not is_recording() or reading.device_id != _device_id:
		return
	_file.store_line(reading.to_csv_row())
	_row_count += 1


func stop() -> Dictionary:
	if not is_recording():
		return {}
	var info := {
		"path": _current_path,
		"rows": _row_count,
		"duration_sec": elapsed_sec(),
	}
	_file.close()
	_file = null
	_device_id = ""
	recording_stopped.emit(info)
	return info


## 記録済みログの一覧（新しい順）。
func list_logs() -> Array:
	_ensure_dir()
	var logs: Array = []
	var dir := DirAccess.open(LOG_DIR)
	if dir == null:
		return logs
	for file_name in dir.get_files():
		if not file_name.ends_with(".csv"):
			continue
		var path := "%s/%s" % [LOG_DIR, file_name]
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
	_ensure_dir()
	OS.shell_open(ProjectSettings.globalize_path(LOG_DIR))


static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(LOG_DIR):
		DirAccess.make_dir_recursive_absolute(LOG_DIR)
