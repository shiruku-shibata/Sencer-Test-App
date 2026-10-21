extends "res://tests/test_case.gd"
## end-to-end シナリオ:
##   合成信号（静止ノイズ + ジェスチャー）で
##   ThresholdAnalyzer（静止測定 → 試行）→ recommend → build_rule → ThresholdDetector
## と流し、「ジェスチャー N 回 → 検出 N 回（各ジェスチャーで1回ずつ）」「静止区間で誤検出 0」を確かめる。
## 複数の軸・向き・組み合わせ・平滑化・ログ経由・プロファイル経由で同じことを確認する。

const SignalGen := preload("res://tests/helpers/signal_gen.gd")
const Dir := ThresholdRule.Direction
const AX := SensorAxis.Id.AX
const GX := SensorAxis.Id.GX
const GZ := SensorAxis.Id.GZ
const AMAG := SensorAxis.Id.ACCEL_MAG

const GESTURE_MS := 150
const TRIALS := 5
const DETECT_GESTURES := 12


## ジェスチャー i 回目の強さの倍率（1.0〜1.3 で毎回少しずつ違う）
static func _strength(i: int) -> float:
	return 1.0 + 0.3 * float((i * 7) % 5) / 4.0


## 静止測定と試行を行った Analyzer を返す。gesture は func(gen, i) -> Array[SensorReading]。
func _measure(gen: SignalGen, axes: Array, smoothing: int, gesture: Callable) -> ThresholdAnalyzer:
	var a := ThresholdAnalyzer.new()
	a.set_axes(axes)
	a.smoothing_window = smoothing
	a.start_baseline(3000)
	for r in gen.rest(3100):
		a.feed(r)
	assert_true(a.has_baseline(), "静止測定はサンプル時刻で自動終了している")
	assert_eq(a.phase(), ThresholdAnalyzer.Phase.IDLE)
	for i in TRIALS:
		a.start_trial()
		var data: Array[SensorReading] = gen.rest(200)
		data.append_array(gesture.call(gen, i))
		data.append_array(gen.rest(200))
		for r in data:
			a.feed(r)
		a.stop()
	assert_eq(a.trial_count(), TRIALS)
	return a


## 判定用の波形: [{reading, gesture}]（gesture = 何回目のジェスチャーか。静止区間は -1）
func _detection_stream(gen: SignalGen, count: int, gesture: Callable) -> Array:
	var out: Array = []
	for r in gen.rest(1000):
		out.append({"reading": r, "gesture": -1})
	for i in count:
		for r in gesture.call(gen, i):
			out.append({"reading": r, "gesture": i})
		for r in gen.rest(400 + (i % 3) * 150):
			out.append({"reading": r, "gesture": -1})
	return out


## 波形を判定器に流し、ジェスチャーごとの検出回数と静止区間での誤検出数を数える。
func _run(detector: ThresholdDetector, stream: Array, count: int) -> Dictionary:
	var per_gesture: Array[int] = []
	per_gesture.resize(count)
	var false_positives := 0
	for item in stream:
		if detector.feed(item["reading"]):
			var g: int = item["gesture"]
			if g < 0:
				false_positives += 1
			else:
				per_gesture[g] += 1
	return {"per_gesture": per_gesture, "false_positives": false_positives}


## 結果の検証: 全ジェスチャーでちょうど1回、静止区間で 0 回。
func _assert_all_detected_once(result: Dictionary, count: int, label: String) -> void:
	var per: Array[int] = result["per_gesture"]
	var expected: Array[int] = []
	for i in count:
		expected.append(1)
	assert_eq(per, expected, "%s: 各ジェスチャーで1回ずつ検出" % label)
	assert_eq(result["false_positives"], 0, "%s: 静止区間で誤検出しない" % label)


## 長い静止区間だけを流して誤検出が 0 か。
func _assert_no_false_positive_on_rest(detector: ThresholdDetector, gen: SignalGen, label: String) -> void:
	detector.reset()
	var fires := 0
	for r in gen.rest(20000):
		if detector.feed(r):
			fires += 1
	assert_eq(fires, 0, "%s: 20 秒の静止で誤検出 0" % label)


func _detector_for(rules: Array, combine: int, smoothing: int) -> ThresholdDetector:
	var d := ThresholdDetector.new()
	d.configure(rules, combine, smoothing)
	return d


