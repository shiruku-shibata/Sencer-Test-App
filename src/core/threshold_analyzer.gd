class_name ThresholdAnalyzer
extends RefCounted
## 「静止測定」と「試行（実際に動かす）」の結果から、推奨しきい値を算出する。
##
## 使い方:
##   analyzer.set_axes([SensorAxis.Id.GZ])
##   analyzer.start_baseline(3000)   # 静止状態で 3 秒 → 自動終了して baseline_finished
##   analyzer.start_trial()          # 動かす → stop() で trial_finished（何回でも）
##   var rec := analyzer.recommend(SensorAxis.Id.GZ, analyzer.suggest_direction(SensorAxis.Id.GZ))
##
## 時間はすべて受信サンプルの timestamp_ms で測る（壁時計は使わない）。
## そのためログ再生（LogReplay）でも実機と同じ結果になる。
## 経過時間は「前のサンプルからの増分」を積算する。時刻が巻き戻ったサンプルは増分 0 として扱う。
##
## smoothing_window は各フェーズの開始時に適用され、判定器（ThresholdDetector）と同じ移動平均を通した値で統計を取る。
## 統計の標準偏差は母標準偏差（n で割る）。サンプル1件なら 0 になる。
## NaN / INF の値はその軸の統計に入れない。

enum Phase { IDLE, BASELINE, TRIAL }

## 推奨値の品質判定・ヒステリシス推奨値の係数（根拠は recommend() のコメント参照）
const NOISE_SIGMA := 4.0                 ## ノイズ上限 = 平均 + 4σ
const TIGHT_NOISE_FACTOR := 1.0          ## 余裕 < ノイズ幅 × 1.0 なら tight
const HYSTERESIS_MARGIN_RATIO := 0.25    ## ヒステリシス = 余裕 × 25%
const HYSTERESIS_MAX_RATIO := 0.5        ## ヒステリシス <= (しきい値 − 静止平均) × 50%
const DIRECTION_DOMINANCE := 2.0         ## 片側の振れが反対側の 2 倍以上ならその向き
const MIN_BASELINE_SAMPLES := 2          ## これ未満の静止測定は insufficient

signal phase_changed(phase: int)
## axis(int) -> {mean, stddev, min, max, count}
signal baseline_finished(stats: Dictionary)
## axis(int) -> {max, min, peak_abs, count, duration_ms}
signal trial_finished(index: int, result: Dictionary)
## 有効なサンプルが1件も無いまま試行が終わり、結果を破棄したとき（trial_finished は出ない）。
signal trial_discarded()

var axes: Array[int] = []
## 移動平均の窓幅（1 = 平滑化なし）。次に開始するフェーズから適用される。
var smoothing_window: int = 1:
	set(value):
		smoothing_window = maxi(1, value)

var _phase: int = Phase.IDLE
var _baseline: Dictionary = {}
var _trials: Array[Dictionary] = []

# --- 実行中フェーズの状態 ---
var _duration_ms := 0                    ## BASELINE: 測定時間 / TRIAL: 最大時間（0 = 無制限）
var _elapsed_ms := 0
var _last_ts := 0
var _sample_count := 0                   ## このフェーズで受け取ったサンプル数
var _filter := AxisFilter.new(1)
var _acc: Dictionary = {}                ## axis -> {count, mean, m2, min, max}


## 計測対象の軸を設定する。内容が変わったときは全結果をクリアし、実行中のフェーズも中止する。
## 未知の軸は無視し、重複は1つにまとめる。
func set_axes(p_axes: Array) -> void:
	var cleaned: Array[int] = []
	for a in p_axes:
		if typeof(a) != TYPE_INT and typeof(a) != TYPE_FLOAT:
			continue
		var axis := int(a)
		if SensorAxis.ALL.has(axis) and not cleaned.has(axis):
			cleaned.append(axis)
	if cleaned == axes:
		return
	axes = cleaned
	clear_all()


## 静止測定を開始する。最初のサンプルから duration_ms 経過したサンプルが来たら自動終了する
## （終了を知らせたサンプル自体は統計に含めない）。実行中のフェーズがあれば先に stop() する。
func start_baseline(duration_ms: int = 3000) -> void:
	_begin(Phase.BASELINE, maxi(1, duration_ms))


