extends "res://tests/test_case.gd"
## ThresholdProfile（保存・読み込み・コード生成）のテスト。

const Dir := ThresholdRule.Direction
const SignalGen := preload("res://tests/helpers/signal_gen.gd")
const AX := SensorAxis.Id.AX
const GZ := SensorAxis.Id.GZ


func _sample_profile() -> ThresholdProfile:
	var p := ThresholdProfile.new()
	p.name = "振り下ろし"
	p.device_name = "M5-Sensor-1A2B"
	p.combine = ThresholdDetector.Combine.ALL
	p.smoothing_window = 3
	p.sample_rate_hz = 100.0
	p.note = "テスト用"
	p.rules.append(ThresholdRule.new(GZ, 180.5, Dir.POSITIVE, 30.25, 250))
	p.rules.append(ThresholdRule.new(AX, -1.75, Dir.NEGATIVE, 0.4, 150))
	var off := ThresholdRule.new(SensorAxis.Id.GYRO_MAG, 999.0, Dir.ABSOLUTE)
	off.enabled = false
	p.rules.append(off)
	p.measurement = {
		"baseline": {GZ: {"mean": 0.5, "stddev": 2.0, "min": -6.0, "max": 7.0, "count": 300}},
		"trials": [{GZ: {"max": 250.0, "min": -40.0, "peak_abs": 250.0, "count": 30, "duration_ms": 290}}],
	}
	return p


func test_defaults() -> void:
	var p := ThresholdProfile.new()
	assert_eq(p.rules.size(), 0)
	assert_eq(p.combine, ThresholdDetector.Combine.ANY)
	assert_eq(p.smoothing_window, 1)
	assert_false(p.created_at.is_empty(), "作成日時は自動で入る")


func test_to_dict_format() -> void:
	var d := _sample_profile().to_dict()
	assert_eq(d["format_version"], ThresholdProfile.FORMAT_VERSION)
	assert_eq(d["app"], "Sensor Test App")
	assert_eq(d["combine"], "all")
	assert_eq(d["rules"][0]["axis"], "gz")
	assert_eq(d["rules"][1]["direction"], "negative")
	assert_has(d["measurement"]["baseline"], "gz", "measurement は軸キー文字列で保存")
	assert_has(d["measurement"]["trials"][0], "gz")


func test_json_roundtrip() -> void:
	var p := _sample_profile()
	var text := p.to_json()
	var q := ThresholdProfile.from_json(text)
	assert_not_null(q)
	if q == null:
		return
	assert_eq(q.name, "振り下ろし")
	assert_eq(q.device_name, p.device_name)
	assert_eq(q.created_at, p.created_at)
	assert_eq(q.note, "テスト用")
	assert_eq(q.combine, ThresholdDetector.Combine.ALL)
	assert_eq(q.smoothing_window, 3)
	assert_almost_eq(q.sample_rate_hz, 100.0)
	assert_eq(q.rules.size(), 3)
	for i in 3:
		assert_eq(q.rules[i].to_dict(), p.rules[i].to_dict(), "ルール %d" % i)
	assert_eq(q.measurement, p.measurement, "measurement は int 軸キーに戻る")
	assert_eq(typeof(q.measurement["baseline"][GZ]["count"]), TYPE_INT)
	assert_eq(typeof(q.measurement["trials"][0][GZ]["duration_ms"]), TYPE_INT)
	assert_eq(q.to_json(), text, "2回目の書き出しも同じ文字列")


func test_json_starts_with_format_version() -> void:
	var text := _sample_profile().to_json()
	assert_lt(text.find("format_version"), text.find("rules"), "キーは読みやすい順に並ぶ")


