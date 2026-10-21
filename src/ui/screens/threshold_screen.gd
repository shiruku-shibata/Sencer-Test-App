class_name ThresholdScreen
extends VBoxContainer
## S4 しきい値測定画面。静止中のノイズと動作時のピークを測り、推奨しきい値を出し、
## 判定テストで確かめ、プロファイル（JSON）として保存・共有する。
##
## 画面構成:
##   上部 … 対象デバイス・平滑化・軸選択（AxisSelector）
##   左   … 選択軸ごとの波形（しきい値線ドラッグ・判定マーカー・ノイズ帯）
##   右   … ①静止測定 ②動作測定 ③推奨しきい値 ④判定テスト ⑤保存と共有 ⑥ログで判定テスト（スクロール）
##
## 表示モード:
##   ライブ … 受信中のデータを直近 WINDOW_SEC 秒ぶん流す（通常）
##   ログ   … ⑥で選んだ CSV（LogReplay）の全体を描き、別の ThresholdDetector に流した判定位置を打つ。
##            しきい値を動かすたびに判定し直すので、実機なしでしきい値を詰められる。
##            波形を横にドラッグして範囲を選び、静止測定・試行として ThresholdAnalyzer に取り込める。
##
## 役割分担:
##   - 測定・推奨値の計算は ThresholdAnalyzer、判定は ThresholdDetector に任せる（画面側で独自判定しない）。
##   - 波形表示にも AxisFilter で同じ平滑化をかけ、線と波形と判定が一致するようにする。
##   - 編集中のしきい値は _rules（axis -> ThresholdRule）が正。SpinBox・波形の線・Detector はここから作る。
##     Detector は configure() で渡した ThresholdRule を参照し続けるので、値の編集はその場で反映される
##     （configure() は判定回数もリセットするため、値の編集のたびには呼ばない）。

const SETTINGS_KEY := "threshold"
const DEFAULT_AXES: Array[int] = [SensorAxis.Id.ACCEL_MAG]
const SMOOTHING_OPTIONS: Array[int] = [1, 3, 5, 10]
const BASELINE_OPTIONS: Array[int] = [3, 5, 10]
const RECOMMENDED_TRIALS := 5
const WINDOW_SEC := 5.0
const RING_CAPACITY := 4000
const FALLBACK_RATE_HZ := 100.0
const MAX_MARKERS := 200
const RIGHT_PANEL_WIDTH := 440
const PLOT_MIN_HEIGHT := 90
const PANEL_FONT_SIZE := 14
const LAMP_HOLD_MS := 250
const LOG_DETECT_INTERVAL_MS := 80             ## ログ判定のやり直しの最短間隔（ドラッグ中に毎フレーム走らせない）
const LOG_MAX_LISTED_FIRES := 20               ## ⑥に並べる判定位置の最大数
const LOG_BASELINE_FOREVER_MS := 1 << 30       ## 取り込み時の静止測定は stop() で締めるので、時間では終わらせない
const DEMO_QUIET_MARGIN_MS := 500              ## デモ: 静止測定の時間よりこれだけ長く振らないでもらう
const DEMO_TRIAL_GESTURE_DELAY_MS := 400       ## デモ: 試行を始めてから振るまでの時間

const COLOR_THRESHOLD := Color("ff6b6b")
const COLOR_THRESHOLD_OFF := Color(1.0, 0.42, 0.42, 0.35)
const COLOR_RELEASE := Color(1.0, 0.42, 0.42, 0.45)
const COLOR_SUGGEST := Color("f2d16b")
const COLOR_MARKER := Color(1.0, 0.42, 0.42, 0.9)
const COLOR_BASELINE_SPAN := Color(0.45, 0.65, 1.0, 0.12)
const COLOR_TRIAL_SPAN := Color(1.0, 0.82, 0.35, 0.12)
const COLOR_LAMP_ON := Color("ffcc33")
const COLOR_LAMP_OFF := Color(0.18, 0.2, 0.22)
const COLOR_DIM := Color(1, 1, 1, 0.6)
const QUALITY_COLORS := {
	"good": Color("5cc77a"),
	"tight": Color("e8c547"),
	"overlap": Color("e85d5d"),
	"insufficient": Color(0.6, 0.6, 0.6),
}

var _manager: SensorManager
var _analyzer := ThresholdAnalyzer.new()
var _detector := ThresholdDetector.new()
var _filter := AxisFilter.new(1)               ## 波形表示用（Analyzer/Detector と同じ窓幅）

# ---- 状態
var _selected_id := ""
var _lost_device_id := ""                      ## 測定中・測定済みのまま切断されたデバイス（戻ってきたら選び直す）
var _axes: Array[int] = []
var _smoothing: int = 1
var _smoothing_values: Array[int] = []         ## 平滑化セレクタの各項目の値
var _rules: Dictionary = {}                    ## axis -> ThresholdRule（編集中のしきい値）
var _directions: Dictionary = {}               ## axis -> 推奨値計算に使う向き
var _direction_manual: Dictionary = {}         ## axis -> true ならユーザーが向きを選んだ（自動推定で上書きしない）
var _ratio := 0.5
var _combine: int = ThresholdDetector.Combine.ANY
var _rings: Dictionary = {}                    ## axis -> SampleRing（平滑化後の値）
var _sample_total := 0                         ## デバイス選択後に受け取ったサンプル数（マーカー位置の基準）
var _markers: Array[int] = []                  ## 判定したサンプル番号
var _spans: Array = []                         ## [{start, end(-1=継続中), color}] 静止測定・試行の区間
var _last_fire_tick := -100000
var _lamp_lit := false
var _confirm_ok := Callable()
var _confirm_cancel := Callable()

# ---- ⑥ ログで判定テスト
var _logger: LoggingService
var _log_detector := ThresholdDetector.new()   ## ログ専用（ライブの判定状態・回数を乱さない）
var _log_mode := false
var _log_path := ""
var _log_readings: Array[SensorReading] = []
var _log_columns: Array[int] = []              ## CSV にある軸（LogReplay.axes_in）
var _log_markers: Array[int] = []              ## 判定したサンプル番号
var _log_selection := Vector2(-1.0, -1.0)      ## 選択範囲（比率）。x < 0 なら選択なし（= ログ全体）
var _log_series_dirty := false
var _log_detect_dirty := false
var _log_last_detect_tick := 0
var _importing := false                        ## ログ取り込み中（区間の塗りを作らない）

# ---- UI（全体）
var _device_selector: OptionButton
var _smoothing_selector: OptionButton
var _axis_selector: AxisSelector
var _message: Label
var _hint: Label
var _plots_box: VBoxContainer
var _confirm: ConfirmationDialog

# ---- UI（軸ごと）
var _plot_views: Dictionary = {}               ## axis -> WaveformView
var _plot_values: Dictionary = {}              ## axis -> Label（現在値）
var _plot_states: Dictionary = {}              ## axis -> Label（判定中表示）
var _rec_rows: Dictionary = {}                 ## axis -> {direction, noise, weakest, recommended, quality, desc}
var _rule_rows: Dictionary = {}                ## axis -> {enabled, direction, threshold, hysteresis, refractory, lamp}

# ---- UI（①〜⑤）
var _baseline_seconds: OptionButton
var _baseline_button: Button
var _baseline_cancel_button: Button
var _trial_cancel_button: Button
var _baseline_progress: ProgressBar
var _baseline_grid: GridContainer
var _baseline_empty: Label
var _trial_button: Button
var _trial_count: Label
var _trial_grid: GridContainer
var _trial_empty: Label
var _trial_clear_button: Button
var _ratio_slider: HSlider
var _ratio_label: Label
var _rec_box: VBoxContainer
var _apply_button: Button
var _rule_box: VBoxContainer
var _combine_selector: OptionButton
var _lamp: PanelContainer
var _lamp_style: StyleBoxFlat
var _lamp_label: Label
var _count_label: Label
var _profile_name: LineEdit
var _profile_note: LineEdit
var _profile_list: OptionButton
var _code_lang: OptionButton
var _log_banner: PanelContainer
var _log_banner_label: Label
var _log_list: OptionButton
var _log_open_button: Button
var _log_info: Label
var _log_warning: Label
var _log_count: Label
var _log_times: Label
var _log_import_baseline: Button
var _log_import_trial: Button


## logger は ⑥ のログ一覧に使う（省略時は ⑥ の一覧が空になる）。
func setup(manager: SensorManager, logger: LoggingService = null) -> void:
	_manager = manager
	_logger = logger
	_smoothing_values = SMOOTHING_OPTIONS.duplicate()
	_build()

	_manager.reading_received.connect(_on_reading_received)
	_manager.devices_changed.connect(_refresh_device_list)
	_analyzer.phase_changed.connect(_on_phase_changed)
	_analyzer.baseline_finished.connect(_on_baseline_finished)
	_analyzer.trial_finished.connect(_on_trial_finished)
	_analyzer.trial_discarded.connect(func() -> void: _show_message(UIStrings.TH_MSG_TRIAL_DISCARDED))
	_analyzer.phase_interrupted.connect(_on_phase_interrupted)
	_detector.fired.connect(_on_detector_fired)

	if _logger != null:
		_logger.recording_stopped.connect(func(_info: Dictionary) -> void: _refresh_log_list())

	_apply_axes(_axis_selector.get_axes())
	_refresh_device_list()
	_refresh_profile_list()
	_refresh_log_list()


## ステータスバー用の短い表示（判定回数）。デバイス未選択なら空文字。
func status_text() -> String:
	if _selected_id.is_empty():
		return ""
	return UIStrings.TH_STATUS_COUNT % _detector.trigger_count


# ================================================================ UI構築

