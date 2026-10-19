class_name WaveformView
extends Control
## 時系列データを折れ線で描画するウィジェット。
## 外部依存を増やさないよう、Godot標準の _draw() だけで実装している。
##
## 描画するもの（下から順に）:
##   背景 → 区間の塗り（静止測定中・試行中など）→ ノイズ帯 → 目盛り・0線 → 波形
##   → しきい値線 → 判定マーカー → 左端の目盛り数値 → ドラッグ中の値表示
##
## しきい値線のうち draggable なものはマウスで上下にドラッグでき、
## そのたびに line_dragged(id, value) が発火する。値の確定や丸めは受け取り側が行い、
## 必要なら set_lines() で描き直す（ドラッグ中に呼んでも掴んだ線は外れない）。
##
## selectable にすると、線の無い所を横にドラッグして範囲を選べる（selection_changed）。

## しきい値線をドラッグ中、マウス位置の値を通知する。
signal line_dragged(id: Variant, value: float)
## しきい値線のドラッグを離したときに通知する。
signal line_drag_finished(id: Variant, value: float)
## selectable のとき、横方向にドラッグして選んだ範囲（0..1 の比率）を通知する。
## ドラッグ中も逐次通知する。解除（クリックだけ）は (-1, -1)。
signal selection_changed(x0: float, x1: float)

const BG_COLOR := Color(0.078, 0.105, 0.113)
const GRID_COLOR := Color(0.149, 0.192, 0.184)
const CENTER_COLOR := Color(0.239, 0.302, 0.29)
const ZERO_COLOR := Color(0.36, 0.43, 0.42)
const TICK_TEXT_COLOR := Color(1, 1, 1, 0.5)
const TICK_BG_COLOR := Color(0.078, 0.105, 0.113, 0.7)
const TOOLTIP_BG := Color(0.05, 0.06, 0.07, 0.92)
const DEFAULT_LINE_COLOR := Color("ff6b6b")
const DEFAULT_BAND_COLOR := Color(0.55, 0.75, 1.0, 0.16)
const SELECTION_COLOR := Color(0.55, 0.85, 1.0, 0.16)
const SELECTION_EDGE := Color(0.55, 0.85, 1.0, 0.7)
const MIN_SELECTION_PX := 4.0     ## これより短いドラッグはクリックとみなして選択解除

const TICK_FONT_SIZE := 11
const TOOLTIP_FONT_SIZE := 13
const PLOT_MARGIN := 6.0          ## 上下の余白 [px]
const GRAB_DISTANCE := 6.0        ## しきい値線を掴める距離 [px]
const AUTO_RANGE_HEADROOM := 1.15 ## 自動レンジでデータの外側に空ける割合
const AUTO_RANGE_SHRINK := 0.04   ## 自動レンジが縮むときの追従速度（1フレームあたり）

## 固定レンジの大きさ。positive_only なら 0〜この値、そうでなければ ±この値を表示する。
var value_range: float = 2.5:
	set(v):
		value_range = maxf(v, 0.0001)
		queue_redraw()
## 0 以上の値だけを扱う軸（合成値など）。
var positive_only := false:
	set(v):
		positive_only = v
		queue_redraw()
## true なら表示中のデータ・しきい値線・ノイズ帯が収まるようにレンジを自動調整する。
var auto_range := false:
	set(v):
		auto_range = v
		queue_redraw()
## 自動レンジの最小値（静止中にノイズが画面いっぱいに拡大されないように）。
var min_auto_range: float = 0.1
## 左端に目盛りの数値を描くか。
var show_ticks := true
## ドラッグ中の値表示に付ける単位（"G" など）。
var unit_text := ""
## 表示区間のサンプル数。0 ならデータ長に合わせて横いっぱいに引き伸ばす。
## データが capacity に満たない間は右詰めで描く（マーカーの x 比率と揃えるため）。
var capacity: int = 0
## true なら、しきい値線の無い所を横にドラッグして範囲を選べる（ログ表示用）。
var selectable := false:
	set(v):
		selectable = v
		if not v:
			_selecting = false
		mouse_default_cursor_shape = Control.CURSOR_CROSS if v else Control.CURSOR_ARROW

