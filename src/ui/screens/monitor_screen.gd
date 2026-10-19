class_name MonitorScreen
extends VBoxContainer
## S2 モニタリング画面。波形・数値のリアルタイム表示と、記録の開始/停止を行う。

const MAX_SAMPLES := 6000                      ## 60秒 @100Hz 相当
const WINDOW_OPTIONS := [1, 5, 10, 30]         ## 時間窓の選択肢 [秒]
const ASSUMED_RATE_HZ := 100.0
const SMOOTHING_WINDOW := 5

const COLOR_X := Color("e8843f")
const COLOR_Y := Color("3fb3aa")
const COLOR_Z := Color("7d90e0")

var _manager: SensorManager
var _logger: LoggingService

var _device_selector: OptionButton
var _record_button: Button
var _pause_button: Button
var _accel_view: WaveformView
var _gyro_view: WaveformView
var _hint: Label
var _readouts: Dictionary = {}                 ## ラベル名 -> Label

var _paused := false
var _window_sec: int = 5
var _smoothing := true
var _selected_id := ""
var _buffers: Dictionary = {}                  ## "ax" 等 -> PackedFloat32Array


func setup(manager: SensorManager, logger: LoggingService) -> void:
	_manager = manager
	_logger = logger
	_reset_buffers()
	_build()
	_manager.reading_received.connect(_on_reading_received)
	_manager.devices_changed.connect(_refresh_device_list)
	_refresh_device_list()


# ---------------------------------------------------------------- UI構築

func _build() -> void:
	add_theme_constant_override("separation", 10)
	add_child(_build_toolbar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)

	var plots := VBoxContainer.new()
	plots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plots.add_theme_constant_override("separation", 8)
	plots.add_child(_build_plot(UIStrings.LABEL_ACCEL))
	_accel_view = _make_waveform(110, 2.5)
	plots.add_child(_accel_view)
	plots.add_child(_build_plot(UIStrings.LABEL_GYRO))
	_gyro_view = _make_waveform(90, 260.0)
	plots.add_child(_gyro_view)

	_hint = Label.new()
	_hint.text = UIStrings.HINT_NO_DEVICE
	_hint.modulate = Color(1, 1, 1, 0.6)
	plots.add_child(_hint)

	body.add_child(plots)
	body.add_child(_build_readout_panel())
	add_child(body)


func _build_toolbar() -> HBoxContainer:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 10)

	_record_button = Button.new()
	_record_button.text = UIStrings.BTN_RECORD_START
	_record_button.pressed.connect(_on_record_pressed)
	toolbar.add_child(_record_button)

	_pause_button = Button.new()
	_pause_button.text = UIStrings.BTN_PAUSE
	_pause_button.pressed.connect(func() -> void:
		_paused = not _paused
		_pause_button.text = UIStrings.BTN_RESUME if _paused else UIStrings.BTN_PAUSE
	)
	toolbar.add_child(_pause_button)

	toolbar.add_child(_make_label(UIStrings.LABEL_TARGET_DEVICE))
	_device_selector = OptionButton.new()
	_device_selector.custom_minimum_size.x = 200
	_device_selector.item_selected.connect(_on_device_selected)
	toolbar.add_child(_device_selector)

	toolbar.add_child(_make_label(UIStrings.LABEL_TIME_WINDOW))
	var window_selector := OptionButton.new()
	for sec in WINDOW_OPTIONS:
		window_selector.add_item("%d s" % sec)
	window_selector.select(WINDOW_OPTIONS.find(_window_sec))
	window_selector.item_selected.connect(func(index: int) -> void:
		_window_sec = WINDOW_OPTIONS[index]
	)
	toolbar.add_child(window_selector)

	var smooth_check := CheckBox.new()
	smooth_check.text = "移動平均"
	smooth_check.button_pressed = _smoothing
	smooth_check.toggled.connect(func(pressed: bool) -> void: _smoothing = pressed)
	toolbar.add_child(smooth_check)

	return toolbar


func _build_plot(title: String) -> Label:
	var label := Label.new()
	label.text = title
	label.modulate = Color(1, 1, 1, 0.7)
	return label


func _make_waveform(height: int, value_range: float) -> WaveformView:
	var view := WaveformView.new()
	view.custom_minimum_size.y = height
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.value_range = value_range
	return view


func _build_readout_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 200

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	for key in ["合成加速度", "X", "Y", "Z", "最大", "最小", "サンプル数"]:
		var row := HBoxContainer.new()
		var name_label := _make_label(key)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var value_label := Label.new()
		value_label.text = "-"
		row.add_child(value_label)
		_readouts[key] = value_label
		box.add_child(row)
	panel.add_child(box)
	return panel


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# ---------------------------------------------------------------- データ処理