func test_from_json_rejects_invalid_input() -> void:
	var cases := {
		"": "空文字",
		"{bad json": "壊れた JSON",
		"[]": "配列",
		"42": "数値",
		"null": "null",
		"{}": "format_version なし",
		"{\"format_version\": \"1\"}": "文字列の版",
		"{\"format_version\": 999}": "未来の版",
		"{\"format_version\": 0}": "0 版",
		"{\"format_version\": 1, \"rules\": {}}": "rules が配列でない",
		"{\"format_version\": 1, \"rules\": [1]}": "ルールが辞書でない",
		"{\"format_version\": 1, \"rules\": [{\"axis\": \"zz\"}]}": "未知の軸",
		"{\"format_version\": 1, \"combine\": \"most\"}": "未知の組み合わせ",
		"{\"format_version\": 1, \"combine\": [1]}": "組み合わせの型",
	}
	for text in cases.keys():
		assert_null(ThresholdProfile.from_json(text), cases[text])


func test_from_json_tolerates_missing_and_odd_fields() -> void:
	var p := ThresholdProfile.from_json(
			"{\"format_version\": 1, \"name\": 5, \"smoothing_window\": -3, \"sample_rate_hz\": \"x\"," +
			" \"measurement\": {\"baseline\": {\"gz\": {\"mean\": 1, \"note\": \"x\"}, \"zz\": {}}, \"trials\": [1, {}]}}")
	assert_not_null(p)
	if p == null:
		return
	assert_eq(p.name, "", "文字列でない名前は空")
	assert_eq(p.smoothing_window, 1)
	assert_almost_eq(p.sample_rate_hz, 0.0)
	assert_eq(p.rules.size(), 0)
	assert_eq(p.combine, ThresholdDetector.Combine.ANY)
	assert_eq(p.measurement["baseline"], {GZ: {"mean": 1}}, "未知の軸・数値でない値は捨てる")
	assert_eq(p.measurement["trials"], [{}])


func test_from_json_accepts_numeric_combine() -> void:
	var p := ThresholdProfile.from_json("{\"format_version\": 1, \"combine\": 1}")
	assert_not_null(p)
	assert_eq(p.combine, ThresholdDetector.Combine.ALL)


func test_non_finite_values_are_saved_as_zero() -> void:
	var p := ThresholdProfile.new()
	p.sample_rate_hz = INF
	p.rules.append(ThresholdRule.new(GZ, NAN, Dir.POSITIVE))
	p.measurement = {"baseline": {GZ: {"mean": NAN, "count": 1}}}
	var q := ThresholdProfile.from_json(p.to_json())
	assert_not_null(q, "NaN/INF を含んでいても読める JSON になる")
	if q == null:
		return
	assert_almost_eq(q.rules[0].threshold, 0.0)
	assert_almost_eq(q.measurement["baseline"][GZ]["mean"], 0.0)


func test_set_measurement_from_analyzer() -> void:
	var a := ThresholdAnalyzer.new()
	a.set_axes([GZ])
	a.start_baseline(1000)
	for i in 10:
		a.feed(SensorReading.new("d", i * 10, Vector3.ZERO, Vector3(0, 0, float(i % 2))))
	a.stop()
	a.start_trial()
	a.feed(SensorReading.new("d", 500, Vector3.ZERO, Vector3(0, 0, 200)))
	a.stop()
	var p := ThresholdProfile.new()
	p.set_measurement_from(a)
	var q := ThresholdProfile.from_json(p.to_json())
	assert_eq(q.measurement["baseline"], a.baseline())
	assert_eq(q.measurement["trials"], a.trials())


func test_save_load_list_delete() -> void:
	var dir := make_temp_dir().path_join("nested/thresholds")
	var p := _sample_profile()
	var path := p.save_to_dir(dir)
	assert_false(path.is_empty(), "保存できる（フォルダは自動作成）")
	assert_true(FileAccess.file_exists(path))
	assert_eq(path.get_file(), "振り下ろし.json", "日本語名はそのままファイル名になる")
	var q := ThresholdProfile.load_file(path)
	assert_not_null(q)
	assert_eq(q.to_json(), p.to_json())

	var files := ThresholdProfile.list_files_in(dir)
	assert_eq(files.size(), 1)
	assert_eq(files[0]["name"], "振り下ろし")
	assert_eq(files[0]["path"], path)
	assert_true(files[0].has("modified"))

	ThresholdProfile.delete_file(path)
	assert_false(FileAccess.file_exists(path))
	assert_eq(ThresholdProfile.list_files_in(dir).size(), 0)
	ThresholdProfile.delete_file(path)   # 2回消してもエラーにならない


