class_name ThresholdProfile
extends RefCounted
## しきい値の設定一式（ルール・組み合わせ・平滑化・測定結果）を JSON として保存・共有する。
##
## JSON の例:
##   {
##     "format_version": 1,
##     "app": "Sensor Test App",
##     "name": "振り下ろし",
##     "device_name": "M5-Sensor-1A2B",
##     "created_at": "2026-10-20T12:34:56",
##     "combine": "any",
##     "smoothing_window": 3,
##     "sample_rate_hz": 100.0,
##     "rules": [{"axis": "gz", "enabled": true, "threshold": 180.0, "direction": "positive",
##                "hysteresis": 30.0, "refractory_ms": 200}],
##     "measurement": {"baseline": {"gz": {"mean": 0.1, "stddev": 2.0, ...}},
##                     "trials": [{"gz": {"max": 250.0, "min": -40.0, ...}}]},
##     "note": ""
##   }
##
## 軸は SensorAxis のキー文字列（"gz" 等）で保存する。
## measurement はメモリ上では ThresholdAnalyzer と同じ形（軸 = SensorAxis.Id の int）で持ち、
## JSON にするときだけ軸キー文字列に変換する。

const DIR := "user://thresholds"
const FORMAT_VERSION := 1
const APP_NAME := "Sensor Test App"
## 保存ファイル名（拡張子を除く）の最大文字数
const MAX_FILE_NAME_LENGTH := 64

var name: String = ""
var device_name: String = ""
var rules: Array[ThresholdRule] = []
var combine: int = ThresholdDetector.Combine.ANY
var smoothing_window: int = 1
var sample_rate_hz: float = 0.0
## 任意: {baseline: axis(int) -> {...}, trials: [axis(int) -> {...}, ...]}
var measurement: Dictionary = {}
var created_at: String = ""
var note: String = ""


func _init() -> void:
	created_at = Time.get_datetime_string_from_system()


## ThresholdAnalyzer の測定結果を measurement に取り込む。
func set_measurement_from(analyzer: ThresholdAnalyzer) -> void:
	measurement = {"baseline": analyzer.baseline(), "trials": analyzer.trials()}


## この設定と同じ判定をする ThresholdDetector を作る（ルールはコピーする）。
func make_detector() -> ThresholdDetector:
	var copies: Array = []
	for r in rules:
		copies.append(r.copy())
	var detector := ThresholdDetector.new()
	detector.configure(copies, combine, smoothing_window)
	return detector


func to_dict() -> Dictionary:
	var rule_dicts: Array = []
	for r in rules:
		rule_dicts.append(r.to_dict())
	return {
		"format_version": FORMAT_VERSION,
		"app": APP_NAME,
		"name": name,
		"device_name": device_name,
		"created_at": created_at,
		"combine": ThresholdDetector.combine_key(combine),
		"smoothing_window": smoothing_window,
		"sample_rate_hz": sample_rate_hz if is_finite(sample_rate_hz) else 0.0,
		"rules": rule_dicts,
		"measurement": _measurement_to_saved(measurement),
		"note": note,
	}


## 辞書からプロファイルを作る。形式が不正（必須の format_version が無い・未来の版・
## rules が配列でない・読めないルールがある 等）なら null。
static func from_dict(d: Dictionary) -> ThresholdProfile:
	var version: Variant = d.get("format_version", null)
	if typeof(version) != TYPE_INT and typeof(version) != TYPE_FLOAT:
		return null
	if int(version) < 1 or int(version) > FORMAT_VERSION:
		return null
	var p := ThresholdProfile.new()
	p.name = _get_string(d, "name", "")
	p.device_name = _get_string(d, "device_name", "")
	p.created_at = _get_string(d, "created_at", "")
	p.note = _get_string(d, "note", "")
	var c: Variant = d.get("combine", "any")
	if typeof(c) == TYPE_STRING:
		p.combine = ThresholdDetector.combine_from_key(c)
	elif typeof(c) == TYPE_INT or typeof(c) == TYPE_FLOAT:
		p.combine = int(c) if int(c) in [ThresholdDetector.Combine.ANY, ThresholdDetector.Combine.ALL] else -1
	else:
		p.combine = -1
	if p.combine < 0:
		return null
	p.smoothing_window = maxi(1, int(_get_number(d, "smoothing_window", 1.0)))
	p.sample_rate_hz = maxf(0.0, _get_number(d, "sample_rate_hz", 0.0))

	var raw_rules: Variant = d.get("rules", [])
	if typeof(raw_rules) != TYPE_ARRAY:
		return null
	for rd in raw_rules:
		if typeof(rd) != TYPE_DICTIONARY:
			return null
		var rule := ThresholdRule.from_dict(rd)
		if rule == null:
			return null
		p.rules.append(rule)

	var m: Variant = d.get("measurement", {})
	p.measurement = _measurement_from_saved(m) if typeof(m) == TYPE_DICTIONARY else {}
	return p