## [{ "color": Color, "data": PackedFloat32Array, "width": float(任意) }] の配列
var series: Array = []

var _lines: Array = []     ## [{id, value, color, dashed, draggable, width, label}]
var _markers: Array = []   ## [{x, color, style("line"|"dot"), value}]
var _spans: Array = []     ## [{x0, x1, color}]
var _band: Dictionary = {} ## {min, max, color}

var _auto_half: float = 0.0       ## 自動レンジの現在値
var _drag_index := -1
var _hover_index := -1
var _mouse_pos := Vector2.ZERO
var _frozen_lo := 0.0             ## ドラッグ中はレンジを固定する（線を動かすとレンジが動く循環を防ぐ）
var _frozen_hi := 0.0
var _selection := Vector2(-1.0, -1.0)  ## 選択範囲（比率）。x < 0 なら選択なし
var _selecting := false
var _select_from := 0.0


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


# ---------------------------------------------------------------- 公開API

func set_series(new_series: Array) -> void:
	series = new_series
	queue_redraw()


## しきい値線を設定する。各要素は次のキーを持つ Dictionary:
##   id: Variant（line_dragged で返る識別子）, value: float,
##   color: Color（省略時 赤）, dashed: bool, draggable: bool, width: float, label: String
func set_lines(lines: Array) -> void:
	_lines = lines
	if _drag_index >= _lines.size():
		_end_drag(false)
	if _hover_index >= _lines.size():
		_hover_index = -1
	queue_redraw()


## 判定マーカーを設定する。x は表示区間の左端=0・右端=1 の比率。
## style "line" は縦線、"dot" は value の位置に点を描く。
func set_markers(markers: Array) -> void:
	_markers = markers
	queue_redraw()


## 区間の塗りを設定する。[{x0, x1, color}]（x は 0..1 の比率）。
func set_spans(spans: Array) -> void:
	_spans = spans
	queue_redraw()


## ノイズ帯（静止測定の min〜max）を薄く塗る。
func set_noise_band(min_value: float, max_value: float, color: Color = DEFAULT_BAND_COLOR) -> void:
	_band = {"min": minf(min_value, max_value), "max": maxf(min_value, max_value), "color": color}
	queue_redraw()


## 選択範囲を設定する（比率）。他の波形と選択をそろえるとき用。シグナルは出さない。
func set_selection(x0: float, x1: float) -> void:
	if x0 < 0.0 or x1 < 0.0:
		_selection = Vector2(-1.0, -1.0)
	else:
		_selection = Vector2(clampf(minf(x0, x1), 0.0, 1.0), clampf(maxf(x0, x1), 0.0, 1.0))
	queue_redraw()


func clear_selection() -> void:
	set_selection(-1.0, -1.0)


## 現在の選択範囲（比率）。選択なしなら (-1, -1)。
func selection() -> Vector2:
	return _selection


func clear_noise_band() -> void:
	_band = {}
	queue_redraw()


func is_dragging() -> bool:
	return _drag_index >= 0


## 現在表示しているレンジ（x = 下端, y = 上端）。
func current_range() -> Vector2:
	var r := _range()
	return Vector2(r[0], r[1])


# ---------------------------------------------------------------- 座標変換

func _range() -> Array:
	if _drag_index >= 0:
		return [_frozen_lo, _frozen_hi]
	var half := _auto_half if auto_range and _auto_half > 0.0 else value_range
	if positive_only:
		return [0.0, half]
	return [-half, half]


func _value_to_y(value: float, lo: float, hi: float) -> float:
	var top := PLOT_MARGIN
	var bottom := size.y - PLOT_MARGIN
	return bottom - (value - lo) / (hi - lo) * (bottom - top)


func _y_to_value(y: float, lo: float, hi: float) -> float:
	var top := PLOT_MARGIN
	var bottom := size.y - PLOT_MARGIN
	return lo + (bottom - y) / maxf(bottom - top, 1.0) * (hi - lo)