func _build() -> void:
	add_theme_constant_override("separation", 8)
	add_child(_build_top_bar())

	_hint = Label.new()
	_hint.text = UIStrings.HINT_NO_DEVICE
	_hint.modulate = Color(1.0, 0.75, 0.55)
	add_child(_hint)

	add_child(_build_log_banner())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)

	var plots_scroll := ScrollContainer.new()
	plots_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plots_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_plots_box = VBoxContainer.new()
	_plots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plots_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_plots_box.add_theme_constant_override("separation", 8)
	plots_scroll.add_child(_plots_box)
	body.add_child(plots_scroll)

	body.add_child(_build_side_panel())
	add_child(body)

	_confirm = ConfirmationDialog.new()
	_confirm.title = UIStrings.TH_CONFIRM_TITLE
	_confirm.ok_button_text = UIStrings.BTN_OK
	_confirm.cancel_button_text = UIStrings.BTN_CANCEL
	_confirm.dialog_autowrap = true
	_confirm.min_size = Vector2i(420, 0)
	_confirm.confirmed.connect(_on_confirm_result.bind(true))
	_confirm.canceled.connect(_on_confirm_result.bind(false))
	add_child(_confirm)


func _build_top_bar() -> VBoxContainer:
	var top := VBoxContainer.new()
	top.add_theme_constant_override("separation", 6)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_make_label(UIStrings.LABEL_TARGET_DEVICE))
	_device_selector = OptionButton.new()
	_device_selector.custom_minimum_size.x = 200
	_device_selector.focus_mode = Control.FOCUS_NONE
	_device_selector.item_selected.connect(_on_device_selected)
	row.add_child(_device_selector)

	var smoothing_label := _make_label(UIStrings.LABEL_SMOOTHING)
	smoothing_label.tooltip_text = UIStrings.TH_SMOOTHING_TOOLTIP
	smoothing_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(smoothing_label)
	_smoothing_selector = OptionButton.new()
	_smoothing_selector.tooltip_text = UIStrings.TH_SMOOTHING_TOOLTIP
	_smoothing_selector.focus_mode = Control.FOCUS_NONE
	for value in _smoothing_values:
		_smoothing_selector.add_item(_smoothing_text(value))
	_smoothing_selector.select(_smoothing_values.find(_smoothing))
	_smoothing_selector.item_selected.connect(_on_smoothing_selected)
	row.add_child(_smoothing_selector)

	_message = Label.new()
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_message.modulate = Color(0.75, 0.9, 1.0)
	row.add_child(_message)
	top.add_child(row)

	var axis_row := HBoxContainer.new()
	axis_row.add_theme_constant_override("separation", 10)
	axis_row.add_child(_make_label(UIStrings.LABEL_AXES))
	_axis_selector = AxisSelector.new()
	_axis_selector.setup(SETTINGS_KEY, DEFAULT_AXES)
	_axis_selector.axes_changed.connect(_on_axes_requested)
	axis_row.add_child(_axis_selector)
	top.add_child(axis_row)
	return top


## ログ表示中だけ出す帯（何を表示しているか・ライブに戻るボタン）。
func _build_log_banner() -> PanelContainer:
	_log_banner = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.55, 0.85, 1.0, 0.12)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_log_banner.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_log_banner_label = Label.new()
	_log_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_banner_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_log_banner_label)
	row.add_child(_make_button(UIStrings.TH_LOG_BACK_TO_LIVE, func() -> void: _set_log_mode(false)))
	_log_banner.add_child(row)
	_log_banner.visible = false
	return _log_banner


func _build_side_panel() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = RIGHT_PANEL_WIDTH
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var panel_theme := Theme.new()
	panel_theme.default_font_size = PANEL_FONT_SIZE
	scroll.theme = panel_theme

	var steps := VBoxContainer.new()
	steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps.add_theme_constant_override("separation", 10)
	steps.add_child(_build_step1())
	steps.add_child(_build_step2())
	steps.add_child(_build_step3())
	steps.add_child(_build_step4())
	steps.add_child(_build_step5())
	steps.add_child(_build_step6())
	scroll.add_child(steps)
	return scroll


## ステップ1つぶんの枠（タイトル＋説明）。中身を足す VBox を返す。
func _make_step(title: String, description: String) -> Array:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.04)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + 3)
	box.add_child(title_label)
	if not description.is_empty():
		box.add_child(_make_note(description))
	panel.add_child(box)
	return [panel, box]


func _build_step1() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP1_TITLE, UIStrings.TH_STEP1_DESC)
	var box: VBoxContainer = step[1]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_make_label(UIStrings.TH_BASELINE_SECONDS))
	_baseline_seconds = OptionButton.new()
	_baseline_seconds.focus_mode = Control.FOCUS_NONE
	for sec in BASELINE_OPTIONS:
		_baseline_seconds.add_item(UIStrings.TH_SECONDS % sec)
	_baseline_seconds.select(0)
	row.add_child(_baseline_seconds)
	_baseline_button = Button.new()
	_baseline_button.text = UIStrings.TH_BASELINE_START
	_baseline_button.focus_mode = Control.FOCUS_NONE
	_baseline_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_baseline_button.pressed.connect(_on_baseline_pressed)
	row.add_child(_baseline_button)
	_baseline_cancel_button = _make_button(UIStrings.TH_PHASE_CANCEL, _on_cancel_phase_pressed)
	_baseline_cancel_button.tooltip_text = UIStrings.TH_PHASE_CANCEL_TOOLTIP
	row.add_child(_baseline_cancel_button)
	box.add_child(row)

	_baseline_progress = ProgressBar.new()
	_baseline_progress.min_value = 0.0
	_baseline_progress.max_value = 100.0
	_baseline_progress.show_percentage = false
	_baseline_progress.custom_minimum_size.y = 8
	box.add_child(_baseline_progress)

	_baseline_empty = _make_note(UIStrings.TH_BASELINE_EMPTY)
	box.add_child(_baseline_empty)
	_baseline_grid = GridContainer.new()
	_baseline_grid.columns = 4
	_baseline_grid.add_theme_constant_override("h_separation", 14)
	_baseline_grid.add_theme_constant_override("v_separation", 2)
	box.add_child(_baseline_grid)
	return step[0]


func _build_step2() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP2_TITLE, UIStrings.TH_STEP2_DESC)
	var box: VBoxContainer = step[1]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_trial_button = Button.new()
	_trial_button.text = UIStrings.TH_TRIAL_START
	_trial_button.focus_mode = Control.FOCUS_NONE
	_trial_button.custom_minimum_size.x = 170
	_trial_button.pressed.connect(_toggle_trial)
	row.add_child(_trial_button)
	_trial_cancel_button = _make_button(UIStrings.TH_PHASE_CANCEL, _on_cancel_phase_pressed)
	_trial_cancel_button.tooltip_text = UIStrings.TH_PHASE_CANCEL_TOOLTIP
	row.add_child(_trial_cancel_button)
	_trial_count = _make_label("")
	_trial_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_trial_count)
	box.add_child(row)

	_trial_empty = _make_note(UIStrings.TH_TRIAL_EMPTY)
	box.add_child(_trial_empty)
	_trial_grid = GridContainer.new()
	_trial_grid.add_theme_constant_override("h_separation", 10)
	_trial_grid.add_theme_constant_override("v_separation", 2)
	box.add_child(_trial_grid)

	var bottom := HBoxContainer.new()
	var note := _make_note(UIStrings.TH_TRIAL_PEAK_NOTE)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(note)
	_trial_clear_button = Button.new()
	_trial_clear_button.text = UIStrings.TH_TRIAL_CLEAR
	_trial_clear_button.focus_mode = Control.FOCUS_NONE
	_trial_clear_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_trial_clear_button.pressed.connect(func() -> void:
		_analyzer.clear_trials()
		_refresh_measurement()
	)
	bottom.add_child(_trial_clear_button)
	box.add_child(bottom)
	return step[0]


func _build_step3() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP3_TITLE, UIStrings.TH_STEP3_DESC)
	var box: VBoxContainer = step[1]

	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 6)
	slider_row.tooltip_text = UIStrings.TH_RATIO_TOOLTIP
	slider_row.add_child(_make_label(UIStrings.TH_RATIO_EASY))
	_ratio_slider = HSlider.new()
	_ratio_slider.min_value = 0.0
	_ratio_slider.max_value = 1.0
	_ratio_slider.step = 0.05
	_ratio_slider.value = _ratio
	_ratio_slider.focus_mode = Control.FOCUS_NONE
	_ratio_slider.tooltip_text = UIStrings.TH_RATIO_TOOLTIP
	_ratio_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ratio_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_ratio_slider.value_changed.connect(func(value: float) -> void:
		_ratio = value
		_refresh_recommendations()
	)
	slider_row.add_child(_ratio_slider)
	slider_row.add_child(_make_label(UIStrings.TH_RATIO_STRICT))
	box.add_child(slider_row)

	_ratio_label = _make_note("")
	_ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_ratio_label)

	_rec_box = VBoxContainer.new()
	_rec_box.add_theme_constant_override("separation", 8)
	box.add_child(_rec_box)

	_apply_button = Button.new()
	_apply_button.text = UIStrings.TH_APPLY
	_apply_button.focus_mode = Control.FOCUS_NONE
	_apply_button.pressed.connect(_apply_recommendation)
	box.add_child(_apply_button)
	return step[0]


