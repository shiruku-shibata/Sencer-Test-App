class_name BridgeSerialSensorProvider
extends SensorProvider
## 有線（USB シリアル）を「BLEブリッジ経由」で受ける Provider。
##
## アプリ自身でシリアルを読む方法（OS 標準コマンドの PipeSerialSensorProvider、
## シリアル通信アドオンの SerialSensorProvider）がどちらも使えない環境（主に Windows）向け。
## ブリッジ（tools/ble_bridge/ble_bridge.py）が pyserial でポートを読み、BLE と同じ UDP・同じ形式
## （"kind": "serial"）で行を送ってくる。画面からは普通の「有線」デバイスに見える。
##
## ブリッジの起動・UDP ポートは1つだけにしたいので、それらを管理している BleSensorProvider（host）に
## attach_channel() で相乗りする。ブリッジの再起動・手動起動の操作は BLE の枠のボタンと共通。
## どの有線方式を使うかは SensorManager.choose_serial_mode() が決める。

const KIND := "serial"
const CONNECT_TIMEOUT_SEC := 10.0
const SCAN_TIMEOUT_SEC := 6.0

var _host: BleSensorProvider
var _has_hello := false
var _serial_info: Variant = null              ## hello の "serial"（null = ブリッジ側で無効）
var _known: Dictionary = {}                   ## address -> 表示名（ポートの説明）
var _connected: Dictionary = {}               ## address -> true
var _connecting: Dictionary = {}              ## address -> 経過秒
var _cancelled: Dictionary = {}               ## 切断を押し、ブリッジの切断完了（status disconnected）を待っている address -> true
var _device_errors: Dictionary = {}           ## address -> 直近のエラー文
var _device_info: Dictionary = {}             ## address -> 情報行（model= を含む行だけ）
var _device_replies: Dictionary = {}          ## address -> 直近のその他の '#' 行
var _clocks: Dictionary = {}                  ## address -> BleSensorProvider.SampleClock
var _scan_requested := false
var _scanning := false
var _scan_elapsed := 0.0
var _scan_error := ""
var _is_shut_down := false


func _init(host: BleSensorProvider) -> void:
	_host = host
	host.attach_channel(KIND, self)


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.SERIAL


# --- SensorProvider の実装 ---------------------------------------------------

## 既に分かっているポートをすぐ返し、ブリッジからの一覧は devices_discovered で知らせる。
func scan() -> Array:
	if _is_shut_down:
		return []
	_host.start()
	if _host.is_ready() and _serial_ready():
		_send_scan()
	else:
		_scan_requested = true
	provider_status_changed.emit()
	return _known_devices()


func open_device(device_id: String) -> bool:
	if _is_shut_down:
		return false
	if _connected.has(device_id):
		return true
	if not _host.is_ready() or not _serial_ready():
		return false
	_cancelled.erase(device_id)
	_device_errors.erase(device_id)
	_connecting[device_id] = 0.0
	_host.bridge_send({"cmd": "connect", "kind": KIND, "address": device_id})
	provider_status_changed.emit()
	return true   # 結果は connection_changed で届く


func close_device(device_id: String) -> void:
	_connecting.erase(device_id)
	# 切断完了までは、それ以前に出た pong の connected で接続済みに戻さない（BleSensorProvider と同じ）
	_cancelled[device_id] = true
	_host.bridge_send({"cmd": "disconnect", "kind": KIND, "address": device_id})
	if _connected.erase(device_id):
		connection_changed.emit(device_id, false)
	provider_status_changed.emit()


func send_command(device_id: String, line: String) -> bool:
	if not _connected.has(device_id):
		return false
	var text := line.strip_edges()
	if text.is_empty() or text.contains("\n"):
		return false
	return _host.bridge_send({"cmd": "send", "kind": KIND, "address": device_id, "line": text})


## ブリッジ自体の見張りは host が行う。ここでは接続・スキャンの待ち時間だけを見る。
func poll(delta: float) -> void:
	if _is_shut_down:
		return
	if _scanning:
		_scan_elapsed += delta
		if _scan_elapsed >= SCAN_TIMEOUT_SEC:
			_scanning = false
			_scan_error = "シリアルポートの一覧が返ってきませんでした。もう一度スキャンしてください"
			provider_status_changed.emit()
	for address in _connecting.keys():
		_connecting[address] = float(_connecting[address]) + delta
		if _connecting[address] >= CONNECT_TIMEOUT_SEC:
			_connecting.erase(address)
			_device_errors[address] = "接続がタイムアウトしました"
			_host.bridge_send({"cmd": "disconnect", "kind": KIND, "address": address})
			connection_changed.emit(address, false)