func to_json() -> String:
	return JSON.stringify(to_dict(), "  ", false)


## JSON 文字列から読み込む。不正なら null（エラー出力もしない）。
static func from_json(text: String) -> ThresholdProfile:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return null
	return from_dict(data)


## DIR に保存して保存先パスを返す（失敗は ""）。ファイル名は name から安全な名前を作る。
## 同じ名前のファイルがあれば上書きする。
func save() -> String:
	return save_to_dir(DIR)


## 任意のフォルダに保存する（テストや書き出し用）。フォルダが無ければ作る。
func save_to_dir(dir_path: String) -> String:
	if not _ensure_dir(dir_path):
		return ""
	var path := dir_path.path_join(safe_file_name(name) + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("しきい値プロファイルを保存できませんでした: %s" % path)
		return ""
	file.store_string(to_json())
	file.close()
	return path


static func load_file(path: String) -> ThresholdProfile:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	return from_json(text)


## DIR 内のプロファイル一覧（新しい順）。[{name, path, modified, file, created_at}]
##   name: プロファイル名（読めないファイルはファイル名）/ modified: 更新日時（UNIX 秒）
static func list_files() -> Array:
	return list_files_in(DIR)


## 任意のフォルダのプロファイル一覧（新しい順。更新日時 → created_at → ファイル名の順で比較）。
static func list_files_in(dir_path: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir_path):
		return out
	for file_name in DirAccess.get_files_at(dir_path):
		if not file_name.ends_with(".json"):
			continue
		var path := dir_path.path_join(file_name)
		var p := load_file(path)
		out.append({
			"name": p.name if p != null and not p.name.is_empty() else file_name.get_basename(),
			"path": path,
			"modified": FileAccess.get_modified_time(path),
			"file": file_name,
			"created_at": p.created_at if p != null else "",
		})
	out.sort_custom(_newer_first)
	return out


static func delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## OS のファイラーで保存フォルダを開く。
static func open_folder() -> void:
	_ensure_dir(DIR)
	OS.shell_open(ProjectSettings.globalize_path(DIR))


## プロファイル名から安全なファイル名（拡張子なし）を作る。日本語はそのまま使う。
## / \ : * ? " < > | と制御文字は "_" に置き換え、先頭の "." や Windows の予約名も避ける。
static func safe_file_name(text: String) -> String:
	var s := ""
	for ch in text.strip_edges():
		if ch.unicode_at(0) < 0x20 or ch.unicode_at(0) == 0x7f or ch in "/\\:*?\"<>|":
			s += "_"
		else:
			s += ch
	while s.begins_with("."):
		s = "_" + s.substr(1)
	s = s.strip_edges()
	if s.length() > MAX_FILE_NAME_LENGTH:
		s = s.substr(0, MAX_FILE_NAME_LENGTH)
	if s.is_empty():
		s = "profile"
	if s.to_upper().get_basename() in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4",
			"LPT1", "LPT2", "LPT3"]:
		s = "_" + s
	return s


# ------------------------------------------------------------ コード生成

