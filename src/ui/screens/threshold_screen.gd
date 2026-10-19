class_name ThresholdScreen
extends VBoxContainer
## S4 しきい値測定画面。静止中のノイズと動作時のピークを測り、推奨しきい値を出し、
## 判定テストで確かめ、プロファイル（JSON）として保存・共有する。
##
## 画面構成:
##   上部 … 対象デバイス・平滑化・軸選択（AxisSelector）
##   左   … 選択軸ごとの波形（しきい値線ドラッグ・判定マーカー・ノイズ帯）
##   右   … ①静止測定 ②動作測定 ③推奨しきい値 ④判定テスト ⑤保存と共有（スクロール）
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
var _profile_bands: Dictionary = {}            ## axis -> {min, max}（読み込んだプロファイルの静止測定）
var _last_fire_tick := -100000
var _lamp_lit := false
var _confirm_ok := Callable()
var _confirm_cancel := Callable()

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


func setup(manager: SensorManager) -> void:
	_manager = manager
	_smoothing_values = SMOOTHING_OPTIONS.duplicate()
	_build()

	_manager.reading_received.connect(_on_reading_received)
	_manager.devices_changed.connect(_refresh_device_list)
	_analyzer.phase_changed.connect(_on_phase_changed)
	_analyzer.baseline_finished.connect(_on_baseline_finished)
	_analyzer.trial_finished.connect(_on_trial_finished)
	_detector.fired.connect(_on_detector_fired)

	_apply_axes(_axis_selector.get_axes())
	_refresh_device_list()
	_refresh_profile_list()


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
		_detector.combine = _combine   # configure() は判定回数もリセットするので、ここでは値だけ変える
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
		block.add_child(view)

		_plots_box.add_child(block)
		_plot_views[axis] = view
		_plot_values[axis] = value
		_plot_states[axis] = state
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
	_apply_threshold_limits(row["threshold"], rule.direction)
	row["threshold"].set_value_no_signal(rule.threshold)
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
	if _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		_analyzer.stop()
	_axes.clear()
	for axis in axes:
		_axes.append(int(axis))

	var kept_rules: Dictionary = {}
	for axis in _axes:
		kept_rules[axis] = _rules[axis] if _rules.has(axis) else _default_rule(axis)
		if not _directions.has(axis):
			_directions[axis] = _default_direction(axis)
	_rules = kept_rules
	_profile_bands.clear()

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
	if _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		_analyzer.stop()
	_analyzer.smoothing_window = value
	_analyzer.clear_all()
	_profile_bands.clear()
	_reset_stream()
	_configure_detector()
	_refresh_measurement()


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
		_set_device("")
		return
	var index := 0
	for i in connected.size():
		if connected[i].id == previous:
			index = i
	_device_selector.select(index)
	# 自動で選び直すときは測定結果を残す（一時的な切断で結果が消えないように）
	_set_device(str(_device_selector.get_item_metadata(index)))


func _on_device_selected(index: int) -> void:
	var new_id := str(_device_selector.get_item_metadata(index))
	if new_id == _selected_id:
		return
	var change := func() -> void:
		_set_device(new_id)
		if _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
			_analyzer.stop()
		_analyzer.clear_all()
		_profile_bands.clear()
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
	# デバイスが切り替わったら（切断を含む）、進行中の測定はそこまでの値で締める
	if _analyzer.phase() != ThresholdAnalyzer.Phase.IDLE:
		_analyzer.stop()
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
	_profile_bands.clear()
	_refresh_measurement()


func _on_trial_finished(_index: int, _result: Dictionary) -> void:
	_refresh_measurement()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
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
		var active := _detector.axis_active(axis)
		_plot_states[axis].modulate.a = 1.0 if active else 0.0
		var row: Dictionary = _rule_rows.get(axis, {})
		if not row.is_empty():
			row["lamp"].modulate.a = 1.0 if active else 0.15

	if _analyzer.phase() == ThresholdAnalyzer.Phase.BASELINE:
		_baseline_progress.value = _analyzer.progress() * 100.0

	_set_lamp(_detector.is_active() or Time.get_ticks_msec() - _last_fire_tick < LAMP_HOLD_MS)
	_count_label.text = UIStrings.TH_TRIGGER_COUNT % _detector.trigger_count


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
	_analyzer.start_baseline(BASELINE_OPTIONS[_baseline_seconds.selected] * 1000)


