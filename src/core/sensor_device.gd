class_name SensorDevice
extends RefCounted
## 接続対象のセンサーデバイス1台分の情報。

enum Mode { SERIAL, BLE, MOCK }

var id: String                ## 内部キー（有線: ポート名 / BLE: MACアドレス）
var nickname: String = ""     ## ユーザーが付ける表示名（未設定なら id を表示）
var mode: Mode = Mode.SERIAL
var connected: bool = false
var last_received_ms: int = 0
var sample_count: int = 0
var rate_hz: float = 0.0


func _init(p_id: String = "", p_mode: Mode = Mode.SERIAL) -> void:
	id = p_id
	mode = p_mode


## UIに表示する名前。ニックネーム未設定時はIDをそのまま見せる。
func display_name() -> String:
	return nickname if not nickname.is_empty() else id


static func mode_label(p_mode: Mode) -> String:
	match p_mode:
		Mode.SERIAL: return "有線"
		Mode.BLE: return "BLE"
		Mode.MOCK: return "デモ"
	return "不明"
