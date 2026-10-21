extends SceneTree
## 生成コードの等価性チェック用: シナリオごとに
##   <name>.h / <name>.cs   … ThresholdProfile.to_code_snippet("cpp" / "csharp") の出力
##   <name>.input.txt       … 入力列（1行 = "ax ay az gx gy gz timestamp_ms"）
##   <name>.expected.txt    … 同じ入力を ThresholdDetector に流したときの判定（1行 = 0/1）
## を書き出す。cases.txt にシナリオ名の一覧を書く。
##
##   godot --headless --path . -s res://tests/snippets/gen_cases.gd -- --out=/tmp/xxx
##
## 通常は tests/snippets/run.sh から呼ばれる（直接使う必要はない）。
##
## 入力値は「書き出した10進文字列 → float32」に丸めてから ThresholdDetector に渡す。
## C++ / C# 側は同じ文字列を float で読むので、両者は同じ入力を見ている。

const SignalGen := preload("res://tests/helpers/signal_gen.gd")
const Dir := ThresholdRule.Direction
const ANY := ThresholdDetector.Combine.ANY
const ALL := ThresholdDetector.Combine.ALL
const AX := SensorAxis.Id.AX
const AZ := SensorAxis.Id.AZ
const GX := SensorAxis.Id.GX
const GZ := SensorAxis.Id.GZ
const AMAG := SensorAxis.Id.ACCEL_MAG
const GMAG := SensorAxis.Id.GYRO_MAG