func test_save_overwrites_same_name() -> void:
	var dir := make_temp_dir()
	var p := _sample_profile()
	var path1 := p.save_to_dir(dir)
	p.note = "更新"
	var path2 := p.save_to_dir(dir)
	assert_eq(path1, path2)
	assert_eq(ThresholdProfile.load_file(path2).note, "更新")
	assert_eq(ThresholdProfile.list_files_in(dir).size(), 1)


## 名前が違うのにファイル名が重なるプロファイル（大文字小文字だけ違う・記号の置き換え・切り詰め）は
## 上書きせず、連番を付けた別ファイルに保存する（PR #11 レビュー 中-1）。
func test_save_never_overwrites_a_differently_named_profile() -> void:
	var dir := make_temp_dir()
	var long_name := "x".repeat(ThresholdProfile.MAX_FILE_NAME_LENGTH)
	var names := ["Swing", "swing", "a/b", "a:b", long_name + "_v1", long_name + "_v2", "a.", "a"]
	var paths: Dictionary = {}
	for i in names.size():
		var p := ThresholdProfile.new()
		p.name = names[i]
		p.note = str(i)
		var path := p.save_to_dir(dir)
		assert_false(path.is_empty(), names[i])
		paths[path.to_lower()] = true
	assert_eq(paths.size(), names.size(), "大文字小文字を無視しても、すべて別のファイル")
	var files := ThresholdProfile.list_files_in(dir)
	assert_eq(files.size(), names.size(), "どれも消えていない")
	var loaded: Dictionary = {}
	for e in files:
		var q := ThresholdProfile.load_file(e["path"])
		loaded[q.name] = q.note
	for i in names.size():
		assert_eq(loaded.get(names[i], ""), str(i), "「%s」の中身が残っている" % names[i])


func test_save_path_suffix_and_existing_path() -> void:
	var dir := make_temp_dir()
	var a := ThresholdProfile.new()
	a.name = "a/b"
	assert_eq(a.existing_path_in(dir), "", "フォルダが無ければ既存なし")
	var path_a := a.save_to_dir(dir)
	assert_eq(path_a.get_file(), "a_b.json")
	var b := ThresholdProfile.new()
	b.name = "a:b"
	assert_eq(b.existing_path_in(dir), "", "名前が違えば既存扱いにしない")
	assert_eq(b.save_path_in(dir).get_file(), "a_b_2.json")
	var path_b := b.save_to_dir(dir)
	assert_eq(path_b.get_file(), "a_b_2.json")
	# 同じ名前で保存し直すと、連番のファイルでもそのファイルを上書きする
	b.note = "更新"
	assert_eq(b.existing_path_in(dir), path_b)
	assert_eq(b.save_to_dir(dir), path_b)
	assert_eq(ThresholdProfile.load_file(path_b).note, "更新")
	assert_eq(ThresholdProfile.load_file(path_a).name, "a/b", "別名のほうは消えていない")
	assert_eq(ThresholdProfile.list_files_in(dir).size(), 2)


func test_save_does_not_clobber_unreadable_file() -> void:
	var dir := make_temp_dir()
	var f := FileAccess.open(dir.path_join("broken.json"), FileAccess.WRITE)
	f.store_string("{ これは壊れた JSON")
	f.close()
	var p := ThresholdProfile.new()
	p.name = "broken"
	assert_eq(p.save_to_dir(dir).get_file(), "broken_2.json", "読めないファイルも他人のものとして残す")
	assert_eq(FileAccess.get_file_as_string(dir.path_join("broken.json")), "{ これは壊れた JSON")


