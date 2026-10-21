class_name AxisFilter
extends RefCounted
## 軸ごとの単純移動平均フィルタ。window=1 で素通し（入力をそのまま返す）。
##
## しきい値の「解析」「判定」「表示」で同じ平滑化を使うための共通部品。
## 平滑化の仕方が画面ごとに違うと、測定した推奨値と判定結果がずれるため、必ずこのクラスを通す。
##
## 窓に溜まるまでの立ち上がり（サンプル数 < window）の間は、溜まっている分だけで平均する。
## NaN / INF は窓に入れずに無視し、直前の平均値（窓が空なら 0.0）を返す。

## 移動平均の窓幅（サンプル数）。1 未満を指定すると 1 になる。
## 途中で小さくした場合は古いサンプルから切り捨てる。
var window: int = 1:
	set(value):
		window = maxi(1, value)
		for axis in _buffers.keys():
			var buffer: Array = _buffers[axis]
			while buffer.size() > window:
				buffer.pop_front()

## axis(int) -> Array[float]（新しいものが末尾）
var _buffers: Dictionary = {}


func _init(p_window: int = 1) -> void:
	window = p_window


## 値を1つ追加し、平滑化後の値を返す。
func push(axis: int, value: float) -> float:
	if not _buffers.has(axis):
		_buffers[axis] = []
	var buffer: Array = _buffers[axis]
	if is_finite(value):
		buffer.append(value)
		while buffer.size() > window:
			buffer.pop_front()
	return _average(buffer)


## 指定軸の現在の平滑化値（まだ値が無ければ 0.0）。値は追加しない。
func current(axis: int) -> float:
	if not _buffers.has(axis):
		return 0.0
	return _average(_buffers[axis])


## 指定軸に溜まっているサンプル数（0〜window）。
func sample_count(axis: int) -> int:
	if not _buffers.has(axis):
		return 0
	var buffer: Array = _buffers[axis]
	return buffer.size()


## 全軸の履歴を消す（window はそのまま）。
func reset() -> void:
	_buffers.clear()


static func _average(buffer: Array) -> float:
	if buffer.is_empty():
		return 0.0
	# 累積和を持ち回ると浮動小数の誤差が溜まるため、毎回合計し直す（window は小さい前提）
	var total := 0.0
	for v in buffer:
		total += float(v)
	return total / float(buffer.size())