func _initialize() -> void:
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if out.is_empty():
		printerr("使い方: -- --out=<出力フォルダ>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)

	var names := PackedStringArray()
	for c in _cases():
		var name: String = c["name"]
		var profile: ThresholdProfile = c["profile"]
		var data: Array[SensorReading] = c["data"]
		_write(out.path_join(name + ".h"), profile.to_code_snippet("cpp"))
		_write(out.path_join(name + ".cs"), profile.to_code_snippet("csharp"))
		var input := PackedStringArray()
		var expected := PackedStringArray()
		var detector := profile.make_detector()
		var fires := 0
		for r in data:
			var line := _format(r)
			input.append(line)
			var fired := detector.feed(_parse(line, r.device_id))
			expected.append("1" if fired else "0")
			if fired:
				fires += 1
		_write(out.path_join(name + ".input.txt"), "\n".join(input) + "\n")
		_write(out.path_join(name + ".expected.txt"), "\n".join(expected) + "\n")
		names.append(name)
		print("  生成: %-22s サンプル %5d / 判定 %3d 回" % [name, data.size(), fires])
	_write(out.path_join("cases.txt"), "\n".join(names) + "\n")
	quit(0)


# ------------------------------------------------------------ シナリオ

func _cases() -> Array:
	var cases: Array = []

	# 1. ＋方向・平滑化なし・ヒステリシスあり
	var g1 := SignalGen.new(11)
	g1.gyro_noise = 15.0
	g1.rebound = 0.3
	cases.append(_case("pos_gz", [ThresholdRule.new(GZ, 120.0, Dir.POSITIVE, 30.0, 200)], ANY, 1,
			_stream(g1, 14, func(g: SignalGen, i: int) -> Array[SensorReading]:
				return g.gesture(150, Vector3.ZERO, Vector3(0, 0, 180.0 + 15.0 * (i % 4))))))

	# 2. −方向・平滑化 3
	var g2 := SignalGen.new(22)
	g2.accel_noise = 0.15
	g2.rebound = 0.3
	cases.append(_case("neg_ax_smooth3", [ThresholdRule.new(AX, -1.2, Dir.NEGATIVE, 0.3, 200)], ANY, 3,
			_stream(g2, 14, func(g: SignalGen, i: int) -> Array[SensorReading]:
				return g.gesture(150, Vector3(-1.8 - 0.1 * (i % 3), 0, 0), Vector3.ZERO))))

	# 3. 絶対値・左右交互
	var g3 := SignalGen.new(33)
	g3.gyro_noise = 20.0
	cases.append(_case("abs_gx", [ThresholdRule.new(GX, 150.0, Dir.ABSOLUTE, 40.0, 150)], ANY, 1,
			_stream(g3, 14, func(g: SignalGen, i: int) -> Array[SensorReading]:
				var s := 1.0 if i % 2 == 0 else -1.0
				return g.gesture(150, Vector3.ZERO, Vector3(240.0 * s, 0, 0)))))

	# 4. 2軸 ANY（ジャイロ＋方向・合成加速度 絶対値）・平滑化 3
	var g4 := SignalGen.new(44)
	g4.gyro_noise = 10.0
	g4.accel_noise = 0.1
	cases.append(_case("any_gz_amag", [
				ThresholdRule.new(GZ, 120.0, Dir.POSITIVE, 30.0, 200),
				ThresholdRule.new(AMAG, 1.8, Dir.ABSOLUTE, 0.3, 300),
			], ANY, 3,
			_stream(g4, 15, func(g: SignalGen, i: int) -> Array[SensorReading]:
				match i % 3:
					0: return g.gesture(150, Vector3.ZERO, Vector3(0, 0, 200))
					1: return g.gesture(150, Vector3(1.6, 0, 0), Vector3.ZERO)
				return g.gesture(150, Vector3(1.6, 0, 0), Vector3(0, 0, 200)))))

	# 5. 2軸 ALL（片方だけの動作は判定しない）・平滑化 2
	var g5 := SignalGen.new(55)
	g5.gyro_noise = 10.0
	g5.accel_noise = 0.1
	cases.append(_case("all_ax_gz", [
				ThresholdRule.new(AX, 0.8, Dir.POSITIVE, 0.2, 200),
				ThresholdRule.new(GZ, 110.0, Dir.POSITIVE, 25.0, 200),
			], ALL, 2,
			_stream(g5, 15, func(g: SignalGen, i: int) -> Array[SensorReading]:
				match i % 3:
					0: return g.gesture(150, Vector3(1.5, 0, 0), Vector3(0, 0, 200))
					1: return g.gesture(150, Vector3(1.5, 0, 0), Vector3.ZERO)
				return g.gesture(150, Vector3.ZERO, Vector3(0, 0, 200)))))

	# 6. ヒステリシス 0・不応期 0（ゆっくりした動作 + 大きいノイズでチャタリングする波形）
	var g6 := SignalGen.new(66)
	g6.gyro_noise = 25.0
	cases.append(_case("chatter_no_hys", [ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 0.0, 0)], ANY, 1,
			_stream(g6, 8, func(g: SignalGen, _i: int) -> Array[SensorReading]:
				return g.gesture(800, Vector3.ZERO, Vector3(0, 0, 200)))))

	# 7. 長い不応期（300ms 間隔の連打の一部だけ判定）
	var g7 := SignalGen.new(77)
	g7.gyro_noise = 5.0
	var taps: Array[SensorReading] = g7.rest(500)
	for _i in 20:
		taps.append_array(g7.gesture(100, Vector3.ZERO, Vector3(0, 0, 250)))
		taps.append_array(g7.rest(200))
	cases.append(_case("refractory_600", [ThresholdRule.new(GZ, 120.0, Dir.POSITIVE, 30.0, 600)], ANY, 1, taps))

	# 8. 重力のかかる軸の −方向（正のしきい値）＋ 合成角速度、無効なルール入り、平滑化 5
	var g8 := SignalGen.new(88)
	g8.rest_accel = Vector3(0, 0, 1.0)
	g8.accel_noise = 0.05
	g8.gyro_noise = 8.0
	var disabled := ThresholdRule.new(GX, 1.0, Dir.ABSOLUTE, 0.0, 0)
	disabled.enabled = false
	cases.append(_case("neg_az_gravity_gmag", [
				ThresholdRule.new(AZ, 0.5, Dir.NEGATIVE, 0.15, 250),
				ThresholdRule.new(GMAG, 220.0, Dir.POSITIVE, 50.0, 250),
				disabled,
			], ANY, 5,
			_stream(g8, 14, func(g: SignalGen, i: int) -> Array[SensorReading]:
				if i % 2 == 0:
					return g.gesture(200, Vector3(0, 0, -0.9), Vector3.ZERO)   # 落下（aZ が 0.1 付近まで下がる）
				return g.gesture(200, Vector3.ZERO, Vector3(200, 150, 0)))))

	# 9. 同じ軸の ＋方向・−方向を ANY（どちらに振っても判定）、平滑化 10
	var g9 := SignalGen.new(99)
	g9.gyro_noise = 12.0
	cases.append(_case("same_axis_both_ways", [
				ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 25.0, 200),
				ThresholdRule.new(GZ, -100.0, Dir.NEGATIVE, 25.0, 200),
			], ANY, 10,
			_stream(g9, 14, func(g: SignalGen, i: int) -> Array[SensorReading]:
				var s := 1.0 if i % 3 != 0 else -1.0
				return g.gesture(250, Vector3.ZERO, Vector3(0, 0, 220.0 * s)))))

	# 10〜12. 不応期 0 でヒステリシスだけが効く（ゆっくりした動作 + 大きいノイズ）。＋/−/絶対値それぞれ
	var g10 := SignalGen.new(110)
	g10.gyro_noise = 25.0
	cases.append(_case("hys_only_pos", [ThresholdRule.new(GZ, 100.0, Dir.POSITIVE, 45.0, 0)], ANY, 1,
			_stream(g10, 8, func(g: SignalGen, _i: int) -> Array[SensorReading]:
				return g.gesture(800, Vector3.ZERO, Vector3(0, 0, 200)))))
	var g11 := SignalGen.new(111)
	g11.accel_noise = 0.25
	cases.append(_case("hys_only_neg", [ThresholdRule.new(AX, -1.0, Dir.NEGATIVE, 0.45, 0)], ANY, 1,
			_stream(g11, 8, func(g: SignalGen, _i: int) -> Array[SensorReading]:
				return g.gesture(800, Vector3(-2.0, 0, 0), Vector3.ZERO))))
	var g12 := SignalGen.new(112)
	g12.gyro_noise = 25.0
	cases.append(_case("hys_only_abs", [ThresholdRule.new(GX, 100.0, Dir.ABSOLUTE, 45.0, 0)], ANY, 1,
			_stream(g12, 8, func(g: SignalGen, i: int) -> Array[SensorReading]:
				return g.gesture(800, Vector3.ZERO, Vector3(200.0 if i % 2 == 0 else -200.0, 0, 0)))))

	# 13. 不応期のちょうど境界（ノイズ無し、300ms 周期の連打に不応期 300ms → 「経過 = 不応期」で判定できる）
	var g13 := SignalGen.new(113)
	g13.gyro_noise = 0.0
	g13.accel_noise = 0.0
	g13.t_ms = 1000
	var exact: Array[SensorReading] = g13.rest(500)
	for _i in 12:
		exact.append_array(g13.gesture(100, Vector3.ZERO, Vector3(0, 0, 250)))
		exact.append_array(g13.rest(200))   # 10 サンプル + 20 サンプル = 30 サンプル = ちょうど 300ms 周期
	cases.append(_case("refractory_boundary", [ThresholdRule.new(GZ, 120.0, Dir.POSITIVE, 0.0, 300)], ANY, 1, exact))

	# 14. 50Hz で測ったプロファイル（平滑化 5）。生成コードの update() は 20ms ごとにだけ読む
	var g14 := SignalGen.new(114)
	g14.interval_ms = 20
	g14.gyro_noise = 30.0
	var c14 := _case("rate_50hz_smooth5", [ThresholdRule.new(GZ, 110.0, Dir.POSITIVE, 25.0, 200)], ANY, 5,
			_stream(g14, 12, func(g: SignalGen, i: int) -> Array[SensorReading]:
				return g.gesture(200, Vector3.ZERO, Vector3(0, 0, 200.0 + 20.0 * (i % 3)))))
	c14["profile"].sample_rate_hz = 50.0
	cases.append(c14)
	return cases


