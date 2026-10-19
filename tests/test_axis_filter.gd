extends "res://tests/test_case.gd"
## AxisFilter（軸ごとの移動平均）のテスト。

const AX := SensorAxis.Id.AX
const GZ := SensorAxis.Id.GZ


func test_window_one_passes_through() -> void:
	var f := AxisFilter.new()
	assert_eq(f.window, 1)
	for v in [0.0, 5.0, -3.5, 100.0]:
		assert_almost_eq(f.push(AX, v), v)


func test_moving_average() -> void:
	var f := AxisFilter.new(3)
	assert_almost_eq(f.push(AX, 3.0), 3.0, 1e-6, "溜まるまでは溜まった分で平均")
	assert_almost_eq(f.push(AX, 6.0), 4.5)
	assert_almost_eq(f.push(AX, 9.0), 6.0)
	assert_almost_eq(f.push(AX, 12.0), 9.0, 1e-6, "古い値が抜ける")
	assert_eq(f.sample_count(AX), 3)
	assert_almost_eq(f.current(AX), 9.0)


func test_axes_are_independent() -> void:
	var f := AxisFilter.new(2)
	f.push(AX, 1.0)
	f.push(GZ, 100.0)
	assert_almost_eq(f.push(AX, 3.0), 2.0)
	assert_almost_eq(f.push(GZ, 200.0), 150.0)


func test_reset_clears_history() -> void:
	var f := AxisFilter.new(4)
	f.push(AX, 10.0)
	f.push(AX, 20.0)
	f.reset()
	assert_eq(f.sample_count(AX), 0)
	assert_almost_eq(f.current(AX), 0.0)
	assert_almost_eq(f.push(AX, 7.0), 7.0)
	assert_eq(f.window, 4, "reset で窓幅は変わらない")


func test_invalid_window_is_clamped() -> void:
	assert_eq(AxisFilter.new(0).window, 1)
	assert_eq(AxisFilter.new(-5).window, 1)


func test_shrinking_window_drops_oldest() -> void:
	var f := AxisFilter.new(4)
	for v in [1.0, 2.0, 3.0, 4.0]:
		f.push(AX, v)
	f.window = 2
	assert_eq(f.sample_count(AX), 2)
	assert_almost_eq(f.current(AX), 3.5)


func test_non_finite_values_are_ignored() -> void:
	var f := AxisFilter.new(2)
	assert_almost_eq(f.push(AX, NAN), 0.0, 1e-6, "空の窓に NaN → 0")
	f.push(AX, 4.0)
	assert_almost_eq(f.push(AX, INF), 4.0, 1e-6, "INF は窓に入れない")
	assert_almost_eq(f.push(AX, -INF), 4.0)
	assert_eq(f.sample_count(AX), 1)


func test_long_run_has_no_drift() -> void:
	# 累積和の誤差が溜まらないこと
	var f := AxisFilter.new(5)
	for i in 10000:
		f.push(AX, 1000000.0 + 0.1 * float(i % 7))
	for i in 5:
		f.push(AX, 0.5)
	assert_almost_eq(f.current(AX), 0.5, 1e-9)
