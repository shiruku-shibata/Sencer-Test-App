class_name MonitorScreen
extends VBoxContainer
## S2 モニタリング画面。波形・数値のリアルタイム表示と、記録の開始/停止を行う。
##
## 軸選択（AxisSelector）で選んだ軸だけを表示・記録する。
##   - 加速度系（aX/aY/aZ/|a|）とジャイロ系（gX/gY/gZ/|g|）は別グラフ。選ばれていない系のグラフは隠す。
##   - 右の数値パネルは、選択軸ごとの現在値と、表示中の時間窓での最大・最小。
##   - 記録は LoggingService.start(device, 選択軸) で、選択軸の列だけを CSV に出す。

const RING_CAPACITY := 6000                    ## 60秒 @100Hz 相当
const WINDOW_OPTIONS := [1, 5, 10, 30]         ## 時間窓の選択肢 [秒]
const ASSUMED_RATE_HZ := 100.0
const SMOOTHING_WINDOW := 5
const SETTINGS_KEY := "monitor"
const PLOT_MIN_HEIGHT := 120
const READOUT_WIDTH := 250

var _manager: SensorManager
var _logger: LoggingService

var _device_selector: OptionButton
var _record_button: Button
var _pause_button: Button
var _axis_selector: AxisSelector
var _record_target: Label
var _accel_block: VBoxContainer
var _accel_legend: HBoxContainer
var _accel_view: WaveformView
var _gyro_block: VBoxContainer
var _gyro_legend: HBoxContainer
var _gyro_view: WaveformView
var _hint: Label
var _readout_grid: GridContainer
var _readouts: Dictionary = {}                 ## axis -> {"now": Label, "max": Label, "min": Label}
var _sample_label: Label

var _paused := false
var _window_sec: int = 5
var _smoothing := true
var _selected_id := ""
var _axes: Array[int] = []                     ## 表示・記録する軸
var _recording_axes: Array[int] = []           ## 記録中の軸（記録開始時に確定）
var _rings: Dictionary = {}                    ## axis -> SampleRing（全8軸の生値を保持）


func setup(manager: SensorManager, logger: LoggingService) -> void:
	_manager = manager
	_logger = logger
	for axis in SensorAxis.ALL:
		_rings[axis] = SampleRing.new(RING_CAPACITY)
	_build()
	_manager.reading_received.connect(_on_reading_received)
	_manager.devices_changed.connect(_refresh_device_list)
	_logger.recording_stopped.connect(_on_recording_stopped)
	_apply_axes(_axis_selector.get_axes())
	_refresh_device_list()


## 記録中の軸（ステータスバー表示用）。記録していなければ空文字。
func recording_axes_text() -> String:
	if not _logger.is_recording():
		return ""
	return _axes_text(_recording_axes)


# ---------------------------------------------------------------- UI構築

func _build() -> void:
	add_theme_constant_override("separation", 10)
	add_child(_build_toolbar())
	add_child(_build_axis_bar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)

	var plots := VBoxContainer.new()
	plots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plots.add_theme_constant_override("separation", 8)

	_accel_legend = HBoxContainer.new()
	_accel_view = _make_waveform(SensorAxis.default_range(SensorAxis.Id.AX), SensorAxis.unit(SensorAxis.Id.AX))
	_accel_block = _make_plot_block(_accel_legend, _accel_view)
	plots.add_child(_accel_block)

	_gyro_legend = HBoxContainer.new()
	_gyro_view = _make_waveform(SensorAxis.default_range(SensorAxis.Id.GX), SensorAxis.unit(SensorAxis.Id.GX))
	_gyro_block = _make_plot_block(_gyro_legend, _gyro_view)
	plots.add_child(_gyro_block)

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
	smooth_check.text = UIStrings.LABEL_MOVING_AVERAGE
	smooth_check.button_pressed = _smoothing
	smooth_check.toggled.connect(func(pressed: bool) -> void: _smoothing = pressed)
	toolbar.add_child(smooth_check)

	return toolbar


