class_name MockSensorProvider
extends SensorProvider
## 実機やアドオンが無くても動作確認できるダミーデータ供給元。
## UIの確認、しきい値調整の練習、開発中の回帰確認に使う。

const SAMPLE_INTERVAL_SEC := 0.01   ## 100Hz 相当
const DEVICE_IDS := ["demo-01", "demo-02"]

var _open_ids: Array[String] = []
var _elapsed := 0.0
var _phase := 0.0


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.MOCK


func scan() -> Array:
	var devices: Array = []
	for id in DEVICE_IDS:
		var device := SensorDevice.new(id, SensorDevice.Mode.MOCK)
		device.connected = _open_ids.has(id)
		devices.append(device)
	device_list_changed.emit()
	return devices


func open_device(device_id: String) -> bool:
	if not DEVICE_IDS.has(device_id):
		return false
	if not _open_ids.has(device_id):
		_open_ids.append(device_id)
	connection_changed.emit(device_id, true)
	return true


func close_device(device_id: String) -> void:
	_open_ids.erase(device_id)
	connection_changed.emit(device_id, false)


func poll(delta: float) -> void:
	if _open_ids.is_empty():
		return
	_elapsed += delta
	while _elapsed >= SAMPLE_INTERVAL_SEC:
		_elapsed -= SAMPLE_INTERVAL_SEC
		_phase += 0.06
		for id in _open_ids:
			reading_received.emit(_make_reading(id))


func _make_reading(device_id: String) -> SensorReading:
	# ときどき大きな振り（ジェスチャー相当のピーク）を混ぜる
	var spike := 0.0
	if randf() < 0.012:
		spike = randf_range(0.6, 2.2)
	var accel := Vector3(
		sin(_phase) * 0.25 + randf_range(-0.04, 0.04) + spike,
		0.98 + sin(_phase * 0.7) * 0.12 + randf_range(-0.03, 0.03),
		cos(_phase * 1.3) * 0.18 + randf_range(-0.035, 0.035) - spike * 0.4
	)
	var gyro := Vector3(
		sin(_phase * 1.8) * 60.0 + randf_range(-7.0, 7.0) + spike * 120.0,
		cos(_phase * 1.1) * 45.0 + randf_range(-6.0, 6.0),
		sin(_phase * 0.5) * 30.0 + randf_range(-5.0, 5.0)
	)
	return SensorReading.new(device_id, Time.get_ticks_msec(), accel, gyro)