## ゲーム側にそのまま貼れる判定コードを返す。lang: "cpp" | "gdscript" | "csharp"（不明は ""）。
## 生成コードは ThresholdDetector と同じ判定（移動平均 → ヒステリシス付きラッチ →
## ANY/ALL → 立ち上がり + 不応期）をする。無効（enabled=false）のルールは含めない。
func to_code_snippet(lang: String) -> String:
	var active_rules: Array[ThresholdRule] = []
	for r in rules:
		if r.enabled:
			active_rules.append(r)
	var comment := "#" if lang == "gdscript" else "//"
	if not lang in ["cpp", "gdscript", "csharp"]:
		return ""
	var header := _snippet_header(comment)
	if active_rules.is_empty():
		return header + "%s 有効なルールがありません。しきい値を設定してから書き出してください。\n" % comment
	match lang:
		"cpp":
			return header + _snippet_cpp(active_rules)
		"gdscript":
			return header + _snippet_gdscript(active_rules)
		_:
			return header + _snippet_csharp(active_rules)


func _snippet_header(c: String) -> String:
	var lines: Array[String] = [
		"%s ============================================================" % c,
		"%s しきい値判定: %s" % [c, _one_line(name if not name.is_empty() else "(名前なし)")],
		"%s %s で生成 / 作成日時 %s" % [c, APP_NAME, _one_line(created_at)],
	]
	if not device_name.is_empty():
		lines.append("%s 測定デバイス: %s" % [c, _one_line(device_name)])
	lines.append("%s 値は生の値（重力分を引かない）。加速度は G、角速度は deg/s。" % c)
	lines.append("%s 組み合わせ: %s / 平滑化: %d サンプル移動平均 / 不応期: %d ms" % [
			c, ThresholdDetector.combine_label(combine), smoothing_window, _refractory_ms()])
	var disabled := 0
	for r in rules:
		if r.enabled:
			lines.append("%s   %s" % [c, r.summary()])
		else:
			disabled += 1
	if disabled > 0:
		lines.append("%s   （無効にしたルール %d 件は含めていません）" % [c, disabled])
	if not note.is_empty():
		lines.append("%s メモ: %s" % [c, _one_line(note)])
	lines.append("%s ============================================================" % c)
	return "\n".join(lines) + "\n"


