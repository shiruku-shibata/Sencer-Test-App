class_name DeviceCommandDialog
extends AcceptDialog
## デバイス操作のダイアログ（デバイス管理画面の各行の「操作…」から開く）。
## 接続中のデバイスへ PAUSE / RESUME / RATE <Hz> / INFO を送り、応答（デバイスからの '#' 行）を表示する。
##
##   ・送ったら応答（DeviceCommand.is_reply_to）が届くか REPLY_TIMEOUT_MS たつまで「応答待ち」にし、
##     その間はコマンドのボタンを押せなくする（二重送信の防止）
##   ・送信できなかった（send_command が false）・応答が無い・切断された、もそれぞれ表示する
##   ・# error=… は警告色、# ok=… と情報行は通常色、# event=… は薄い色

const REPLY_TIMEOUT_MS := 3000
const REFRESH_INTERVAL := 0.1
const CONTENT_WIDTH := 620             ## 折り返すラベルの幅（決めないとラベルが縦に伸びてダイアログが画面からはみ出す）
const HISTORY_LINES := 8
const HISTORY_HEIGHT := 96
const INFO_COLUMNS := 3                ## デバイス情報の「項目: 値」を横に並べる数
const RATE_MISMATCH_RATIO := 0.85     ## 実際の受信が設定のこの割合を下回ったら注意を出す
const COLOR_NORMAL := Color(1, 1, 1)
const COLOR_WARN := Color(1.0, 0.72, 0.35)
const COLOR_MUTED := Color(1, 1, 1, 0.6)
const COLOR_BUSY := Color(0.9, 0.85, 0.4)

var _manager: SensorManager
var _device_id := ""
var _pending_command := ""      ## 応答待ちのコマンド（空 = 待っていない）
var _pending_seq := 0           ## 送信直前の DeviceLineLog.last_seq()
var _pending_since_ms := 0
var _refresh_timer := 0.0

var _device_label: Label
var _state_label: Label
var _mismatch_label: Label
var _pause_button: Button
var _resume_button: Button
var _rate_spin: SpinBox
var _rate_button: Button
var _info_button: Button
var _result_label: Label
var _info_label: Label
var _info_grid: GridContainer
var _shown_info := ""
var _history: RichTextLabel


func setup(manager: SensorManager) -> void:
	_manager = manager
	ok_button_text = UIStrings.CMD_CLOSE
	min_size = Vector2i(CONTENT_WIDTH + 40, 0)
	_build()
	visibility_changed.connect(func() -> void: set_process(visible))
	set_process(false)


## 指定したデバイスの操作画面を開く。
func open_for(device_id: String) -> void:
	if _device_id != device_id:
		_device_id = device_id
		_clear_pending()
		_set_result(UIStrings.CMD_RESULT_NONE, COLOR_MUTED)
	var settings := _settings()
	if settings.has("rate"):
		_rate_spin.set_value_no_signal(int(settings["rate"]))
	_refresh()
	if visible:
		grab_focus()   # 開いたまま別の行の「操作…」を押したときは中身だけ切り替える
	else:
		popup_centered()


