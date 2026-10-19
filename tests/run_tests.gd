extends SceneTree
## 自動テストの実行スクリプト。
##
##   godot --headless --path . -s res://tests/run_tests.gd
##   godot --headless --path . -s res://tests/run_tests.gd -- --filter=analyzer   # ファイル名・メソッド名で絞り込み
##
## tests/ 配下（サブフォルダ含む）の test_*.gd を探し、tests/test_case.gd を継承しているものについて、
## test_ で始まるメソッドを宣言順に実行する。全テスト成功なら終了コード 0、1つでも失敗なら 1。
##
## Godot 4.5 以降では Logger でエンジンのエラー（スクリプトの実行時エラー・push_error）を捕まえ、
## テスト中に出たらそのテストを失敗にする（エラーで途中終了したテストを見逃さないため）。
## 4.4 ではこの検出ができないので、出力のエラーを目で確認すること。

const TESTS_DIR := "res://tests"
const TEST_CASE_PATH := "res://tests/test_case.gd"

## Logger を継承したエラー収集器（Logger が無い 4.4 でも読み込めるよう、文字列から生成する）
const _ERROR_CATCHER_SOURCE := """extends Logger
var errors: Array[String] = []
var enabled := false
var _mutex := Mutex.new()

func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if not enabled or error_type == ERROR_TYPE_WARNING:
		return
	var text := rationale if not rationale.is_empty() else code
	_mutex.lock()
	errors.append("%s (%s:%d %s)" % [text, file, line, function])
	_mutex.unlock()

func _log_message(_message: String, _error: bool) -> void:
	pass

func take() -> Array[String]:
	_mutex.lock()
	var out := errors.duplicate()
	errors.clear()
	_mutex.unlock()
	return out
"""

var _catcher: Object = null
var _catch_supported := false


func _initialize() -> void:
	var filter := _parse_filter()
	_install_error_catcher()
	var test_case_script: Script = load(TEST_CASE_PATH)

	var total := 0
	var passed := 0
	var assertions := 0
	var failures: Array[String] = []
	var started := Time.get_ticks_msec()

	var files := _find_test_files(TESTS_DIR)
	print("== テスト実行: %d ファイル ==" % files.size())
	for path in files:
		var file_label := path.trim_prefix(TESTS_DIR + "/")
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			failures.append("%s — 読み込みに失敗（構文エラー？）" % file_label)
			total += 1
			continue
		if not _inherits(script, test_case_script):
			continue
		var methods := _test_methods(script, file_label, filter)
		if methods.is_empty():
			continue
		var suite: RefCounted = script.new()
		var file_passed := 0
		suite.call("before_all")
		for method in methods:
			suite.call("_begin_test", file_label, method)
			_take_errors()
			suite.call("before_each")
			suite.call(method)
			suite.call("after_each")
			suite.call("_end_test")
			var test_failures: Array[String] = suite.get("_failures").duplicate()
			var engine_errors := _take_errors()
			if not engine_errors.is_empty() and not suite.get("_allow_engine_errors"):
				for e in engine_errors:
					test_failures.append("%s::%s — エンジンのエラー: %s" % [file_label, method, e])
			total += 1
			if test_failures.is_empty():
				passed += 1
				file_passed += 1
			else:
				failures.append_array(test_failures)
		suite.call("after_all")
		_take_errors()
		assertions += int(suite.get("_assert_count"))
		var mark := "OK " if file_passed == methods.size() else "NG "
		print("%s %-40s %3d / %3d" % [mark, file_label, file_passed, methods.size()])

	test_case_script.call("remove_dir_recursive", test_case_script.get("TEMP_ROOT"))
	_remove_error_catcher()

	print("")
	if not failures.is_empty():
		print("---- 失敗一覧 (%d) ----" % failures.size())
		for f in failures:
			print("  ✗ " + f)
		print("")
	print("== 結果: %d 件中 %d 成功 / %d 失敗（アサーション %d 回, %d ms） ==" % [
			total, passed, total - passed, assertions, Time.get_ticks_msec() - started])
	if not _catch_supported:
		print("（注意: この Godot ではエンジンエラーの自動検出が使えません。上の出力に ERROR が無いか確認してください）")
	quit(0 if total > 0 and passed == total else 1)


func _parse_filter() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			return arg.trim_prefix("--filter=")
	return ""


## tests/ 配下の test_*.gd（test_case.gd を除く）を名前順に返す。
func _find_test_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir_path):
		if f.begins_with("test_") and f.ends_with(".gd") and dir_path.path_join(f) != TEST_CASE_PATH:
			out.append(dir_path.path_join(f))
	for d in DirAccess.get_directories_at(dir_path):
		if not d.begins_with("."):
			out.append_array(_find_test_files(dir_path.path_join(d)))
	out.sort()
	return out


func _inherits(script: Script, base: Script) -> bool:
	var s := script.get_base_script()
	while s != null:
		if s == base:
			return true
		s = s.get_base_script()
	return false


## test_ で始まるメソッド名（宣言順・重複なし）。filter があればファイル名かメソッド名に含むものだけ。
func _test_methods(script: Script, file_label: String, filter: String) -> Array[String]:
	var out: Array[String] = []
	for m in script.get_script_method_list():
		var method_name: String = m["name"]
		if not method_name.begins_with("test_") or out.has(method_name):
			continue
		if not filter.is_empty() and not (filter in file_label or filter in method_name):
			continue
		out.append(method_name)
	return out


func _install_error_catcher() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var script := GDScript.new()
	script.source_code = _ERROR_CATCHER_SOURCE
	if script.reload() != OK:
		return
	_catcher = script.new()
	_catcher.set("enabled", true)
	OS.call("add_logger", _catcher)
	_catch_supported = true


func _remove_error_catcher() -> void:
	if _catcher != null:
		OS.call("remove_logger", _catcher)
		_catcher = null


func _take_errors() -> Array[String]:
	var out: Array[String] = []
	if _catcher != null:
		out.assign(_catcher.call("take"))
	return out