func _snippet_cpp(active: Array[ThresholdRule]) -> String:
	var rule_lines := ""
	for r in active:
		rule_lines += "  {%s, %s, %sf, %sf},  // %s\n" % [
			SensorAxis.key(r.axis).to_upper(), _dir_name(r.direction).to_upper(),
			_lit(r.threshold), _lit(r.hysteresis), r.summary()]
	return """// 使い方（M5Unified）:
//   motion_threshold::MotionDetector detector;
//   void loop() {
//     M5.update();
//     if (detector.update(millis())) { /* 動作した！ */ }
//   }
#include <M5Unified.h>
#include <math.h>
#include <stdint.h>

namespace motion_threshold {

enum Axis { AX, AY, AZ, GX, GY, GZ, AMAG, GMAG };
enum Direction { POSITIVE, NEGATIVE, ABSOLUTE };

struct Rule {
  Axis axis;
  Direction direction;
  float threshold;   // POSITIVE/NEGATIVE: 波形上の値（NEGATIVE は通常マイナス） / ABSOLUTE: 大きさ
  float hysteresis;  // 判定解除はしきい値からこの量だけ戻ったとき
};

static const Rule RULES[] = {
%s};
static const int RULE_COUNT = %d;
static const bool COMBINE_ALL = %s;        // false: どれか1つ / true: すべて同時
static const uint32_t REFRACTORY_MS = %d;   // 一度判定したら、この時間は次の判定をしない
static const int SMOOTHING_WINDOW = %d;     // 移動平均のサンプル数（1 = 平滑化なし）

// 軸の値の取り出し方
//   加速度 [G]     : M5.Imu.getAccelData(&ax, &ay, &az);  → AX, AY, AZ
//   角速度 [deg/s] : M5.Imu.getGyroData(&gx, &gy, &gz);   → GX, GY, GZ
//   合成値         : sqrtf(x*x + y*y + z*z)               → AMAG, GMAG
inline float axisValue(Axis axis, const float a[3], const float g[3]) {
  switch (axis) {
    case AX: return a[0];
    case AY: return a[1];
    case AZ: return a[2];
    case GX: return g[0];
    case GY: return g[1];
    case GZ: return g[2];
    case AMAG: return sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    case GMAG: return sqrtf(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
  }
  return 0.0f;
}

class MotionDetector {
 public:
  // IMU から値を読んで判定する。動作が始まった瞬間だけ true を返す。
  bool update(uint32_t nowMs) {
    float a[3], g[3];
    M5.Imu.getAccelData(&a[0], &a[1], &a[2]);
    M5.Imu.getGyroData(&g[0], &g[1], &g[2]);
    return feed(a, g, nowMs);
  }

  // 値を直接渡して判定する（a: 加速度 G, g: 角速度 deg/s）。
  bool feed(const float a[3], const float g[3], uint32_t nowMs) {
    int activeCount = 0;
    for (int i = 0; i < RULE_COUNT; ++i) {
      const Rule& r = RULES[i];
      float v = smooth(i, axisValue(r.axis, a, g));
      if (!active_[i]) {
        active_[i] = exceeds(r, v);
      } else if (released(r, v)) {
        active_[i] = false;  // ヒステリシス: しきい値から戻りきるまで解除しない
      }
      if (active_[i]) ++activeCount;
    }
    bool nowActive = COMBINE_ALL ? (activeCount == RULE_COUNT) : (activeCount > 0);
    bool rising = nowActive && !combined_;
    combined_ = nowActive;
    if (!rising) return false;
    if (hasFired_ && (uint32_t)(nowMs - lastFireMs_) < REFRACTORY_MS) return false;  // 不応期
    hasFired_ = true;
    lastFireMs_ = nowMs;
    return true;
  }

  bool isActive() const { return combined_; }

 private:
  static bool exceeds(const Rule& r, float v) {
    switch (r.direction) {
      case POSITIVE: return v >= r.threshold;
      case NEGATIVE: return v <= r.threshold;
      default: return fabsf(v) >= fabsf(r.threshold);
    }
  }

  static bool released(const Rule& r, float v) {
    switch (r.direction) {
      case POSITIVE: return v < r.threshold - r.hysteresis;
      case NEGATIVE: return v > r.threshold + r.hysteresis;
      default: return fabsf(v) < fabsf(r.threshold) - r.hysteresis;
    }
  }

  // 移動平均（溜まるまでは溜まった分で平均）
  float smooth(int i, float v) {
    buf_[i][head_[i]] = v;
    head_[i] = (head_[i] + 1) %% SMOOTHING_WINDOW;
    if (count_[i] < SMOOTHING_WINDOW) ++count_[i];
    float sum = 0.0f;
    for (int k = 0; k < count_[i]; ++k) sum += buf_[i][k];
    return sum / count_[i];
  }

  bool active_[RULE_COUNT] = {};
  float buf_[RULE_COUNT][SMOOTHING_WINDOW] = {};
  int head_[RULE_COUNT] = {};
  int count_[RULE_COUNT] = {};
  bool combined_ = false;
  bool hasFired_ = false;
  uint32_t lastFireMs_ = 0;
};

}  // namespace motion_threshold
""" % [rule_lines, active.size(), "true" if combine == ThresholdDetector.Combine.ALL else "false",
		_refractory_ms(), maxi(1, smoothing_window)]


