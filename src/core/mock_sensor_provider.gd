class_name MockSensorProvider
extends SensorProvider
## 実機やアドオンが無くても動作確認できるダミーデータ供給元。
## UIの確認、しきい値調整の練習、開発中の回帰確認に使う。
##
## サンプルの時刻（timestamp_ms）は 10ms 刻みの「仮想時刻」:
##   ・1回の poll() で複数サンプルを出しても、それぞれ 10ms ずつずれた時刻になる
##     （実機が 100Hz で送ってくるのと同じ見え方。解析・判定はこの時刻で時間を測るため）
##   ・必ず単調増加する（巻き戻らない。デバイスを閉じて開き直しても続きから進む）
##   ・実時間（time_source）に追従する。初回や、長く止まっていて RESYNC_MS 以上遅れたときは、
##     その回に出すサンプルの最後が実時間になるよう前へ合わせ直す（その間は「受信が途切れた」扱い）
##   ・停止明けに大量のサンプルをまとめて出さないよう、1回の poll() で出すのは MAX_SAMPLES_PER_POLL まで

const SAMPLE_INTERVAL_SEC := 0.01   ## 100Hz 相当
const SAMPLE_INTERVAL_MS := 10
const RESYNC_MS := 200              ## 仮想時刻が実時間からこれ以上遅れたら合わせ直す
const MAX_SAMPLES_PER_POLL := 50    ## 1回の poll() で出すサンプル数の上限（0.5 秒分）
const DEVICE_IDS := ["demo-01", "demo-02"]

## 実時間（ミリ秒）を返す関数。テストでは差し替えて時間を進める。
var time_source: Callable = Time.get_ticks_msec

var _open_ids: Array[String] = []
var _elapsed := 0.0
var _phase := 0.0
var _clock_ms := -1                 ## 直前に出したサンプルの時刻（-1 = まだ1つも出していない）


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.MOCK


func scan() -> Array:
	var devices: Array = []
	for id in DEVICE_IDS:
		var device := SensorDevice.new(id, SensorDevice.Mode.MOCK)
		device.connected = _open_ids.has(id)
		devices.append(device)
	device_list_changed.emit()
	return devices


func open_device(device_id: String) -> bool:
	if not DEVICE_IDS.has(device_id):
		return false
	if not _open_ids.has(device_id):
		_open_ids.append(device_id)
	connection_changed.emit(device_id, true)
	return true


func close_device(device_id: String) -> void:
	_open_ids.erase(device_id)
	connection_changed.emit(device_id, false)


func poll(delta: float) -> void:
	if _open_ids.is_empty():
		return
	_elapsed += delta
	var count := 0
	# 0.05 秒 = 0.01 × 5 が浮動小数の誤差で 4 回分になるのを防ぐため、ごく小さい許容誤差を入れる
	while _elapsed + 1e-9 >= SAMPLE_INTERVAL_SEC:
		_elapsed -= SAMPLE_INTERVAL_SEC
		count += 1
	if count == 0:
		return
	count = mini(count, MAX_SAMPLES_PER_POLL)   # 超えた分は「途切れた」ものとして捨てる

	var now: int = time_source.call()
	if _clock_ms < 0 or now - _clock_ms > RESYNC_MS:
		# この回の最後のサンプルがちょうど実時間になるように合わせる（ただし巻き戻さない）
		_clock_ms = maxi(_clock_ms, now - count * SAMPLE_INTERVAL_MS)

	for _i in count:
		_clock_ms += SAMPLE_INTERVAL_MS
		_phase += 0.06
		for id in _open_ids:
			reading_received.emit(_make_reading(id, _clock_ms))


## 直前に出したサンプルの時刻（まだ出していなければ -1）。
func clock_ms() -> int:
	return _clock_ms


func _make_reading(device_id: String, timestamp_ms: int) -> SensorReading:
	# ときどき大きな振り（ジェスチャー相当のピーク）を混ぜる
	var spike := 0.0
	if randf() < 0.012:
		spike = randf_range(0.6, 2.2)
	var accel := Vector3(
		sin(_phase) * 0.25 + randf_range(-0.04, 0.04) + spike,
		0.98 + sin(_phase * 0.7) * 0.12 + randf_range(-0.03, 0.03),
		cos(_phase * 1.3) * 0.18 + randf_range(-0.035, 0.035) - spike * 0.4
	)
	var gyro := Vector3(
		sin(_phase * 1.8) * 60.0 + randf_range(-7.0, 7.0) + spike * 120.0,
		cos(_phase * 1.1) * 45.0 + randf_range(-6.0, 6.0),
		sin(_phase * 0.5) * 30.0 + randf_range(-5.0, 5.0)
	)
	return SensorReading.new(device_id, timestamp_ms, accel, gyro)
