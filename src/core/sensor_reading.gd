class_name SensorReading
extends RefCounted
## センサーの1サンプル分の値を表すデータクラス。
## 通信方式（有線／BLE）に関わらず、アプリ内ではこの型に正規化して扱う。

var device_id: String      ## 内部キー（有線: ポート名 / BLE: MACアドレス）
var timestamp_ms: int      ## 受信時刻（アプリ起動からの経過ミリ秒）
var accel: Vector3         ## 加速度 [G]
var gyro: Vector3          ## 角速度 [deg/s]
## 1本の線で複数のセンサーを中継する機器（Beer-fw のゲートウェイ等）での送信元ノード番号。無ければ -1。
## SensorManager がこれを見て、ノードごとに別のデバイスとして振り分ける。
var source_node: int = -1
var source_mac: String = ""   ## 送信元ノードの MAC アドレス（分かる場合のみ。表示名に使う）


func _init(p_device_id: String = "", p_timestamp_ms: int = 0,
		p_accel: Vector3 = Vector3.ZERO, p_gyro: Vector3 = Vector3.ZERO) -> void:
	device_id = p_device_id
	timestamp_ms = p_timestamp_ms
	accel = p_accel
	gyro = p_gyro


## 合成加速度（3軸のベクトル長）。しきい値判定の既定値として使う。
func magnitude() -> float:
	return accel.length()


func to_csv_row() -> String:
	return "%d,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f" % [
		timestamp_ms, accel.x, accel.y, accel.z, gyro.x, gyro.y, gyro.z
	]


static func csv_header() -> String:
	return "timestamp_ms,ax,ay,az,gx,gy,gz"


## 指定した軸だけの CSV 行（列の並びは axes の順）。axes は SensorAxis.Id の配列。
## 加速度系は小数4桁、角速度系は小数3桁（to_csv_row と同じ精度）。
func to_csv_row_for(axes: Array) -> String:
	var parts := PackedStringArray([str(timestamp_ms)])
	for axis in axes:
		var fmt := "%.4f" if SensorAxis.is_accel(axis) else "%.3f"
		parts.append(fmt % SensorAxis.value_of(self, axis))
	return ",".join(parts)


## 指定した軸だけの CSV ヘッダ（例: "timestamp_ms,ax,gz"）。
static func csv_header_for(axes: Array) -> String:
	var parts := PackedStringArray(["timestamp_ms"])
	parts.append_array(SensorAxis.keys_of(axes))
	return ",".join(parts)