func _build_axis_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)

	var label := _make_label(UIStrings.LABEL_AXES)
	bar.add_child(label)

	_axis_selector = AxisSelector.new()
	_axis_selector.setup(SETTINGS_KEY, SensorAxis.RAW)
	_axis_selector.axes_changed.connect(_apply_axes)
	bar.add_child(_axis_selector)

	_record_target = Label.new()
	_record_target.modulate = Color(1, 1, 1, 0.7)
	_record_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_record_target.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_record_target)
	return bar


func _make_plot_block(legend: HBoxContainer, view: WaveformView) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.size_flags_vertical = Control.SIZE_EXPAND_FILL
	block.add_theme_constant_override("separation", 4)
	legend.add_theme_constant_override("separation", 12)
	block.add_child(legend)
	block.add_child(view)
	return block


func _make_waveform(value_range: float, unit: String) -> WaveformView:
	var view := WaveformView.new()
	view.custom_minimum_size.y = PLOT_MIN_HEIGHT
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.value_range = value_range
	view.unit_text = unit
	return view


func _build_readout_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = READOUT_WIDTH

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	_readout_grid = GridContainer.new()
	_readout_grid.columns = 4
	_readout_grid.add_theme_constant_override("h_separation", 12)
	_readout_grid.add_theme_constant_override("v_separation", 4)
	box.add_child(_readout_grid)

	box.add_child(HSeparator.new())
	var sample_row := HBoxContainer.new()
	var sample_name := _make_label(UIStrings.MONITOR_SAMPLE_COUNT)
	sample_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sample_row.add_child(sample_name)
	_sample_label = _make_label("0")
	sample_row.add_child(_sample_label)
	box.add_child(sample_row)

	var note := _make_label(UIStrings.MONITOR_READOUT_NOTE)
	note.modulate = Color(1, 1, 1, 0.45)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)

	panel.add_child(box)
	return panel


## 選択軸に合わせて数値パネルの行を作り直す。
func _rebuild_readouts() -> void:
	for child in _readout_grid.get_children():
		_readout_grid.remove_child(child)
		child.queue_free()
	_readouts.clear()

	for header in [UIStrings.MONITOR_READOUT_AXIS, UIStrings.MONITOR_READOUT_NOW,
			UIStrings.MONITOR_READOUT_MAX, UIStrings.MONITOR_READOUT_MIN]:
		var label := _make_label(header)
		label.modulate = Color(1, 1, 1, 0.6)
		_readout_grid.add_child(label)

	for axis in _axes:
		var name_label := _make_label(SensorAxis.short_label(axis))
		name_label.add_theme_color_override("font_color", SensorAxis.color(axis))
		name_label.tooltip_text = "%s [%s]" % [SensorAxis.label(axis), SensorAxis.unit(axis)]
		name_label.mouse_filter = Control.MOUSE_FILTER_PASS
		_readout_grid.add_child(name_label)
		var row := {}
		for key in ["now", "max", "min"]:
			var value := _make_label("-")
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value.custom_minimum_size.x = 52
			_readout_grid.add_child(value)
			row[key] = value
		_readouts[axis] = row


func _rebuild_legend(legend: HBoxContainer, title: String, axes: Array[int]) -> void:
	for child in legend.get_children():
		legend.remove_child(child)
		child.queue_free()
	var title_label := _make_label(title)
	title_label.modulate = Color(1, 1, 1, 0.7)
	legend.add_child(title_label)
	for axis in axes:
		var item := _make_label("■ " + SensorAxis.short_label(axis))
		item.add_theme_color_override("font_color", SensorAxis.color(axis))
		legend.add_child(item)


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# ---------------------------------------------------------------- 軸

func _apply_axes(axes: Array) -> void:
	_axes.clear()
	for axis in axes:
		_axes.append(int(axis))
	var accel_axes := _accel_axes()
	var gyro_axes := _gyro_axes()
	_accel_block.visible = not accel_axes.is_empty()
	_gyro_block.visible = not gyro_axes.is_empty()
	_rebuild_legend(_accel_legend, UIStrings.LABEL_ACCEL, accel_axes)
	_rebuild_legend(_gyro_legend, UIStrings.LABEL_GYRO, gyro_axes)
	_rebuild_readouts()
	_update_record_status()


