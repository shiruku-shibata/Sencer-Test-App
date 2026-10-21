class_name MockSensorProvider
extends SensorProvider
## 実機やアドオンが無くても動作確認できるダミーデータ供給元。
## UIの確認、しきい値調整の練習、開発中の回帰確認に使う。
## 波形は「静止中の小さなノイズ ＋ 決まったリズムの振り」（詳しくは DEMO_GESTURE_MS 付近のコメント）。
##
## サンプルの時刻（timestamp_ms）は 10ms 刻みの「仮想時刻」:
##   ・1回の poll() で複数サンプルを出しても、それぞれ 10ms ずつずれた時刻になる
##     （実機が 100Hz で送ってくるのと同じ見え方。解析・判定はこの時刻で時間を測るため）
##   ・必ず単調増加する（巻き戻らない。デバイスを閉じて開き直しても続きから進む）
##   ・実時間（time_source）に追従する。初回や、長く止まっていて RESYNC_MS 以上遅れたときは、
##     その回に出すサンプルの最後が実時間になるよう前へ合わせ直す（その間は「受信が途切れた」扱い）
##   ・停止明けに大量のサンプルをまとめて出さないよう、1回の poll() で出すのは MAX_SAMPLES_PER_POLL まで
##
## コマンド（send_command）は実機ファームと同じ規則で解釈し、同じ書式の '#' 行で答える（DeviceCommand.emulate）。
##   ・PAUSE / RESUME でそのデバイスの送信を止める／再開する
##   ・RATE <Hz> で送信レートを変える。ただしデモの時刻は 10ms 刻みなので、出せるのは最大 100Hz
##     （101〜200 を設定しても実際は 100Hz。応答は設定した値で返す＝設定と実受信の差を確かめられる）
##   ・設定は実機と同じく、接続し直しても保たれる（アプリを再起動すると既定に戻る）

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
var _states: Dictionary = {}        ## device_id -> {"rate": int, "sending": bool}（コマンドで変わる設定）
var _credits: Dictionary = {}       ## device_id -> 送信レートの間引き用の持ち越し


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
	var newly_opened := not _open_ids.has(device_id)
	if newly_opened:
		_open_ids.append(device_id)
	connection_changed.emit(device_id, true)
	if newly_opened:
		_record_device_line(device_id, _info_line(device_id))   # 実機の BLE 購読時と同じく、接続後に情報行を出す
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
			if _should_send(id):
				reading_received.emit(_make_reading(id, _clock_ms))


## 直前に出したサンプルの時刻（まだ出していなければ -1）。
func clock_ms() -> int:
	return _clock_ms


## コマンドを実機ファームと同じ規則で処理し、応答を '#' 行として記録する（device_reply などで読める）。
func send_command(device_id: String, line: String) -> bool:
	if not _open_ids.has(device_id) or line.contains("\n"):
		return false
	var reply := DeviceCommand.emulate(line, _state(device_id), func() -> String: return _info_line(device_id))
	if not reply.is_empty():
		_record_device_line(device_id, reply)
	return true


## そのデバイスの現在の設定 {"rate": int, "sending": bool}（テスト・確認用の複製）。
func device_state(device_id: String) -> Dictionary:
	return _state(device_id).duplicate()


func _state(device_id: String) -> Dictionary:
	if not _states.has(device_id):
		_states[device_id] = {"rate": DeviceCommand.RATE_DEFAULT, "sending": true}
	return _states[device_id]


## 100Hz の刻みごとに、このデバイスのサンプルを出すか（一時停止・送信レートの間引き）。
func _should_send(device_id: String) -> bool:
	var state := _state(device_id)
	if not bool(state["sending"]):
		return false
	var credit: float = float(_credits.get(device_id, 0.0)) + float(state["rate"]) / 100.0
	var send := credit + 1e-9 >= 1.0
	if send:
		credit -= 1.0
	_credits[device_id] = minf(credit, 1.0)   # 100Hz を超える設定は 100Hz で頭打ち（ため込まない）
	return send


## 実機ファーム（firmware/m5stick_sender の情報行）と同じ項目の情報行。
func _info_line(device_id: String) -> String:
	var state := _state(device_id)
	return "# model=DEMO name=%s rate=%d ble=0 fw=demo imu=DEMO sending=%d connected=0 drop_usb=0 drop_ble=0" % [
		device_id, int(state["rate"]), 1 if bool(state["sending"]) else 0
	]


