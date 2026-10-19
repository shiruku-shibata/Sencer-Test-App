class_name DevicesScreen
extends VBoxContainer
## S1 デバイス管理画面。デバイスの探索・接続・切断・ニックネーム設定を行う。

const COLUMN_COUNT := 6

var _manager: SensorManager
var _grid: GridContainer
var _notice: Label


func setup(manager: SensorManager) -> void:
	_manager = manager
	_manager.devices_changed.connect(_refresh)
	_manager.status_changed.connect(_refresh)
	_build()
	_refresh()


func _build() -> void:
	add_theme_constant_override("separation", 10)

	var toolbar := HBoxContainer.new()
	var scan_button := Button.new()
	scan_button.text = UIStrings.BTN_SCAN
	scan_button.pressed.connect(func() -> void: _manager.scan_all())
	toolbar.add_child(scan_button)

	var hint := Label.new()
	hint.text = UIStrings.HINT_RENAME
	hint.modulate = Color(1, 1, 1, 0.6)
	toolbar.add_child(hint)
	add_child(toolbar)

	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.modulate = Color(1.0, 0.75, 0.55)
	add_child(_notice)

	_grid = GridContainer.new()
	_grid.columns = COLUMN_COUNT
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 6)
	add_child(_grid)


func _refresh() -> void:
	if _grid == null:
		return
	_notice.text = "\n".join(_manager.unavailable_notices())
	_notice.visible = not _notice.text.is_empty()

	for child in _grid.get_children():
		child.queue_free()

	for header in [UIStrings.LABEL_NICKNAME, UIStrings.LABEL_MODE, UIStrings.LABEL_ID,
			UIStrings.LABEL_STATE, UIStrings.LABEL_RATE, UIStrings.LABEL_ACTION]:
		var label := Label.new()
		label.text = header
		label.modulate = Color(1, 1, 1, 0.6)
		_grid.add_child(label)

	for device in _manager.registry.all():
		_add_row(device)


func _add_row(device: SensorDevice) -> void:
	var name_edit := LineEdit.new()
	name_edit.text = device.nickname
	name_edit.placeholder_text = device.id
	name_edit.custom_minimum_size.x = 160
	name_edit.text_submitted.connect(
		func(new_text: String) -> void: _manager.registry.set_nickname(device.id, new_text)
	)
	_grid.add_child(name_edit)

	_grid.add_child(_make_label(SensorDevice.mode_label(device.mode)))
	_grid.add_child(_make_label(device.id))
	_grid.add_child(_make_label(
		UIStrings.LABEL_CONNECTED if device.connected else UIStrings.LABEL_DISCONNECTED
	))
	_grid.add_child(_make_label("%.0f Hz" % device.rate_hz if device.connected else "-"))

	var action := Button.new()
	action.text = UIStrings.BTN_DISCONNECT if device.connected else UIStrings.BTN_CONNECT
	action.pressed.connect(func() -> void:
		if device.connected:
			_manager.close_device(device.id)
		else:
			_manager.open_device(device.id)
	)
	_grid.add_child(action)


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label
