extends "res://tests/test_case.gd"
## しきい値測定画面（ThresholdScreen）を、デモデバイス（MockSensorProvider）とつないで操作するテスト。
## README「はじめかた」の手順がそのまま通ること、測定の中止・途切れ、推奨値の適用の確認を見る。
##
## SensorManager はツリーに入れない（_ready で実機やブリッジを探しに行かないように）。
## デモの Provider だけを登録し、時刻は time_source を差し替えて 10ms ずつ進める。
## 画面はツリーに入れない（フレームを進めないので _process・_input は呼ばれない）。
## 確認ダイアログはツリー外では表示できない（エンジンのエラーになる）ので、ダイアログの中身と
## OK/キャンセル時の処理（_confirm_ok / _on_confirm_result）で確かめる。
## 軸は _apply_axes() で直接決める（AxisSelector.set_axes() はユーザー設定に保存するので使わない）。

const GZ := SensorAxis.Id.GZ
const AX := SensorAxis.Id.AX
const AMAG := SensorAxis.Id.ACCEL_MAG
const Phase := ThresholdAnalyzer.Phase

var _manager: SensorManager
var _mock: MockSensorProvider
var _screen: ThresholdScreen
var _now := 0


func before_each() -> void:
	seed(12345)
	_now = 1000
	_manager = SensorManager.new()
	_mock = MockSensorProvider.new()
	_mock.time_source = func() -> int: return _now
	_manager._add_provider(_mock)
	for d in _mock.scan():
		_manager.registry.upsert(d)
	_mock.open_device("demo-01")
	_screen = ThresholdScreen.new()
	_screen.setup(_manager, null)


func after_each() -> void:
	_screen.free()
	_manager.free()
	_mock.time_source = Callable()   # このテストを参照するラムダを外して循環参照を切る
	_mock = null


## デモを ms ミリ秒ぶん進める（10ms ごとに poll）。
func _run(ms: int) -> void:
	for _i in ms / 10:
		_now += 10
		_mock.poll(0.01)


func _rec(axis: int) -> Dictionary:
	return _screen._analyzer.recommend(axis, int(_screen._directions[axis]), _screen._ratio)


## README の手順: 軸を選ぶ → 静止測定（3 秒）→ 試行（開始 → 振り → 終了）× 5 → 推奨値。
func _readme_flow(axes: Array) -> void:
	_screen._apply_axes(axes)
	assert_eq(_screen._selected_id, "demo-01")
	_run(700)   # 適当なタイミングで始める
	_screen._on_baseline_pressed()
	_run(3200)
	assert_eq(_screen._analyzer.phase(), Phase.IDLE, "静止測定は 3 秒で終わる")
	assert_true(_screen._analyzer.has_baseline())
	for i in 5:
		_screen._toggle_trial()           # Space キーと同じ
		_run(1000 + 150 * i)              # 人が「振ったな」と思って止めるまで
		_screen._toggle_trial()
		_run(400)
	assert_eq(_screen._analyzer.trial_count(), 5)


# ------------------------------------------------------------ README「はじめかた」（PR #11 レビュー 中-4）

## 以前はデモの振りがランダムで、静止測定にも入るため、どの軸でも品質が「重なり」になっていた。
func test_readme_flow_with_demo_gives_good_recommendation() -> void:
	_readme_flow([GZ, AMAG, AX])
	for axis in [GZ, AMAG, AX]:
		var rec := _rec(axis)
		assert_eq(rec["quality"], "good", "%s の品質（%s）" % [SensorAxis.label(axis), rec])
	assert_eq(int(_screen._directions[GZ]), ThresholdRule.Direction.POSITIVE, "gZ は＋方向と推定される")


func test_readme_flow_then_judge_test_fires_once_per_demo_swing() -> void:
	_readme_flow([GZ])
	_screen._apply_recommendation()
	assert_false(_screen._confirm_ok.is_valid(), "品質が良好なら確認なしで適用")
	var rule: ThresholdRule = _screen._rules[GZ]
	assert_almost_eq(rule.threshold, float(_rec(GZ)["threshold"]), 0.001)
	var swings_before := _mock._gesture_count
	var fires_before := _screen._detector.trigger_count
	_run(15000)
	var swings := _mock._gesture_count - swings_before
	assert_ge(float(swings), 3.0, "15 秒に 3 回以上は振る")
	assert_eq(_screen._detector.trigger_count - fires_before, swings, "振り 1 回につき判定 1 回（静止中の誤検出なし）")