## 応答待ちのコマンド（無ければ空）。
func pending_command() -> String:
	return _pending_command


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	_device_label = Label.new()
	box.add_child(_device_label)
	_state_label = Label.new()
	box.add_child(_state_label)
	_mismatch_label = Label.new()
	_mismatch_label.modulate = COLOR_WARN
	_mismatch_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mismatch_label.custom_minimum_size.x = CONTENT_WIDTH
	_mismatch_label.text = UIStrings.CMD_RATE_MISMATCH
	box.add_child(_mismatch_label)
	box.add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)

	grid.add_child(_muted_label(UIStrings.CMD_SENDING))
	var send_row := HBoxContainer.new()
	_pause_button = _command_button(UIStrings.CMD_PAUSE, func() -> String: return DeviceCommand.PAUSE)
	send_row.add_child(_pause_button)
	_resume_button = _command_button(UIStrings.CMD_RESUME, func() -> String: return DeviceCommand.RESUME)
	send_row.add_child(_resume_button)
	grid.add_child(send_row)

	grid.add_child(_muted_label(UIStrings.CMD_RATE))
	var rate_row := HBoxContainer.new()
	_rate_spin = SpinBox.new()
	_rate_spin.min_value = DeviceCommand.RATE_MIN
	_rate_spin.max_value = DeviceCommand.RATE_MAX
	_rate_spin.step = 1
	_rate_spin.rounded = true
	_rate_spin.value = DeviceCommand.RATE_DEFAULT
	_rate_spin.suffix = "Hz"
	_rate_spin.custom_minimum_size.x = 110
	rate_row.add_child(_rate_spin)
	_rate_button = _command_button(UIStrings.CMD_RATE_APPLY,
			func() -> String: return DeviceCommand.rate_command(int(_rate_spin.value)))
	rate_row.add_child(_rate_button)
	grid.add_child(rate_row)

	grid.add_child(Control.new())
	var rate_hint := _muted_label(UIStrings.CMD_RATE_HINT % [DeviceCommand.RATE_MIN, DeviceCommand.RATE_MAX])
	rate_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rate_hint.custom_minimum_size.x = 440
	grid.add_child(rate_hint)

	grid.add_child(Control.new())
	_info_button = _command_button(UIStrings.CMD_INFO, func() -> String: return DeviceCommand.INFO)
	_info_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	grid.add_child(_info_button)
	box.add_child(grid)
	box.add_child(HSeparator.new())

	box.add_child(_muted_label(UIStrings.CMD_RESULT_TITLE))
	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.custom_minimum_size.x = CONTENT_WIDTH
	box.add_child(_result_label)

	box.add_child(_muted_label(UIStrings.CMD_INFO_TITLE))
	_info_label = _muted_label(UIStrings.CMD_INFO_EMPTY)
	box.add_child(_info_label)
	_info_grid = GridContainer.new()
	_info_grid.columns = INFO_COLUMNS * 2
	_info_grid.add_theme_constant_override("h_separation", 10)
	box.add_child(_info_grid)

	box.add_child(_muted_label(UIStrings.CMD_HISTORY_TITLE))
	_history = RichTextLabel.new()
	_history.bbcode_enabled = true
	_history.custom_minimum_size.y = HISTORY_HEIGHT
	_history.scroll_following = true
	_history.selection_enabled = true
	box.add_child(_history)

	add_child(box)