func _case(name: String, rules: Array, combine: int, smoothing: int, data: Array[SensorReading]) -> Dictionary:
	var p := ThresholdProfile.new()
	p.name = name
	p.created_at = "2026-01-01T00:00:00"
	p.combine = combine
	p.smoothing_window = smoothing
	p.sample_rate_hz = 100.0   # 入力は 10ms 間隔（SignalGen の既定）。違うシナリオは呼び出し側で上書きする
	for r in rules:
		p.rules.append(r)
	return {"name": name, "profile": p, "data": data}


## 静止 → (ジェスチャー → 間隔) × count → 静止
func _stream(gen: SignalGen, count: int, gesture: Callable) -> Array[SensorReading]:
	gen.t_ms = 1000
	var out: Array[SensorReading] = gen.rest(1000)
	for i in count:
		out.append_array(gesture.call(gen, i))
		out.append_array(gen.rest(150 + (i % 4) * 120))
	out.append_array(gen.rest(1500))
	return out


# ------------------------------------------------------------ 入出力

func _format(r: SensorReading) -> String:
	return "%.6f %.6f %.6f %.4f %.4f %.4f %d" % [
		r.accel.x, r.accel.y, r.accel.z, r.gyro.x, r.gyro.y, r.gyro.z, r.timestamp_ms]


## 書き出した文字列を読み直し、float32 に丸める（C++ / C# 側が float で読むのと同じ値にする）。
func _parse(line: String, device_id: String) -> SensorReading:
	var p := line.split(" ")
	var f := PackedFloat32Array()
	for i in 6:
		f.append(p[i].to_float())
	return SensorReading.new(device_id, int(p[6]), Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]))


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("書き込めません: " + path)
		quit(1)
		return
	file.store_string(text)
	file.close()