## 試行を開始する。max_duration_ms > 0 なら、その時間で自動終了する（0 = stop() まで）。
## 実行中のフェーズがあれば先に stop() する。
func start_trial(max_duration_ms: int = 0) -> void:
	_begin(Phase.TRIAL, maxi(0, max_duration_ms))


## 実行中のフェーズを終了して結果を確定する。
## 有効なサンプルが0件だった場合、静止測定は前回の結果を残し、試行は破棄して trial_discarded を出す。
func stop() -> void:
	match _phase:
		Phase.BASELINE:
			_finish_baseline()
		Phase.TRIAL:
			_finish_trial()


func feed(reading: SensorReading) -> void:
	if _phase == Phase.IDLE or reading == null:
		return
	var ts := reading.timestamp_ms
	if _sample_count > 0:
		_elapsed_ms += maxi(0, ts - _last_ts)
	_last_ts = ts
	if _duration_ms > 0 and _elapsed_ms >= _duration_ms:
		stop()
		return
	_sample_count += 1
	for axis in axes:
		var raw := SensorAxis.value_of(reading, axis)
		if not is_finite(raw):
			continue
		_accumulate(axis, _filter.push(axis, raw))


func phase() -> int:
	return _phase


## 進み具合 0..1（BASELINE と時間指定 TRIAL のみ。それ以外は 0）。
func progress() -> float:
	if _phase == Phase.IDLE or _duration_ms <= 0:
		return 0.0
	return clampf(float(_elapsed_ms) / float(_duration_ms), 0.0, 1.0)


## 実行中フェーズの経過ミリ秒（サンプル時刻基準）。
func elapsed_ms() -> int:
	return _elapsed_ms if _phase != Phase.IDLE else 0


## 静止測定の結果。axis(int) -> {mean, stddev, min, max, count}。未測定なら空。
func baseline() -> Dictionary:
	return _baseline.duplicate(true)


## 試行結果の一覧。各要素は axis(int) -> {max, min, peak_abs, count, duration_ms}。
func trials() -> Array:
	var out: Array = []
	for t in _trials:
		out.append(t.duplicate(true))
	return out


func trial_count() -> int:
	return _trials.size()


func has_baseline() -> bool:
	return not _baseline.is_empty()


func remove_trial(index: int) -> void:
	if index >= 0 and index < _trials.size():
		_trials.remove_at(index)


func clear_trials() -> void:
	_trials.clear()


## 静止測定・試行の結果をすべて消す。実行中のフェーズは結果を出さずに中止する。
func clear_all() -> void:
	_baseline.clear()
	_trials.clear()
	_set_phase(Phase.IDLE)


## 試行結果から、判定の向きを推定する。
## 各試行で「静止平均から上に振れた量」と「下に振れた量」を比べ、
## 片側が反対側の DIRECTION_DOMINANCE 倍以上なら、その試行はその向きとみなす。
## 全試行が同じ向きならその向き、試行ごとに向きが違う／両側に大きく振れるなら ABSOLUTE。
## 試行が無ければ ABSOLUTE。
func suggest_direction(axis: int) -> int:
	var level := 0.0
	if _baseline.has(axis):
		level = float(_baseline[axis]["mean"])
	var votes: Dictionary = {}
	for t in _trials:
		if not t.has(axis) or int(t[axis]["count"]) <= 0:
			continue
		var up := maxf(0.0, float(t[axis]["max"]) - level)
		var down := maxf(0.0, level - float(t[axis]["min"]))
		var d: int = ThresholdRule.Direction.ABSOLUTE
		if up > 0.0 and up >= down * DIRECTION_DOMINANCE:
			d = ThresholdRule.Direction.POSITIVE
		elif down > 0.0 and down >= up * DIRECTION_DOMINANCE:
			d = ThresholdRule.Direction.NEGATIVE
		votes[d] = true
	if votes.size() == 1:
		return int(votes.keys()[0])
	return ThresholdRule.Direction.ABSOLUTE


