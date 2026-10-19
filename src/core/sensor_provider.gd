class_name SensorProvider
extends RefCounted
## 通信方式ごとの実装が継承する基底クラス。
## 新しい通信方式（例: ESP-NOW）を追加する場合は、このクラスを継承するだけでよい。

signal reading_received(reading: SensorReading)
signal device_list_changed
signal connection_changed(device_id: String, connected: bool)
## 非同期スキャン（BLE など）の結果が届いたとき。devices は SensorDevice の配列。
signal devices_discovered(devices: Array)
## Provider 全体の状態（スキャン中・接続処理中・利用可否など）が変わったとき。
signal provider_status_changed


## この Provider が担当する通信方式。
func get_mode() -> SensorDevice.Mode:
	push_error("get_mode() は派生クラスで実装してください")
	return SensorDevice.Mode.MOCK


## 接続候補デバイスを探索し、SensorDevice の配列を返す。
## 時間のかかる方式（BLE）は、既に分かっている一覧をすぐ返し、
## 結果は後から devices_discovered で知らせる。
func scan() -> Array:
	return []


func open_device(_device_id: String) -> bool:
	return false


func close_device(_device_id: String) -> void:
	pass


## デバイスへ1行のコマンドを送る（PAUSE / RESUME / RATE <Hz> / INFO）。
## 送信に対応していない、または送れなかった場合は false。
func send_command(_device_id: String, _line: String) -> bool:
	return false


## 毎フレーム呼ばれる。受信バッファの読み出しはここで行う。
func poll(_delta: float) -> void:
	pass


## アプリ終了時に呼ばれる。外部プロセスやポートを確実に解放すること。
## 2回呼ばれても安全に作ること。
func shutdown() -> void:
	pass


## この Provider が利用可能か（必要なアドオンが入っているか等）。
func is_available() -> bool:
	return true


## 利用できない場合の理由。UIにそのまま表示する。
func unavailable_reason() -> String:
	return ""


## 現在の状態をひとことで（UI表示用。対処方法を含めてよい）。空なら表示しない。
func status_text() -> String:
	return ""


## 非同期スキャンの実行中か。
func is_scanning() -> bool:
	return false


## 接続処理の途中か（BLE の接続待ちなど）。
func is_connecting(_device_id: String) -> bool:
	return false
