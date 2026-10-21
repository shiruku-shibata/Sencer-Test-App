class_name SensorDevice
extends RefCounted
## 接続対象のセンサーデバイス1台分の情報。

enum Mode { SERIAL, BLE, MOCK }

var id: String                ## 内部キー（有線: ポート名 / BLE: bleak のアドレス。macOS は UUID、Windows/Linux は MAC）
var nickname: String = ""     ## ユーザーが付ける表示名
var label: String = ""        ## 機器側の名前（BLE の広告名など）。ニックネーム未設定時の表示名
var mode: Mode = Mode.SERIAL
var connected: bool = false
var rssi: int = 0             ## BLE の電波強度 [dBm]。0 = 不明（有線・デモ・圏外）
var last_received_ms: int = 0
var sample_count: int = 0
var rate_hz: float = 0.0


func _init(p_id: String = "", p_mode: Mode = Mode.SERIAL, p_label: String = "") -> void:
	id = p_id
	mode = p_mode
	label = p_label


## UIに表示する名前。ニックネーム → 機器名（label）→ ID の順で使う。
func display_name() -> String:
	if not nickname.is_empty():
		return nickname
	if not label.is_empty():
		return label
	return id


static func mode_label(p_mode: Mode) -> String:
	match p_mode:
		Mode.SERIAL: return "有線"
		Mode.BLE: return "BLE"
		Mode.MOCK: return "デモ"
	return "不明"