func _snippet_gdscript(active: Array[ThresholdRule]) -> String:
	var rule_lines := ""
	for r in active:
		rule_lines += "\t[Axis.%s, Direction.%s, %s, %s],  # %s\n" % [
			SensorAxis.key(r.axis).to_upper(), _dir_name(r.direction).to_upper(),
			_lit(r.threshold), _lit(r.hysteresis), r.summary()]
	return """# 使い方（Godot 4）:
#   このコードを motion_detector.gd として保存し、
#   var detector = preload("res://motion_detector.gd").new()
#   if detector.feed(accel, gyro, Time.get_ticks_msec()):
#       print("動作した！")
# 軸の値の取り出し方: accel = Vector3(ax, ay, az) [G], gyro = Vector3(gx, gy, gz) [deg/s]
#   （M5 から届く CSV 行 "ax,ay,az,gx,gy,gz" の順）。合成値は accel.length() / gyro.length()
extends RefCounted

enum Axis { AX, AY, AZ, GX, GY, GZ, AMAG, GMAG }
enum Direction { POSITIVE, NEGATIVE, ABSOLUTE }

## [軸, 向き, しきい値, ヒステリシス]
## しきい値は POSITIVE/NEGATIVE なら波形上の値（NEGATIVE は通常マイナス）、ABSOLUTE なら大きさ
const RULES := [
%s]
const COMBINE_ALL := %s        ## false: どれか1つ / true: すべて同時
const REFRACTORY_MS := %d       ## 一度判定したら、この時間は次の判定をしない
const SMOOTHING_WINDOW := %d    ## 移動平均のサンプル数（1 = 平滑化なし）

var _active: Array[bool] = []
var _buffers: Array = []
var _combined := false
var _has_fired := false
var _last_fire_ms := 0


func _init() -> void:
	for i in RULES.size():
		_active.append(false)
		_buffers.append([])


## 1サンプルを判定する。動作が始まった瞬間だけ true を返す。
func feed(accel: Vector3, gyro: Vector3, now_ms: int) -> bool:
	var active_count := 0
	for i in RULES.size():
		var rule: Array = RULES[i]
		var v := _smooth(i, _axis_value(rule[0], accel, gyro))
		if not _active[i]:
			_active[i] = _exceeds(rule, v)
		elif _released(rule, v):
			_active[i] = false  # ヒステリシス: しきい値から戻りきるまで解除しない
		if _active[i]:
			active_count += 1
	var now_active := active_count == RULES.size() if COMBINE_ALL else active_count > 0
	var rising := now_active and not _combined
	_combined = now_active
	if not rising:
		return false
	if _has_fired and now_ms >= _last_fire_ms and now_ms - _last_fire_ms < REFRACTORY_MS:
		return false  # 不応期
	_has_fired = true
	_last_fire_ms = now_ms
	return true


func is_active() -> bool:
	return _combined


func _axis_value(axis: int, accel: Vector3, gyro: Vector3) -> float:
	match axis:
		Axis.AX: return accel.x
		Axis.AY: return accel.y
		Axis.AZ: return accel.z
		Axis.GX: return gyro.x
		Axis.GY: return gyro.y
		Axis.GZ: return gyro.z
		Axis.AMAG: return accel.length()
		Axis.GMAG: return gyro.length()
	return 0.0


func _exceeds(rule: Array, v: float) -> bool:
	match rule[1]:
		Direction.POSITIVE: return v >= rule[2]
		Direction.NEGATIVE: return v <= rule[2]
	return absf(v) >= absf(rule[2])


func _released(rule: Array, v: float) -> bool:
	match rule[1]:
		Direction.POSITIVE: return v < rule[2] - rule[3]
		Direction.NEGATIVE: return v > rule[2] + rule[3]
	return absf(v) < absf(rule[2]) - rule[3]


## 移動平均（溜まるまでは溜まった分で平均）
func _smooth(i: int, v: float) -> float:
	var buf: Array = _buffers[i]
	buf.append(v)
	if buf.size() > SMOOTHING_WINDOW:
		buf.pop_front()
	var sum := 0.0
	for x in buf:
		sum += x
	return sum / buf.size()
""" % [rule_lines, "true" if combine == ThresholdDetector.Combine.ALL else "false",
		_refractory_ms(), maxi(1, smoothing_window)]


