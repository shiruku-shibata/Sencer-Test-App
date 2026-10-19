class_name ThresholdDetector
extends RefCounted
## しきい値ルールにサンプルを流し、「動作した」瞬間を検出する判定器。
##
## 判定の流れ（1サンプルごと）:
##   1. ルールで使う軸の値を取り出し、AxisFilter で平滑化する（smoothing_window）
##   2. ルールごとにラッチ（判定中フラグ）を更新する
##        判定中でない → exceeds() なら判定中にする
##        判定中       → released() なら解除する（= ヒステリシス。しきい値付近で揺れてもチャタリングしない）
##   3. 組み合わせ条件（ANY: どれか1つが判定中 / ALL: 有効な全ルールが判定中）を求める
##   4. 組み合わせ条件が false → true に変わった瞬間（立ち上がり）だけ、
##      不応期の外であれば fired を発火して feed() が true を返す
##
## 不応期（refractory_ms）は「最後に発火したサンプルの timestamp_ms」からの経過で判断する。
## 複数ルールがあるときは、有効なルールの refractory_ms の最大値を使う。
## 不応期中に来た立ち上がりは捨てる（条件が続いていても、不応期明けに遅れて発火はしない）。
## サンプル時刻が最後の発火より前に巻き戻った場合（デバイス切替・ログ再生のやり直し等）は不応期を解除する。
##
## ルールは参照で保持するので、UI でしきい値をドラッグして書き換えると次のサンプルから反映される。
## enabled=false のルールは無視する。有効なルールが1つも無ければ feed() は常に false。

enum Combine { ANY, ALL }        ## ANY: どれか1軸が超えたら / ALL: 全軸が同時に超えたら

const _COMBINE_KEYS := {Combine.ANY: "any", Combine.ALL: "all"}

## 判定が立ち上がった瞬間に発火する。values: axis(int) -> 平滑化後の値（有効なルールの軸のみ）
signal fired(timestamp_ms: int, values: Dictionary)

var rules: Array[ThresholdRule] = []
var combine: int = Combine.ANY
## 移動平均の窓幅（1 = 平滑化なし）。変更すると平滑化の履歴はリセットされる。
var smoothing_window: int = 1:
	set(value):
		smoothing_window = maxi(1, value)
		_filter = AxisFilter.new(smoothing_window)
var trigger_count: int = 0

var _filter := AxisFilter.new(1)
var _rule_active: Array[bool] = []       ## rules と同じ並びのラッチ状態
var _active := false                     ## 組み合わせ条件の状態
var _last_values: Dictionary = {}        ## axis -> 平滑化後の直近値
var _has_fired := false
var _last_fire_ms := 0


## ルール・組み合わせ方法・平滑化をまとめて設定し、状態をリセットする。
## rules の中の ThresholdRule 以外の要素は無視する。
func configure(p_rules: Array, p_combine: int, p_smoothing_window: int = 1) -> void:
	var typed: Array[ThresholdRule] = []
	for r in p_rules:
		if r is ThresholdRule:
			typed.append(r)
	rules = typed
	combine = p_combine if _COMBINE_KEYS.has(p_combine) else Combine.ANY
	smoothing_window = p_smoothing_window
	reset()


## 1サンプルを判定する。判定が立ち上がった瞬間だけ true（fired も発火）。
func feed(reading: SensorReading) -> bool:
	if reading == null:
		return false
	_sync_state_size()

	# 1. 使う軸だけ平滑化（同じ軸を複数ルールで使っても1サンプルにつき1回だけ push する）
	var fresh: Dictionary = {}           ## axis -> この サンプルで有効な値が得られたか
	var enabled_count := 0
	for rule in rules:
		if not rule.enabled:
			continue
		enabled_count += 1
		if fresh.has(rule.axis):
			continue
		var raw := SensorAxis.value_of(reading, rule.axis)
		fresh[rule.axis] = is_finite(raw)
		if is_finite(raw):
			_last_values[rule.axis] = _filter.push(rule.axis, raw)

	# 2. ルールごとのラッチ更新
	for i in rules.size():
		var rule := rules[i]
		if not rule.enabled:
			_rule_active[i] = false
			continue
		if not fresh.get(rule.axis, false):
			continue   # NaN 等で値が得られなかった軸は状態を据え置く
		var v: float = _last_values[rule.axis]
		if not _rule_active[i]:
			_rule_active[i] = rule.exceeds(v)
		elif rule.released(v):
			_rule_active[i] = false

	# 3. 組み合わせ
	var was_active := _active
	_active = _combined(enabled_count)

	# 4. 立ち上がり + 不応期
	if not _active or was_active:
		return false
	var now := reading.timestamp_ms
	if _has_fired and now >= _last_fire_ms and now - _last_fire_ms < _refractory_ms():
		return false
	_has_fired = true
	_last_fire_ms = now
	trigger_count += 1
	fired.emit(now, _fired_values())
	return true


## 組み合わせ条件を満たしている最中か。
func is_active() -> bool:
	return _active


## 指定軸のルール（有効なもの）のどれかが判定中か。
func axis_active(axis: int) -> bool:
	_sync_state_size()
	for i in rules.size():
		if rules[i].enabled and rules[i].axis == axis and _rule_active[i]:
			return true
	return false


## 平滑化後の直近値（まだ値が無い軸は 0.0）。
func last_value(axis: int) -> float:
	return float(_last_values.get(axis, 0.0))


## 最後に発火したサンプルの timestamp_ms（未発火なら -1）。
func last_fire_ms() -> int:
	return _last_fire_ms if _has_fired else -1


## 有効なルールのうち最大の不応期（ミリ秒）。
func effective_refractory_ms() -> int:
	return _refractory_ms()


## 状態とカウントをクリアする（ルール・設定はそのまま）。
func reset() -> void:
	_filter.reset()
	_rule_active.clear()
	_sync_state_size()
	_active = false
	_last_values.clear()
	_has_fired = false
	_last_fire_ms = 0
	trigger_count = 0


## 組み合わせ方法の保存用キー（"any" / "all"）。
static func combine_key(p_combine: int) -> String:
	return _COMBINE_KEYS.get(p_combine, "any")


## 保存用キーから組み合わせ方法を引く。不明は -1。
static func combine_from_key(combine_text: String) -> int:
	for c in _COMBINE_KEYS.keys():
		if _COMBINE_KEYS[c] == combine_text:
			return c
	return -1


## 組み合わせ方法の表示名。
static func combine_label(p_combine: int) -> String:
	match p_combine:
		Combine.ANY: return "どれか1つ（ANY）"
		Combine.ALL: return "すべて同時（ALL）"
	return "?"


func _combined(enabled_count: int) -> bool:
	if enabled_count == 0:
		return false
	var active_count := 0
	for i in rules.size():
		if rules[i].enabled and _rule_active[i]:
			active_count += 1
	if combine == Combine.ALL:
		return active_count == enabled_count
	return active_count > 0


func _refractory_ms() -> int:
	var ms := 0
	for rule in rules:
		if rule.enabled:
			ms = maxi(ms, rule.refractory_ms)
	return ms


func _fired_values() -> Dictionary:
	var values: Dictionary = {}
	for rule in rules:
		if rule.enabled:
			values[rule.axis] = last_value(rule.axis)
	return values


## UI が rules 配列を直接書き換えた場合でもラッチ配列の長さを合わせる。
func _sync_state_size() -> void:
	if _rule_active.size() != rules.size():
		_rule_active.resize(rules.size())