# ------------------------------------------------------------ シナリオ

func test_gyro_z_positive_flick() -> void:
	var gen := SignalGen.new(101)
	gen.gyro_noise = 3.0
	gen.rebound = 0.3     # 振った後の小さな揺り戻し（逆向き）
	var flick := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(0, 0, 200.0 * _strength(i)))
	var a := _measure(gen, [GZ], 1, flick)
	var direction := a.suggest_direction(GZ)
	assert_eq(direction, Dir.POSITIVE)
	var rec := a.recommend(GZ, direction)
	assert_eq(rec["quality"], "good")
	var d := _detector_for([a.build_rule(GZ, direction)], ThresholdDetector.Combine.ANY, 1)
	_assert_all_detected_once(_run(d, _detection_stream(gen, DETECT_GESTURES, flick), DETECT_GESTURES), DETECT_GESTURES, "gZ ＋方向")
	_assert_no_false_positive_on_rest(d, gen, "gZ ＋方向")


func test_accel_x_negative_thrust() -> void:
	var gen := SignalGen.new(202)
	gen.accel_noise = 0.03
	gen.rebound = 0.3
	var thrust := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3(-1.8 * _strength(i), 0, 0), Vector3.ZERO)
	var a := _measure(gen, [AX], 1, thrust)
	var direction := a.suggest_direction(AX)
	assert_eq(direction, Dir.NEGATIVE)
	var rule := a.build_rule(AX, direction)
	assert_lt(rule.threshold, 0.0, "−方向のしきい値はマイナス")
	assert_eq(a.recommend(AX, direction)["quality"], "good")
	var d := _detector_for([rule], ThresholdDetector.Combine.ANY, 1)
	_assert_all_detected_once(_run(d, _detection_stream(gen, DETECT_GESTURES, thrust), DETECT_GESTURES), DETECT_GESTURES, "aX −方向")
	_assert_no_false_positive_on_rest(d, gen, "aX −方向")


func test_accel_magnitude_shake_with_gravity() -> void:
	var gen := SignalGen.new(303)
	gen.rest_accel = Vector3(0, 0, 1.0)   # 合成加速度は静止で 1G
	gen.accel_noise = 0.04
	gen.rebound = 0.3
	var shake := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3(0, 2.0 * _strength(i), 0), Vector3.ZERO)
	var a := _measure(gen, [AMAG], 2, shake)
	var direction := a.suggest_direction(AMAG)
	assert_eq(direction, Dir.POSITIVE)
	var rec := a.recommend(AMAG, direction)
	assert_gt(rec["noise_level"], 1.0, "生の値（重力込み）で扱う")
	assert_eq(rec["quality"], "good")
	var d := _detector_for([a.build_rule(AMAG, direction)], ThresholdDetector.Combine.ANY, 2)
	_assert_all_detected_once(_run(d, _detection_stream(gen, DETECT_GESTURES, shake), DETECT_GESTURES), DETECT_GESTURES, "|a| ＋方向")
	_assert_no_false_positive_on_rest(d, gen, "|a| ＋方向")


func test_gyro_x_absolute_both_ways() -> void:
	var gen := SignalGen.new(404)
	gen.gyro_noise = 4.0
	var twist := func(g: SignalGen, i: int) -> Array[SensorReading]:
		var s := 1.0 if i % 2 == 0 else -1.0     # 左右交互にひねる
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(250.0 * s * _strength(i), 0, 0))
	var a := _measure(gen, [GX], 1, twist)
	var direction := a.suggest_direction(GX)
	assert_eq(direction, Dir.ABSOLUTE, "試行ごとに向きが違うので絶対値")
	assert_eq(a.recommend(GX, direction)["quality"], "good")
	assert_eq(a.recommend(GX, Dir.POSITIVE)["quality"], "overlap", "＋方向だけでは−側の試行を拾えない")
	var d := _detector_for([a.build_rule(GX, direction)], ThresholdDetector.Combine.ANY, 1)
	_assert_all_detected_once(_run(d, _detection_stream(gen, DETECT_GESTURES, twist), DETECT_GESTURES), DETECT_GESTURES, "gX 絶対値")
	_assert_no_false_positive_on_rest(d, gen, "gX 絶対値")


