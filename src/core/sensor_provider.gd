class_name SensorProvider
extends RefCounted
## 通信方式ごとの実装が継承する基底クラス。
## 新しい通信方式（例: ESP-NOW）を追加する場合は、このクラスを継承するだけでよい。

signal reading_received(reading: SensorReading)
signal device_list_changed
signal connection_changed(device_id: String, connected: bool)


## この Provider が担当する通信方式。
func get_mode() -> SensorDevice.Mode:
	push_error("get_mode() は派生クラスで実装してください")
	return SensorDevice.Mode.MOCK


## 接続候補デバイスを探索し、SensorDevice の配列を返す。
func scan() -> Array:
	return []


func open_device(_device_id: String) -> bool:
	return false


func close_device(_device_id: String) -> void:
	pass


## 毎フレーム呼ばれる。受信バッファの読み出しはここで行う。
func poll(_delta: float) -> void:
	pass


## この Provider が利用可能か（必要なアドオンが入っているか等）。
func is_available() -> bool:
	return true


## 利用できない場合の理由。UIにそのまま表示する。
func unavailable_reason() -> String:
	return ""
