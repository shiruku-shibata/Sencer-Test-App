class_name DeviceRegistry
extends RefCounted
## 接続対象デバイスの一覧を保持する。
## 内部キーはポート名／BLEアドレス、表示名はニックネーム（未設定なら機器名）。

const NICKNAME_FILE := "user://device_names.cfg"

signal devices_changed

var _devices: Dictionary = {}      ## id -> SensorDevice
var _nicknames: Dictionary = {}    ## id -> String


func _init() -> void:
	load_nicknames()


func upsert(device: SensorDevice) -> void:
	if _devices.has(device.id):
		var existing: SensorDevice = _devices[device.id]
		existing.mode = device.mode
		# 機器名と電波強度はスキャンのたびに新しい値へ更新する（名前が取れなかった回は前の名前を残す）
		if not device.label.is_empty():
			existing.label = device.label
		existing.rssi = device.rssi
	else:
		device.nickname = _nicknames.get(device.id, "")
		_devices[device.id] = device
	devices_changed.emit()


func get_device(device_id: String) -> SensorDevice:
	return _devices.get(device_id, null)


func all() -> Array:
	var list: Array = _devices.values()
	list.sort_custom(func(a: SensorDevice, b: SensorDevice) -> bool: return a.id < b.id)
	return list


func connected_devices() -> Array:
	return all().filter(func(d: SensorDevice) -> bool: return d.connected)


func set_nickname(device_id: String, nickname: String) -> void:
	var device: SensorDevice = get_device(device_id)
	if device == null:
		return
	device.nickname = nickname
	_nicknames[device_id] = nickname
	save_nicknames()
	devices_changed.emit()


func save_nicknames() -> void:
	var config := ConfigFile.new()
	for id in _nicknames.keys():
		config.set_value("nicknames", id, _nicknames[id])
	config.save(NICKNAME_FILE)


func load_nicknames() -> void:
	var config := ConfigFile.new()
	if config.load(NICKNAME_FILE) != OK:
		return
	if not config.has_section("nicknames"):
		return
	for id in config.get_section_keys("nicknames"):
		_nicknames[id] = config.get_value("nicknames", id, "")