func test_two_axes_all_vs_any() -> void:
	var gen := SignalGen.new(505)
	gen.gyro_noise = 3.0
	gen.accel_noise = 0.03
	var both := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3(1.5 * _strength(i), 0, 0), Vector3(0, 0, 200.0 * _strength(i)))
	var a := _measure(gen, [AX, GZ], 1, both)
	var rules: Array = []
	for axis in [AX, GZ]:
		assert_eq(a.suggest_direction(axis), Dir.POSITIVE)
		assert_eq(a.recommend(axis, Dir.POSITIVE)["quality"], "good")
		rules.append(a.build_rule(axis, Dir.POSITIVE))

	# 判定用: 両軸が動く 6 回 + 片方の軸だけ動く 6 回（ax だけ / gz だけ を交互）
	var mixed := func(g: SignalGen, i: int) -> Array[SensorReading]:
		var k := _strength(i)
		match i % 3:
			0: return g.gesture(GESTURE_MS, Vector3(1.5 * k, 0, 0), Vector3(0, 0, 200.0 * k))
			1: return g.gesture(GESTURE_MS, Vector3(1.5 * k, 0, 0), Vector3.ZERO)
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(0, 0, 200.0 * k))
	var stream := _detection_stream(gen, DETECT_GESTURES, mixed)

	var all_result := _run(_detector_for(rules, ThresholdDetector.Combine.ALL, 1), stream, DETECT_GESTURES)
	var any_result := _run(_detector_for(rules, ThresholdDetector.Combine.ANY, 1), stream, DETECT_GESTURES)
	var expected_all: Array[int] = []
	for i in DETECT_GESTURES:
		expected_all.append(1 if i % 3 == 0 else 0)
	assert_eq(all_result["per_gesture"], expected_all, "ALL: 両軸が同時に動いたときだけ")
	assert_eq(all_result["false_positives"], 0)
	_assert_all_detected_once(any_result, DETECT_GESTURES, "ANY")


func test_smoothing_rejects_single_sample_glitches() -> void:
	var gen := SignalGen.new(606)
	gen.gyro_noise = 3.0
	var flick := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(0, 0, 200.0 * _strength(i)))
	var a := _measure(gen, [GZ], 5, flick)
	var rule := a.build_rule(GZ, Dir.POSITIVE)
	assert_eq(a.recommend(GZ, Dir.POSITIVE)["quality"], "good")

	# 静止中に1サンプルだけの大きなノイズ（通信の乱れ等）が混ざる波形
	var glitchy: Array = []
	for i in 60:
		for r in gen.rest(300):
			glitchy.append({"reading": r, "gesture": -1})
		glitchy.append({"reading": gen.sample(Vector3.ZERO, Vector3(0, 0, 220.0)), "gesture": -1})
	var smoothed := _run(_detector_for([rule], ThresholdDetector.Combine.ANY, 5), glitchy, 0)
	assert_eq(smoothed["false_positives"], 0, "平滑化 5 なら単発ノイズでは判定しない")
	var raw := _run(_detector_for([rule.copy()], ThresholdDetector.Combine.ANY, 1), glitchy, 0)
	assert_gt(float(raw["false_positives"]), 0.0, "平滑化しないと単発ノイズで誤検出する（比較のため）")

	var d := _detector_for([rule], ThresholdDetector.Combine.ANY, 5)
	_assert_all_detected_once(_run(d, _detection_stream(gen, DETECT_GESTURES, flick), DETECT_GESTURES), DETECT_GESTURES, "平滑化 5")


func test_chattering_noise_near_threshold_counts_once() -> void:
	# ジェスチャーのピーク付近にも大きめのノイズが乗る（しきい値付近で何度も上下する）
	# 0.8 秒かけてゆっくり振る（しきい値付近の傾き ≈ 7 deg/s/サンプル）のに対し、ノイズは ±20 deg/s
	var gen := SignalGen.new(707)
	gen.gyro_noise = 20.0
	var slow := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(800, Vector3.ZERO, Vector3(0, 0, 220.0 * _strength(i)))
	var a := _measure(gen, [GZ], 1, slow)
	var rule := a.build_rule(GZ, Dir.POSITIVE)
	rule.refractory_ms = 0   # 不応期に頼らず、ヒステリシスだけでチャタリングを防げること
	assert_gt(rule.hysteresis, 0.0)
	var stream := _detection_stream(gen, DETECT_GESTURES, slow)
	var d := _detector_for([rule], ThresholdDetector.Combine.ANY, 1)
	_assert_all_detected_once(_run(d, stream, DETECT_GESTURES), DETECT_GESTURES, "ヒステリシス")
	# 比較: ヒステリシス 0 だと同じ波形でチャタリングする（このシナリオが意味を持つことの確認）
	var no_h := rule.copy()
	no_h.hysteresis = 0.0
	var chatter := _run(_detector_for([no_h], ThresholdDetector.Combine.ANY, 1), stream, DETECT_GESTURES)
	var total := 0
	for n in chatter["per_gesture"]:
		total += n
	assert_gt(float(total), float(DETECT_GESTURES), "ヒステリシス無しでは複数回判定される")