func test_unsafe_names_are_sanitized() -> void:
	var dir := make_temp_dir()
	var p := ThresholdProfile.new()
	p.name = "../a/b:c*d?\"e<f>g|h"
	var path := p.save_to_dir(dir)
	assert_eq(path.get_base_dir(), dir, "フォルダの外に出ない")
	assert_eq(path.get_file(), "_._a_b_c_d__e_f_g_h.json")
	assert_eq(ThresholdProfile.load_file(path).name, p.name, "プロファイル名自体はそのまま")


func test_safe_file_name() -> void:
	assert_eq(ThresholdProfile.safe_file_name("ジャンプ判定"), "ジャンプ判定")
	assert_eq(ThresholdProfile.safe_file_name("  "), "profile")
	assert_eq(ThresholdProfile.safe_file_name(""), "profile")
	assert_eq(ThresholdProfile.safe_file_name("a/b\\c:d"), "a_b_c_d")
	assert_eq(ThresholdProfile.safe_file_name(".hidden"), "_hidden")
	assert_eq(ThresholdProfile.safe_file_name("tab\there"), "tab_here")
	assert_eq(ThresholdProfile.safe_file_name("CON"), "_CON")
	assert_eq(ThresholdProfile.safe_file_name("com9"), "_com9")
	assert_eq(ThresholdProfile.safe_file_name("a."), "a_", "末尾の . は Windows で消えるので置き換える")
	assert_eq(ThresholdProfile.safe_file_name("a. ."), "a. _")
	assert_eq(ThresholdProfile.safe_file_name("x".repeat(200)).length(), ThresholdProfile.MAX_FILE_NAME_LENGTH)


func test_list_files_newest_first() -> void:
	var dir := make_temp_dir()
	var names := ["古い", "新しい", "中間"]
	var stamps := ["2026-01-01T00:00:00", "2026-03-01T00:00:00", "2026-02-01T00:00:00"]
	for i in 3:
		var p := ThresholdProfile.new()
		p.name = names[i]
		p.created_at = stamps[i]
		p.save_to_dir(dir)
	write_text(dir.path_join("readme.txt"), "json 以外は無視")
	write_text(dir.path_join("broken.json"), "{壊れている")
	var files := ThresholdProfile.list_files_in(dir)
	var listed: Array = []
	for f in files:
		listed.append(f["name"])
	# 更新時刻が同じ秒なら created_at の新しい順。壊れたファイルは created_at 空で最後
	assert_eq(listed.size(), 4)
	if FileAccess.get_modified_time(files[0]["path"]) == FileAccess.get_modified_time(files[2]["path"]):
		assert_eq(listed, ["新しい", "中間", "古い", "broken"])
	assert_has(listed, "broken", "読めないファイルはファイル名で一覧に出る")


func test_list_and_load_missing() -> void:
	assert_eq(ThresholdProfile.list_files_in("user://__no_such_dir__/x"), [])
	assert_null(ThresholdProfile.load_file("user://__no_such_dir__/x.json"))
	var dir := make_temp_dir()
	write_text(dir.path_join("empty.json"), "")
	assert_null(ThresholdProfile.load_file(dir.path_join("empty.json")))


func test_make_detector_uses_copies() -> void:
	var p := _sample_profile()
	var d := p.make_detector()
	assert_eq(d.combine, ThresholdDetector.Combine.ALL)
	assert_eq(d.smoothing_window, 3)
	assert_eq(d.rules.size(), 3)
	d.rules[0].threshold = 1.0
	assert_almost_eq(p.rules[0].threshold, 180.5, 1e-6, "プロファイル側は変わらない")


# ------------------------------------------------------------ コード生成

func test_snippets_contain_values() -> void:
	var p := _sample_profile()
	for lang in ["cpp", "gdscript", "csharp"]:
		var code := p.to_code_snippet(lang)
		assert_contains(code, "180.5", lang)
		assert_contains(code, "30.25", lang)
		assert_contains(code, "-1.75", lang)
		assert_contains(code, "0.4", lang)
		assert_contains(code, "250", lang + "（不応期 = 有効ルールの最大）")
		assert_contains(code, "振り下ろし", lang)
		assert_not_contains(code, "999", lang + "（無効なルールは含めない）")