## 推奨しきい値を計算する。
##
## 戻り値 {threshold, hysteresis, noise_level, weakest_peak, margin, quality,
##        baseline_level, direction, ratio}
##   threshold / noise_level / weakest_peak / baseline_level は「波形上の値」
##     （NEGATIVE ならマイナス側の値、ABSOLUTE なら正の大きさ）
##   margin / hysteresis は大きさ（正の値、overlap なら margin <= 0）
##
## 計算（向きに合わせて値を変換した「判定方向の空間」で行う）:
##   POSITIVE: x = v      NEGATIVE: x = −v      ABSOLUTE: x = |v|
##   noise   = max(静止中の x の最大, x の平均 + 4σ)
##             ABSOLUTE は静止中の範囲 [min(最小, 平均−4σ), max(最大, 平均+4σ)] の絶対値の大きい方
##   weakest = 各試行の x の最大値のうち、最も小さいもの
##   threshold = noise + (weakest − noise) × ratio      ratio は 0..1 に丸める
##   margin    = weakest − noise
##
## quality:
##   "insufficient" … 静止測定（MIN_BASELINE_SAMPLES 件以上）か、この軸の有効な試行が無い
##                    （足りない側は、静止平均 0・ノイズ 0／最弱ピーク = ノイズ として計算した値を返す）
##   "overlap"      … margin <= 0（静止中の揺れと最弱の動作が重なっていて区別できない）
##   "tight"        … margin < ノイズ幅 w（= noise − 静止平均）× TIGHT_NOISE_FACTOR(1.0)
##                    最弱ピークの振れ幅 s（= weakest − 静止平均）は s = margin + w なので、
##                    これは「margin が s の 50% 未満」と同じ意味になる。つまり
##                      ・余裕が、静止中の揺れ幅（平均からノイズ上限まで）より小さい
##                      ・最も弱い動作でも、振れ幅の半分以上が静止ノイズに埋もれている
##                    状態。姿勢の違い・人による振り方の差で誤検出や見逃しが起きやすいので注意喚起する。
##                    （静止ノイズが完全に 0 の場合 w = 0 なので tight にはならない）
##   "good"         … それ以外
##
## hysteresis（推奨）= margin × 25%。ただし (threshold − 静止平均) × 50% を上限とする。
##   ・margin の 1/4 あれば、ピーク付近の細かい揺れ（通常ノイズ幅程度）で解除→再判定を繰り返さない
##   ・解除点が静止平均より上に残るよう上限を設ける（下回ると静止しても解除されず、二度と判定されない）
func recommend(axis: int, direction: int, ratio: float = 0.5) -> Dictionary:
	if ThresholdRule.direction_key(direction).is_empty():
		direction = ThresholdRule.Direction.ABSOLUTE
	var r := clampf(ratio, 0.0, 1.0) if is_finite(ratio) else 0.5

	var has_base := _baseline.has(axis) and int(_baseline[axis]["count"]) >= MIN_BASELINE_SAMPLES
	var level := 0.0
	var noise := 0.0
	if has_base:
		var b: Dictionary = _baseline[axis]
		var mean := float(b["mean"])
		var sd := float(b["stddev"])
		var upper := maxf(float(b["max"]), mean + NOISE_SIGMA * sd)
		var lower := minf(float(b["min"]), mean - NOISE_SIGMA * sd)
		match direction:
			ThresholdRule.Direction.POSITIVE:
				level = mean
				noise = upper
			ThresholdRule.Direction.NEGATIVE:
				level = -mean
				noise = -lower
			_:
				level = absf(mean)
				noise = maxf(absf(upper), absf(lower))

	var weakest := INF
	for t in _trials:
		if not t.has(axis) or int(t[axis]["count"]) <= 0:
			continue
		var peak: float
		match direction:
			ThresholdRule.Direction.POSITIVE:
				peak = float(t[axis]["max"])
			ThresholdRule.Direction.NEGATIVE:
				peak = -float(t[axis]["min"])
			_:
				peak = float(t[axis]["peak_abs"])
		weakest = minf(weakest, peak)
	var has_trials := is_finite(weakest)
	if not has_trials:
		weakest = noise

	var margin := weakest - noise
	var threshold_x := noise + margin * r

	var quality := "good"
	if not has_base or not has_trials:
		quality = "insufficient"
	elif margin <= 0.0:
		quality = "overlap"
	elif margin < TIGHT_NOISE_FACTOR * (noise - level):
		quality = "tight"

	var hysteresis := maxf(0.0, margin * HYSTERESIS_MARGIN_RATIO)
	hysteresis = minf(hysteresis, maxf(0.0, (threshold_x - level) * HYSTERESIS_MAX_RATIO))

	var out_sign := -1.0 if direction == ThresholdRule.Direction.NEGATIVE else 1.0
	return {
		"threshold": threshold_x * out_sign,
		"hysteresis": hysteresis,
		"noise_level": noise * out_sign,
		"weakest_peak": weakest * out_sign,
		"margin": margin,
		"quality": quality,
		"baseline_level": level * out_sign,
		"direction": direction,
		"ratio": r,
	}


