class_name SensorManager
extends Node
## 各 Provider を束ね、受信データをUI・ロギング・キャリブレーションへ配信する中心クラス。
## 画面側はこのクラスのシグナルだけを見ればよく、通信方式の違いを意識しなくてよい。

signal reading_received(reading: SensorReading)
signal devices_changed
signal status_changed

## 有線の方式を選ぶ環境変数（auto / addon / pipe / bridge。既定 auto）
const ENV_SERIAL_MODE := "SENSOR_SERIAL_MODE"
## godot ... -- --serial-bridge でも、有線をブリッジ経由にできる
const CMDLINE_SERIAL_BRIDGE := "--serial-bridge"
const SERIAL_MODE_AUTO := "auto"
const SERIAL_MODE_ADDON := "addon"     ## シリアル通信アドオン（SerialSensorProvider）
const SERIAL_MODE_PIPE := "pipe"       ## OS 標準の stty / cat（PipeSerialSensorProvider。macOS / Linux）
const SERIAL_MODE_BRIDGE := "bridge"   ## BLEブリッジの pyserial（BridgeSerialSensorProvider。主に Windows）
## 1本の線で複数のセンサーを中継する機器（Beer-fw のゲートウェイ等）のノードは、
## 「<接続先のID>#node<番号>」という ID の子デバイスとして見せる。接続・切断・コマンドは接続先（親）へ送る。
const NODE_SEPARATOR := "#node"

var registry := DeviceRegistry.new()
var providers: Array[SensorProvider] = []
## 実際に使っている有線の方式（SERIAL_MODE_*）
var serial_mode := SERIAL_MODE_AUTO

var _sample_counter: Dictionary = {}   ## device_id -> 直近1秒の受信数
var _rate_timer := 0.0
var _is_shut_down := false


func _ready() -> void:
	registry.devices_changed.connect(func() -> void: devices_changed.emit())
	# ブラウザ版: 外部プロセス（BLEブリッジ・stty/cat）も UDP も使えないので、デモデバイスだけで動かす
	if OS.has_feature("web"):
		_add_provider(MockSensorProvider.new())
		scan_all()
		return

	# BLE: 別プロセスのブリッジ（tools/ble_bridge）経由。Python が無くてもアプリは動く
	var ble := BleSensorProvider.new()

	# 有線: 使える方式を1つだけ選ぶ（同じポートを2つの方式で開かないように）
	var requested := OS.get_environment(ENV_SERIAL_MODE).strip_edges().to_lower()
	if OS.get_cmdline_user_args().has(CMDLINE_SERIAL_BRIDGE):
		requested = SERIAL_MODE_BRIDGE
	serial_mode = choose_serial_mode(requested, SerialPortAdapter.is_addon_available(),
			PipeSerialSensorProvider.is_supported_os())
	if not requested.is_empty() and requested != SERIAL_MODE_AUTO and requested != serial_mode:
		push_warning("有線の方式 %s は使えないため %s を使います" % [requested, serial_mode])
	match serial_mode:
		SERIAL_MODE_ADDON:
			_add_provider(SerialSensorProvider.new())
		SERIAL_MODE_PIPE:
			_add_provider(PipeSerialSensorProvider.new())
		_:
			# アドオンも OS 標準コマンドも使えない（主に Windows）: ブリッジに pyserial で読んでもらう
			_add_provider(BridgeSerialSensorProvider.new(ble))

	_add_provider(ble)
	_add_provider(MockSensorProvider.new())
	scan_all()


## 有線の方式を決める。requested が使えなければ自動選択に戻す。
## 自動: アドオン → OS 標準コマンド（macOS / Linux）→ ブリッジ経由 の順。
## ブリッジ経由は Python と pyserial が要るので、他が使えるときは使わない（フォールバック）。
static func choose_serial_mode(requested: String, addon_available: bool, pipe_available: bool) -> String:
	match requested:
		SERIAL_MODE_ADDON:
			if addon_available:
				return SERIAL_MODE_ADDON
		SERIAL_MODE_PIPE:
			if pipe_available:
				return SERIAL_MODE_PIPE
		SERIAL_MODE_BRIDGE:
			return SERIAL_MODE_BRIDGE
	if addon_available:
		return SERIAL_MODE_ADDON
	if pipe_available:
		return SERIAL_MODE_PIPE
	return SERIAL_MODE_BRIDGE


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
	var target := parent_id_of(device_id)
	var provider := _provider_for(target)
	if provider == null:
		return false
	var ok := provider.open_device(target)
	if not ok:
		push_warning("デバイスに接続できませんでした: %s" % target)
	return ok


