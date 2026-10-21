class_name ThresholdRule
extends RefCounted
## 1軸ぶんの「しきい値ルール」。どの軸が、どちら向きに、いくつを超えたら判定するかを表す。
##
## 判定の向き（Direction）:
##   POSITIVE : 値 >= threshold で判定（threshold は波形上の実際の値）
##   NEGATIVE : 値 <= threshold で判定（threshold は波形上の実際の値。通常はマイナス）
##   ABSOLUTE : |値| >= threshold で判定（threshold は正の大きさ。±threshold の線を引く）
##
## 「以上 / 以下」で判定するので、threshold ちょうどの値も判定に入る。
## 判定の解除（released）は、しきい値から hysteresis だけ戻ったとき（未満 / 超）。
## hysteresis = 0 のとき exceeds と released はちょうど反対になる。

enum Direction { POSITIVE, NEGATIVE, ABSOLUTE }

## 保存形式（JSON）での向きの表記。変更すると過去のプロファイルが読めなくなるので固定。
const _DIRECTION_KEYS := {
	Direction.POSITIVE: "positive",
	Direction.NEGATIVE: "negative",
	Direction.ABSOLUTE: "absolute",
}

const DEFAULT_REFRACTORY_MS := 200

var axis: int = SensorAxis.Id.AX         ## SensorAxis.Id
var enabled := true
## POSITIVE/NEGATIVE: 波形上の実際の値（NEGATIVE なら通常マイナス）
## ABSOLUTE: 正の大きさ（±threshold を超えたら判定）
var threshold: float = 0.0
var direction: int = Direction.ABSOLUTE
## 判定解除はしきい値からこの量だけ戻ったとき（チャタリング防止）。負の値は 0 として扱う。
var hysteresis: float = 0.0
## 一度判定したら、この時間（ミリ秒）は次の判定をしない。
var refractory_ms: int = DEFAULT_REFRACTORY_MS


func _init(p_axis: int = SensorAxis.Id.AX, p_threshold: float = 0.0,
		p_direction: int = Direction.ABSOLUTE, p_hysteresis: float = 0.0,
		p_refractory_ms: int = DEFAULT_REFRACTORY_MS) -> void:
	axis = p_axis
	threshold = p_threshold
	direction = p_direction
	hysteresis = p_hysteresis
	refractory_ms = p_refractory_ms


## 値がしきい値を超えているか（判定に入る条件）。NaN は常に false。
func exceeds(value: float) -> bool:
	if is_nan(value):
		return false
	match direction:
		Direction.POSITIVE:
			return value >= threshold
		Direction.NEGATIVE:
			return value <= threshold
		_:
			return absf(value) >= absf(threshold)


## 値がしきい値から hysteresis だけ戻ったか（判定を解除する条件）。NaN は常に false。
func released(value: float) -> bool:
	if is_nan(value):
		return false
	var h := _effective_hysteresis()
	match direction:
		Direction.POSITIVE:
			return value < threshold - h
		Direction.NEGATIVE:
			return value > threshold + h
		_:
			return absf(value) < absf(threshold) - h


## 波形に引くしきい値の線（ABSOLUTE は [t, -t]）。
func line_values() -> PackedFloat32Array:
	if direction == Direction.ABSOLUTE:
		var t := absf(threshold)
		return PackedFloat32Array([t, -t])
	return PackedFloat32Array([threshold])


## 波形に引く「解除ライン」（しきい値から hysteresis 戻った位置）。hysteresis が 0 なら空。
func release_line_values() -> PackedFloat32Array:
	var h := _effective_hysteresis()
	if h <= 0.0:
		return PackedFloat32Array()
	match direction:
		Direction.POSITIVE:
			return PackedFloat32Array([threshold - h])
		Direction.NEGATIVE:
			return PackedFloat32Array([threshold + h])
		_:
			var r := absf(threshold) - h
			return PackedFloat32Array([r, -r])