## recommend() の結果から ThresholdRule を作る（refractory_ms は既定値）。
func build_rule(axis: int, direction: int, ratio: float = 0.5) -> ThresholdRule:
	var rec := recommend(axis, direction, ratio)
	return ThresholdRule.new(axis, float(rec["threshold"]), int(rec["direction"]),
			float(rec["hysteresis"]))


## 品質の表示名。
static func quality_label(quality: String) -> String:
	match quality:
		"good": return "良好"
		"tight": return "余裕が少ない"
		"overlap": return "静止と区別できない"
		"insufficient": return "測定が足りない"
	return "?"


# ---------------------------------------------------------------- 内部

func _begin(p_phase: int, duration_ms: int) -> void:
	stop()
	_duration_ms = duration_ms
	_elapsed_ms = 0
	_last_ts = 0
	_sample_count = 0
	_filter = AxisFilter.new(smoothing_window)
	_acc.clear()
	_set_phase(p_phase)


func _set_phase(p_phase: int) -> void:
	if p_phase == Phase.IDLE:
		_acc.clear()
		_filter.reset()
	if _phase == p_phase:
		return
	_phase = p_phase
	phase_changed.emit(_phase)


func _accumulate(axis: int, v: float) -> void:
	if not _acc.has(axis):
		_acc[axis] = {"count": 0, "mean": 0.0, "m2": 0.0, "min": INF, "max": -INF}
	var a: Dictionary = _acc[axis]
	# Welford 法（平均と分散を1パスで、桁落ちしにくく求める）
	var n: int = a["count"] + 1
	var delta := v - float(a["mean"])
	var mean := float(a["mean"]) + delta / float(n)
	a["m2"] = float(a["m2"]) + delta * (v - mean)
	a["mean"] = mean
	a["count"] = n
	a["min"] = minf(float(a["min"]), v)
	a["max"] = maxf(float(a["max"]), v)


func _finish_baseline() -> void:
	var stats: Dictionary = {}
	for axis in axes:
		if not _acc.has(axis):
			continue
		var a: Dictionary = _acc[axis]
		var n: int = a["count"]
		stats[axis] = {
			"mean": float(a["mean"]),
			"stddev": sqrt(maxf(0.0, float(a["m2"]) / float(n))),
			"min": float(a["min"]),
			"max": float(a["max"]),
			"count": n,
		}
	# 結果を確定してからフェーズを戻す（phase_changed の受け手が baseline() を読めるように）
	if not stats.is_empty():
		_baseline = stats
	_set_phase(Phase.IDLE)
	if stats.is_empty():
		return   # 有効なサンプルが無い → 前回の結果を残す
	baseline_finished.emit(stats.duplicate(true))


func _finish_trial() -> void:
	var result: Dictionary = {}
	var duration := _elapsed_ms
	for axis in axes:
		if not _acc.has(axis):
			continue
		var a: Dictionary = _acc[axis]
		var lo := float(a["min"])
		var hi := float(a["max"])
		result[axis] = {
			"max": hi,
			"min": lo,
			"peak_abs": maxf(absf(hi), absf(lo)),
			"count": int(a["count"]),
			"duration_ms": duration,
		}
	if not result.is_empty():
		_trials.append(result)
	_set_phase(Phase.IDLE)
	if result.is_empty():
		trial_discarded.emit()
		return
	trial_finished.emit(_trials.size() - 1, result.duplicate(true))
