extends Control
## アプリのルート。サイドバー・画面切り替え・ステータスバーを組み立てる。
##
## 画面（S1〜S5）はそれぞれ独立したクラスになっており、
## 新しい画面を追加する場合は _create_screens() に1行足すだけでよい。

const SIDEBAR_WIDTH := 180

var _manager: SensorManager
var _logger := LoggingService.new()

var _sidebar_box: VBoxContainer
var _screens: Dictionary = {}          ## 画面名 -> Control
var _nav_buttons: Dictionary = {}      ## 画面名 -> Button
var _content: MarginContainer
var _title_label: Label
var _status_devices: Label
var _status_rate: Label
var _status_record: Label
var _current_screen := ""


func _ready() -> void:
	_manager = SensorManager.new()
	_manager.name = "SensorManager"
	add_child(_manager)

	_build_layout()
	_create_screens()
	_show_screen(UIStrings.SCREEN_DEVICES)


func _build_layout() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# --- サイドバー ---
	var sidebar_panel := PanelContainer.new()
	sidebar_panel.custom_minimum_size.x = SIDEBAR_WIDTH
	var sidebar := VBoxContainer.new()
	sidebar.add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = UIStrings.APP_TITLE
	sidebar.add_child(title)
	var subtitle := Label.new()
	subtitle.text = UIStrings.APP_SUBTITLE
	subtitle.modulate = Color(1, 1, 1, 0.5)
	sidebar.add_child(subtitle)
	sidebar.add_child(HSeparator.new())

	sidebar_panel.add_child(sidebar)
	root.add_child(sidebar_panel)
	_sidebar_box = sidebar

	# --- メイン領域 ---
	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)

	var topbar := PanelContainer.new()
	var topbar_box := HBoxContainer.new()
	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topbar_box.add_child(_title_label)
	var help_button := Button.new()
	help_button.text = "?"
	help_button.tooltip_text = "使い方を開く"
	help_button.pressed.connect(func() -> void: _show_screen(UIStrings.SCREEN_MANUAL))
	topbar_box.add_child(help_button)
	topbar.add_child(topbar_box)
	main.add_child(topbar)

	_content = MarginContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_content.add_theme_constant_override(side, 14)
	main.add_child(_content)

	main.add_child(_build_status_bar())
	root.add_child(main)


func _build_status_bar() -> PanelContainer:
	var panel := PanelContainer.new()
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 20)

	_status_devices = Label.new()
	_status_rate = Label.new()
	_status_record = Label.new()
	box.add_child(_status_devices)
	box.add_child(_status_rate)
	box.add_child(_status_record)

	panel.add_child(box)
	return panel


func _create_screens() -> void:
	var devices := DevicesScreen.new()
	devices.setup(_manager)
	_register_screen(UIStrings.SCREEN_DEVICES, devices)

	var monitor := MonitorScreen.new()
	monitor.setup(_manager, _logger)
	_register_screen(UIStrings.SCREEN_MONITOR, monitor)

	var logs := LogsScreen.new()
	logs.setup(_logger)
	_register_screen(UIStrings.SCREEN_LOGS, logs)

	var manual := ManualScreen.new()
	manual.setup()
	_register_screen(UIStrings.SCREEN_MANUAL, manual)


func _register_screen(screen_name: String, screen: Control) -> void:
	screen.visible = false
	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(screen)
	_screens[screen_name] = screen

	var button := Button.new()
	button.text = screen_name
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.pressed.connect(func() -> void: _show_screen(screen_name))
	_sidebar_box.add_child(button)
	_nav_buttons[screen_name] = button


func _show_screen(screen_name: String) -> void:
	_current_screen = screen_name
	for key in _screens.keys():
		_screens[key].visible = (key == screen_name)
		_nav_buttons[key].button_pressed = (key == screen_name)
	_title_label.text = screen_name


func _process(_delta: float) -> void:
	var connected := _manager.registry.connected_devices()
	_status_devices.text = "接続: %d 台" % connected.size()

	var rate := 0.0
	for device in connected:
		rate = maxf(rate, device.rate_hz)
	_status_rate.text = "受信: %.0f Hz" % rate

	if _logger.is_recording():
		_status_record.text = "記録中 %.1f s" % _logger.elapsed_sec()
	else:
		_status_record.text = "記録: 停止中"