func _toggle_trial() -> void:
	match _analyzer.phase():
		ThresholdAnalyzer.Phase.TRIAL:
			_analyzer.stop()
		ThresholdAnalyzer.Phase.IDLE:
			if not _selected_id.is_empty():
				_analyzer.start_trial(0)


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
		var band: Dictionary = stats.get(axis, _profile_bands.get(axis, {}))
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
		var ready := quality != "insufficient"
		any_ready = any_ready or ready
		row["noise"].text = _fmt(axis, float(rec.get("noise_level", 0.0))) if ready else "-"
		row["weakest"].text = _fmt(axis, float(rec.get("weakest_peak", 0.0))) if ready else "-"
		row["recommended"].text = _fmt(axis, float(rec.get("threshold", 0.0)), true) if ready else "-"
		var quality_label: Label = row["quality"]
		quality_label.text = str(UIStrings.QUALITY_LABELS.get(quality, quality))
		quality_label.add_theme_color_override("font_color", QUALITY_COLORS.get(quality, Color.WHITE))
		row["desc"].text = str(UIStrings.QUALITY_DESCRIPTIONS.get(quality, ""))
	_apply_button.disabled = not any_ready
	_update_all_lines()


func _apply_recommendation() -> void:
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
	# 向きに合わせてしきい値の符号をそろえる（＋方向は正、−方向は負、絶対値は大きさ）
	var magnitude := absf(rule.threshold)
	match direction:
		ThresholdRule.Direction.NEGATIVE:
			rule.threshold = -magnitude
		_:
			rule.threshold = magnitude
	rule.direction = direction
	_sync_rule_controls(axis)
	_update_lines(axis)


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
	if rule.enabled and rule.hysteresis > 0.0:
		for value in values:
			var release := value
			match rule.direction:
				ThresholdRule.Direction.POSITIVE: release = value - rule.hysteresis
				ThresholdRule.Direction.NEGATIVE: release = value + rule.hysteresis
				_: release = value - signf(value) * rule.hysteresis
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
	var files := ThresholdProfile.list_files()
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("modified", 0)) > int(b.get("modified", 0))
	)
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
	var axes: Array[int] = []
	for rule in profile.rules:
		if rule.axis in SensorAxis.ALL and rule.axis not in axes:
			axes.append(rule.axis)
	axes = AxisSelector._sorted(axes)
	if axes.is_empty():
		_show_message(UIStrings.TH_MSG_LOAD_FAILED)
		return
	var needs_reset := axes != _axes or maxi(profile.smoothing_window, 1) != _smoothing
	if needs_reset and _has_measurement():
		_ask(UIStrings.TH_CONFIRM_LOAD, func() -> void: _apply_profile(profile, axes, true))
	else:
		_apply_profile(profile, axes, needs_reset)


func _apply_profile(profile: ThresholdProfile, axes: Array[int], needs_reset: bool) -> void:
	if needs_reset:
		var smoothing := maxi(profile.smoothing_window, 1)
		if smoothing != _smoothing:
			_set_smoothing(smoothing)
		_axis_selector.set_axes(axes)
		_apply_axes(axes)
	for rule in profile.rules:
		if rule.axis in _axes:
			_rules[rule.axis] = rule
	_combine = profile.combine
	_combine_selector.select(_combine_selector.get_item_index(_combine))
	_profile_name.text = profile.name
	_profile_note.text = profile.note

	# 現在の静止測定が無ければ、プロファイルに残っている静止測定をノイズ帯として表示する
	_profile_bands.clear()
	var baseline: Dictionary = profile.measurement.get("baseline", {}) if profile.measurement is Dictionary else {}
	for axis_key in baseline.keys():
		# ThresholdProfile はメモリ上では軸を int（SensorAxis.Id）で持つ。念のため文字列キーも受け付ける
		var axis: int = int(axis_key) if typeof(axis_key) == TYPE_INT else SensorAxis.from_key(str(axis_key))
		if axis >= 0 and baseline[axis_key] is Dictionary:
			_profile_bands[axis] = baseline[axis_key]

	_rebuild_rule_rows()
	_refresh_measurement()
	_configure_detector()
	_show_message(UIStrings.TH_MSG_LOADED % profile.name)


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


# ================================================================ 共通

func _update_controls() -> void:
	if _baseline_button == null:
		return
	var has_device := not _selected_id.is_empty()
	var phase := _analyzer.phase()
	_hint.visible = not has_device
	_baseline_button.disabled = not has_device or phase != ThresholdAnalyzer.Phase.IDLE
	_baseline_button.text = (UIStrings.TH_BASELINE_RUNNING if phase == ThresholdAnalyzer.Phase.BASELINE
			else UIStrings.TH_BASELINE_START)
	_baseline_seconds.disabled = phase != ThresholdAnalyzer.Phase.IDLE
	_trial_button.disabled = not has_device or phase == ThresholdAnalyzer.Phase.BASELINE
	_trial_button.text = UIStrings.TH_TRIAL_STOP if phase == ThresholdAnalyzer.Phase.TRIAL else UIStrings.TH_TRIAL_START
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
	_confirm.popup_centered()


func _on_confirm_result(accepted: bool) -> void:
	var callback := _confirm_ok if accepted else _confirm_cancel
	_confirm_ok = Callable()
	_confirm_cancel = Callable()
	if callback.is_valid():
		callback.call()