func _snippet_csharp(active: Array[ThresholdRule]) -> String:
	var rule_lines := ""
	for r in active:
		rule_lines += "        new Rule(Axis.%s, Direction.%s, %sf, %sf),  // %s\n" % [
			SensorAxis.key(r.axis).to_upper(), _dir_name(r.direction).capitalize(),
			_lit(r.threshold), _lit(r.hysteresis), r.summary()]
	return """// 使い方（C# / Unity など）:
//   var detector = new MotionDetector();
//   if (detector.Feed(ax, ay, az, gx, gy, gz, nowMs)) { /* 動作した！ */ }
// 軸の値の取り出し方: ax, ay, az = 加速度 [G] / gx, gy, gz = 角速度 [deg/s]
//   （M5 から届く CSV 行 "ax,ay,az,gx,gy,gz" の順）。合成値は内部で sqrt(x*x + y*y + z*z) を計算する。
using System;

public class MotionDetector
{
    public enum Axis { AX, AY, AZ, GX, GY, GZ, AMAG, GMAG }
    public enum Direction { Positive, Negative, Absolute }

    private readonly struct Rule
    {
        public readonly Axis AxisId;
        public readonly Direction Dir;
        public readonly float Threshold;   // Positive/Negative: 波形上の値（Negative は通常マイナス） / Absolute: 大きさ
        public readonly float Hysteresis;  // 判定解除はしきい値からこの量だけ戻ったとき

        public Rule(Axis axis, Direction dir, float threshold, float hysteresis)
        {
            AxisId = axis;
            Dir = dir;
            Threshold = threshold;
            Hysteresis = hysteresis;
        }
    }

    private static readonly Rule[] Rules =
    {
%s    };
    private static readonly bool CombineAll = %s;      // false: どれか1つ / true: すべて同時
    public const long RefractoryMs = %d;              // 一度判定したら、この時間は次の判定をしない
    public const int SmoothingWindow = %d;            // 移動平均のサンプル数（1 = 平滑化なし）

    private readonly bool[] _active = new bool[Rules.Length];
    private readonly float[,] _buf = new float[Rules.Length, SmoothingWindow];
    private readonly int[] _head = new int[Rules.Length];
    private readonly int[] _count = new int[Rules.Length];
    private bool _combined;
    private bool _hasFired;
    private long _lastFireMs;

    public bool IsActive => _combined;

    /// <summary>1サンプルを判定する。動作が始まった瞬間だけ true を返す。</summary>
    public bool Feed(float ax, float ay, float az, float gx, float gy, float gz, long nowMs)
    {
        int activeCount = 0;
        for (int i = 0; i < Rules.Length; i++)
        {
            Rule r = Rules[i];
            float v = Smooth(i, AxisValue(r.AxisId, ax, ay, az, gx, gy, gz));
            if (!_active[i]) _active[i] = Exceeds(r, v);
            else if (Released(r, v)) _active[i] = false;  // ヒステリシス
            if (_active[i]) activeCount++;
        }
        bool nowActive = CombineAll ? activeCount == Rules.Length : activeCount > 0;
        bool rising = nowActive && !_combined;
        _combined = nowActive;
        if (!rising) return false;
        if (_hasFired && nowMs >= _lastFireMs && nowMs - _lastFireMs < RefractoryMs) return false;  // 不応期
        _hasFired = true;
        _lastFireMs = nowMs;
        return true;
    }

    private static float AxisValue(Axis axis, float ax, float ay, float az, float gx, float gy, float gz)
    {
        switch (axis)
        {
            case Axis.AX: return ax;
            case Axis.AY: return ay;
            case Axis.AZ: return az;
            case Axis.GX: return gx;
            case Axis.GY: return gy;
            case Axis.GZ: return gz;
            case Axis.AMAG: return (float)Math.Sqrt(ax * ax + ay * ay + az * az);
            case Axis.GMAG: return (float)Math.Sqrt(gx * gx + gy * gy + gz * gz);
        }
        return 0f;
    }

    private static bool Exceeds(Rule r, float v)
    {
        switch (r.Dir)
        {
            case Direction.Positive: return v >= r.Threshold;
            case Direction.Negative: return v <= r.Threshold;
            default: return Math.Abs(v) >= Math.Abs(r.Threshold);
        }
    }

    private static bool Released(Rule r, float v)
    {
        switch (r.Dir)
        {
            case Direction.Positive: return v < r.Threshold - r.Hysteresis;
            case Direction.Negative: return v > r.Threshold + r.Hysteresis;
            default: return Math.Abs(v) < Math.Abs(r.Threshold) - r.Hysteresis;
        }
    }

    // 移動平均（溜まるまでは溜まった分で平均）
    private float Smooth(int i, float v)
    {
        _buf[i, _head[i]] = v;
        _head[i] = (_head[i] + 1) %% SmoothingWindow;
        if (_count[i] < SmoothingWindow) _count[i]++;
        float sum = 0f;
        for (int k = 0; k < _count[i]; k++) sum += _buf[i, k];
        return sum / _count[i];
    }
}
""" % [rule_lines, "true" if combine == ThresholdDetector.Combine.ALL else "false",
		_refractory_ms(), maxi(1, smoothing_window)]