func test_through_csv_log_and_profile() -> void:
	# 測定 → プロファイル保存 → 読み込み、判定用の波形は CSV に記録 → LogReplay で再生
	var gen := SignalGen.new(808)
	gen.gyro_noise = 3.0
	gen.device_id = "dev-e2e"
	var flick := func(g: SignalGen, i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(0, 0, -200.0 * _strength(i)))
	var a := _measure(gen, [GZ], 3, flick)
	var direction := a.suggest_direction(GZ)
	assert_eq(direction, Dir.NEGATIVE)

	var profile := ThresholdProfile.new()
	profile.name = "e2e テスト"
	profile.smoothing_window = 3
	profile.rules.append(a.build_rule(GZ, direction))
	profile.set_measurement_from(a)
	var dir := make_temp_dir()
	var loaded := ThresholdProfile.load_file(profile.save_to_dir(dir))
	assert_not_null(loaded)
	if loaded == null:
		return

	var logger := LoggingService.new()
	logger.log_dir = dir
	var device := SensorDevice.new("dev-e2e", SensorDevice.Mode.MOCK)
	assert_true(logger.start(device, [GZ]))
	var stream := _detection_stream(gen, DETECT_GESTURES, flick)
	for item in stream:
		logger.write(item["reading"])
	var info := logger.stop()
	assert_eq(info["rows"], stream.size())

	var replayed := LogReplay.load_csv(info["path"])
	assert_eq(replayed.size(), stream.size())
	assert_eq(LogReplay.axes_in(info["path"]), [GZ] as Array[int])
	var replay_stream: Array = []
	for i in replayed.size():
		replay_stream.append({"reading": replayed[i], "gesture": stream[i]["gesture"]})
	_assert_all_detected_once(_run(loaded.make_detector(), replay_stream, DETECT_GESTURES), DETECT_GESTURES, "CSV 再生 + プロファイル")

	# ログから再解析しても、ほぼ同じ推奨値になる（CSV の丸めは gyro 小数3桁）
	var b := ThresholdAnalyzer.new()
	b.set_axes([GZ])
	b.smoothing_window = 3
	b.start_trial()
	for r in replayed:
		b.feed(r)
	b.stop()
	var original_peak := 0.0
	for item in stream:
		original_peak = minf(original_peak, item["reading"].gyro.z)
	assert_almost_eq(float(b.trials()[0][GZ]["min"]), _smoothed_min(stream, 3), 0.01)
	assert_lt(original_peak, -150.0)


## 判定用の波形に平滑化をかけたときの最小値（ログ再解析との比較用）
func _smoothed_min(stream: Array, window: int) -> float:
	var f := AxisFilter.new(window)
	var lowest := INF
	for item in stream:
		lowest = minf(lowest, f.push(GZ, item["reading"].gyro.z))
	return lowest


func test_overlapping_gesture_is_reported() -> void:
	# 静止ノイズと同じくらいの弱い動作 → overlap と判定され、ユーザーに知らせられる
	var gen := SignalGen.new(909)
	gen.gyro_noise = 20.0
	var weak := func(g: SignalGen, _i: int) -> Array[SensorReading]:
		return g.gesture(GESTURE_MS, Vector3.ZERO, Vector3(0, 0, 25.0))
	var a := _measure(gen, [GZ], 1, weak)
	var quality: String = a.recommend(GZ, Dir.POSITIVE)["quality"]
	assert_true(quality == "overlap" or quality == "tight", "弱すぎる動作は good にならない（%s）" % quality)
