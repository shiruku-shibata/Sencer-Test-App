extends Control
## アプリのルート。サイドバー・画面切り替え・ステータスバーを組み立てる。
##
## 画面（S1〜S5）はそれぞれ独立したクラスになっており、
## 新しい画面を追加する場合は _create_screens() に数行足すだけでよい。
## 並び順: デバイス管理 / モニタリング / しきい値測定 / ログ管理 / マニュアル

const SIDEBAR_WIDTH := 200
const SIDEBAR_PADDING := 12          ## サイドバーの内側の余白 [px]
const BAR_PADDING_H := 14            ## 上下のバーの左右の余白（本文の余白とそろえる）
const BAR_PADDING_V := 5
## ブラウザ版で使う日本語フォント（Noto Sans JP のサブセット, OFL-1.1）。
## デスクトップ版は OS の日本語フォントを使うので読み込まない（書き出しにも含めない）。
const WEB_FONT_PATH := "res://assets/fonts/NotoSansJP-Regular-Subset.ttf"
## この環境変数を 1 にすると、デスクトップでもブラウザ版の見た目（同梱フォント・縮小表示）で起動する（確認用）
const ENV_WEB_PREVIEW := "SENSOR_WEB_PREVIEW"
const BASE_SIZE := Vector2i(1280, 800)

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
var _status_threshold: Label
var _monitor: MonitorScreen
var _threshold: ThresholdScreen
var _current_screen := ""


func _ready() -> void:
	if OS.has_feature("web") or OS.get_environment(ENV_WEB_PREVIEW) == "1":
		_apply_web_look()
	_manager = SensorManager.new()
	_manager.name = "SensorManager"
	add_child(_manager)

	_build_layout()
	_create_screens()
	_show_screen(UIStrings.SCREEN_DEVICES)


## ブラウザ版の見た目を整える。
##   - ブラウザには OS の日本語フォントが無いので、同梱フォントを既定のフォントにする
##     （ダイアログ等の別ウィンドウにも効くよう、テーマではなく既定テーマのフォントを差し替える）
##   - 画面が 1280x800 より小さいときは、全体を縮小して表示する
func _apply_web_look() -> void:
	var font := load(WEB_FONT_PATH) as Font
	if font != null:
		var bold := FontVariation.new()
		bold.base_font = font
		bold.variation_embolden = 0.8
		var default_theme := ThemeDB.get_default_theme()
		default_theme.default_font = font
		default_theme.set_font("normal_font", "RichTextLabel", font)
		default_theme.set_font("bold_font", "RichTextLabel", bold)
		default_theme.set_font("mono_font", "RichTextLabel", font)
		ThemeDB.fallback_font = font
	else:
		push_warning("ブラウザ版のフォントを読み込めませんでした: %s" % WEB_FONT_PATH)
	var window := get_window()
	window.content_scale_size = BASE_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND


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
	title.add_theme_font_size_override("font_size", 17)
	sidebar.add_child(title)
	var subtitle := Label.new()
	subtitle.text = UIStrings.APP_SUBTITLE
	subtitle.modulate = Color(1, 1, 1, 0.5)
	subtitle.add_theme_font_size_override("font_size", 13)
	sidebar.add_child(subtitle)
	var separator := HSeparator.new()
	separator.add_theme_constant_override("separation", 14)
	sidebar.add_child(separator)

	sidebar_panel.add_child(_padded(sidebar, SIDEBAR_PADDING, SIDEBAR_PADDING))
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
	help_button.tooltip_text = UIStrings.TOOLTIP_HELP
	help_button.pressed.connect(func() -> void: _show_screen(UIStrings.SCREEN_MANUAL))
	topbar_box.add_child(help_button)
	topbar.add_child(_padded(topbar_box, BAR_PADDING_H, BAR_PADDING_V))
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

	_status_threshold = Label.new()
	box.add_child(_status_threshold)

	panel.add_child(_padded(box, BAR_PADDING_H, BAR_PADDING_V))
	return panel


## 子を左右 h・上下 v の余白で包む。
static func _padded(child: Control, h: int, v: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", h)
	margin.add_theme_constant_override("margin_right", h)
	margin.add_theme_constant_override("margin_top", v)
	margin.add_theme_constant_override("margin_bottom", v)
	margin.add_child(child)
	return margin


func _create_screens() -> void:
	var devices := DevicesScreen.new()
	devices.setup(_manager)
	_register_screen(UIStrings.SCREEN_DEVICES, devices)

	_monitor = MonitorScreen.new()
	_monitor.setup(_manager, _logger)
	_register_screen(UIStrings.SCREEN_MONITOR, _monitor)

	_threshold = ThresholdScreen.new()
	_threshold.setup(_manager, _logger)
	_register_screen(UIStrings.SCREEN_THRESHOLD, _threshold)

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
	_status_devices.text = UIStrings.STATUS_DEVICES % connected.size()

	var rate := 0.0
	for device in connected:
		rate = maxf(rate, device.rate_hz)
	_status_rate.text = UIStrings.STATUS_RATE % rate

	if _logger.is_recording():
		_status_record.text = UIStrings.STATUS_RECORDING % [_logger.elapsed_sec(), _monitor.recording_axes_text()]
	else:
		_status_record.text = UIStrings.STATUS_NOT_RECORDING

	_status_threshold.text = _threshold.status_text()
