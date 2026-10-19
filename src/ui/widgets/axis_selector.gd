class_name AxisSelector
extends HBoxContainer
## 計測に使う軸を選ぶトグルボタン群（加速度 / ジャイロ / 合成 のグループ表示）。
##
## - 最低1軸は必ず選ばれた状態を保つ（最後の1つは外せない）。
## - 選択は user://ui_settings.cfg に画面ごと（settings_key）に保存し、次回起動時に復元する。
## - 軸の並びは常に SensorAxis.ALL の順。

## ユーザー操作で選択が変わったときに発火する（set_axes() では notify=true のときだけ）。
signal axes_changed(axes: Array)

const SETTINGS_FILE := "user://ui_settings.cfg"
const SETTINGS_SECTION := "axes"
const BUTTON_MIN_WIDTH := 44
const OFF_FONT_COLOR := Color(1, 1, 1, 0.45)

## [グループ名, 軸の配列]
const GROUPS := [
	[UIStrings.AXIS_GROUP_ACCEL, [SensorAxis.Id.AX, SensorAxis.Id.AY, SensorAxis.Id.AZ]],
	[UIStrings.AXIS_GROUP_GYRO, [SensorAxis.Id.GX, SensorAxis.Id.GY, SensorAxis.Id.GZ]],
	[UIStrings.AXIS_GROUP_MAGNITUDE, [SensorAxis.Id.ACCEL_MAG, SensorAxis.Id.GYRO_MAG]],
]

var _settings_key := ""
var _selected: Array[int] = []
var _buttons: Dictionary = {}   ## axis -> Button


## settings_key: 保存用のキー（画面名など）。default_axes: 保存が無いときの初期選択。
func setup(settings_key: String, default_axes: Array) -> void:
	_settings_key = settings_key
	_selected = _sorted(_load_saved(default_axes))
	_build()
	_sync_buttons()


## 選択中の軸（SensorAxis.ALL の順）。
func get_axes() -> Array[int]:
	return _selected.duplicate()


## 選択をコードから変更する。空配列は無視する。notify=true なら axes_changed を発火する。
func set_axes(axes: Array, notify: bool = false) -> void:
	var sorted := _sorted(axes)
	if sorted.is_empty():
		return
	_selected = sorted
	_sync_buttons()
	_save()
	if notify:
		axes_changed.emit(get_axes())


## 記録中・測定中など、軸を変えてはいけない間は false にする。
func set_editable(editable: bool, reason: String = "") -> void:
	for axis in _buttons.keys():
		var button: Button = _buttons[axis]
		button.disabled = not editable
		button.tooltip_text = _tooltip(axis) if editable or reason.is_empty() else reason


# ---------------------------------------------------------------- UI構築

func _build() -> void:
	add_theme_constant_override("separation", 4)
	var first := true
	for group in GROUPS:
		if not first:
			var sep := VSeparator.new()
			add_child(sep)
		first = false
		var title := Label.new()
		title.text = group[0]
		title.modulate = Color(1, 1, 1, 0.6)
		add_child(title)
		for axis in group[1]:
			add_child(_make_button(axis))


func _make_button(axis: int) -> Button:
	var color := SensorAxis.color(axis)
	var button := Button.new()
	button.text = SensorAxis.short_label(axis)
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE   # Space キーを判定テスト等に使う画面があるため
	button.custom_minimum_size.x = BUTTON_MIN_WIDTH
	button.tooltip_text = _tooltip(axis)
	button.add_theme_color_override("font_color", OFF_FONT_COLOR)
	button.add_theme_color_override("font_pressed_color", color)
	button.add_theme_color_override("font_hover_pressed_color", color.lightened(0.2))

	# 選択中は下線を軸の色にして、グラフの線の色と対応させる
	var on_style := StyleBoxFlat.new()
	on_style.bg_color = Color(color.r, color.g, color.b, 0.18)
	on_style.border_color = color
	on_style.border_width_bottom = 3
	on_style.set_corner_radius_all(3)
	on_style.content_margin_left = 6
	on_style.content_margin_right = 6
	on_style.content_margin_top = 3
	on_style.content_margin_bottom = 3
	button.add_theme_stylebox_override("pressed", on_style)
	button.add_theme_stylebox_override("hover_pressed", on_style)
	button.set_meta("on_style", on_style)

	button.toggled.connect(func(pressed: bool) -> void: _on_toggled(axis, pressed))
	_buttons[axis] = button
	return button


func _tooltip(axis: int) -> String:
	return "%s [%s]" % [SensorAxis.label(axis), SensorAxis.unit(axis)]


func _sync_buttons() -> void:
	for axis in _buttons.keys():
		var button: Button = _buttons[axis]
		var selected: bool = axis in _selected
		button.set_pressed_no_signal(selected)
		# 無効（記録中など）でも、どの軸が選ばれているかは見えるようにする
		if selected:
			button.add_theme_stylebox_override("disabled", button.get_meta("on_style"))
			button.add_theme_color_override("font_disabled_color", SensorAxis.color(axis).darkened(0.25))
		else:
			button.remove_theme_stylebox_override("disabled")
			button.remove_theme_color_override("font_disabled_color")


func _on_toggled(axis: int, pressed: bool) -> void:
	if pressed:
		if axis not in _selected:
			_selected.append(axis)
	else:
		if _selected.size() <= 1:
			# 最後の1軸は外せない
			_buttons[axis].set_pressed_no_signal(true)
			return
		_selected.erase(axis)
	_selected = _sorted(_selected)
	_sync_buttons()
	_save()
	axes_changed.emit(get_axes())


static func _sorted(axes: Array) -> Array[int]:
	var result: Array[int] = []
	for axis in SensorAxis.ALL:
		if axis in axes:
			result.append(axis)
	return result


# ---------------------------------------------------------------- 保存・復元

func _load_saved(default_axes: Array) -> Array:
	var config := ConfigFile.new()
	if _settings_key.is_empty() or config.load(SETTINGS_FILE) != OK:
		return default_axes
	var keys: Variant = config.get_value(SETTINGS_SECTION, _settings_key, null)
	if not (keys is PackedStringArray or keys is Array):
		return default_axes
	var axes: Array = []
	for axis_key in keys:
		var axis := SensorAxis.from_key(str(axis_key))
		if axis >= 0:
			axes.append(axis)
	return axes if not axes.is_empty() else default_axes


func _save() -> void:
	if _settings_key.is_empty():
		return
	var config := ConfigFile.new()
	config.load(SETTINGS_FILE)   # 無ければ新規作成（他画面の設定を消さないため読み込んでから書く）
	config.set_value(SETTINGS_SECTION, _settings_key, SensorAxis.keys_of(_selected))
	config.save(SETTINGS_FILE)
