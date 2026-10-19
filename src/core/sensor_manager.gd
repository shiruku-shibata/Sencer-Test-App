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
var _is_shut_down := false


func _ready() -> void:
	# 有線: シリアル通信アドオンがあればそれを使い、無ければOS標準コマンド経由で接続する
	if SerialPortAdapter.is_addon_available():
		_add_provider(SerialSensorProvider.new())
	else:
		_add_provider(PipeSerialSensorProvider.new())
	# BLE: 別プロセスのブリッジ（tools/ble_bridge）経由。Python が無くてもアプリは動く
	_add_provider(BleSensorProvider.new())
	_add_provider(MockSensorProvider.new())
	registry.devices_changed.connect(func() -> void: devices_changed.emit())
	scan_all()


func _add_provider(provider: SensorProvider) -> void:
	provider.reading_received.connect(_on_reading_received)
	provider.connection_changed.connect(_on_connection_changed)
	provider.devices_discovered.connect(_on_devices_discovered)
	provider.provider_status_changed.connect(func() -> void: status_changed.emit())
	providers.append(provider)


func _process(delta: float) -> void:
	if _is_shut_down:
		return
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


## ウィンドウを閉じる・ツリーから外れる・解放される、のどれでも確実に後始末する。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		shutdown()


func _exit_tree() -> void:
	shutdown()


## すべての Provider を終了する（外部プロセスの停止・ポートの解放）。2回呼んでも安全。
func shutdown() -> void:
	if _is_shut_down:
		return
	_is_shut_down = true
	for provider in providers:
		provider.shutdown()


## すべての Provider でデバイスを探索し、レジストリへ反映する。
## BLE のように時間がかかる方式は、結果が届いた時点で devices_changed が発火する。
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


## デバイスへコマンドを1行送る（PAUSE / RESUME / RATE <Hz> / INFO）。
## 未対応の方式・未接続・送信失敗のときは false。
func send_command(device_id: String, line: String) -> bool:
	var provider := _provider_for(device_id)
	if provider == null:
		return false
	return provider.send_command(device_id, line)


## 指定した通信方式の Provider（無ければ null）。方式固有の操作（BLEブリッジの再起動など）に使う。
func get_provider(mode: SensorDevice.Mode) -> SensorProvider:
	for provider in providers:
		if provider.get_mode() == mode:
			return provider
	return null


## どれかの Provider が非同期スキャン中か。
func is_scanning() -> bool:
	for provider in providers:
		if provider.is_scanning():
			return true
	return false


## そのデバイスが接続処理の途中か（BLE の接続待ちなど）。
func is_connecting(device_id: String) -> bool:
	var provider := _provider_for(device_id)
	return provider != null and provider.is_connecting(device_id)


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
	return get_provider(device.mode)


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
		if not connected:
			device.rate_hz = 0.0
	devices_changed.emit()
	status_changed.emit()


func _on_devices_discovered(devices: Array) -> void:
	for device in devices:
		if device is SensorDevice:
			registry.upsert(device)
	devices_changed.emit()