## 人が読む1行の説明（例: "ジャイロ Z ≥ 180.0 deg/s"）。
func summary() -> String:
	var u := SensorAxis.unit(axis)
	match direction:
		Direction.POSITIVE:
			return "%s ≥ %s %s" % [SensorAxis.label(axis), _num(threshold), u]
		Direction.NEGATIVE:
			return "%s ≤ %s %s" % [SensorAxis.label(axis), _num(threshold), u]
		_:
			return "|%s| ≥ %s %s" % [SensorAxis.label(axis), _num(absf(threshold)), u]


## 同じ内容の別インスタンスを返す。
func copy() -> ThresholdRule:
	var r := ThresholdRule.new(axis, threshold, direction, hysteresis, refractory_ms)
	r.enabled = enabled
	return r


## 保存用の辞書。軸と向きは文字列キー（"gz", "positive" 等）で保存する。
## NaN / INF は JSON にできないため 0 に置き換える。
func to_dict() -> Dictionary:
	return {
		"axis": SensorAxis.key(axis),
		"enabled": enabled,
		"threshold": _finite_or_zero(threshold),
		"direction": direction_key(direction),
		"hysteresis": _finite_or_zero(hysteresis),
		"refractory_ms": refractory_ms,
	}


## 辞書からルールを作る。軸や向きが読めない・数値が不正なときは null。
## 軸・向きは文字列キーのほか、数値（enum 値）も受け付ける。
static func from_dict(d: Dictionary) -> ThresholdRule:
	var p_axis := _parse_axis(d.get("axis", null))
	if p_axis < 0:
		return null
	var p_direction := _parse_direction(d.get("direction", direction_key(Direction.ABSOLUTE)))
	if p_direction < 0:
		return null
	var p_threshold: Variant = _parse_number(d.get("threshold", 0.0))
	var p_hysteresis: Variant = _parse_number(d.get("hysteresis", 0.0))
	var p_refractory: Variant = _parse_number(d.get("refractory_ms", DEFAULT_REFRACTORY_MS))
	if p_threshold == null or p_hysteresis == null or p_refractory == null:
		return null
	var r := ThresholdRule.new(p_axis, float(p_threshold), p_direction,
			maxf(0.0, float(p_hysteresis)), maxi(0, int(p_refractory)))
	var p_enabled: Variant = d.get("enabled", true)
	r.enabled = bool(p_enabled) if typeof(p_enabled) == TYPE_BOOL else true
	return r


## 向きの表示名（"＋方向" / "−方向" / "絶対値"）。
static func direction_label(p_direction: int) -> String:
	match p_direction:
		Direction.POSITIVE: return "＋方向"
		Direction.NEGATIVE: return "−方向"
		Direction.ABSOLUTE: return "絶対値"
	return "?"


## 向きの保存用キー（"positive" / "negative" / "absolute"）。不明は ""。
static func direction_key(p_direction: int) -> String:
	return _DIRECTION_KEYS.get(p_direction, "")


## 保存用キーから向きを引く。不明は -1。
static func direction_from_key(direction_text: String) -> int:
	for d in _DIRECTION_KEYS.keys():
		if _DIRECTION_KEYS[d] == direction_text:
			return d
	return -1


func _effective_hysteresis() -> float:
	return hysteresis if is_finite(hysteresis) and hysteresis > 0.0 else 0.0


static func _parse_axis(v: Variant) -> int:
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			return SensorAxis.from_key(String(v))
		TYPE_INT, TYPE_FLOAT:
			var i := int(v)
			return i if SensorAxis.ALL.has(i) and float(i) == float(v) else -1
	return -1


static func _parse_direction(v: Variant) -> int:
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			return direction_from_key(String(v))
		TYPE_INT, TYPE_FLOAT:
			var i := int(v)
			return i if _DIRECTION_KEYS.has(i) and float(i) == float(v) else -1
	return -1


## 数値（有限）なら float、そうでなければ null。
static func _parse_number(v: Variant) -> Variant:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return null
	var f := float(v)
	if not is_finite(f):
		return null
	return f


static func _finite_or_zero(v: float) -> float:
	return v if is_finite(v) else 0.0


static func _num(v: float) -> String:
	return String.num(v, 3)
