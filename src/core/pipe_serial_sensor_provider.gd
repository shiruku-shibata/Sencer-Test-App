class_name PipeSerialSensorProvider
extends SensorProvider
## 外部アドオンを使わずに有線シリアル接続を行う Provider（macOS / Linux 専用）。
##
## 仕組み:
##   1. OS標準の stty でポートのボーレート等を設定する
##   2. cat でポートの内容を一時ファイルへ流し込む（別プロセス）
##   3. アプリ側は一時ファイルの増加分だけを読み取り、1行ずつ解析する
##
## GDExtensionのバイナリに依存しないため、配布物のライセンスと動作環境が単純になる。
## Windows では使えないため、その場合は別途シリアル通信アドオンを導入すること。

const BAUDRATE := 115200
const STREAM_DIR := "user://serial_streams"
const SUPPORTED_OS := ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]
const MAX_COMMAND_LENGTH := 64


## 1ポート分の受信状態。
class Stream:
	var pid: int = -1
	var stream_path: String = ""   ## 受信内容を書き出す一時ファイル（絶対パス）
	var offset: int = 0            ## 読み取り済みのバイト数
	var buffer: String = ""        ## 未完の行の持ち越し


var _streams: Dictionary = {}   ## device_id -> Stream


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.SERIAL


func is_available() -> bool:
	return SUPPORTED_OS.has(OS.get_name())


func unavailable_reason() -> String:
	if is_available():
		return ""
	return "このOSでは、アドオンなしの有線接続に対応していません（macOS / Linux のみ）"


## /dev 以下からシリアルポートらしきものを探す。
func scan() -> Array:
	var devices: Array = []
	if not is_available():
		return devices
	for port in list_ports():
		var device := SensorDevice.new(port, SensorDevice.Mode.SERIAL)
		device.connected = _streams.has(port)
		devices.append(device)
	device_list_changed.emit()
	return devices


## macOS では /dev/cu.*、Linux では /dev/ttyUSB* と /dev/ttyACM* を対象とする。
static func list_ports() -> PackedStringArray:
	var ports := PackedStringArray()
	var dir := DirAccess.open("/dev")
	if dir == null:
		return ports
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if _is_serial_port_name(entry):
			ports.append("/dev/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()
	ports.sort()
	return ports


static func _is_serial_port_name(entry: String) -> bool:
	# Bluetooth の仮想ポートは紛らわしいので除外する
	if entry.begins_with("cu.Bluetooth"):
		return false
	return entry.begins_with("cu.") or entry.begins_with("ttyUSB") or entry.begins_with("ttyACM")


func open_device(device_id: String) -> bool:
	if _streams.has(device_id):
		return true
	if not is_available():
		return false

	DirAccess.make_dir_recursive_absolute(STREAM_DIR)
	var stream_path := ProjectSettings.globalize_path(
		"%s/%s.stream" % [STREAM_DIR, device_id.get_file()]
	)

	# 前回の内容が残っていると古いデータを読んでしまうため、空にしてから始める
	var truncate := FileAccess.open(stream_path, FileAccess.WRITE)
	if truncate == null:
		push_error("受信用の一時ファイルを作成できませんでした: %s" % stream_path)
		return false
	truncate.close()

	# stty のオプションは macOS が -f、Linux が -F で異なるため両方試す
	var command := "stty -f %s %d raw -echo 2>/dev/null || stty -F %s %d raw -echo; exec cat %s >> %s" % [
		_quote(device_id), BAUDRATE, _quote(device_id), BAUDRATE,
		_quote(device_id), _quote(stream_path)
	]
	var pid := OS.create_process("/bin/sh", ["-c", command])
	if pid <= 0:
		push_error("シリアル受信プロセスを起動できませんでした: %s" % device_id)
		return false

	# アプリが強制終了しても cat がポートを掴んだまま残らないよう、見張りを付ける
	_start_orphan_guard(pid)

	var stream := Stream.new()
	stream.pid = pid
	stream.stream_path = stream_path
	_streams[device_id] = stream
	connection_changed.emit(device_id, true)
	return true


func close_device(device_id: String) -> void:
	if not _streams.has(device_id):
		return
	_stop_stream(_streams[device_id])
	_streams.erase(device_id)
	connection_changed.emit(device_id, false)


## アプリ終了時: すべての受信プロセス（cat）を止め、一時ファイルを消す。
## 終了処理中なのでシグナルは出さない。
func shutdown() -> void:
	for device_id in _streams.keys():
		_stop_stream(_streams[device_id])
	_streams.clear()


func _stop_stream(stream: Stream) -> void:
	if stream.pid > 0 and OS.is_process_running(stream.pid):
		OS.kill(stream.pid)
	stream.pid = -1
	DirAccess.remove_absolute(stream.stream_path)


## 受信プロセスの見張り役（sh）を起動する。アプリが居なくなったら受信プロセスを止め、
## 受信プロセスが先に終われば見張りも終わる。
func _start_orphan_guard(reader_pid: int) -> void:
	var script := "while kill -0 %d 2>/dev/null; do kill -0 %d 2>/dev/null || { kill %d; exit 0; }; sleep 1; done" % [
		reader_pid, OS.get_process_id(), reader_pid
	]
	OS.create_process("/bin/sh", ["-c", script])


## デバイスへ1行送る。ポートは受信用の cat が開いたままなので、
## 別プロセス（sh の printf）で同じポートへ書き込む。完了は待たない（UIを止めないため）。
func send_command(device_id: String, line: String) -> bool:
	if not _streams.has(device_id):
		return false
	var text := line.strip_edges()
	if text.is_empty() or text.contains("\n") or text.length() > MAX_COMMAND_LENGTH:
		return false
	var command := "printf '%%s\\n' %s > %s" % [_quote(text), _quote(device_id)]
	return OS.create_process("/bin/sh", ["-c", command]) > 0


func poll(_delta: float) -> void:
	for device_id in _streams.keys():
		var stream: Stream = _streams[device_id]

		# 受信プロセスが落ちていたら切断扱いにする（ケーブルを抜いた場合など）
		if stream.pid > 0 and not OS.is_process_running(stream.pid):
			close_device(device_id)
			continue

		for line in _read_new_lines(stream):
			if SensorDataParser.is_info_line(line):
				_record_device_line(device_id, line)   # コマンド応答・情報行を覚える
				continue
			var reading := SensorDataParser.parse_line(line, device_id)
			if reading != null:
				reading_received.emit(reading)


## 一時ファイルの増加分を読み、完全な行だけを返す。
func _read_new_lines(stream: Stream) -> PackedStringArray:
	var lines := PackedStringArray()
	var file := FileAccess.open(stream.stream_path, FileAccess.READ)
	if file == null:
		return lines

	var length := file.get_length()
	if length <= stream.offset:
		file.close()
		return lines

	file.seek(stream.offset)
	var chunk := file.get_buffer(length - stream.offset).get_string_from_utf8()
	file.close()
	stream.offset = length

	stream.buffer += chunk
	var parts := stream.buffer.split("\n")
	for i in range(parts.size() - 1):
		lines.append(parts[i].strip_edges())
	stream.buffer = parts[parts.size() - 1]   # 未完の行は次回に持ち越す
	return lines


## シェルに渡すパスを安全に引用する。
static func _quote(path: String) -> String:
	return "'%s'" % path.replace("'", "'\\''")
