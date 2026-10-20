class_name DevicesScreen
extends VBoxContainer
## S1 デバイス管理画面。デバイスの探索・接続・切断・ニックネーム設定と、BLE ブリッジの状態表示を行う。
## 接続中のデバイスは「操作…」から一時停止・送信レート変更・情報取得ができる（DeviceCommandDialog）。
##
## 一覧は1秒ごとに更新されるが、行は作り直さずに中身だけ書き換える
## （作り直すとニックネーム入力中にフォーカスが外れてしまうため）。

const COLUMN_COUNT := 9
const MODE_COLORS := {
	SensorDevice.Mode.SERIAL: Color(0.55, 0.8, 1.0),
	SensorDevice.Mode.BLE: Color(0.78, 0.62, 1.0),
	SensorDevice.Mode.MOCK: Color(0.65, 0.65, 0.65),
}
const COLOR_OK := Color(0.45, 0.85, 0.5)
const COLOR_BUSY := Color(0.9, 0.85, 0.4)
const COLOR_ERROR := Color(1.0, 0.6, 0.45)
const COLOR_MUTED := Color(1, 1, 1, 0.6)


## 一覧の1行分のコントロール。
class Row:
	var name_edit: LineEdit
	var mode: Label
	var device_name: Label
	var id: Label
	var state: Label
	var rssi: Label
	var rate: Label
	var action: Button
	var commands: Button

	func controls() -> Array[Control]:
		return [name_edit, mode, device_name, id, state, rssi, rate, action, commands]


var _manager: SensorManager
var _grid: GridContainer
var _notice: Label
var _scan_state: Label
var _ble_panel: Control
var _ble_dot: Label
var _ble_status: Label
var _ble_restart: Button
var _ble_manual: Button
var _manual_box: VBoxContainer
var _manual_command: LineEdit
var _copy_button: Button
var _header_count := 0
var _rows: Dictionary = {}           ## device_id -> Row
var _row_order: PackedStringArray = []
var _command_dialog: DeviceCommandDialog


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

	_scan_state = Label.new()
	_scan_state.modulate = COLOR_BUSY
	toolbar.add_child(_scan_state)

	var hint := Label.new()
	hint.text = UIStrings.HINT_RENAME
	hint.modulate = COLOR_MUTED
	toolbar.add_child(hint)
	add_child(toolbar)

	_ble_panel = _build_ble_panel()
	add_child(_ble_panel)

	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.modulate = Color(1.0, 0.75, 0.55)
	add_child(_notice)

	_grid = GridContainer.new()
	_grid.columns = COLUMN_COUNT
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 6)
	for header in [UIStrings.LABEL_NICKNAME, UIStrings.LABEL_MODE, UIStrings.DEV_LABEL_DEVICE_NAME,
			UIStrings.LABEL_ID, UIStrings.LABEL_STATE, UIStrings.DEV_LABEL_RSSI, UIStrings.LABEL_RATE,
			UIStrings.LABEL_ACTION, UIStrings.DEV_LABEL_COMMANDS]:
		var label := _make_label(header)
		label.modulate = COLOR_MUTED
		_grid.add_child(label)
	_header_count = _grid.get_child_count()
	add_child(_grid)

	_command_dialog = DeviceCommandDialog.new()
	add_child(_command_dialog)
	_command_dialog.setup(_manager)


