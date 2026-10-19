class_name SensorManager
extends Node
## 各 Provider を束ね、受信データをUI・ロギング・キャリブレーションへ配信する中心クラス。
## 画面側はこのクラスのシグナルだけを見ればよく、通信方式の違いを意識しなくてよい。

signal reading_received(reading: SensorReading)
signal devices_changed
signal status_changed

var registry := DeviceRegistry.new()
var providers: Array[SensorProvider] = []

var _sample_counter: Dictionary = {}   ## device_id -> 直近1秒の受信数
var _rate_timer := 0.0


func _ready() -> void:
	# 有線: シリアル通信アドオンがあればそれを使い、無ければOS標準コマンド経由で接続する
	if SerialPortAdapter.is_addon_available():
		_add_provider(SerialSensorProvider.new())
	else:
		_add_provider(PipeSerialSensorProvider.new())
	_add_provider(MockSensorProvider.new())
	registry.devices_changed.connect(func() -> void: devices_changed.emit())
	scan_all()


func _add_provider(provider: SensorProvider) -> void:
	provider.reading_received.connect(_on_reading_received)
	provider.connection_changed.connect(_on_connection_changed)
	providers.append(provider)


func _process(delta: float) -> void:
	for provider in providers:
		provider.poll(delta)

	# 受信レート（Hz）を1秒ごとに更新する
	_rate_timer += delta
	if _rate_timer >= 1.0:
		for device in registry.all():
			device.rate_hz = float(_sample_counter.get(device.id, 0)) / _rate_timer
		_sample_counter.clear()
		_rate_timer = 0.0
		status_changed.emit()


## すべての Provider でデバイスを探索し、レジストリへ反映する。
func scan_all() -> void:
	for provider in providers:
		if not provider.is_available():
			continue
		for device in provider.scan():
			registry.upsert(device)
	devices_changed.emit()


func open_device(device_id: String) -> bool:
	var provider := _provider_for(device_id)
	if provider == null:
		return false
	var ok := provider.open_device(device_id)
	if not ok:
		push_warning("デバイスに接続できませんでした: %s" % device_id)
	return ok


func close_device(device_id: String) -> void:
	var provider := _provider_for(device_id)
	if provider != null:
		provider.close_device(device_id)


## 利用できない Provider の理由一覧（UIの注意書きに使う）。
func unavailable_notices() -> PackedStringArray:
	var notices := PackedStringArray()
	for provider in providers:
		if not provider.is_available():
			notices.append(provider.unavailable_reason())
	return notices


func _provider_for(device_id: String) -> SensorProvider:
	var device := registry.get_device(device_id)
	if device == null:
		return null
	for provider in providers:
		if provider.get_mode() == device.mode:
			return provider
	return null


func _on_reading_received(reading: SensorReading) -> void:
	var device := registry.get_device(reading.device_id)
	if device != null:
		device.last_received_ms = reading.timestamp_ms
		device.sample_count += 1
	_sample_counter[reading.device_id] = int(_sample_counter.get(reading.device_id, 0)) + 1
	reading_received.emit(reading)


func _on_connection_changed(device_id: String, connected: bool) -> void:
	var device := registry.get_device(device_id)
	if device != null:
		device.connected = connected
	devices_changed.emit()
	status_changed.emit()