## デモの「振り」: しきい値測定の練習ができるよう、決まったリズムで振る（ランダムには振らない）。
##   ・静止中は小さなノイズだけ（手で構えている程度の揺れ）
##   ・DEMO_GESTURE_PERIOD_MS ごとに DEMO_GESTURE_MS の振りを1回（gZ・gX・aX・aZ、つまり |a| |g| も動く）。
##     強さは DEMO_STRENGTHS の順に少しずつ変わる（「一番弱い振り」が意味を持つように）
##   ・hold_still(ms): その間は振らない（ThresholdScreen が静止測定の開始時に呼ぶ）
##   ・gesture_soon(ms): その時間の後に1回振る（ThresholdScreen が試行の開始時に呼ぶ）
## 時刻はサンプルの timestamp_ms（仮想時刻）で数えるので、開いている全デバイスで同じタイミングになる。
const DEMO_GESTURE_MS := 240
const DEMO_GESTURE_PERIOD_MS := 3500
const DEMO_FIRST_GESTURE_MS := 2000
const DEMO_AFTER_QUIET_MS := 600
const DEMO_STRENGTHS := [1.0, 0.8, 1.15, 0.9, 1.05, 0.85]

var _gesture_start_ms := -1         ## 次の（または実行中の）振りの開始時刻（-1 = まだ決めていない）
var _gesture_count := 0
var _quiet_until_ms := -1


## デモ: これから duration_ms の間は振らない（静止測定用）。実行中の振りも止める。
func hold_still(duration_ms: int) -> void:
	var now := maxi(_clock_ms, 0)
	_quiet_until_ms = now + maxi(0, duration_ms)
	_gesture_start_ms = maxi(_gesture_start_ms, _quiet_until_ms + DEMO_AFTER_QUIET_MS)


## デモ: delay_ms 後に1回振る（試行用）。振っている最中・振らない期間中なら何もしない。
func gesture_soon(delay_ms: int) -> void:
	var now := maxi(_clock_ms, 0)
	if now < _quiet_until_ms or _gesture_active(now):
		return
	_gesture_start_ms = now + maxi(0, delay_ms)


## その時刻に振っている最中か。
func _gesture_active(ts: int) -> bool:
	return _gesture_start_ms >= 0 and ts >= _gesture_start_ms and ts < _gesture_start_ms + DEMO_GESTURE_MS


## その時刻の振りの大きさ（0 = 静止。振りの最中は 0 → 強さ → 0 の半周期の正弦波）。
func _gesture_amount(ts: int) -> float:
	if _gesture_start_ms < 0:
		_gesture_start_ms = ts + DEMO_FIRST_GESTURE_MS
	if ts >= _gesture_start_ms + DEMO_GESTURE_MS:
		# 振り終わった → 次を予約（一時停止などで大きく飛んだら、今から数え直す）
		_gesture_count += 1
		_gesture_start_ms += DEMO_GESTURE_PERIOD_MS
		if ts >= _gesture_start_ms:
			_gesture_start_ms = ts + DEMO_GESTURE_PERIOD_MS
	if not _gesture_active(ts):
		return 0.0
	var strength: float = DEMO_STRENGTHS[_gesture_count % DEMO_STRENGTHS.size()]
	return strength * sin(PI * float(ts - _gesture_start_ms + SAMPLE_INTERVAL_MS) / float(DEMO_GESTURE_MS + SAMPLE_INTERVAL_MS))


func _make_reading(device_id: String, timestamp_ms: int) -> SensorReading:
	var k := _gesture_amount(timestamp_ms)
	var accel := Vector3(
		sin(_phase * 0.3) * 0.02 + randf_range(-0.02, 0.02) + 1.6 * k,
		0.98 + randf_range(-0.015, 0.015),
		randf_range(-0.02, 0.02) - 0.5 * k
	)
	var gyro := Vector3(
		sin(_phase * 0.5) * 2.0 + randf_range(-3.0, 3.0) + 80.0 * k,
		randf_range(-3.0, 3.0) - 40.0 * k,
		sin(_phase * 0.2) * 3.0 + randf_range(-2.5, 2.5) + 260.0 * k
	)
	return SensorReading.new(device_id, timestamp_ms, accel, gyro)