func test_demo_does_not_swing_during_baseline() -> void:
	_screen._apply_axes([GZ])
	for start in [0, 900, 1900, 2900]:   # 振りの周期のどこで押しても
		_run(start)
		_screen._on_baseline_pressed()
		_run(3200)
		var b: Dictionary = _screen._analyzer.baseline()[GZ]
		assert_lt(float(b["max"]), 20.0, "静止測定に振りが入らない（開始 +%d ms）" % start)


# ------------------------------------------------------------ 中止ボタン・途切れ（PR #11 レビュー 中-2）

func test_cancel_buttons_stop_running_phase_without_result() -> void:
	_readme_flow([GZ])
	var before := _screen._analyzer.baseline()
	assert_true(_screen._baseline_cancel_button.disabled, "実行中でなければ押せない")
	assert_true(_screen._trial_cancel_button.disabled)

	_screen._on_baseline_pressed()
	_run(500)
	assert_false(_screen._baseline_cancel_button.disabled)
	_screen._baseline_cancel_button.pressed.emit()
	assert_eq(_screen._analyzer.phase(), Phase.IDLE)
	assert_eq(_screen._analyzer.baseline(), before, "前の静止測定が残る")
	assert_contains(_screen._message.text, "中止")

	_screen._toggle_trial()
	_run(800)
	assert_false(_screen._trial_cancel_button.disabled)
	_screen._trial_cancel_button.pressed.emit()
	assert_eq(_screen._analyzer.phase(), Phase.IDLE)
	assert_eq(_screen._analyzer.trial_count(), 5, "中止した試行は数えない")
	assert_false(_screen._axis_selector._buttons[GZ].disabled, "軸のロックも解ける")


## デモに PAUSE を送る（＝本体ボタンで一時停止）と、静止測定は途切れとして中止され、理由が出る。
func test_pause_during_baseline_interrupts_with_message() -> void:
	_screen._apply_axes([GZ])
	_run(500)
	_screen._on_baseline_pressed()
	_run(300)
	_mock.send_command("demo-01", "PAUSE")
	_run(5000)
	assert_eq(_screen._analyzer.phase(), Phase.BASELINE, "一時停止中は止まったまま（中止ボタンで抜けられる）")
	_mock.send_command("demo-01", "RESUME")
	_run(100)
	assert_eq(_screen._analyzer.phase(), Phase.IDLE)
	assert_false(_screen._analyzer.has_baseline(), "途切れる前の 0.3 秒分で静止測定を確定しない")
	assert_contains(_screen._message.text, "途切れ")


# ------------------------------------------------------------ 推奨値の適用（PR #11 レビュー 低-2）

func test_apply_overlap_recommendation_asks_first() -> void:
	allow_engine_errors()   # ツリー外でダイアログを開こうとしたエラー（上のコメント参照）
	_screen._apply_axes([GZ])
	_screen._analyzer.restore_measurement({
		"baseline": {GZ: {"mean": 0.0, "stddev": 20.0, "min": -100.0, "max": 100.0, "count": 300}},
		"trials": [{GZ: {"max": 60.0, "min": -5.0, "count": 30}}],
	})
	_screen._refresh_measurement()
	assert_eq(_rec(GZ)["quality"], "overlap")
	var before: ThresholdRule = _screen._rules[GZ]
	_screen._apply_recommendation()
	assert_true(_screen._confirm_ok.is_valid(), "重なりなら確認を出す")
	assert_contains(_screen._confirm.dialog_text, SensorAxis.label(GZ))
	assert_eq(_screen._rules[GZ], before, "確認するまでは適用しない")
	_screen._on_confirm_result(false)
	assert_eq(_screen._rules[GZ], before, "キャンセルなら適用しない")
	_screen._apply_recommendation()
	_screen._on_confirm_result(true)
	assert_ne(_screen._rules[GZ], before, "OK なら適用する")
	assert_almost_eq(_screen._rules[GZ].threshold, float(_rec(GZ)["threshold"]), 0.001)