## BLE ブリッジの状態・対処・操作ボタンをまとめた枠。
func _build_ble_panel() -> Control:
	var panel := PanelContainer.new()
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	var box := VBoxContainer.new()

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	_ble_dot = Label.new()
	_ble_dot.text = "●"
	line.add_child(_ble_dot)
	_ble_status = Label.new()
	_ble_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ble_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(_ble_status)

	_ble_restart = Button.new()
	_ble_restart.text = UIStrings.DEV_BLE_RESTART
	_ble_restart.tooltip_text = UIStrings.DEV_BLE_RESTART_TIP
	_ble_restart.pressed.connect(func() -> void:
		var ble := _ble()
		if ble != null:
			ble.restart_bridge()
		_refresh()
	)
	line.add_child(_ble_restart)

	_ble_manual = Button.new()
	_ble_manual.text = UIStrings.DEV_BLE_MANUAL
	_ble_manual.tooltip_text = UIStrings.DEV_BLE_MANUAL_TIP
	_ble_manual.pressed.connect(func() -> void:
		var ble := _ble()
		if ble != null:
			ble.use_manual_bridge()
		_refresh()
	)
	line.add_child(_ble_manual)
	box.add_child(line)

	_manual_box = VBoxContainer.new()
	var manual_hint := _make_label(UIStrings.DEV_BLE_MANUAL_HINT)
	manual_hint.modulate = COLOR_MUTED
	_manual_box.add_child(manual_hint)
	var command_line := HBoxContainer.new()
	_manual_command = LineEdit.new()
	_manual_command.editable = false
	_manual_command.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_line.add_child(_manual_command)
	_copy_button = Button.new()
	_copy_button.text = UIStrings.DEV_COPY
	_copy_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_manual_command.text)
		_copy_button.text = UIStrings.DEV_COPIED
	)
	command_line.add_child(_copy_button)
	_manual_box.add_child(command_line)
	box.add_child(_manual_box)

	margin.add_child(box)
	panel.add_child(margin)
	return panel


func _ble() -> BleSensorProvider:
	return _manager.get_provider(SensorDevice.Mode.BLE) as BleSensorProvider


func _refresh() -> void:
	if _grid == null:
		return
	_scan_state.text = UIStrings.DEV_SCANNING if _manager.is_scanning() else ""
	_refresh_ble_panel()

	# BLE 以外で使えない方式の注意書き（BLE は上の枠に出す）
	var notices := PackedStringArray()
	for provider in _manager.providers:
		if provider.get_mode() != SensorDevice.Mode.BLE and not provider.is_available():
			notices.append(provider.unavailable_reason())
	_notice.text = "\n".join(notices)
	_notice.visible = not _notice.text.is_empty()

	_sync_rows()
	for device in _manager.registry.all():
		_update_row(_rows[device.id], device)


func _refresh_ble_panel() -> void:
	var ble := _ble()
	_ble_panel.visible = ble != null
	if ble == null:
		return
	_ble_status.text = ble.status_text()
	if ble.has_problem():
		_ble_dot.modulate = COLOR_ERROR
	elif ble.is_ready():
		_ble_dot.modulate = COLOR_OK
	else:
		_ble_dot.modulate = COLOR_BUSY

	var show_manual := ble.suggests_manual_launch()
	_manual_box.visible = show_manual
	if show_manual:
		var command := ble.manual_command()
		if _manual_command.text != command:
			_manual_command.text = command
			_copy_button.text = UIStrings.DEV_COPY


## 行の集合を、レジストリのデバイス一覧に合わせる。既存の行は作り直さず並べ替えるだけ。
func _sync_rows() -> void:
	var ids := PackedStringArray()
	for device in _manager.registry.all():
		ids.append(device.id)
	if ids == _row_order:
		return

	for id in _rows.keys():
		if not ids.has(id):
			for control in (_rows[id] as Row).controls():
				_grid.remove_child(control)
				control.queue_free()
			_rows.erase(id)

	var index := _header_count
	for id in ids:
		if not _rows.has(id):
			_rows[id] = _create_row(id)
		for control in (_rows[id] as Row).controls():
			_grid.move_child(control, index)   # move_child はフォーカスを保つ
			index += 1
	_row_order = ids