func _accel_axes() -> Array[int]:
	var result: Array[int] = []
	for axis in _axes:
		if SensorAxis.is_accel(axis):
			result.append(axis)
	return result


func _gyro_axes() -> Array[int]:
	var result: Array[int] = []
	for axis in _axes:
		if not SensorAxis.is_accel(axis):
			result.append(axis)
	return result


static func _axes_text(axes: Array) -> String:
	var names := PackedStringArray()
	for axis in axes:
		names.append(SensorAxis.short_label(axis))
	return ", ".join(names)


# ---------------------------------------------------------------- データ処理

func _clear_rings() -> void:
	for axis in _rings.keys():
		_rings[axis].clear()


func _on_reading_received(reading: SensorReading) -> void:
	_logger.write(reading)
	if reading.device_id != _selected_id or _paused:
		return
	for axis in SensorAxis.ALL:
		_rings[axis].push(SensorAxis.value_of(reading, axis))


## 表示する区間を切り出す（必要なら移動平均をかける）。
func _window_of(axis: int) -> PackedFloat32Array:
	var visible_count := int(ASSUMED_RATE_HZ * float(_window_sec))
	var buffer: PackedFloat32Array = _rings[axis].latest(visible_count)
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
	# 1フレームに1回だけ各軸の表示区間を切り出し、グラフと数値パネルで使い回す
	var windows: Dictionary = {}
	for axis in _axes:
		windows[axis] = _window_of(axis)

	var visible_count := int(ASSUMED_RATE_HZ * float(_window_sec))
	_accel_view.capacity = visible_count
	_gyro_view.capacity = visible_count
	if _accel_block.visible:
		_accel_view.set_series(_series_for(_accel_axes(), windows))
	if _gyro_block.visible:
		_gyro_view.set_series(_series_for(_gyro_axes(), windows))
	_update_readouts(windows)


func _series_for(axes: Array[int], windows: Dictionary) -> Array:
	var result: Array = []
	for axis in axes:
		result.append({"color": SensorAxis.color(axis), "data": windows[axis]})
	return result


func _update_readouts(windows: Dictionary) -> void:
	for axis in _axes:
		var data: PackedFloat32Array = windows[axis]
		var row: Dictionary = _readouts.get(axis, {})
		if row.is_empty():
			continue
		if data.is_empty():
			row["now"].text = "-"
			row["max"].text = "-"
			row["min"].text = "-"
			continue
		var max_value := -INF
		var min_value := INF
		for v in data:
			max_value = maxf(max_value, v)
			min_value = minf(min_value, v)
		var fmt := "%.2f" if SensorAxis.is_accel(axis) else "%.1f"
		row["now"].text = fmt % data[data.size() - 1]
		row["max"].text = fmt % max_value
		row["min"].text = fmt % min_value

	var device := _manager.registry.get_device(_selected_id)
	_sample_label.text = str(device.sample_count) if device != null else "0"


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
		_clear_rings()


func _on_record_pressed() -> void:
	if _logger.is_recording():
		_logger.stop()   # recording_stopped で表示を戻す
		return

	var device := _manager.registry.get_device(_selected_id)
	if device == null:
		return
	if _logger.start(device, _axes):
		_recording_axes = _axes.duplicate()
		_record_button.text = UIStrings.BTN_RECORD_STOP
		_axis_selector.set_editable(false, UIStrings.AXIS_LOCKED_RECORDING)
		_update_record_status()


func _on_recording_stopped(_info: Dictionary) -> void:
	_record_button.text = UIStrings.BTN_RECORD_START
	_axis_selector.set_editable(true)
	_recording_axes.clear()
	_update_record_status()


func _update_record_status() -> void:
	if _logger.is_recording():
		_record_target.text = UIStrings.MONITOR_RECORDING_AXES % _axes_text(_recording_axes)
	else:
		_record_target.text = UIStrings.MONITOR_RECORD_TARGET % _axes_text(_axes)