func _build_step4() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP4_TITLE, UIStrings.TH_STEP4_DESC)
	var box: VBoxContainer = step[1]

	var combine_row := HBoxContainer.new()
	combine_row.add_theme_constant_override("separation", 8)
	combine_row.add_child(_make_label(UIStrings.TH_COMBINE))
	_combine_selector = OptionButton.new()
	_combine_selector.focus_mode = Control.FOCUS_NONE
	_combine_selector.add_item(UIStrings.TH_COMBINE_ANY, ThresholdDetector.Combine.ANY)
	_combine_selector.add_item(UIStrings.TH_COMBINE_ALL, ThresholdDetector.Combine.ALL)
	_combine_selector.select(_combine_selector.get_item_index(_combine))
	_combine_selector.item_selected.connect(func(index: int) -> void:
		_combine = _combine_selector.get_item_id(index)
		# 判定条件そのものが変わるので、ラッチ状態を持ち越さない（ALL→ANY で偽の立ち上がりが出るのを防ぐ）。
		# ルールは差し替えないので configure() ではなく reset()。判定回数とマーカーも 0 からにする。
		_detector.combine = _combine
		_detector.reset()
		_markers.clear()
		_log_detect_dirty = _log_mode
	)
	combine_row.add_child(_combine_selector)
	box.add_child(combine_row)

	_rule_box = VBoxContainer.new()
	_rule_box.add_theme_constant_override("separation", 8)
	box.add_child(_rule_box)

	# 判定ランプ・回数・リセット
	var lamp_row := HBoxContainer.new()
	lamp_row.add_theme_constant_override("separation", 12)
	_lamp = PanelContainer.new()
	_lamp.custom_minimum_size = Vector2(110, 44)
	_lamp_style = StyleBoxFlat.new()
	_lamp_style.bg_color = COLOR_LAMP_OFF
	_lamp_style.set_corner_radius_all(22)
	_lamp.add_theme_stylebox_override("panel", _lamp_style)
	_lamp_label = Label.new()
	_lamp_label.text = UIStrings.TH_LAMP
	_lamp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lamp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_lamp_label.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + 4)
	_lamp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_lamp.add_child(_lamp_label)
	lamp_row.add_child(_lamp)

	_count_label = _make_label(UIStrings.TH_TRIGGER_COUNT % 0)
	_count_label.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + 4)
	_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lamp_row.add_child(_count_label)

	var reset_button := Button.new()
	reset_button.text = UIStrings.TH_RESET
	reset_button.focus_mode = Control.FOCUS_NONE
	reset_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset_button.pressed.connect(func() -> void:
		_detector.reset()
		_markers.clear()
	)
	lamp_row.add_child(reset_button)
	box.add_child(lamp_row)
	return step[0]


func _build_step5() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP5_TITLE, "")
	var box: VBoxContainer = step[1]

	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 8)
	form.add_child(_make_label(UIStrings.TH_PROFILE_NAME))
	_profile_name = LineEdit.new()
	_profile_name.placeholder_text = UIStrings.TH_PROFILE_NAME_PLACEHOLDER
	_profile_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_profile_name)
	form.add_child(_make_label(UIStrings.TH_PROFILE_NOTE))
	_profile_note = LineEdit.new()
	_profile_note.placeholder_text = UIStrings.TH_PROFILE_NOTE_PLACEHOLDER
	_profile_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_profile_note)
	box.add_child(form)

	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 8)
	save_row.add_child(_make_button(UIStrings.TH_SAVE, _on_save_pressed))
	save_row.add_child(_make_button(UIStrings.BTN_OPEN_FOLDER, func() -> void: ThresholdProfile.open_folder()))
	box.add_child(save_row)

	var load_row := HBoxContainer.new()
	load_row.add_theme_constant_override("separation", 8)
	_profile_list = OptionButton.new()
	_profile_list.focus_mode = Control.FOCUS_NONE
	_profile_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_profile_list.clip_text = true
	_profile_list.custom_minimum_size.x = 120
	load_row.add_child(_profile_list)
	load_row.add_child(_make_button(UIStrings.TH_LOAD, _on_load_pressed))
	load_row.add_child(_make_button(UIStrings.BTN_DELETE, _on_delete_pressed))
	var refresh := _make_button("↻", _refresh_profile_list)
	refresh.tooltip_text = UIStrings.BTN_REFRESH
	load_row.add_child(refresh)
	box.add_child(load_row)

	var share_row := HBoxContainer.new()
	share_row.add_theme_constant_override("separation", 8)
	share_row.add_child(_make_button(UIStrings.TH_COPY_JSON, _on_copy_json_pressed))
	share_row.add_child(_make_button(UIStrings.TH_COPY_CODE, _on_copy_code_pressed))
	_code_lang = OptionButton.new()
	_code_lang.focus_mode = Control.FOCUS_NONE
	for entry in UIStrings.TH_CODE_LANGS:
		_code_lang.add_item(entry[0])
	_code_lang.select(0)
	share_row.add_child(_code_lang)
	box.add_child(share_row)
	return step[0]


func _build_step6() -> PanelContainer:
	var step := _make_step(UIStrings.TH_STEP6_TITLE, UIStrings.TH_STEP6_DESC)
	var box: VBoxContainer = step[1]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_log_list = OptionButton.new()
	_log_list.focus_mode = Control.FOCUS_NONE
	_log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_list.clip_text = true
	_log_list.custom_minimum_size.x = 120
	row.add_child(_log_list)
	_log_open_button = _make_button(UIStrings.TH_LOG_OPEN, _on_log_open_pressed)
	row.add_child(_log_open_button)
	var refresh := _make_button("↻", _refresh_log_list)
	refresh.tooltip_text = UIStrings.BTN_REFRESH
	row.add_child(refresh)
	box.add_child(row)

	_log_info = _make_note("")
	box.add_child(_log_info)
	_log_warning = _make_note("")
	_log_warning.modulate = Color(1.0, 0.75, 0.55)
	box.add_child(_log_warning)

	_log_count = _make_label("")
	_log_count.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + 4)
	box.add_child(_log_count)
	_log_times = _make_note("")
	box.add_child(_log_times)

	box.add_child(HSeparator.new())
	box.add_child(_make_note(UIStrings.TH_LOG_IMPORT_HINT))
	var import_row := HBoxContainer.new()
	import_row.add_theme_constant_override("separation", 8)
	_log_import_baseline = _make_button(UIStrings.TH_LOG_IMPORT_BASELINE, func() -> void: _import_log(true))
	import_row.add_child(_log_import_baseline)
	_log_import_trial = _make_button(UIStrings.TH_LOG_IMPORT_TRIAL, func() -> void: _import_log(false))
	import_row.add_child(_log_import_trial)
	box.add_child(import_row)
	_refresh_log_panel()
	return step[0]


# ---------------------------------------------------------------- 軸ごとのUI（軸が変わるたびに作り直す）

func _rebuild_axis_ui() -> void:
	_rebuild_plots()
	_rebuild_recommend_rows()
	_rebuild_rule_rows()
	_refresh_measurement()


func _rebuild_plots() -> void:
	_clear_children(_plots_box)
	_plot_views.clear()
	_plot_values.clear()
	_plot_states.clear()
	for axis in _axes:
		var block := VBoxContainer.new()
		block.size_flags_vertical = Control.SIZE_EXPAND_FILL
		block.add_theme_constant_override("separation", 2)

		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 10)
		header.add_child(_axis_title(axis, true))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(spacer)
		var state := _make_label("● " + UIStrings.TH_DETECTING)
		state.add_theme_color_override("font_color", COLOR_LAMP_ON)
		state.modulate.a = 0.0
		header.add_child(state)
		var value := _make_label("-")
		value.custom_minimum_size.x = 110
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		header.add_child(value)
		block.add_child(header)

		var view := WaveformView.new()
		view.custom_minimum_size.y = PLOT_MIN_HEIGHT
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		view.value_range = SensorAxis.default_range(axis)
		view.positive_only = SensorAxis.is_magnitude(axis)
		view.auto_range = true
		view.min_auto_range = SensorAxis.default_range(axis) * 0.2
		view.unit_text = SensorAxis.unit(axis)
		view.line_dragged.connect(_on_line_dragged)
		view.selection_changed.connect(_on_log_selection_changed)
		view.selectable = _log_mode
		if _log_mode:
			view.capacity = 0
			view.set_selection(_log_selection.x, _log_selection.y)
		block.add_child(view)

		_plots_box.add_child(block)
		_plot_views[axis] = view
		_plot_values[axis] = value
		_plot_states[axis] = state
	if _log_mode:
		_log_series_dirty = true
		_log_detect_dirty = true
	_update_all_lines()


func _rebuild_recommend_rows() -> void:
	_clear_children(_rec_box)
	_rec_rows.clear()
	for axis in _axes:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 3)

		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 6)
		var title := _axis_title(axis, false)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		header.add_child(_make_label(UIStrings.TH_DIRECTION))
		var direction := _make_direction_selector(int(_directions.get(axis, _default_direction(axis))))
		direction.item_selected.connect(func(index: int) -> void:
			_directions[axis] = direction.get_item_id(index)
			_direction_manual[axis] = true
			_refresh_measurement()
		)
		header.add_child(direction)
		row.add_child(header)

		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 18)
		grid.add_theme_constant_override("v_separation", 0)
		for caption in [UIStrings.TH_NOISE_LEVEL, UIStrings.TH_WEAKEST_PEAK, UIStrings.TH_RECOMMENDED]:
			var label := _make_label(caption)
			label.modulate = COLOR_DIM
			grid.add_child(label)
		var noise := _make_label("-")
		var weakest := _make_label("-")
		var recommended := _make_label("-")
		recommended.add_theme_color_override("font_color", COLOR_SUGGEST)
		grid.add_child(noise)
		grid.add_child(weakest)
		grid.add_child(recommended)
		row.add_child(grid)

		var quality := _make_label("")
		row.add_child(quality)
		var desc := _make_note("")
		row.add_child(desc)

		if axis != _axes[_axes.size() - 1]:
			row.add_child(HSeparator.new())
		_rec_box.add_child(row)
		_rec_rows[axis] = {
			"direction": direction, "noise": noise, "weakest": weakest,
			"recommended": recommended, "quality": quality, "desc": desc,
		}