## ブリッジの終了は host が行う（手動起動のブリッジには bye が送られ、ポートも閉じられる）。
func shutdown() -> void:
	_is_shut_down = true
	_connected.clear()
	_connecting.clear()


func is_available() -> bool:
	if _host.is_bridge_failed():
		return false
	if _has_hello and not _serial_ready():
		return false
	return true


func unavailable_reason() -> String:
	if is_available():
		return ""
	return status_text()


func status_text() -> String:
	if _host.is_bridge_failed():
		return "有線（ブリッジ経由）: " + _host.bridge_problem()
	if not _has_hello:
		return "有線（ブリッジ経由）: ブリッジを準備中…"
	if not _serial_ready():
		return "有線（ブリッジ経由）: " + _serial_problem_text()
	var text := "有線（ブリッジ経由・%s）: %s" % [
		str((_serial_info as Dictionary).get("backend", "?")),
		"スキャン中…" if is_scanning() else "準備完了",
	]
	if not _scan_error.is_empty():
		text += "\n" + _scan_error
	return text


func is_scanning() -> bool:
	if _scanning:
		return true
	return _scan_requested and not _has_hello and not _host.is_bridge_failed()


func is_connecting(device_id: String) -> bool:
	return _connecting.has(device_id)


## そのポートで直近に起きたエラー（接続失敗・切断理由）。無ければ空。
func device_error(device_id: String) -> String:
	return str(_device_errors.get(device_id, ""))


## デバイスが送ってきた情報行（model= を含む行）。無ければ空。
func device_info(device_id: String) -> String:
	return str(_device_info.get(device_id, ""))


## デバイスが送ってきた直近の応答・イベント・エラー行。無ければ空。
func device_reply(device_id: String) -> String:
	return str(_device_replies.get(device_id, ""))


# --- host（BleSensorProvider）から呼ばれる ---------------------------------------

func _on_bridge_hello(message: Dictionary) -> void:
	_has_hello = true
	if not message.has("serial"):
		# kind=serial に対応する前のブリッジ（v1.0.x）
		_serial_info = {"ready": false, "error": "unsupported",
				"message": "ブリッジが古いため有線に対応していません。「ブリッジ再起動」を押してください"}
	else:
		_serial_info = message.get("serial")
	if _serial_ready():
		_sync_connected((_serial_info as Dictionary).get("connected", []))
		if _scan_requested:
			_send_scan()
	else:
		_scan_requested = false
		_scanning = false
	provider_status_changed.emit()


func _on_bridge_pong(message: Dictionary) -> void:
	if message.has("serial_connected"):
		_sync_connected(message.get("serial_connected", []))


func _on_bridge_message(message: Dictionary) -> void:
	if _is_shut_down:
		return
	match str(message.get("type", "")):
		"scanning":
			_scanning = true
			provider_status_changed.emit()
		"devices":
			_on_devices(message)
		"status":
			_on_status(message)
		"data":
			_on_data(message)


## ブリッジが落ちた・再起動・終了したとき。notify=true なら切断を画面に知らせる。
func _on_bridge_reset(notify: bool) -> void:
	var lost := _connected.keys()
	_connected.clear()
	_connecting.clear()
	_cancelled.clear()
	_scanning = false
	_has_hello = false
	_serial_info = null
	# ブリッジが起動し直したら、ポートの一覧も取り直す
	_scan_requested = not _is_shut_down
	if notify and not _is_shut_down:
		for address in lost:
			connection_changed.emit(address, false)
		provider_status_changed.emit()


# --- 内部処理 ---------------------------------------------------------------

func _serial_ready() -> bool:
	return typeof(_serial_info) == TYPE_DICTIONARY and bool((_serial_info as Dictionary).get("ready", false))


func _serial_problem_text() -> String:
	if typeof(_serial_info) != TYPE_DICTIONARY:
		return "ブリッジで USB シリアル受信が無効になっています（--no-serial を外して起動してください）"
	var info: Dictionary = _serial_info
	match str(info.get("error", "")):
		"pyserial_missing":
			return "pyserial 未インストール: tools/ble_bridge/setup.sh（Windows は setup.bat）を実行してから「ブリッジ再起動」を押してください"
	var detail := str(info.get("message", ""))
	return detail if not detail.is_empty() else "USB シリアル受信が使えません"


