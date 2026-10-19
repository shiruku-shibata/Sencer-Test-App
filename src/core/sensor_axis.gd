class_name SensorAxis
extends RefCounted
## 計測対象の「軸」の定義を1箇所に集約する。
## 軸指定計測・しきい値判定・ログ記録・波形表示は、すべてこの定義を通して軸を扱う。

enum Id { AX, AY, AZ, GX, GY, GZ, ACCEL_MAG, GYRO_MAG }

## 画面に並べる順番
const ALL: Array[int] = [Id.AX, Id.AY, Id.AZ, Id.GX, Id.GY, Id.GZ, Id.ACCEL_MAG, Id.GYRO_MAG]
## 生の6軸（CSV記録の既定列）
const RAW: Array[int] = [Id.AX, Id.AY, Id.AZ, Id.GX, Id.GY, Id.GZ]

## 保存ファイル・CSV列名に使うキー（変更すると過去ファイルが読めなくなるので固定）
const _KEYS := {
	Id.AX: "ax", Id.AY: "ay", Id.AZ: "az",
	Id.GX: "gx", Id.GY: "gy", Id.GZ: "gz",
	Id.ACCEL_MAG: "amag", Id.GYRO_MAG: "gmag",
}

const _LABELS := {
	Id.AX: "加速度 X", Id.AY: "加速度 Y", Id.AZ: "加速度 Z",
	Id.GX: "ジャイロ X", Id.GY: "ジャイロ Y", Id.GZ: "ジャイロ Z",
	Id.ACCEL_MAG: "合成加速度", Id.GYRO_MAG: "合成角速度",
}

const _SHORT_LABELS := {
	Id.AX: "aX", Id.AY: "aY", Id.AZ: "aZ",
	Id.GX: "gX", Id.GY: "gY", Id.GZ: "gZ",
	Id.ACCEL_MAG: "|a|", Id.GYRO_MAG: "|g|",
}

const _COLORS := {
	Id.AX: Color("e8843f"), Id.AY: Color("3fb3aa"), Id.AZ: Color("7d90e0"),
	Id.GX: Color("e8843f"), Id.GY: Color("3fb3aa"), Id.GZ: Color("7d90e0"),
	Id.ACCEL_MAG: Color("d9c35b"), Id.GYRO_MAG: Color("c779d0"),
}


static func key(axis: int) -> String:
	return _KEYS.get(axis, "")


## キーから軸を引く。不明なキーは -1。
static func from_key(axis_key: String) -> int:
	for axis in _KEYS.keys():
		if _KEYS[axis] == axis_key:
			return axis
	return -1


static func label(axis: int) -> String:
	return _LABELS.get(axis, "?")


static func short_label(axis: int) -> String:
	return _SHORT_LABELS.get(axis, "?")


static func color(axis: int) -> Color:
	return _COLORS.get(axis, Color.WHITE)


static func is_accel(axis: int) -> bool:
	return axis in [Id.AX, Id.AY, Id.AZ, Id.ACCEL_MAG]


static func is_magnitude(axis: int) -> bool:
	return axis == Id.ACCEL_MAG or axis == Id.GYRO_MAG


static func unit(axis: int) -> String:
	return "G" if is_accel(axis) else "deg/s"


## 波形表示の既定レンジ（±この値）。合成値は0以上なので上側だけ使う。
static func default_range(axis: int) -> float:
	return 2.5 if is_accel(axis) else 300.0


## 1サンプルから指定軸の値を取り出す。
static func value_of(reading: SensorReading, axis: int) -> float:
	match axis:
		Id.AX: return reading.accel.x
		Id.AY: return reading.accel.y
		Id.AZ: return reading.accel.z
		Id.GX: return reading.gyro.x
		Id.GY: return reading.gyro.y
		Id.GZ: return reading.gyro.z
		Id.ACCEL_MAG: return reading.accel.length()
		Id.GYRO_MAG: return reading.gyro.length()
	return 0.0


static func keys_of(axes: Array) -> PackedStringArray:
	var keys := PackedStringArray()
	for axis in axes:
		keys.append(key(axis))
	return keys
