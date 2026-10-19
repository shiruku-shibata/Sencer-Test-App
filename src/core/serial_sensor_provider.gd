class_name SerialSensorProvider
extends SensorProvider
## USBシリアル（有線）接続でセンサーデータを受け取る Provider。

const BAUDRATE := 115200

var _adapters: Dictionary = {}   ## device_id -> SerialPortAdapter


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.SERIAL


func is_available() -> bool:
	return SerialPortAdapter.is_addon_available()


func unavailable_reason() -> String:
	if is_available():
		return ""
	return "シリアル通信アドオンが未導入のため、有線接続は使用できません（デモモードで動作確認できます）"


func scan() -> Array:
	var devices: Array = []
	for port in SerialPortAdapter.list_ports():
		var device := SensorDevice.new(port, SensorDevice.Mode.SERIAL)
		device.connected = _adapters.has(port)
		devices.append(device)
	device_list_changed.emit()
	return devices


func open_device(device_id: String) -> bool:
	if _adapters.has(device_id):
		return true
	var adapter := SerialPortAdapter.new()
	if not adapter.open(device_id, BAUDRATE):
		return false
	_adapters[device_id] = adapter
	connection_changed.emit(device_id, true)
	return true


func close_device(device_id: String) -> void:
	if not _adapters.has(device_id):
		return
	var adapter: SerialPortAdapter = _adapters[device_id]
	adapter.close()
	_adapters.erase(device_id)
	connection_changed.emit(device_id, false)


## デバイスへ1行送る。アドオンに書き込みAPIが無い場合は false。
func send_command(device_id: String, line: String) -> bool:
	if not _adapters.has(device_id):
		return false
	var adapter: SerialPortAdapter = _adapters[device_id]
	return adapter.write_line(line)


## アプリ終了時: 開いているポートをすべて閉じる（シグナルは出さない）。
func shutdown() -> void:
	for device_id in _adapters.keys():
		var adapter: SerialPortAdapter = _adapters[device_id]
		adapter.close()
	_adapters.clear()


func poll(_delta: float) -> void:
	for device_id in _adapters.keys():
		var adapter: SerialPortAdapter = _adapters[device_id]
		for line in adapter.read_lines():
			var reading := SensorDataParser.parse_line(line, device_id)
			if reading != null:
				reading_received.emit(reading)