## 自動レンジ: 広がるときは即座に、縮むときはゆっくり追従する（ちらつき防止）。
func _update_auto_range() -> void:
	if not auto_range or _drag_index >= 0:
		return
	var extent := 0.0
	for entry in series:
		var data: PackedFloat32Array = entry["data"]
		for v in data:
			extent = maxf(extent, absf(v))
	for line in _lines:
		extent = maxf(extent, absf(float(line["value"])))
	if not _band.is_empty():
		extent = maxf(extent, maxf(absf(_band["min"]), absf(_band["max"])))
	var target := maxf(extent * AUTO_RANGE_HEADROOM, min_auto_range)
	if target >= _auto_half or _auto_half <= 0.0:
		_auto_half = target
	else:
		_auto_half = lerpf(_auto_half, target, AUTO_RANGE_SHRINK)


# ---------------------------------------------------------------- 描画

func _draw() -> void:
	_update_auto_range()
	var w := size.x
	var h := size.y
	var r := _range()
	var lo: float = r[0]
	var hi: float = r[1]
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)

	_draw_spans(w, h)
	_draw_selection(w, h)
	_draw_band(w, lo, hi)
	var ticks := _draw_grid(w, h, lo, hi)
	_draw_series(w, h, lo, hi)
	_draw_lines(w, lo, hi)
	_draw_markers(w, h, lo, hi)
	if show_ticks:
		_draw_tick_labels(ticks, lo, hi)
	_draw_drag_tooltip(w, lo, hi)


func _draw_spans(w: float, h: float) -> void:
	for span in _spans:
		var x0 := clampf(float(span["x0"]), 0.0, 1.0) * w
		var x1 := clampf(float(span["x1"]), 0.0, 1.0) * w
		if x1 - x0 < 1.0:
			continue
		draw_rect(Rect2(x0, 0.0, x1 - x0, h), span["color"])


func _draw_selection(w: float, h: float) -> void:
	if _selection.x < 0.0:
		return
	var x0 := _selection.x * w
	var x1 := _selection.y * w
	draw_rect(Rect2(x0, 0.0, maxf(x1 - x0, 1.0), h), SELECTION_COLOR)
	draw_line(Vector2(x0, 0.0), Vector2(x0, h), SELECTION_EDGE, 1.0)
	draw_line(Vector2(x1, 0.0), Vector2(x1, h), SELECTION_EDGE, 1.0)


func _draw_band(w: float, lo: float, hi: float) -> void:
	if _band.is_empty():
		return
	var y_top := _value_to_y(_band["max"], lo, hi)
	var y_bottom := _value_to_y(_band["min"], lo, hi)
	# 帯が細すぎても見えるように最低 2px にする
	if y_bottom - y_top < 2.0:
		var mid := (y_top + y_bottom) * 0.5
		y_top = mid - 1.0
		y_bottom = mid + 1.0
	var color: Color = _band["color"]
	draw_rect(Rect2(0.0, y_top, w, y_bottom - y_top), color)
	var edge := Color(color.r, color.g, color.b, minf(color.a * 2.5, 1.0))
	draw_line(Vector2(0.0, y_top), Vector2(w, y_top), edge, 1.0)
	draw_line(Vector2(0.0, y_bottom), Vector2(w, y_bottom), edge, 1.0)


## 目盛り線を引き、数値を描く位置（値の配列）を返す。
func _draw_grid(w: float, h: float, lo: float, hi: float) -> PackedFloat32Array:
	for i in range(1, 8):
		var x := w * float(i) / 8.0
		draw_line(Vector2(x, 0.0), Vector2(x, h), GRID_COLOR, 1.0)

	var ticks := PackedFloat32Array()
	var step := _nice_step((hi - lo) / 4.0)
	var value := ceilf(lo / step) * step
	var guard := 0
	while value <= hi + step * 0.001 and guard < 20:
		ticks.append(value)
		var y := _value_to_y(value, lo, hi)
		var is_zero := absf(value) < step * 0.001
		draw_line(Vector2(0.0, y), Vector2(w, y), ZERO_COLOR if is_zero else GRID_COLOR, 1.0)
		value += step
		guard += 1
	return ticks


## 1, 2, 2.5, 5 × 10^n のうち raw 以上で最小の値。
static func _nice_step(raw: float) -> float:
	if raw <= 0.0:
		return 1.0
	var magnitude := pow(10.0, floorf(log(raw) / log(10.0)))
	for factor in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if magnitude * factor >= raw:
			return magnitude * factor
	return magnitude * 10.0