# ------------------------------------------------------------ 内部

## ThresholdDetector と同じく、有効なルールの不応期の最大値。
func _refractory_ms() -> int:
	var ms := 0
	for r in rules:
		if r.enabled:
			ms = maxi(ms, r.refractory_ms)
	return ms


static func _dir_name(direction: int) -> String:
	var k := ThresholdRule.direction_key(direction)
	return k if not k.is_empty() else "absolute"


## コード中の数値リテラル（必ず小数点を含む。NaN/INF は 0.0）。
static func _lit(v: float) -> String:
	if not is_finite(v):
		return "0.0"
	var s := String.num(v, 6)
	if s == "-0":
		s = "0"
	if not ("." in s or "e" in s):
		s += ".0"
	return s


static func _one_line(text: String) -> String:
	return text.replace("\r", " ").replace("\n", " ")


static func _get_string(d: Dictionary, k: String, fallback: String) -> String:
	var v: Variant = d.get(k, fallback)
	return String(v) if typeof(v) == TYPE_STRING else fallback


static func _get_number(d: Dictionary, k: String, fallback: float) -> float:
	var v: Variant = d.get(k, fallback)
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return fallback
	var f := float(v)
	return f if is_finite(f) else fallback


static func _ensure_dir(dir_path: String) -> bool:
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	return DirAccess.make_dir_recursive_absolute(dir_path) == OK


static func _newer_first(a: Dictionary, b: Dictionary) -> bool:
	if a["modified"] != b["modified"]:
		return a["modified"] > b["modified"]
	if a["created_at"] != b["created_at"]:
		return a["created_at"] > b["created_at"]
	return a["file"] > b["file"]


## measurement（axis(int) キー）→ 保存形式（軸キー文字列）。数値の NaN/INF は 0 にする。
static func _measurement_to_saved(m: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if m.has("baseline") and typeof(m["baseline"]) == TYPE_DICTIONARY:
		out["baseline"] = _axis_map_to_saved(m["baseline"])
	if m.has("trials") and typeof(m["trials"]) == TYPE_ARRAY:
		var trials: Array = []
		for t in m["trials"]:
			if typeof(t) == TYPE_DICTIONARY:
				trials.append(_axis_map_to_saved(t))
		out["trials"] = trials
	return out


## 保存形式 → measurement（axis(int) キー）。読めない軸・値は捨てる。
static func _measurement_from_saved(m: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if m.has("baseline") and typeof(m["baseline"]) == TYPE_DICTIONARY:
		out["baseline"] = _axis_map_from_saved(m["baseline"])
	if m.has("trials") and typeof(m["trials"]) == TYPE_ARRAY:
		var trials: Array = []
		for t in m["trials"]:
			if typeof(t) == TYPE_DICTIONARY:
				trials.append(_axis_map_from_saved(t))
		out["trials"] = trials
	return out


static func _axis_map_to_saved(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		var axis_key := ""
		if typeof(k) == TYPE_INT:
			axis_key = SensorAxis.key(k)
		elif typeof(k) == TYPE_STRING and SensorAxis.from_key(k) >= 0:
			axis_key = k
		if axis_key.is_empty() or typeof(src[k]) != TYPE_DICTIONARY:
			continue
		out[axis_key] = _clean_numbers(src[k])
	return out


static func _axis_map_from_saved(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		if typeof(k) != TYPE_STRING or typeof(src[k]) != TYPE_DICTIONARY:
			continue
		var axis := SensorAxis.from_key(k)
		if axis < 0:
			continue
		var stats := _clean_numbers(src[k])
		# JSON の数値はすべて float になるので、件数・時間は int に戻す
		for int_key in ["count", "duration_ms"]:
			if stats.has(int_key):
				stats[int_key] = int(stats[int_key])
		out[axis] = stats
	return out


## 数値だけを残し、NaN/INF は 0 にする。
static func _clean_numbers(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		var v: Variant = src[k]
		if typeof(v) == TYPE_INT:
			out[String(k)] = v
		elif typeof(v) == TYPE_FLOAT:
			out[String(k)] = v if is_finite(v) else 0.0
	return out
