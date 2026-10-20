class_name SampleRing
extends RefCounted
## 波形表示用の固定長リングバッファ（1軸ぶん）。
##
## PackedFloat32Array を Dictionary に入れて append → slice すると、
## 受信のたびに配列全体のコピーが走る。ここでは書き込み位置を回すだけにして、
## 描画時に必要な区間だけを latest() で切り出す。

var _data := PackedFloat32Array()
var _capacity: int = 1
var _count: int = 0
var _head: int = 0          ## 次に書き込む位置
var _last: float = 0.0


func _init(p_capacity: int = 6000) -> void:
	_capacity = maxi(1, p_capacity)
	_data.resize(_capacity)


func push(value: float) -> void:
	_data[_head] = value
	_head = (_head + 1) % _capacity
	_count = mini(_count + 1, _capacity)
	_last = value


func clear() -> void:
	_count = 0
	_head = 0
	_last = 0.0


func size() -> int:
	return _count


func capacity() -> int:
	return _capacity


func is_empty() -> bool:
	return _count == 0


## 直近の値（空なら 0）。
func last() -> float:
	return _last


## 直近 n サンプルを古い順に返す（n が保持数より多ければ保持しているぶんだけ）。
func latest(n: int) -> PackedFloat32Array:
	n = mini(n, _count)
	if n <= 0:
		return PackedFloat32Array()
	var start := _head - n
	if start >= 0:
		return _data.slice(start, _head)
	var result := _data.slice(_capacity + start, _capacity)
	result.append_array(_data.slice(0, _head))
	return result