func _rebuild_rule_rows() -> void:
	_clear_children(_rule_box)
	_rule_rows.clear()
	for axis in _axes:
		var rule: ThresholdRule = _rules[axis]
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 3)

		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 6)
		var enabled := CheckBox.new()
		enabled.text = UIStrings.TH_ENABLED
		enabled.focus_mode = Control.FOCUS_NONE
		enabled.button_pressed = rule.enabled
		enabled.toggled.connect(func(pressed: bool) -> void:
			rule.enabled = pressed
			_update_lines(axis)
		)
		header.add_child(enabled)
		var title := _axis_title(axis, false)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		var lamp := _make_label("●")
		lamp.add_theme_color_override("font_color", COLOR_LAMP_ON)
		lamp.modulate.a = 0.15
		header.add_child(lamp)
		header.add_child(_make_label(UIStrings.TH_DIRECTION))
		var direction := _make_direction_selector(rule.direction)
		header.add_child(direction)
		row.add_child(header)

		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 3)
		var step := _value_step(axis)
		var span := SensorAxis.default_range(axis) * 4.0

		grid.add_child(_make_label(UIStrings.TH_THRESHOLD))
		var threshold := _make_spin(-span, span, step, SensorAxis.unit(axis))
		threshold.value = rule.threshold
		threshold.value_changed.connect(func(value: float) -> void:
			rule.threshold = value
			_update_lines(axis)
		)
		grid.add_child(threshold)

		var hysteresis_label := _make_label(UIStrings.TH_HYSTERESIS)
		hysteresis_label.tooltip_text = UIStrings.TH_HYSTERESIS_TOOLTIP
		hysteresis_label.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(hysteresis_label)
		var hysteresis := _make_spin(0.0, span, step, "")
		hysteresis.tooltip_text = UIStrings.TH_HYSTERESIS_TOOLTIP
		hysteresis.value = rule.hysteresis
		hysteresis.value_changed.connect(func(value: float) -> void:
			rule.hysteresis = value
			_update_lines(axis)
		)
		grid.add_child(hysteresis)

		var refractory_label := _make_label(UIStrings.TH_REFRACTORY)
		refractory_label.tooltip_text = UIStrings.TH_REFRACTORY_TOOLTIP
		refractory_label.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(refractory_label)
		var refractory := _make_spin(0.0, 5000.0, 10.0, "ms")
		refractory.tooltip_text = UIStrings.TH_REFRACTORY_TOOLTIP
		refractory.value = rule.refractory_ms
		refractory.value_changed.connect(func(value: float) -> void:
			rule.refractory_ms = int(value)
		)
		grid.add_child(refractory)
		row.add_child(grid)

		direction.item_selected.connect(func(index: int) -> void:
			_set_rule_direction(axis, direction.get_item_id(index))
		)
		_apply_threshold_limits(threshold, rule.direction)

		if axis != _axes[_axes.size() - 1]:
			row.add_child(HSeparator.new())
		_rule_box.add_child(row)
		_rule_rows[axis] = {
			"enabled": enabled, "direction": direction, "threshold": threshold,
			"hysteresis": hysteresis, "refractory": refractory, "lamp": lamp,
		}


## _rules の内容を④の入力欄へ反映する（シグナルは出さない）。
func _sync_rule_controls(axis: int) -> void:
	var row: Dictionary = _rule_rows.get(axis, {})
	if row.is_empty():
		return
	var rule: ThresholdRule = _rules[axis]
	row["enabled"].set_pressed_no_signal(rule.enabled)
	var direction: OptionButton = row["direction"]
	direction.select(direction.get_item_index(rule.direction))
	# 下限を変えると SpinBox が古い値を丸めて value_changed を出し、ルールを書き戻してしまう。
	# 先に新しい値を入れてから下限を変える（新しい値は新しい範囲に収まっているので丸められない）。
	var threshold: SpinBox = row["threshold"]
	threshold.min_value = -threshold.max_value
	threshold.set_value_no_signal(rule.threshold)
	_apply_threshold_limits(threshold, rule.direction)
	threshold.set_value_no_signal(rule.threshold)
	row["hysteresis"].set_value_no_signal(rule.hysteresis)
	row["refractory"].set_value_no_signal(rule.refractory_ms)


## 絶対値ではしきい値は正の大きさなので、負の値を入力できないようにする。
func _apply_threshold_limits(spin: SpinBox, direction: int) -> void:
	var absolute := direction == ThresholdRule.Direction.ABSOLUTE
	spin.min_value = 0.0 if absolute else -spin.max_value
	spin.allow_lesser = not absolute


# ---------------------------------------------------------------- 小さな部品

func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _make_note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = COLOR_DIM
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", PANEL_FONT_SIZE - 1)
	return label


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	return button


