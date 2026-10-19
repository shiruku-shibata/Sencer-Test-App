extends RefCounted
## テストケースの基底クラス。テストファイルは `extends "res://tests/test_case.gd"` で継承し、
## `test_` で始まるメソッドを書く（tests/run_tests.gd が自動で見つけて実行する）。
##
## 失敗してもそのテストメソッドは最後まで実行される（失敗はまとめて報告）。
## 失敗メッセージには「ファイル::メソッド」と、取得できる環境（Godot 4.5 以降）では行番号が付く。
##
## フック: before_all / after_all（ファイル単位）、before_each / after_each（メソッド単位）。
## ファイルを扱うテストは make_temp_dir() で一時フォルダを作る（テスト終了時に自動で消える）。

## 一時フォルダの親。テストが終わると run_tests.gd が丸ごと消す。
const TEMP_ROOT := "user://__sensor_test_tmp"

var current_file := ""
var current_test := ""

var _failures: Array[String] = []
var _assert_count := 0
var _allow_engine_errors := false
var _temp_dirs: Array[String] = []


# ------------------------------------------------------------ フック（必要なら上書き）

func before_all() -> void:
	pass


func after_all() -> void:
	pass


func before_each() -> void:
	pass


func after_each() -> void:
	pass


# ------------------------------------------------------------ アサーション

func assert_true(condition: bool, msg: String = "") -> void:
	_assert_count += 1
	if not condition:
		_fail("true であるべき", msg)


func assert_false(condition: bool, msg: String = "") -> void:
	_assert_count += 1
	if condition:
		_fail("false であるべき", msg)


## 値が等しいか。配列・辞書は中身を再帰的に比較する（int と float は数値として比較）。
func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	_assert_count += 1
	if not deep_equal(actual, expected):
		_fail("期待値 %s / 実際 %s" % [_repr(expected), _repr(actual)], msg)


func assert_ne(actual: Variant, unexpected: Variant, msg: String = "") -> void:
	_assert_count += 1
	if deep_equal(actual, unexpected):
		_fail("%s 以外であるべき" % _repr(unexpected), msg)


## 浮動小数を誤差 epsilon 以内で比較する。
func assert_almost_eq(actual: float, expected: float, epsilon: float = 1e-4, msg: String = "") -> void:
	_assert_count += 1
	if is_nan(actual) or is_nan(expected) or absf(actual - expected) > epsilon:
		_fail("期待値 %s ± %s / 実際 %s" % [expected, epsilon, actual], msg)


func assert_gt(actual: float, bound: float, msg: String = "") -> void:
	_assert_count += 1
	if not actual > bound:
		_fail("%s > %s であるべき" % [actual, bound], msg)


func assert_ge(actual: float, bound: float, msg: String = "") -> void:
	_assert_count += 1
	if not actual >= bound:
		_fail("%s >= %s であるべき" % [actual, bound], msg)


func assert_lt(actual: float, bound: float, msg: String = "") -> void:
	_assert_count += 1
	if not actual < bound:
		_fail("%s < %s であるべき" % [actual, bound], msg)


func assert_le(actual: float, bound: float, msg: String = "") -> void:
	_assert_count += 1
	if not actual <= bound:
		_fail("%s <= %s であるべき" % [actual, bound], msg)


func assert_null(value: Variant, msg: String = "") -> void:
	_assert_count += 1
	if value != null:
		_fail("null であるべき（実際 %s）" % _repr(value), msg)


func assert_not_null(value: Variant, msg: String = "") -> void:
	_assert_count += 1
	if value == null:
		_fail("null でないべき", msg)


## 文字列 text に part が含まれるか。
func assert_contains(text: String, part: String, msg: String = "") -> void:
	_assert_count += 1
	if not part in text:
		_fail("%s を含むべき（実際 %s）" % [_repr(part), _repr(text.left(200))], msg)


func assert_not_contains(text: String, part: String, msg: String = "") -> void:
	_assert_count += 1
	if part in text:
		_fail("%s を含まないべき" % _repr(part), msg)