func _draw_series(w: float, h: float, lo: float, hi: float) -> void:
	for entry in series:
		var data: PackedFloat32Array = entry["data"]
		if data.size() < 2:
			continue
		var points := _series_points(data, w, h, lo, hi)
		if points.size() >= 2:
			draw_polyline(points, entry["color"], float(entry.get("width", 1.5)), true)


## データ点を画面座標にする。点数が横幅より十分多いときは、1px 列ごとに
## 最大・最小の2点へ間引く（ピークを落とさずに描画負荷を下げる）。
func _series_points(data: PackedFloat32Array, w: float, h: float, lo: float, hi: float) -> PackedVector2Array:
	var n := data.size()
	var slots := maxi(capacity, n)
	var offset := slots - n   # 右詰め
	var denom := float(maxi(slots - 1, 1))
	var points := PackedVector2Array()

	if n <= int(w) * 2:
		points.resize(n)
		for i in n:
			var x := w * float(i + offset) / denom
			points[i] = Vector2(x, clampf(_value_to_y(data[i], lo, hi), 0.0, h))
		return points

	var columns := maxi(int(w), 1)
	var per_column := float(n) / float(columns)
	var x0 := w * float(offset) / denom
	var x_scale := (w - x0) / float(columns)
	for c in columns:
		var start := int(c * per_column)
		var end := mini(int((c + 1) * per_column), n)
		if end <= start:
			continue
		var mn := data[start]
		var mx := data[start]
		for i in range(start + 1, end):
			mn = minf(mn, data[i])
			mx = maxf(mx, data[i])
		var x := x0 + x_scale * float(c)
		points.append(Vector2(x, clampf(_value_to_y(mx, lo, hi), 0.0, h)))
		points.append(Vector2(x, clampf(_value_to_y(mn, lo, hi), 0.0, h)))
	return points


func _draw_lines(w: float, lo: float, hi: float) -> void:
	var font := get_theme_default_font()
	for i in _lines.size():
		var line: Dictionary = _lines[i]
		var value := float(line["value"])
		var y := _value_to_y(value, lo, hi)
		if y < -2.0 or y > size.y + 2.0:
			continue
		var color: Color = line.get("color", DEFAULT_LINE_COLOR)
		var width := float(line.get("width", 1.5))
		if i == _drag_index or i == _hover_index:
			width += 1.5
		if bool(line.get("dashed", false)):
			draw_dashed_line(Vector2(0.0, y), Vector2(w, y), color, width, 6.0)
		else:
			draw_line(Vector2(0.0, y), Vector2(w, y), color, width)
		if bool(line.get("draggable", false)):
			# 右端の「つまみ」と値
			draw_rect(Rect2(w - 10.0, y - 5.0, 10.0, 10.0), color)
			if font != null:
				var text := _format_value(value, lo, hi)
				var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_FONT_SIZE).x
				var ty := y - 4.0 if y > 16.0 else y + 14.0
				draw_string(font, Vector2(w - 14.0 - text_width, ty), text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_FONT_SIZE, color)


func _draw_markers(w: float, h: float, lo: float, hi: float) -> void:
	for marker in _markers:
		var ratio := float(marker["x"])
		if ratio < 0.0 or ratio > 1.0:
			continue
		var x := ratio * w
		var color: Color = marker.get("color", DEFAULT_LINE_COLOR)
		if str(marker.get("style", "line")) == "dot":
			var y := clampf(_value_to_y(float(marker.get("value", 0.0)), lo, hi), 0.0, h)
			draw_circle(Vector2(x, y), 4.0, color)
		else:
			draw_line(Vector2(x, 0.0), Vector2(x, h), color, 2.0)
			draw_circle(Vector2(x, 4.0), 3.5, color)