func _make_spin(min_value: float, max_value: float, step: float, suffix: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.allow_greater = true
	spin.allow_lesser = min_value < 0.0
	spin.suffix = suffix
	spin.custom_minimum_size.x = 118
	spin.select_all_on_focus = true
	return spin


func _make_direction_selector(selected: int) -> OptionButton:
	var selector := OptionButton.new()
	selector.focus_mode = Control.FOCUS_NONE
	for direction in [ThresholdRule.Direction.POSITIVE, ThresholdRule.Direction.NEGATIVE,
			ThresholdRule.Direction.ABSOLUTE]:
		selector.add_item(ThresholdRule.direction_label(direction), direction)
	selector.select(selector.get_item_index(selected))
	return selector


## 軸の色の印＋軸名。with_unit なら単位も付ける。
func _axis_title(axis: int, with_unit: bool) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var swatch := ColorRect.new()
	swatch.color = SensorAxis.color(axis)
	swatch.custom_minimum_size = Vector2(10, 10)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(swatch)
	var text := SensorAxis.label(axis)
	if with_unit:
		text += " [%s]" % SensorAxis.unit(axis)
	box.add_child(_make_label(text))
	return box


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


static func _smoothing_text(value: int) -> String:
	return UIStrings.SMOOTHING_NONE if value <= 1 else UIStrings.SMOOTHING_SAMPLES % value


static func _value_step(axis: int) -> float:
	return 0.01 if SensorAxis.is_accel(axis) else 0.1


static func _fmt(axis: int, value: float, with_unit: bool = false) -> String:
	var text := ("%.2f" if SensorAxis.is_accel(axis) else "%.1f") % value
	return "%s %s" % [text, SensorAxis.unit(axis)] if with_unit else text


static func _default_direction(axis: int) -> int:
	return ThresholdRule.Direction.POSITIVE if SensorAxis.is_magnitude(axis) else ThresholdRule.Direction.ABSOLUTE


## 測定前の初期しきい値（目安）。合成値は＋方向、それ以外は絶対値。
static func _default_rule(axis: int) -> ThresholdRule:
	var rule := ThresholdRule.new()
	rule.axis = axis
	rule.enabled = true
	rule.direction = _default_direction(axis)
	rule.threshold = SensorAxis.default_range(axis) * 0.6
	rule.hysteresis = SensorAxis.default_range(axis) * 0.04
	rule.refractory_ms = 200
	return rule


# ================================================================ 軸・平滑化・デバイスの変更

func _on_axes_requested(axes: Array) -> void:
	if _has_measurement():
		_ask(UIStrings.TH_CONFIRM_AXES,
				func() -> void: _apply_axes(axes),
				func() -> void: _axis_selector.set_axes(_axes))
	else:
		_apply_axes(axes)


## 軸を確定する。測定結果・表示バッファ・判定状態はすべて作り直す。
func _apply_axes(axes: Array) -> void:
	_cancel_phase()
	_axes.clear()
	for axis in axes:
		_axes.append(int(axis))

	var kept_rules: Dictionary = {}
	for axis in _axes:
		kept_rules[axis] = _rules[axis] if _rules.has(axis) else _default_rule(axis)
		if not _directions.has(axis):
			_directions[axis] = _default_direction(axis)
	_rules = kept_rules

	_analyzer.smoothing_window = _smoothing
	_analyzer.set_axes(_axes)
	_reset_stream()
	_rebuild_axis_ui()
	_configure_detector()


func _on_smoothing_selected(index: int) -> void:
	var value: int = _smoothing_values[index]
	if value == _smoothing:
		return
	if _has_measurement():
		_ask(UIStrings.TH_CONFIRM_SMOOTHING,
				func() -> void: _set_smoothing(value),
				func() -> void: _smoothing_selector.select(_smoothing_values.find(_smoothing)))
	else:
		_set_smoothing(value)


## 平滑化を変える。平滑化の違う測定値は比べられないので測定結果は消す。
func _set_smoothing(value: int) -> void:
	if value not in _smoothing_values:
		_smoothing_values.append(value)
		_smoothing_selector.add_item(_smoothing_text(value))
	_smoothing_selector.select(_smoothing_values.find(value))
	_smoothing = value
	_cancel_phase()
	_analyzer.smoothing_window = value
	_analyzer.clear_all()
	_reset_stream()
	_configure_detector()
	_refresh_measurement()
	if _log_mode:
		_log_series_dirty = true
		_log_detect_dirty = true


## 表示バッファ・マーカー・判定状態を空にする（測定結果は残す）。
func _reset_stream() -> void:
	_filter = AxisFilter.new(_smoothing)
	_rings.clear()
	for axis in _axes:
		_rings[axis] = SampleRing.new(RING_CAPACITY)
	_sample_total = 0
	_markers.clear()
	_spans.clear()
	_detector.reset()


## 接続中デバイスの一覧を作り直す。
## 選んでいたデバイスが切断されたとき:
##   - 測定中・測定済みなら、別のデバイスへは自動で切り替えない（2台の測定結果が混ざるのを防ぐ）。
##     進行中の測定は中止し、案内を出して、同じデバイスが戻ってきたら自動で選び直す。
##   - 何も測っていなければ、残っているデバイスを自動で選ぶ。
func _refresh_device_list() -> void:
	if _device_selector == null:
		return
	var preferred := _selected_id if not _selected_id.is_empty() else _lost_device_id
	_device_selector.clear()
	var connected := _manager.registry.connected_devices()
	var index := -1
	for device in connected:
		_device_selector.add_item(device.display_name())
		_device_selector.set_item_metadata(_device_selector.item_count - 1, device.id)
		if device.id == preferred:
			index = _device_selector.item_count - 1

	if index >= 0:
		_device_selector.select(index)
		_lost_device_id = ""
		_set_device(preferred)
		return
	if not preferred.is_empty() and _has_measurement():
		_device_selector.select(-1)
		var lost_name := preferred
		var device := _manager.registry.get_device(preferred)
		if device != null:
			lost_name = device.display_name()
		if not _selected_id.is_empty():
			_show_message(UIStrings.TH_MSG_DEVICE_LOST % lost_name)
		_lost_device_id = preferred
		_set_device("")
		return
	_lost_device_id = ""
	if connected.is_empty():
		_set_device("")
		return
	_device_selector.select(0)
	_set_device(str(_device_selector.get_item_metadata(0)))


func _on_device_selected(index: int) -> void:
	var new_id := str(_device_selector.get_item_metadata(index))
	if new_id == _selected_id:
		return
	var change := func() -> void:
		_lost_device_id = ""
		_set_device(new_id)
		_analyzer.clear_all()
		_refresh_measurement()
	if _has_measurement():
		_ask(UIStrings.TH_CONFIRM_DEVICE, change, func() -> void:
			for i in _device_selector.item_count:
				if str(_device_selector.get_item_metadata(i)) == _selected_id:
					_device_selector.select(i)
		)
	else:
		change.call()


func _set_device(device_id: String) -> void:
	if device_id == _selected_id:
		_update_controls()
		return
	_selected_id = device_id
	# デバイスが切り替わったら（切断を含む）、進行中の測定は結果を残さずに中止する
	# （途中までの値で確定すると、短い静止測定や振り切る前の試行が推奨値を狂わせるため）
	_cancel_phase()
	_reset_stream()
	_update_controls()


# ================================================================ データ処理

func _on_reading_received(reading: SensorReading) -> void:
	if reading.device_id != _selected_id or _axes.is_empty():
		return
	_analyzer.feed(reading)
	_detector.feed(reading)      # 判定したら _on_detector_fired が呼ばれる（_sample_total は更新前）
	for axis in _axes:
		_rings[axis].push(_filter.push(axis, SensorAxis.value_of(reading, axis)))
	_sample_total += 1


func _on_detector_fired(_timestamp_ms: int, _values: Dictionary) -> void:
	_markers.append(_sample_total)
	if _markers.size() > MAX_MARKERS:
		_markers.remove_at(0)
	_last_fire_tick = Time.get_ticks_msec()


func _on_phase_changed(phase: int) -> void:
	if _importing:
		_update_controls()
		return
	match phase:
		ThresholdAnalyzer.Phase.BASELINE:
			_spans.append({"start": _sample_total, "end": -1, "color": COLOR_BASELINE_SPAN})
		ThresholdAnalyzer.Phase.TRIAL:
			_spans.append({"start": _sample_total, "end": -1, "color": COLOR_TRIAL_SPAN})
		_:
			if not _spans.is_empty() and int(_spans[-1]["end"]) < 0:
				_spans[-1]["end"] = _sample_total
	_update_controls()


func _on_baseline_finished(_stats: Dictionary) -> void:
	_baseline_progress.value = 100.0
	_refresh_measurement()


func _on_trial_finished(_index: int, _result: Dictionary) -> void:
	_refresh_measurement()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if _log_mode:
		_update_log_views()
	else:
		_update_live_views()

	for axis in _axes:
		var row: Dictionary = _rule_rows.get(axis, {})
		if not row.is_empty():
			row["lamp"].modulate.a = 1.0 if _detector.axis_active(axis) else 0.15

	if _analyzer.phase() == ThresholdAnalyzer.Phase.BASELINE:
		_baseline_progress.value = _analyzer.progress() * 100.0

	_set_lamp(_detector.is_active() or Time.get_ticks_msec() - _last_fire_tick < LAMP_HOLD_MS)
	_count_label.text = UIStrings.TH_TRIGGER_COUNT % _detector.trigger_count


## ライブ表示: 直近 WINDOW_SEC 秒の波形・判定マーカー・測定区間。
func _update_live_views() -> void:
	var visible_count := _visible_count()
	var start_index := _sample_total - visible_count
	var denom := float(maxi(visible_count - 1, 1))

	while not _markers.is_empty() and _markers[0] < start_index:
		_markers.remove_at(0)
	var markers: Array = []
	for index in _markers:
		markers.append({"x": float(index - start_index) / denom, "color": COLOR_MARKER})

	var spans: Array = []
	for span in _spans:
		var end := int(span["end"]) if int(span["end"]) >= 0 else _sample_total
		if end < start_index:
			continue
		spans.append({"x0": float(int(span["start"]) - start_index) / denom,
				"x1": float(end - start_index) / denom, "color": span["color"]})

	for axis in _axes:
		var view: WaveformView = _plot_views.get(axis)
		if view == null:
			continue
		var ring: SampleRing = _rings[axis]
		view.capacity = visible_count
		view.set_markers(markers)
		view.set_spans(spans)
		view.set_series([{"color": SensorAxis.color(axis), "data": ring.latest(visible_count), "width": 1.6}])
		_plot_values[axis].text = _fmt(axis, ring.last(), true) if not ring.is_empty() else "-"
		_plot_states[axis].modulate.a = 1.0 if _detector.axis_active(axis) else 0.0


## 判定ランプの点灯/消灯（変化したときだけスタイルを触る）。
func _set_lamp(lit: bool) -> void:
	if lit == _lamp_lit:
		return
	_lamp_lit = lit
	_lamp_style.bg_color = COLOR_LAMP_ON if lit else COLOR_LAMP_OFF
	_lamp_label.add_theme_color_override("font_color", Color.BLACK if lit else Color(1, 1, 1, 0.5))


## 波形に表示するサンプル数（WINDOW_SEC 秒ぶん）。受信レートの揺れで幅が変わらないよう10Hz単位に丸める。
func _visible_count() -> int:
	var rate := FALLBACK_RATE_HZ
	var device := _manager.registry.get_device(_selected_id)
	if device != null and device.rate_hz >= 5.0:
		rate = maxf(roundf(device.rate_hz / 10.0) * 10.0, 10.0)
	return clampi(int(WINDOW_SEC * rate), 50, RING_CAPACITY)


# ================================================================ ① 静止測定 / ② 試行

func _on_baseline_pressed() -> void:
	if _selected_id.is_empty() or _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		return
	_baseline_progress.value = 0.0
	var duration_ms: int = BASELINE_OPTIONS[_baseline_seconds.selected] * 1000
	_analyzer.start_baseline(duration_ms)
	var demo := _demo_provider()
	if demo != null:
		demo.hold_still(duration_ms + DEMO_QUIET_MARGIN_MS)   # デモは静止測定の間は振らない


func _toggle_trial() -> void:
	match _analyzer.phase():
		ThresholdAnalyzer.Phase.TRIAL:
			_analyzer.stop()
		ThresholdAnalyzer.Phase.IDLE:
			if not _selected_id.is_empty():
				_analyzer.start_trial(0)
				var demo := _demo_provider()
				if demo != null:
					demo.gesture_soon(DEMO_TRIAL_GESTURE_DELAY_MS)   # デモは試行を始めると少し後に1回振る


## 選んでいるデバイスがデモ（MockSensorProvider）なら、その Provider。違えば null。
## デモの振りを測定の手順に合わせるためだけに使う（実機には関係しない）。
func _demo_provider() -> MockSensorProvider:
	var device := _manager.registry.get_device(_selected_id)
	if device == null or device.mode != SensorDevice.Mode.MOCK:
		return null
	return _manager.get_provider(SensorDevice.Mode.MOCK) as MockSensorProvider


## Space キーで試行の開始/終了。文字入力中（LineEdit・SpinBox）は通常の入力として扱う。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _confirm.visible:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_SPACE:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if _trial_button.disabled:
		return
	_toggle_trial()
	get_viewport().set_input_as_handled()


## 進行中の静止測定・試行を、結果を確定せずに中止する（過去の結果は残る）。
func _cancel_phase() -> void:
	if _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		_analyzer.cancel()


## ①②の「中止」ボタン: 実行中の静止測定・試行を結果を残さずに止める。
func _on_cancel_phase_pressed() -> void:
	var phase := _analyzer.phase()
	if phase == ThresholdAnalyzer.Phase.IDLE:
		return
	_cancel_phase()
	_show_message(UIStrings.TH_MSG_PHASE_CANCELLED % _phase_name(phase))
	_after_phase_aborted(phase)


## 受信が途切れて Analyzer が測定を中止したとき（デバイスの一時停止・電波の途切れなど）。
func _on_phase_interrupted(phase: int, gap_ms: int) -> void:
	_show_message(UIStrings.TH_MSG_PHASE_INTERRUPTED % [_phase_name(phase), gap_ms / 1000.0])
	_after_phase_aborted(phase)


func _after_phase_aborted(phase: int) -> void:
	if phase == ThresholdAnalyzer.Phase.BASELINE:
		_baseline_progress.value = 100.0 if _analyzer.has_baseline() else 0.0
	_refresh_measurement()


static func _phase_name(phase: int) -> String:
	return UIStrings.TH_PHASE_BASELINE if phase == ThresholdAnalyzer.Phase.BASELINE else UIStrings.TH_PHASE_TRIAL


func _has_measurement() -> bool:
	return (not _analyzer.baseline().is_empty() or not _analyzer.trials().is_empty()
			or _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE)


## 測定結果に関わる表示（①②③・ノイズ帯・推奨線）をまとめて更新する。
func _refresh_measurement() -> void:
	# 向きは、ユーザーが選んでいない軸だけ試行結果から推定し直す
	if not _analyzer.trials().is_empty():
		for axis in _axes:
			if not _direction_manual.get(axis, false):
				_directions[axis] = _analyzer.suggest_direction(axis)
	_refresh_baseline_table()
	_refresh_trial_table()
	_refresh_noise_bands()
	_refresh_recommendations()
	_update_controls()


func _refresh_baseline_table() -> void:
	_clear_children(_baseline_grid)
	var stats := _analyzer.baseline()
	_baseline_empty.visible = stats.is_empty()
	_baseline_grid.visible = not stats.is_empty()
	if stats.is_empty():
		if _analyzer.phase() != ThresholdAnalyzer.Phase.BASELINE:
			_baseline_progress.value = 0.0
		return
	for caption in [UIStrings.TH_COL_AXIS, UIStrings.TH_COL_MEAN, UIStrings.TH_COL_STDDEV, UIStrings.TH_COL_RANGE]:
		var label := _make_label(caption)
		label.modulate = COLOR_DIM
		_baseline_grid.add_child(label)
	for axis in _axes:
		if not stats.has(axis):
			continue
		var s: Dictionary = stats[axis]
		var name_label := _make_label(SensorAxis.short_label(axis))
		name_label.add_theme_color_override("font_color", SensorAxis.color(axis))
		_baseline_grid.add_child(name_label)
		_baseline_grid.add_child(_make_label(_fmt(axis, float(s.get("mean", 0.0)))))
		_baseline_grid.add_child(_make_label(_fmt(axis, float(s.get("stddev", 0.0)))))
		_baseline_grid.add_child(_make_label("%s 〜 %s" % [
				_fmt(axis, float(s.get("min", 0.0))), _fmt(axis, float(s.get("max", 0.0)))]))


func _refresh_trial_table() -> void:
	_clear_children(_trial_grid)
	var trials := _analyzer.trials()
	var count := trials.size()
	_trial_count.text = (UIStrings.TH_TRIAL_ENOUGH if count >= RECOMMENDED_TRIALS
			else UIStrings.TH_TRIAL_COUNT) % [count, RECOMMENDED_TRIALS]
	_trial_clear_button.disabled = count == 0
	_trial_empty.visible = count == 0
	_trial_grid.visible = count > 0
	if count == 0:
		return

	_trial_grid.columns = _axes.size() + 2
	var hash_label := _make_label("#")
	hash_label.modulate = COLOR_DIM
	_trial_grid.add_child(hash_label)
	for axis in _axes:
		var header := _make_label(SensorAxis.short_label(axis))
		header.add_theme_color_override("font_color", SensorAxis.color(axis))
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_trial_grid.add_child(header)
	_trial_grid.add_child(Control.new())

	for i in count:
		var trial: Dictionary = trials[i]
		var number := _make_label(str(i + 1))
		number.modulate = COLOR_DIM
		_trial_grid.add_child(number)
		for axis in _axes:
			var text := "-"
			if trial.has(axis):
				text = _fmt(axis, _trial_peak(trial[axis], int(_directions.get(axis, _default_direction(axis)))))
			var value := _make_label(text)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value.custom_minimum_size.x = 44
			_trial_grid.add_child(value)
		var delete := Button.new()
		delete.text = "×"
		delete.flat = true
		delete.focus_mode = Control.FOCUS_NONE
		delete.tooltip_text = UIStrings.TH_TRIAL_DELETE_TOOLTIP
		delete.disabled = _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE
		delete.pressed.connect(func() -> void:
			_analyzer.remove_trial(i)
			_refresh_measurement()
		)
		_trial_grid.add_child(delete)


## 試行結果のうち、向きに応じたピーク値。
static func _trial_peak(result: Dictionary, direction: int) -> float:
	match direction:
		ThresholdRule.Direction.POSITIVE:
			return float(result.get("max", 0.0))
		ThresholdRule.Direction.NEGATIVE:
			return float(result.get("min", 0.0))
	return float(result.get("peak_abs", 0.0))


func _refresh_noise_bands() -> void:
	var stats := _analyzer.baseline()
	for axis in _axes:
		var view: WaveformView = _plot_views.get(axis)
		if view == null:
			continue
		var band: Dictionary = stats.get(axis, {})
		if band.has("min") and band.has("max"):
			view.set_noise_band(float(band["min"]), float(band["max"]))
		else:
			view.clear_noise_band()


# ================================================================ ③ 推奨しきい値

func _refresh_recommendations() -> void:
	_ratio_label.text = UIStrings.TH_RATIO_VALUE % _ratio
	var any_ready := false
	for axis in _axes:
		var row: Dictionary = _rec_rows.get(axis, {})
		if row.is_empty():
			continue
		var direction := int(_directions.get(axis, _default_direction(axis)))
		var selector: OptionButton = row["direction"]
		selector.select(selector.get_item_index(direction))

		var rec := _analyzer.recommend(axis, direction, _ratio)
		var quality := str(rec.get("quality", "insufficient"))
		var has_result := quality != "insufficient"
		any_ready = any_ready or has_result
		row["noise"].text = _fmt(axis, float(rec.get("noise_level", 0.0))) if has_result else "-"
		row["weakest"].text = _fmt(axis, float(rec.get("weakest_peak", 0.0))) if has_result else "-"
		row["recommended"].text = _fmt(axis, float(rec.get("threshold", 0.0)), true) if has_result else "-"
		var quality_label: Label = row["quality"]
		quality_label.text = str(UIStrings.QUALITY_LABELS.get(quality, quality))
		quality_label.add_theme_color_override("font_color", QUALITY_COLORS.get(quality, Color.WHITE))
		row["desc"].text = str(UIStrings.QUALITY_DESCRIPTIONS.get(quality, ""))
	_apply_button.disabled = not any_ready
	_update_all_lines()


## 「推奨値を適用」。品質が「重なり」の軸があれば、静止中でも判定されてしまうので確認してから適用する。
func _apply_recommendation() -> void:
	var overlapped := PackedStringArray()
	for axis in _axes:
		var direction := int(_directions.get(axis, _default_direction(axis)))
		if str(_analyzer.recommend(axis, direction, _ratio).get("quality", "")) == "overlap":
			overlapped.append(SensorAxis.label(axis))
	if overlapped.is_empty():
		_apply_recommendation_now()
	else:
		_ask(UIStrings.TH_CONFIRM_APPLY_OVERLAP % "、".join(overlapped), _apply_recommendation_now)


func _apply_recommendation_now() -> void:
	var applied := 0
	for axis in _axes:
		var direction := int(_directions.get(axis, _default_direction(axis)))
		var rec := _analyzer.recommend(axis, direction, _ratio)
		if str(rec.get("quality", "insufficient")) == "insufficient":
			continue
		var old: ThresholdRule = _rules[axis]
		var rule := _analyzer.build_rule(axis, direction, _ratio)
		rule.axis = axis
		rule.enabled = old.enabled
		rule.refractory_ms = old.refractory_ms
		_rules[axis] = rule
		applied += 1
	if applied == 0:
		_show_message(UIStrings.TH_APPLY_NOTHING)
		return
	# 新しいルールオブジェクトに差し替えたので、入力欄のクロージャも作り直す
	_rebuild_rule_rows()
	_update_all_lines()
	_configure_detector()
	_show_message(UIStrings.TH_APPLIED)


# ================================================================ ④ 判定テスト

func _set_rule_direction(axis: int, direction: int) -> void:
	var rule: ThresholdRule = _rules[axis]
	if rule.direction == direction:
		return
	rule.threshold = _threshold_for_direction(axis, rule, direction)
	rule.direction = direction
	_sync_rule_controls(axis)
	_update_lines(axis)


## 向きを手で切り替えたときの新しいしきい値。
##   1. ③の推奨値（その向き）が使える品質（良好・ぎりぎり）ならそれを使う。
##      「重なり」の推奨値は静止中の揺れの中にあり、常に判定されてしまうので使わない。
##   2. 絶対値へ → 大きさ。絶対値から → ＋方向は +|t|、−方向は −|t|。
##   3. ＋方向 ⇔ −方向 → 静止中の平均を中心に折り返す。重力で静止 +1G の軸
##      （例: aZ の「0.51 を下回ったら落下」）でも、正しい側（平均より下）に来る。静止測定が無ければ 0 を中心にする。
func _threshold_for_direction(axis: int, rule: ThresholdRule, direction: int) -> float:
	var rec := _analyzer.recommend(axis, direction, _ratio)
	if str(rec.get("quality", "")) in ["good", "tight"]:
		return float(rec.get("threshold", rule.threshold))
	var t := rule.threshold
	if direction == ThresholdRule.Direction.ABSOLUTE:
		return absf(t)
	if rule.direction == ThresholdRule.Direction.ABSOLUTE:
		return absf(t) if direction == ThresholdRule.Direction.POSITIVE else -absf(t)
	var center := 0.0
	var stats: Dictionary = _analyzer.baseline().get(axis, {})
	if stats.has("mean"):
		center = float(stats["mean"])
	return 2.0 * center - t


func _on_line_dragged(id: Variant, value: float) -> void:
	var axis := int(id)
	var rule: ThresholdRule = _rules.get(axis)
	if rule == null:
		return
	var threshold := absf(value) if rule.direction == ThresholdRule.Direction.ABSOLUTE else value
	rule.threshold = snappedf(threshold, _value_step(axis))
	var row: Dictionary = _rule_rows.get(axis, {})
	if not row.is_empty():
		row["threshold"].set_value_no_signal(rule.threshold)
	_update_lines(axis)


## Detector を設定し直す（判定状態と判定回数もリセットされる）。
## 軸・平滑化の変更や、ルールのオブジェクトを差し替えたとき（推奨値の適用・読み込み）だけ呼ぶ。
## しきい値などの値の変更は、Detector が同じ ThresholdRule を参照しているので次のサンプルから反映される。
func _configure_detector() -> void:
	var rules: Array = []
	for axis in _axes:
		rules.append(_rules[axis])
	_detector.configure(rules, _combine, _smoothing)
	_markers.clear()   # 判定回数と一緒に、波形上の判定マーカーも消す


func _update_all_lines() -> void:
	for axis in _axes:
		_update_lines(axis)


## 波形に引く線: しきい値（ドラッグ可）・解除ライン（ヒステリシス）・③の推奨値（黄の破線）。
func _update_lines(axis: int) -> void:
	if _log_mode:
		_log_detect_dirty = true   # しきい値が変わった → 次のフレームでログを判定し直す
	var view: WaveformView = _plot_views.get(axis)
	var rule: ThresholdRule = _rules.get(axis)
	if view == null or rule == null:
		return
	var lines: Array = []
	var values := rule.line_values()
	for value in values:
		lines.append({
			"id": axis, "value": value, "draggable": true, "width": 2.0,
			"color": COLOR_THRESHOLD if rule.enabled else COLOR_THRESHOLD_OFF,
			"dashed": not rule.enabled, "label": UIStrings.TH_LINE_LABEL,
		})
	if rule.enabled:
		for release in rule.release_line_values():
			lines.append({"id": "release", "value": release, "color": COLOR_RELEASE, "dashed": true, "width": 1.0})

	var direction := int(_directions.get(axis, _default_direction(axis)))
	var rec := _analyzer.recommend(axis, direction, _ratio)
	if str(rec.get("quality", "insufficient")) != "insufficient":
		var suggested := float(rec.get("threshold", 0.0))
		var suggested_values: Array = [suggested]
		if direction == ThresholdRule.Direction.ABSOLUTE:
			suggested_values = [absf(suggested), -absf(suggested)]
		for value in suggested_values:
			lines.append({"id": "suggest", "value": value, "color": COLOR_SUGGEST, "dashed": true, "width": 1.0})
	view.set_lines(lines)


# ================================================================ ⑤ 保存と共有

func _build_profile() -> ThresholdProfile:
	var profile := ThresholdProfile.new()
	profile.name = _profile_name.text.strip_edges()
	profile.note = _profile_note.text.strip_edges()
	var device := _manager.registry.get_device(_selected_id)
	profile.device_name = device.display_name() if device != null else ""
	profile.sample_rate_hz = device.rate_hz if device != null else 0.0
	for axis in _axes:
		profile.rules.append(_rules[axis])
	profile.combine = _combine
	profile.smoothing_window = _smoothing
	profile.set_measurement_from(_analyzer)
	profile.created_at = Time.get_datetime_string_from_system()
	return profile


func _on_save_pressed() -> void:
	var profile := _build_profile()
	if profile.name.is_empty():
		_show_message(UIStrings.TH_MSG_NAME_REQUIRED)
		_profile_name.grab_focus()
		return
	# 同じ名前のプロファイルがあれば上書きしてよいか確かめる
	# （名前が違ってファイル名だけ重なる場合は、ThresholdProfile が別のファイル名にする）
	if not profile.existing_path().is_empty():
		_ask(UIStrings.TH_CONFIRM_OVERWRITE % profile.name, func() -> void: _save_profile(profile))
	else:
		_save_profile(profile)


func _save_profile(profile: ThresholdProfile) -> void:
	var path := profile.save()
	if path.is_empty():
		_show_message(UIStrings.TH_MSG_SAVE_FAILED)
		return
	_show_message(UIStrings.TH_MSG_SAVED % path)
	_refresh_profile_list(path)


func _refresh_profile_list(select_path: String = "") -> void:
	if _profile_list == null:
		return
	var previous := select_path
	if previous.is_empty() and _profile_list.selected >= 0 and _profile_list.item_count > 0:
		previous = str(_profile_list.get_item_metadata(_profile_list.selected))
	_profile_list.clear()
	var files := ThresholdProfile.list_files()   # 新しい順に並べ済み
	if files.is_empty():
		_profile_list.add_item(UIStrings.TH_PROFILE_EMPTY)
		_profile_list.set_item_metadata(0, "")
		_profile_list.disabled = true
		return
	_profile_list.disabled = false
	for entry in files:
		_profile_list.add_item(str(entry.get("name", "")))
		_profile_list.set_item_metadata(_profile_list.item_count - 1, str(entry.get("path", "")))
		if str(entry.get("path", "")) == previous:
			_profile_list.select(_profile_list.item_count - 1)


func _selected_profile_path() -> String:
	if _profile_list.disabled or _profile_list.selected < 0:
		return ""
	return str(_profile_list.get_item_metadata(_profile_list.selected))


func _on_load_pressed() -> void:
	var path := _selected_profile_path()
	if path.is_empty():
		return
	var profile := ThresholdProfile.load_file(path)
	if profile == null:
		_show_message(UIStrings.TH_MSG_LOAD_FAILED)
		return
	var axes := profile.rule_axes()
	if axes.is_empty():
		_show_message(UIStrings.TH_MSG_LOAD_FAILED)
		return
	var needs_reset := axes != _axes or maxi(profile.smoothing_window, 1) != _smoothing
	# プロファイルに測定結果があれば、今の測定結果はそれに置き換わる
	var replaces_measurement := needs_reset or not profile.measurement_axes().is_empty()
	if replaces_measurement and _has_measurement():
		_ask(UIStrings.TH_CONFIRM_LOAD, func() -> void: _apply_profile(profile, axes, needs_reset))
	else:
		_apply_profile(profile, axes, needs_reset)


func _apply_profile(profile: ThresholdProfile, axes: Array[int], needs_reset: bool) -> void:
	if needs_reset:
		var smoothing := maxi(profile.smoothing_window, 1)
		if smoothing != _smoothing:
			_set_smoothing(smoothing)
		_axis_selector.set_axes(axes)
		_apply_axes(axes)
	# 画面では1軸1ルールなので、同じ軸のルールが複数あれば最初の1つだけ使う
	var used: Array[int] = []
	var skipped := 0
	for rule in profile.rules:
		if rule.axis in _axes and rule.axis not in used:
			_rules[rule.axis] = rule
			used.append(rule.axis)
		else:
			skipped += 1
	_combine = profile.combine
	_combine_selector.select(_combine_selector.get_item_index(_combine))
	_profile_name.text = profile.name
	_profile_note.text = profile.note

	# 保存されていた静止測定・試行を Analyzer に戻す（③の推奨値がそのまま出て、上書き保存しても消えない）。
	# 軸・平滑化はここまでで profile に合わせてあるので、apply_measurement_to が平滑化を変えても同じ値。
	if not profile.measurement_axes().is_empty():
		_cancel_phase()
		profile.apply_measurement_to(_analyzer)

	_rebuild_rule_rows()
	_refresh_measurement()
	_configure_detector()
	var message := UIStrings.TH_MSG_LOADED % profile.name
	if skipped > 0:
		message += UIStrings.TH_MSG_RULES_SKIPPED % skipped
	_show_message(message)


func _on_delete_pressed() -> void:
	var path := _selected_profile_path()
	if path.is_empty():
		return
	var profile_name := _profile_list.get_item_text(_profile_list.selected)
	_ask(UIStrings.TH_CONFIRM_DELETE % profile_name, func() -> void:
		ThresholdProfile.delete_file(path)
		_refresh_profile_list()
		_show_message(UIStrings.TH_MSG_DELETED % profile_name)
	)


func _on_copy_json_pressed() -> void:
	DisplayServer.clipboard_set(_build_profile().to_json())
	_show_message(UIStrings.TH_MSG_JSON_COPIED)


func _on_copy_code_pressed() -> void:
	var entry: Array = UIStrings.TH_CODE_LANGS[_code_lang.selected]
	DisplayServer.clipboard_set(_build_profile().to_code_snippet(entry[1]))
	_show_message(UIStrings.TH_MSG_CODE_COPIED % entry[0])


# ================================================================ ⑥ ログで判定テスト

func _refresh_log_list() -> void:
	if _log_list == null:
		return
	var previous := _selected_log_path()
	_log_list.clear()
	var logs: Array = _logger.list_logs() if _logger != null else []
	if logs.is_empty():
		_log_list.add_item(UIStrings.TH_LOG_EMPTY)
		_log_list.set_item_metadata(0, "")
		_log_list.disabled = true
	else:
		_log_list.disabled = false
		for entry in logs:
			_log_list.add_item(str(entry.get("name", "")))
			_log_list.set_item_metadata(_log_list.item_count - 1, str(entry.get("path", "")))
			if str(entry.get("path", "")) == previous:
				_log_list.select(_log_list.item_count - 1)
	_refresh_log_panel()


func _selected_log_path() -> String:
	if _log_list == null or _log_list.disabled or _log_list.selected < 0 or _log_list.item_count == 0:
		return ""
	return str(_log_list.get_item_metadata(_log_list.selected))


func _on_log_open_pressed() -> void:
	var path := _selected_log_path()
	if not path.is_empty():
		open_log(path)


## CSV ログを読み込んでログ表示にする。読めなければ false。
func open_log(path: String) -> bool:
	var readings := LogReplay.load_csv(path)
	if readings.size() < 2:
		_show_message(UIStrings.TH_LOG_LOAD_FAILED)
		return false
	_log_path = path
	_log_readings = readings
	_log_columns = LogReplay.axes_in(path)
	_log_selection = Vector2(-1.0, -1.0)
	_log_markers.clear()
	_set_log_mode(true)
	_show_message(UIStrings.TH_LOG_OPENED % path.get_file())
	return true


func _set_log_mode(enabled: bool) -> void:
	_log_mode = enabled
	if not enabled:
		_log_readings = []
		_log_markers.clear()
		_log_selection = Vector2(-1.0, -1.0)
	for axis in _plot_views.keys():
		var view: WaveformView = _plot_views[axis]
		view.selectable = enabled
		view.clear_selection()
		view.set_markers([])
		view.set_spans([])
		if enabled:
			view.capacity = 0
		_plot_states[axis].modulate.a = 0.0
	_log_series_dirty = enabled
	_log_detect_dirty = enabled
	_log_banner.visible = enabled
	_update_controls()


## ログ表示: 波形（平滑化つき）とログの判定結果を必要なときだけ描き直す。
func _update_log_views() -> void:
	if _log_series_dirty:
		_log_series_dirty = false
		_refresh_log_series()
	var now := Time.get_ticks_msec()
	if _log_detect_dirty and now - _log_last_detect_tick >= LOG_DETECT_INTERVAL_MS:
		_log_detect_dirty = false
		_log_last_detect_tick = now
		_run_log_detection()


## ログ全体を軸ごとの波形にする。表示にも判定と同じ平滑化（AxisFilter）をかける。
func _refresh_log_series() -> void:
	var filter := AxisFilter.new(_smoothing)
	var count := _log_readings.size()
	for axis in _axes:
		var view: WaveformView = _plot_views.get(axis)
		if view == null:
			continue
		var data := PackedFloat32Array()
		data.resize(count)
		var lo := INF
		var hi := -INF
		for i in count:
			var v := filter.push(axis, SensorAxis.value_of(_log_readings[i], axis))
			data[i] = v
			lo = minf(lo, v)
			hi = maxf(hi, v)
		view.capacity = 0
		view.set_series([{"color": SensorAxis.color(axis), "data": data, "width": 1.4}])
		_plot_values[axis].text = UIStrings.TH_LOG_RANGE % [_fmt(axis, lo), _fmt(axis, hi, true)]


## 今のルール・組み合わせ・平滑化で、ログを最初から ThresholdDetector に流し直す。
func _run_log_detection() -> void:
	var rules: Array = []
	for axis in _axes:
		rules.append(_rules[axis])
	_log_detector.configure(rules, _combine, _smoothing)
	_log_markers.clear()
	for i in _log_readings.size():
		if _log_detector.feed(_log_readings[i]):
			_log_markers.append(i)

	var denom := float(maxi(_log_readings.size() - 1, 1))
	var markers: Array = []
	for index in _log_markers:
		markers.append({"x": float(index) / denom, "color": COLOR_MARKER})
	for axis in _axes:
		var view: WaveformView = _plot_views.get(axis)
		if view != null:
			view.set_markers(markers)
	_refresh_log_panel()


func _on_log_selection_changed(x0: float, x1: float) -> void:
	_log_selection = Vector2(x0, x1)
	for axis in _plot_views.keys():
		_plot_views[axis].set_selection(x0, x1)
	_refresh_log_panel()


## 選択範囲のサンプル番号 [開始, 終了)。選択なしならログ全体。
func _log_range() -> Vector2i:
	var count := _log_readings.size()
	if _log_selection.x < 0.0:
		return Vector2i(0, count)
	var last := float(maxi(count - 1, 1))
	return Vector2i(int(roundf(_log_selection.x * last)), mini(int(roundf(_log_selection.y * last)) + 1, count))


## 秒表示用: ログ先頭からの経過秒。
func _log_seconds(index: int) -> float:
	if _log_readings.is_empty():
		return 0.0
	return float(_log_readings[index].timestamp_ms - _log_readings[0].timestamp_ms) / 1000.0


## そのログで再現できない軸。合成値は元の3軸の列があれば再現できる（LogReplay は合成列を読まない）。
func _log_missing_axes(axes: Array) -> Array[int]:
	var missing: Array[int] = []
	for axis in axes:
		var needed: Array = [axis]
		if axis == SensorAxis.Id.ACCEL_MAG:
			needed = [SensorAxis.Id.AX, SensorAxis.Id.AY, SensorAxis.Id.AZ]
		elif axis == SensorAxis.Id.GYRO_MAG:
			needed = [SensorAxis.Id.GX, SensorAxis.Id.GY, SensorAxis.Id.GZ]
		for column in needed:
			if column not in _log_columns:
				missing.append(axis)
				break
	return missing


func _refresh_log_panel() -> void:
	if _log_info == null:
		return
	_log_open_button.disabled = _selected_log_path().is_empty()
	var idle := _analyzer.phase() == ThresholdAnalyzer.Phase.IDLE
	_log_import_baseline.disabled = not _log_mode or not idle
	_log_import_trial.disabled = not _log_mode or not idle
	if not _log_mode:
		_log_info.text = UIStrings.TH_LOG_NOT_OPEN
		_log_warning.visible = false
		_log_count.visible = false
		_log_times.visible = false
		_log_import_baseline.text = UIStrings.TH_LOG_IMPORT_BASELINE
		_log_import_trial.text = UIStrings.TH_LOG_IMPORT_TRIAL
		return

	var count := _log_readings.size()
	var columns := PackedStringArray()
	for axis in _log_columns:
		columns.append(SensorAxis.short_label(axis))
	_log_info.text = UIStrings.TH_LOG_INFO % [_log_path.get_file(), _log_seconds(count - 1), count, ", ".join(columns)]
	_log_banner_label.text = UIStrings.TH_LOG_BANNER % _log_path.get_file()

	# 有効なルールの軸のうち、このログに列が無いもの
	var enabled_axes: Array = []
	for axis in _axes:
		if _rules[axis].enabled:
			enabled_axes.append(axis)
	var missing := _log_missing_axes(enabled_axes)
	_log_warning.visible = not missing.is_empty()
	if not missing.is_empty():
		var names := PackedStringArray()
		var has_magnitude := false
		for axis in missing:
			names.append(SensorAxis.label(axis))
			has_magnitude = has_magnitude or SensorAxis.is_magnitude(axis)
		_log_warning.text = UIStrings.TH_LOG_MISSING % ", ".join(names)
		if has_magnitude:
			_log_warning.text += UIStrings.TH_LOG_MISSING_MAG_HINT

	_log_count.visible = true
	_log_count.text = UIStrings.TH_LOG_COUNT % _log_markers.size()
	_log_times.visible = true
	if _log_markers.is_empty():
		_log_times.text = UIStrings.TH_LOG_NO_FIRE
	else:
		var times := PackedStringArray()
		for i in mini(_log_markers.size(), LOG_MAX_LISTED_FIRES):
			times.append("%.2f s" % _log_seconds(_log_markers[i]))
		var text := UIStrings.TH_LOG_FIRES % ", ".join(times)
		if _log_markers.size() > LOG_MAX_LISTED_FIRES:
			text += UIStrings.TH_LOG_FIRES_MORE % (_log_markers.size() - LOG_MAX_LISTED_FIRES)
		_log_times.text = text

	var selected := _log_selection.x >= 0.0
	_log_import_baseline.text = UIStrings.TH_LOG_IMPORT_BASELINE_SEL if selected else UIStrings.TH_LOG_IMPORT_BASELINE
	_log_import_trial.text = UIStrings.TH_LOG_IMPORT_TRIAL_SEL if selected else UIStrings.TH_LOG_IMPORT_TRIAL
	if selected:
		var r := _log_range()
		_log_info.text += "\n" + UIStrings.TH_LOG_SELECTION % [_log_seconds(r.x), _log_seconds(r.y - 1), r.y - r.x]


## ログ（選択範囲。無ければ全体）を静止測定または試行として ThresholdAnalyzer に取り込む。
## 集計は Analyzer に任せる（画面側では計算しない）。
func _import_log(as_baseline: bool) -> void:
	if not _log_mode or _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		return
	var missing := _log_missing_axes(_axes)
	if not missing.is_empty():
		var names := PackedStringArray()
		for axis in missing:
			names.append(SensorAxis.label(axis))
		_show_message(UIStrings.TH_LOG_IMPORT_MISSING % ", ".join(names))
		return
	var r := _log_range()
	if r.y - r.x < 2:
		_show_message(UIStrings.TH_LOG_IMPORT_TOO_SHORT)
		return
	_importing = true
	# 記録したログは、途中で間が空いていても（一時停止して記録を続けた等）そのまま取り込む
	_analyzer.max_gap_ms = 0
	if as_baseline:
		_analyzer.start_baseline(LOG_BASELINE_FOREVER_MS)
	else:
		_analyzer.start_trial(0)
	for i in range(r.x, r.y):
		_analyzer.feed(_log_readings[i])
	_analyzer.stop()
	_analyzer.max_gap_ms = ThresholdAnalyzer.DEFAULT_MAX_GAP_MS
	_importing = false
	_update_controls()
	_show_message((UIStrings.TH_LOG_IMPORTED_BASELINE if as_baseline else UIStrings.TH_LOG_IMPORTED_TRIAL)
			% [_log_seconds(r.x), _log_seconds(r.y - 1)])


# ================================================================ 共通

func _update_controls() -> void:
	if _baseline_button == null:
		return
	var has_device := not _selected_id.is_empty()
	var phase := _analyzer.phase()
	_hint.visible = not has_device and not _log_mode
	_hint.text = UIStrings.TH_HINT_DEVICE_LOST if not _lost_device_id.is_empty() else UIStrings.HINT_NO_DEVICE
	_refresh_log_panel()
	_baseline_button.disabled = not has_device or phase != ThresholdAnalyzer.Phase.IDLE
	_baseline_button.text = (UIStrings.TH_BASELINE_RUNNING if phase == ThresholdAnalyzer.Phase.BASELINE
			else UIStrings.TH_BASELINE_START)
	_baseline_seconds.disabled = phase != ThresholdAnalyzer.Phase.IDLE
	_trial_button.disabled = not has_device or phase == ThresholdAnalyzer.Phase.BASELINE
	_trial_button.text = UIStrings.TH_TRIAL_STOP if phase == ThresholdAnalyzer.Phase.TRIAL else UIStrings.TH_TRIAL_START
	_baseline_cancel_button.disabled = phase != ThresholdAnalyzer.Phase.BASELINE
	_trial_cancel_button.disabled = phase != ThresholdAnalyzer.Phase.TRIAL
	var idle := phase == ThresholdAnalyzer.Phase.IDLE
	_axis_selector.set_editable(idle, UIStrings.AXIS_LOCKED_MEASURING)
	_smoothing_selector.disabled = not idle
	for child in _trial_grid.get_children():
		if child is Button:
			child.disabled = not idle
	_trial_clear_button.disabled = not idle or _analyzer.trials().is_empty()


func _show_message(text: String) -> void:
	_message.text = text
	_message.tooltip_text = text


## 確認ダイアログを出す。OK なら on_ok、キャンセル（閉じる含む）なら on_cancel を呼ぶ。
func _ask(text: String, on_ok: Callable, on_cancel: Callable = Callable()) -> void:
	_confirm_ok = on_ok
	_confirm_cancel = on_cancel
	_confirm.dialog_text = text
	if _confirm.is_inside_tree():   # 画面だけを組み立てる自動テスト（ツリー外）では表示しない
		_confirm.popup_centered()


func _on_confirm_result(accepted: bool) -> void:
	var callback := _confirm_ok if accepted else _confirm_cancel
	_confirm_ok = Callable()
	_confirm_cancel = Callable()
	if callback.is_valid():
		callback.call()