## 配列・辞書（キー）に item が含まれるか。
func assert_has(container: Variant, item: Variant, msg: String = "") -> void:
	_assert_count += 1
	var ok := false
	if container is Array or container is Dictionary:
		ok = container.has(item)
	if not ok:
		_fail("%s に %s が含まれるべき" % [_repr(container), _repr(item)], msg)


func fail(msg: String) -> void:
	_assert_count += 1
	_fail("失敗", msg)


## このテスト中にエンジンのエラー（push_error 等）が出ても失敗にしない。
## わざと失敗させる処理を確かめるテストで呼ぶ。
func allow_engine_errors() -> void:
	_allow_engine_errors = true


# ------------------------------------------------------------ 補助

## このテスト専用の一時フォルダを作って返す（"user://__sensor_test_tmp/…"）。テスト後に自動で消える。
func make_temp_dir() -> String:
	var path := "%s/%s_%d_%d" % [TEMP_ROOT, current_test, Time.get_ticks_usec(), randi() % 100000]
	DirAccess.make_dir_recursive_absolute(path)
	_temp_dirs.append(path)
	return path


## テキストファイルを書く（テストデータ用）。
func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		fail("ファイルを書けません: %s" % path)
		return
	f.store_string(text)
	f.close()


## Variant を深く比較する（配列・辞書は中身、数値は int/float を区別しない）。
static func deep_equal(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var b_num := tb == TYPE_INT or tb == TYPE_FLOAT
	if a_num and b_num:
		return float(a) == float(b)
	if _is_array_type(ta) and _is_array_type(tb):
		var aa: Array = Array(a)
		var bb: Array = Array(b)
		if aa.size() != bb.size():
			return false
		for i in aa.size():
			if not deep_equal(aa[i], bb[i]):
				return false
		return true
	if ta == TYPE_DICTIONARY and tb == TYPE_DICTIONARY:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da.keys():
			if not db.has(k) or not deep_equal(da[k], db[k]):
				return false
		return true
	if (ta == TYPE_STRING or ta == TYPE_STRING_NAME) and (tb == TYPE_STRING or tb == TYPE_STRING_NAME):
		return String(a) == String(b)
	if ta != tb:
		return false
	return a == b


static func _is_array_type(t: int) -> bool:
	return t == TYPE_ARRAY or (t >= TYPE_PACKED_BYTE_ARRAY and t <= TYPE_PACKED_VECTOR4_ARRAY)


static func _repr(v: Variant) -> String:
	if typeof(v) == TYPE_STRING:
		return "\"%s\"" % v
	return str(v)


func _fail(detail: String, msg: String) -> void:
	var where := "%s::%s%s" % [current_file, current_test, _line_suffix()]
	var text := "%s — %s" % [where, detail]
	if not msg.is_empty():
		text += "（%s）" % msg
	_failures.append(text)


## 失敗したアサーションの行番号（Godot 4.5 以降の Engine.capture_script_backtraces がある場合のみ）。
func _line_suffix() -> String:
	if not Engine.has_method("capture_script_backtraces"):
		return ""
	var traces: Variant = Engine.call("capture_script_backtraces", false)
	if typeof(traces) != TYPE_ARRAY:
		return ""
	for bt in traces:
		var trace: Object = bt
		if trace == null:
			continue
		var count: int = trace.call("get_frame_count")
		for i in count:
			var file: String = trace.call("get_frame_file", i)
			if file.begins_with("res://tests/") and not file.ends_with("/test_case.gd"):
				return ":%d" % int(trace.call("get_frame_line", i))
	return ""


# ------------------------------------------------------------ run_tests.gd から呼ぶ

func _begin_test(file: String, test: String) -> void:
	current_file = file
	current_test = test
	_failures.clear()
	_allow_engine_errors = false


func _end_test() -> void:
	for dir in _temp_dirs:
		remove_dir_recursive(dir)
	_temp_dirs.clear()


static func remove_dir_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		remove_dir_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)