func _draw_tick_labels(ticks: PackedFloat32Array, lo: float, hi: float) -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var ascent := font.get_ascent(TICK_FONT_SIZE)
	for value in ticks:
		var text := _format_value(value, lo, hi)
		var y := _value_to_y(value, lo, hi)
		var baseline := clampf(y + ascent * 0.4, ascent + 1.0, size.y - 2.0)
		var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TICK_FONT_SIZE)
		draw_rect(Rect2(2.0, baseline - ascent, text_size.x + 4.0, ascent + 3.0), TICK_BG_COLOR)
		draw_string(font, Vector2(4.0, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				TICK_FONT_SIZE, TICK_TEXT_COLOR)


func _draw_drag_tooltip(w: float, lo: float, hi: float) -> void:
	if _drag_index < 0:
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var line: Dictionary = _lines[_drag_index]
	var label := str(line.get("label", ""))
	var text := _format_value(float(line["value"]), lo, hi)
	if not unit_text.is_empty():
		text += " " + unit_text
	if not label.is_empty():
		text = "%s %s" % [label, text]
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TOOLTIP_FONT_SIZE)
	var box := Rect2(_mouse_pos + Vector2(14.0, -text_size.y - 10.0), text_size + Vector2(10.0, 6.0))
	box.position.x = clampf(box.position.x, 0.0, maxf(w - box.size.x, 0.0))
	box.position.y = clampf(box.position.y, 0.0, maxf(size.y - box.size.y, 0.0))
	draw_rect(box, TOOLTIP_BG)
	draw_string(font, box.position + Vector2(5.0, font.get_ascent(TOOLTIP_FONT_SIZE) + 2.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, TOOLTIP_FONT_SIZE, Color.WHITE)


## レンジの広さに応じて桁数を変える。
static func _format_value(value: float, lo: float, hi: float) -> String:
	var span := hi - lo
	if span >= 50.0:
		return "%.0f" % value
	if span >= 5.0:
		return "%.1f" % value
	return "%.2f" % value


# ---------------------------------------------------------------- マウス操作

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			var index := _line_at(button.position.y)
			if index >= 0:
				var r := _range()
				_frozen_lo = r[0]
				_frozen_hi = r[1]
				_drag_index = index
				_mouse_pos = button.position
				accept_event()
				queue_redraw()
			elif selectable:
				_selecting = true
				_select_from = _x_ratio(button.position.x)
				set_selection(_select_from, _select_from)
				accept_event()
		elif _drag_index >= 0:
			_end_drag(true)
			accept_event()
		elif _selecting:
			_selecting = false
			if (_selection.y - _selection.x) * size.x < MIN_SELECTION_PX:
				clear_selection()
			selection_changed.emit(_selection.x, _selection.y)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_mouse_pos = motion.position
		if _drag_index >= 0:
			var y := clampf(motion.position.y, 0.0, size.y)
			var value := _y_to_value(y, _frozen_lo, _frozen_hi)
			_lines[_drag_index]["value"] = value
			line_dragged.emit(_lines[_drag_index]["id"], value)
			accept_event()
			queue_redraw()
		elif _selecting:
			set_selection(_select_from, _x_ratio(motion.position.x))
			selection_changed.emit(_selection.x, _selection.y)
			accept_event()
		else:
			_set_hover(_line_at(motion.position.y))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _drag_index < 0:
		_set_hover(-1)


func _set_hover(index: int) -> void:
	if index == _hover_index:
		return
	_hover_index = index
	if index >= 0:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
	else:
		mouse_default_cursor_shape = Control.CURSOR_CROSS if selectable else Control.CURSOR_ARROW
	queue_redraw()


func _end_drag(notify: bool) -> void:
	if _drag_index < 0:
		return
	var line: Dictionary = _lines[_drag_index] if _drag_index < _lines.size() else {}
	_drag_index = -1
	queue_redraw()
	if notify and not line.is_empty():
		line_drag_finished.emit(line["id"], float(line["value"]))


func _x_ratio(x: float) -> float:
	return clampf(x / maxf(size.x, 1.0), 0.0, 1.0)


## y 座標の近くにあるドラッグ可能な線の番号（無ければ -1）。
func _line_at(y: float) -> int:
	var r := _range()
	var best := -1
	var best_distance := GRAB_DISTANCE
	for i in _lines.size():
		if not bool(_lines[i].get("draggable", false)):
			continue
		var distance := absf(_value_to_y(float(_lines[i]["value"]), r[0], r[1]) - y)
		if distance <= best_distance:
			best = i
			best_distance = distance
	return best