func _reset_buffers() -> void:
	for key in ["ax", "ay", "az", "gx", "gy", "gz"]:
		_buffers[key] = PackedFloat32Array()


func _on_reading_received(reading: SensorReading) -> void:
	_logger.write(reading)
	if reading.device_id != _selected_id or _paused:
		return
	_append("ax", reading.accel.x)
	_append("ay", reading.accel.y)
	_append("az", reading.accel.z)
	_append("gx", reading.gyro.x)
	_append("gy", reading.gyro.y)
	_append("gz", reading.gyro.z)


func _append(key: String, value: float) -> void:
	var buffer: PackedFloat32Array = _buffers[key]
	buffer.append(value)
	if buffer.size() > MAX_SAMPLES:
		buffer = buffer.slice(buffer.size() - MAX_SAMPLES)
	_buffers[key] = buffer


## 表示する区間を切り出す（必要なら移動平均をかける）。
func _window_of(key: String) -> PackedFloat32Array:
	var buffer: PackedFloat32Array = _buffers[key]
	var visible := int(ASSUMED_RATE_HZ * float(_window_sec))
	if buffer.size() > visible:
		buffer = buffer.slice(buffer.size() - visible)
	if not _smoothing or buffer.size() < SMOOTHING_WINDOW:
		return buffer
	return _moving_average(buffer, SMOOTHING_WINDOW)


static func _moving_average(data: PackedFloat32Array, window: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(data.size())
	var sum := 0.0
	for i in data.size():
		sum += data[i]
		if i >= window:
			sum -= data[i - window]
		var count: int = min(i + 1, window)
		result[i] = sum / float(count)
	return result


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	_accel_view.set_series([
		{"color": COLOR_X, "data": _window_of("ax")},
		{"color": COLOR_Y, "data": _window_of("ay")},
		{"color": COLOR_Z, "data": _window_of("az")},
	])
	_gyro_view.set_series([
		{"color": COLOR_X, "data": _window_of("gx")},
		{"color": COLOR_Y, "data": _window_of("gy")},
		{"color": COLOR_Z, "data": _window_of("gz")},
	])
	_update_readouts()


func _update_readouts() -> void:
	var ax: PackedFloat32Array = _window_of("ax")
	var ay: PackedFloat32Array = _window_of("ay")
	var az: PackedFloat32Array = _window_of("az")
	if ax.is_empty():
		return

	var last := ax.size() - 1
	var max_value := -INF
	var min_value := INF
	for i in ax.size():
		var magnitude := Vector3(ax[i], ay[i], az[i]).length()
		max_value = maxf(max_value, magnitude)
		min_value = minf(min_value, magnitude)

	_readouts["合成加速度"].text = "%.2f" % Vector3(ax[last], ay[last], az[last]).length()
	_readouts["X"].text = "%.2f" % ax[last]
	_readouts["Y"].text = "%.2f" % ay[last]
	_readouts["Z"].text = "%.2f" % az[last]
	_readouts["最大"].text = "%.2f" % max_value
	_readouts["最小"].text = "%.2f" % min_value

	var device := _manager.registry.get_device(_selected_id)
	_readouts["サンプル数"].text = str(device.sample_count) if device != null else "0"


# ---------------------------------------------------------------- デバイス選択・記録

func _refresh_device_list() -> void:
	if _device_selector == null:
		return
	var previous := _selected_id
	_device_selector.clear()

	var connected := _manager.registry.connected_devices()
	for device in connected:
		_device_selector.add_item(device.display_name())
		_device_selector.set_item_metadata(_device_selector.item_count - 1, device.id)

	_hint.visible = connected.is_empty()
	if connected.is_empty():
		_selected_id = ""
		return

	var index := 0
	for i in connected.size():
		if connected[i].id == previous:
			index = i
	_device_selector.select(index)
	_on_device_selected(index)


func _on_device_selected(index: int) -> void:
	var id: Variant = _device_selector.get_item_metadata(index)
	var new_id := str(id)
	if new_id != _selected_id:
		_selected_id = new_id
		_reset_buffers()


func _on_record_pressed() -> void:
	if _logger.is_recording():
		_logger.stop()
		_record_button.text = UIStrings.BTN_RECORD_START
		return

	var device := _manager.registry.get_device(_selected_id)
	if device == null:
		return
	if _logger.start(device):
		_record_button.text = UIStrings.BTN_RECORD_STOP