func _command_button(text: String, make_command: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(func() -> void: _send(str(make_command.call())))
	return button


func _muted_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = COLOR_MUTED
	return label


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer < REFRESH_INTERVAL:
		return
	_refresh_timer = 0.0
	_refresh()


# ---------------------------------------------------------------- 送信と応答

func _send(command: String) -> void:
	if not _pending_command.is_empty() or not _is_connected():
		return   # 応答待ち中・未接続（ボタンは押せないはずだが、念のため）
	var line_log := _manager.device_line_log(_device_id)
	var seq_before := line_log.last_seq() if line_log != null else 0
	if not _manager.send_command(_device_id, command):
		_set_result(UIStrings.CMD_SEND_FAILED % command, COLOR_WARN)
		_refresh()
		return
	_pending_command = command
	_pending_seq = seq_before
	_pending_since_ms = Time.get_ticks_msec()
	_set_result(UIStrings.CMD_WAITING % command, COLOR_BUSY)
	_refresh()   # デモのようにすぐ応答が返る場合はここで表示まで進む


## 応答待ちの状態を進める（応答の到着・時間切れ・切断）。
func _update_pending() -> void:
	if _pending_command.is_empty():
		return
	if not _is_connected():
		_set_result(UIStrings.CMD_DISCONNECTED % _pending_command, COLOR_WARN)
		_clear_pending()
		return
	var line_log := _manager.device_line_log(_device_id)
	if line_log != null:
		for entry in line_log.lines(_device_id):
			if int(entry["seq"]) <= _pending_seq:
				continue
			var text := str(entry["text"])
			if DeviceCommand.is_reply_to(_pending_command, text):
				_show_reply(_pending_command, text)
				_clear_pending()
				return
	if Time.get_ticks_msec() - _pending_since_ms >= REPLY_TIMEOUT_MS:
		_set_result(UIStrings.CMD_NO_REPLY % [_pending_command, REPLY_TIMEOUT_MS / 1000], COLOR_WARN)
		_clear_pending()


func _show_reply(command: String, text: String) -> void:
	if DeviceCommand.kind_of(text) == DeviceCommand.KIND_ERROR:
		var code := str(DeviceCommand.parse_fields(text).get("error", ""))
		var hint := str(UIStrings.CMD_ERROR_HINTS.get(code, ""))
		_set_result(UIStrings.CMD_REPLY_ERROR % [command, text] + ("\n" + hint if not hint.is_empty() else ""),
				COLOR_WARN)
	else:
		_set_result(UIStrings.CMD_REPLY % [command, text], COLOR_NORMAL)


func _clear_pending() -> void:
	_pending_command = ""
	_pending_seq = 0
	_pending_since_ms = 0


func _set_result(text: String, color: Color) -> void:
	_result_label.text = text
	_result_label.modulate = color


# ---------------------------------------------------------------- 表示の更新

func _refresh() -> void:
	if _manager == null or _device_id.is_empty():
		return
	_update_pending()
	var device := _manager.registry.get_device(_device_id)
	var connected := _is_connected()
	title = UIStrings.CMD_TITLE % (device.display_name() if device != null else _device_id)
	if device != null:
		_device_label.text = UIStrings.CMD_DEVICE % [device.display_name(),
				SensorDevice.mode_label(device.mode), device.id]

	var settings := _settings()
	if connected:
		var sending := UIStrings.CMD_STATE_UNKNOWN
		if settings.has("sending"):
			sending = UIStrings.CMD_STATE_SENDING if bool(settings["sending"]) else UIStrings.CMD_STATE_PAUSED
		var rate := UIStrings.CMD_RATE_HZ % int(settings["rate"]) if settings.has("rate") else UIStrings.CMD_RATE_UNKNOWN
		_state_label.text = UIStrings.CMD_STATE_LINE % [sending, rate, device.rate_hz if device != null else 0.0]
		_state_label.modulate = COLOR_NORMAL
	else:
		_state_label.text = UIStrings.CMD_NOT_CONNECTED
		_state_label.modulate = COLOR_WARN
	# 送信中で設定レートが分かっているのに、実際の受信が明らかに少ないときだけ注意を出す
	_mismatch_label.visible = connected and device != null and device.rate_hz > 0.0 \
			and bool(settings.get("sending", true)) and settings.has("rate") \
			and device.rate_hz < float(settings["rate"]) * RATE_MISMATCH_RATIO

	var can_send := connected and _pending_command.is_empty()
	for button in [_pause_button, _resume_button, _rate_button, _info_button]:
		(button as Button).disabled = not can_send
	_rate_spin.editable = connected

	_refresh_info()
	_refresh_history()


func _refresh_info() -> void:
	var line_log := _manager.device_line_log(_device_id)
	var info := line_log.info(_device_id) if line_log != null else ""
	_info_label.visible = info.is_empty()
	if info == _shown_info:
		return
	_shown_info = info
	for child in _info_grid.get_children():
		_info_grid.remove_child(child)
		child.queue_free()
	var fields := DeviceCommand.parse_fields(info)
	for key in fields.keys():
		_info_grid.add_child(_muted_label(str(UIStrings.CMD_INFO_KEYS.get(key, key))))
		var value := Label.new()
		value.text = str(fields[key])
		_info_grid.add_child(value)


func _refresh_history() -> void:
	var line_log := _manager.device_line_log(_device_id)
	var lines: Array = line_log.lines(_device_id) if line_log != null else []
	var bbcode := PackedStringArray()
	for i in range(maxi(0, lines.size() - HISTORY_LINES), lines.size()):
		var text := str(lines[i]["text"])
		var color := COLOR_NORMAL
		match DeviceCommand.kind_of(text):
			DeviceCommand.KIND_ERROR:
				color = COLOR_WARN
			DeviceCommand.KIND_EVENT:
				color = COLOR_MUTED
		bbcode.append("[color=#%s]%s[/color]" % [color.to_html(), _escape_bbcode(text)])
	var joined := "\n".join(bbcode) if not bbcode.is_empty() \
			else "[color=#%s]%s[/color]" % [COLOR_MUTED.to_html(), UIStrings.CMD_HISTORY_EMPTY]
	if _history.text != joined:
		_history.text = joined


func _is_connected() -> bool:
	var device := _manager.registry.get_device(_device_id) if _manager != null else null
	return device != null and device.connected


func _settings() -> Dictionary:
	var line_log := _manager.device_line_log(_device_id) if _manager != null else null
	return line_log.settings(_device_id) if line_log != null else {}


static func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