func _send_scan() -> void:
	_scan_requested = false
	_scanning = true
	_scan_elapsed = 0.0
	_host.bridge_send({"cmd": "scan", "kind": KIND})


func _on_devices(message: Dictionary) -> void:
	_scanning = false
	_scan_error = ""
	if message.has("error"):
		_scan_error = "シリアルポートの一覧を取得できません: %s" % str(message.get("message", message.get("error")))
	else:
		for entry in message.get("devices", []):
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var address := str(entry.get("address", ""))
			if not address.is_empty():
				_known[address] = str(entry.get("name", ""))
	devices_discovered.emit(_known_devices())
	provider_status_changed.emit()


func _on_status(message: Dictionary) -> void:
	var address := str(message.get("address", ""))
	if address.is_empty() or str(message.get("state", "")) == "connecting":
		return
	if bool(message.get("connected", false)):
		_connecting.erase(address)
		if _cancelled.has(address):
			_cancelled.erase(address)
			_host.bridge_send({"cmd": "disconnect", "kind": KIND, "address": address})
			return
		_mark_connected(address)
	else:
		var was_connecting := _connecting.erase(address)
		_cancelled.erase(address)
		if message.has("error"):
			_device_errors[address] = str(message.get("message", message.get("error", "")))
		var was_connected := _connected.erase(address)
		if was_connected or was_connecting:
			connection_changed.emit(address, false)
	provider_status_changed.emit()


func _mark_connected(address: String) -> void:
	if _connected.has(address):
		return
	if not _known.has(address):
		_known[address] = ""
		devices_discovered.emit(_known_devices())
	_connected[address] = true
	_device_errors.erase(address)
	_device_replies.erase(address)
	_clocks[address] = BleSensorProvider.SampleClock.new()
	connection_changed.emit(address, true)


func _sync_connected(list: Variant) -> void:
	if typeof(list) != TYPE_ARRAY:
		return
	var remote := {}
	for item in list:
		remote[str(item)] = true
	for address in remote.keys():
		if not _connected.has(address) and not _cancelled.has(address):
			_connecting.erase(address)
			_mark_connected(address)
	for address in _connected.keys():
		if not remote.has(address):
			_connected.erase(address)
			connection_changed.emit(address, false)


## ブリッジは BLE と同じく約20msごとに行をまとめて送ってくるので、BLE と同じ方法で時刻を付け直す。
func _on_data(message: Dictionary) -> void:
	var address := str(message.get("address", ""))
	if not _connected.has(address):
		return
	var lines: Variant = message.get("lines", [])
	if typeof(lines) != TYPE_ARRAY:
		return
	var readings: Array[SensorReading] = []
	for line in lines:
		var text := str(line)
		if text.begins_with("#"):
			_on_info_line(address, text)
			continue
		var reading := SensorDataParser.parse_line(text, address)
		if reading != null:
			readings.append(reading)
	if readings.is_empty():
		return
	var clock: BleSensorProvider.SampleClock = _clocks.get(address)
	if clock == null:
		clock = BleSensorProvider.SampleClock.new()
		_clocks[address] = clock
	var stamps := clock.stamp(readings.size(), Time.get_ticks_msec())
	for i in readings.size():
		readings[i].timestamp_ms = stamps[i]
		reading_received.emit(readings[i])


func _on_info_line(address: String, text: String) -> void:
	_record_device_line(address, text)   # 基底の記録（デバイス操作画面の応答表示に使う）
	var fields := BleSensorProvider.parse_info_fields(text)
	if fields.has("model"):
		_device_info[address] = text
	else:
		_device_replies[address] = text
	if fields.has("rate") and str(fields["rate"]).is_valid_int():
		var clock: BleSensorProvider.SampleClock = _clocks.get(address)
		if clock != null:
			clock.set_rate_hint(float(int(fields["rate"])))


func _known_devices() -> Array:
	var devices: Array = []
	for address in _known.keys():
		var device := SensorDevice.new(address, SensorDevice.Mode.SERIAL, str(_known[address]))
		device.connected = _connected.has(address)
		devices.append(device)
	return devices