func test_cpp_snippet_uses_m5unified() -> void:
	var code := _sample_profile().to_code_snippet("cpp")
	assert_contains(code, "M5.Imu.getAccelData")
	assert_contains(code, "M5.Imu.getGyroData")
	assert_contains(code, "#include <M5Unified.h>")
	assert_contains(code, "{GZ, POSITIVE, 180.5f, 30.25f}")
	assert_contains(code, "{AX, NEGATIVE, -1.75f, 0.4f}")
	assert_contains(code, "COMBINE_ALL = true")
	assert_contains(code, "REFRACTORY_MS = 250")
	assert_contains(code, "SMOOTHING_WINDOW = 3")
	assert_contains(code, "% SMOOTHING_WINDOW", "剰余演算子が残っている")


func test_csharp_snippet_shape() -> void:
	var code := _sample_profile().to_code_snippet("csharp")
	assert_contains(code, "public class MotionDetector")
	assert_contains(code, "new Rule(Axis.GZ, Direction.Positive, 180.5f, 30.25f)")
	assert_contains(code, "new Rule(Axis.AX, Direction.Negative, -1.75f, 0.4f)")
	assert_contains(code, "CombineAll = true")
	assert_contains(code, "% SmoothingWindow")


func test_snippet_number_literals_have_decimal_point() -> void:
	var p := ThresholdProfile.new()
	p.rules.append(ThresholdRule.new(GZ, 200.0, Dir.POSITIVE, 0.0))
	assert_contains(p.to_code_snippet("cpp"), "200.0f, 0.0f")
	assert_contains(p.to_code_snippet("gdscript"), "200.0, 0.0]")


func test_snippet_unknown_language_and_no_rules() -> void:
	var p := _sample_profile()
	assert_eq(p.to_code_snippet("rust"), "")
	var empty := ThresholdProfile.new()
	for lang in ["cpp", "gdscript", "csharp"]:
		assert_contains(empty.to_code_snippet(lang), "有効なルールがありません", lang)


func test_snippet_comment_is_single_line() -> void:
	var p := _sample_profile()
	p.name = "改行\nを含む\r名前"
	var code := p.to_code_snippet("cpp")
	assert_contains(code, "改行 を含む 名前")


## 生成した GDScript を実際にコンパイルし、ThresholdDetector と同じ判定をするか確かめる。
func test_gdscript_snippet_compiles_and_matches_detector() -> void:
	for combine in [ThresholdDetector.Combine.ANY, ThresholdDetector.Combine.ALL]:
		var p := ThresholdProfile.new()
		p.combine = combine
		p.smoothing_window = 3
		p.rules.append(ThresholdRule.new(GZ, 120.0, Dir.POSITIVE, 30.0, 200))
		p.rules.append(ThresholdRule.new(AX, 0.8, Dir.ABSOLUTE, 0.2, 100))
		var script := GDScript.new()
		script.source_code = p.to_code_snippet("gdscript")
		assert_eq(script.reload(), OK, "生成コードがコンパイルできる")
		if not script.can_instantiate():
			return
		var game_side: RefCounted = script.new()
		var detector := p.make_detector()

		var gen := SignalGen.new(7)
		gen.gyro_noise = 40.0      # しきい値付近まで揺れるノイズでチャタリング処理も比べる
		gen.accel_noise = 0.5
		var data: Array[SensorReading] = gen.rest(2000)
		for i in 8:
			data.append_array(gen.gesture(150, Vector3(1.5 if i % 2 == 0 else -1.5, 0, 0), Vector3(0, 0, 250)))
			data.append_array(gen.rest(120 + i * 40))
		var mismatches := 0
		var fires := 0
		for r in data:
			var a := detector.feed(r)
			var b: bool = game_side.call("feed", r.accel, r.gyro, r.timestamp_ms)
			if a != b:
				mismatches += 1
			if a:
				fires += 1
		assert_eq(mismatches, 0, "combine=%d" % combine)
		assert_gt(fires, 0, "判定が起きている（比較が意味を持つ）")
