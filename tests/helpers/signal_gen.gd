extends RefCounted
## テスト用の合成センサー信号を作る（乱数は seed 固定なので毎回同じ波形になる）。
##
##   var gen := SignalGen.new(42)
##   var data := gen.rest(3000)                               # 静止 3 秒
##   data.append_array(gen.gesture(150, Vector3.ZERO, Vector3(0, 0, 250)))  # gZ に +250 deg/s の振り
##
## 静止中は rest_accel / rest_gyro に一様ノイズ（±accel_noise / ±gyro_noise）を足す。
## ジェスチャーは半周期の正弦波パルス（0 → ピーク → 0）。rebound > 0 なら直後に逆向きの小さな揺り戻しを付ける。

var rng := RandomNumberGenerator.new()
var interval_ms := 10                          ## 100Hz
var t_ms := 0
var device_id := "synthetic"
var rest_accel := Vector3(0.0, 0.0, 1.0)       ## 静止時（重力が Z に 1G）
var rest_gyro := Vector3.ZERO
var accel_noise := 0.02
var gyro_noise := 2.0
var rebound := 0.0                             ## 揺り戻しの大きさ（ピークに対する比）


func _init(seed_value: int = 1) -> void:
	rng.seed = seed_value


## 静止区間。
func rest(duration_ms: int) -> Array[SensorReading]:
	var out: Array[SensorReading] = []
	for _i in _steps(duration_ms):
		out.append(_make(Vector3.ZERO, Vector3.ZERO))
	return out


## ジェスチャー1回（半周期の正弦波パルス + 任意の揺り戻し）。
func gesture(duration_ms: int, accel_peak: Vector3, gyro_peak: Vector3) -> Array[SensorReading]:
	var out: Array[SensorReading] = []
	var n := _steps(duration_ms)
	for i in n:
		var k := sin(PI * float(i + 1) / float(n + 1))
		out.append(_make(accel_peak * k, gyro_peak * k))
	if rebound > 0.0:
		var m := maxi(1, int(n / 2.0))
		for i in m:
			var k := -rebound * sin(PI * float(i + 1) / float(m + 1))
			out.append(_make(accel_peak * k, gyro_peak * k))
	return out


## 1サンプル（静止値 + offset + ノイズ）。時刻を interval_ms 進める。
func sample(accel_offset: Vector3, gyro_offset: Vector3) -> SensorReading:
	return _make(accel_offset, gyro_offset)


## ノイズ無しの値をそのまま1サンプルにする。
func exact(accel: Vector3, gyro: Vector3) -> SensorReading:
	var r := SensorReading.new(device_id, t_ms, accel, gyro)
	t_ms += interval_ms
	return r


func _steps(duration_ms: int) -> int:
	return maxi(1, int(round(float(duration_ms) / float(interval_ms))))


func _make(accel_offset: Vector3, gyro_offset: Vector3) -> SensorReading:
	var a := rest_accel + accel_offset + Vector3(
			rng.randf_range(-accel_noise, accel_noise),
			rng.randf_range(-accel_noise, accel_noise),
			rng.randf_range(-accel_noise, accel_noise))
	var g := rest_gyro + gyro_offset + Vector3(
			rng.randf_range(-gyro_noise, gyro_noise),
			rng.randf_range(-gyro_noise, gyro_noise),
			rng.randf_range(-gyro_noise, gyro_noise))
	var r := SensorReading.new(device_id, t_ms, a, g)
	t_ms += interval_ms
	return r