## 切断する。中継先のノード（子デバイス）を指定した場合は、接続先（親）ごと切断する。
func close_device(device_id: String) -> void:
	var target := parent_id_of(device_id)
	var provider := _provider_for(target)
	if provider != null:
		provider.close_device(target)


## 中継先ノードの子デバイス ID。
static func node_device_id(parent_id: String, node: int) -> String:
	return "%s%s%d" % [parent_id, NODE_SEPARATOR, node]


## 子デバイスなら接続先（親）の ID、そうでなければそのまま。
static func parent_id_of(device_id: String) -> String:
	var i := device_id.rfind(NODE_SEPARATOR)
	return device_id.substr(0, i) if i > 0 else device_id


## デバイスへコマンドを1行送る（PAUSE / RESUME / RATE <Hz> / INFO）。
## 未対応の方式・未接続・送信失敗のときは false。
func send_command(device_id: String, line: String) -> bool:
	var target := parent_id_of(device_id)
	var provider := _provider_for(target)
	if provider == null:
		return false
	return provider.send_command(target, line)


## デバイスから届いた '#' 行（情報行・コマンド応答）の記録。デバイスが不明なら null。
func device_line_log(device_id: String) -> DeviceLineLog:
	var provider := _provider_for(device_id)
	return provider.device_line_log() if provider != null else null


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
	var target := parent_id_of(device_id)
	var provider := _provider_for(target)
	return provider != null and provider.is_connecting(target)


## 利用できない Provider の理由一覧（UIの注意書きに使う）。
func unavailable_notices() -> PackedStringArray:
	var notices := PackedStringArray()
	for provider in providers:
		if not provider.is_available():
			notices.append(provider.unavailable_reason())
	return notices


func _provider_for(device_id: String) -> SensorProvider:
	var device := registry.get_device(parent_id_of(device_id))
	if device == null:
		return null
	return get_provider(device.mode)


func _on_reading_received(reading: SensorReading) -> void:
	if reading.source_node >= 0:
		_route_to_node_device(reading)
	var device := registry.get_device(reading.device_id)
	if device != null:
		device.last_received_ms = reading.timestamp_ms
		device.sample_count += 1
	_sample_counter[reading.device_id] = int(_sample_counter.get(reading.device_id, 0)) + 1
	reading_received.emit(reading)


## 中継された読み取り値を、ノードごとの子デバイスに付け替える（初めてのノードなら一覧に足す）。
func _route_to_node_device(reading: SensorReading) -> void:
	var parent := registry.get_device(reading.device_id)
	var child_id := node_device_id(reading.device_id, reading.source_node)
	var child := registry.get_device(child_id)
	if child == null:
		var label := "ノード %d" % reading.source_node
		if not reading.source_mac.is_empty():
			label += "（%s）" % reading.source_mac
		child = SensorDevice.new(child_id, parent.mode if parent != null else SensorDevice.Mode.SERIAL, label)
		registry.upsert(child)
		child = registry.get_device(child_id)
	if not child.connected:
		child.connected = true
		devices_changed.emit()
		status_changed.emit()
	reading.device_id = child_id


func _on_connection_changed(device_id: String, connected: bool) -> void:
	if not connected:
		# 中継していたノードも、接続先が切れたら受信できない
		for other in registry.all():
			if other.id != device_id and parent_id_of(other.id) == device_id:
				other.connected = false
				other.rate_hz = 0.0
	var device := registry.get_device(device_id)
	if connected:
		# 前回の接続で覚えた設定（一時停止中など）は、本体の再起動で変わっているかもしれないので忘れる
		# （接続後に届く情報行・応答で改めて分かる）
		var line_log := device_line_log(device_id)
		if line_log != null:
			line_log.clear(device_id)
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
