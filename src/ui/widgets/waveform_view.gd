class_name WaveformView
extends Control
## 時系列データを折れ線で描画するウィジェット。
## 外部依存を増やさないよう、Godot標準の _draw() だけで実装している。

const BG_COLOR := Color(0.078, 0.105, 0.113)
const GRID_COLOR := Color(0.149, 0.192, 0.184)
const CENTER_COLOR := Color(0.239, 0.302, 0.29)

## 表示レンジ（±この値までを描画範囲とする）
var value_range: float = 2.5

## [{ "color": Color, "data": PackedFloat32Array }] の配列
var series: Array = []


func set_series(new_series: Array) -> void:
	series = new_series
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)

	# 目盛り
	for i in range(1, 5):
		var y := h * float(i) / 5.0
		draw_line(Vector2(0.0, y), Vector2(w, y), GRID_COLOR, 1.0)
	for i in range(1, 8):
		var x := w * float(i) / 8.0
		draw_line(Vector2(x, 0.0), Vector2(x, h), GRID_COLOR, 1.0)
	draw_line(Vector2(0.0, h * 0.5), Vector2(w, h * 0.5), CENTER_COLOR, 1.0)

	# 波形
	for entry in series:
		var data: PackedFloat32Array = entry["data"]
		if data.size() < 2:
			continue
		var points := PackedVector2Array()
		points.resize(data.size())
		for i in data.size():
			var x := w * float(i) / float(data.size() - 1)
			var y := h * 0.5 - (data[i] / value_range) * (h * 0.5 - 4.0)
			points[i] = Vector2(x, clampf(y, 0.0, h))
		draw_polyline(points, entry["color"], 1.5, true)
