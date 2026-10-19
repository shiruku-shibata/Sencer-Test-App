class_name SensorReading
extends RefCounted
## センサーの1サンプル分の値を表すデータクラス。
## 通信方式（有線／BLE）に関わらず、アプリ内ではこの型に正規化して扱う。

var device_id: String      ## 内部キー（有線: ポート名 / BLE: MACアドレス）
var timestamp_ms: int      ## 受信時刻（アプリ起動からの経過ミリ秒）
var accel: Vector3         ## 加速度 [G]
var gyro: Vector3          ## 角速度 [deg/s]


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