func _create_row(device_id: String) -> Row:
	var row := Row.new()
	row.name_edit = LineEdit.new()
	row.name_edit.custom_minimum_size.x = 160
	row.name_edit.text_submitted.connect(func(new_text: String) -> void:
		_save_nickname(device_id, new_text)
		row.name_edit.release_focus()
	)
	row.name_edit.focus_exited.connect(func() -> void: _save_nickname(device_id, row.name_edit.text))
	row.mode = Label.new()
	row.device_name = Label.new()
	row.device_name.mouse_filter = Control.MOUSE_FILTER_PASS
	row.id = Label.new()
	row.id.mouse_filter = Control.MOUSE_FILTER_PASS
	row.state = Label.new()
	row.state.mouse_filter = Control.MOUSE_FILTER_PASS
	row.rssi = Label.new()
	row.rate = Label.new()
	row.action = Button.new()
	row.action.pressed.connect(func() -> void: _on_action(device_id))
	row.commands = Button.new()
	row.commands.text = UIStrings.CMD_OPEN
	row.commands.pressed.connect(func() -> void: _command_dialog.open_for(device_id))

	# 初回はニックネームを入れておく（以後は入力中でないときだけ同期する）
	var device := _manager.registry.get_device(device_id)
	if device != null:
		row.name_edit.text = device.nickname
	for control in row.controls():
		_grid.add_child(control)
	return row


func _update_row(row: Row, device: SensorDevice) -> void:
	if not row.name_edit.has_focus() and row.name_edit.text != device.nickname:
		row.name_edit.text = device.nickname
	row.name_edit.placeholder_text = device.label if not device.label.is_empty() else device.id

	row.mode.text = SensorDevice.mode_label(device.mode)
	row.mode.modulate = MODE_COLORS.get(device.mode, Color.WHITE)
	row.device_name.text = device.label if not device.label.is_empty() else "-"
	row.id.text = device.id

	var ble: BleSensorProvider = _ble() if device.mode == SensorDevice.Mode.BLE else null
	var line_log := _manager.device_line_log(device.id)
	var settings := line_log.settings(device.id) if line_log != null else {}
	var tips := PackedStringArray()
	if line_log != null:
		for text in [line_log.info(device.id), line_log.reply(device.id)]:
			if not text.is_empty():
				tips.append(text)
	row.device_name.tooltip_text = "\n".join(tips)
	var connecting := _manager.is_connecting(device.id)
	var error := ble.device_error(device.id) if ble != null else ""
	if device.connected:
		row.state.text = UIStrings.LABEL_CONNECTED
		if not bool(settings.get("sending", true)):
			row.state.text += UIStrings.DEV_PAUSED_SUFFIX
		row.state.modulate = COLOR_OK
	elif connecting:
		row.state.text = UIStrings.DEV_CONNECTING
		row.state.modulate = COLOR_BUSY
	elif not error.is_empty():
		row.state.text = UIStrings.LABEL_DISCONNECTED + UIStrings.DEV_ERROR_SUFFIX
		row.state.modulate = COLOR_ERROR
	else:
		row.state.text = UIStrings.LABEL_DISCONNECTED
		row.state.modulate = Color.WHITE
	row.state.tooltip_text = error

	row.rssi.text = "%d dBm" % device.rssi if device.rssi != 0 else "-"
	if not device.connected:
		row.rate.text = "-"
	elif settings.has("rate"):
		row.rate.text = UIStrings.DEV_RATE_WITH_SETTING % [device.rate_hz, int(settings["rate"])]
	else:
		row.rate.text = "%.0f Hz" % device.rate_hz

	if device.connected:
		row.action.text = UIStrings.BTN_DISCONNECT
	elif connecting:
		row.action.text = UIStrings.DEV_CANCEL
	else:
		row.action.text = UIStrings.BTN_CONNECT
	var ble_not_ready := ble != null and not device.connected and not connecting \
			and (not ble.is_ready() or not ble.is_available())
	row.action.disabled = ble_not_ready
	row.action.tooltip_text = UIStrings.DEV_BLE_NOT_READY if ble_not_ready else ""
	row.commands.disabled = not device.connected
	row.commands.tooltip_text = UIStrings.CMD_OPEN_TIP if device.connected else UIStrings.CMD_OPEN_DISABLED_TIP


func _on_action(device_id: String) -> void:
	var device := _manager.registry.get_device(device_id)
	if device == null:
		return
	if device.connected or _manager.is_connecting(device_id):
		_manager.close_device(device_id)
	else:
		_manager.open_device(device_id)
	_refresh()


func _save_nickname(device_id: String, text: String) -> void:
	var device := _manager.registry.get_device(device_id)
	if device != null and device.nickname != text:
		_manager.registry.set_nickname(device_id, text)


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label
