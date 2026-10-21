# 自動テスト

UI に依存しないロジック層（`src/core/`）の自動テストです。外部アドオンは使わず、Godot だけで動きます。

## 実行方法

```bash
# すべて実行（終了コード 0 = 全部成功 / 1 = 失敗あり）
godot --headless --path . -s res://tests/run_tests.gd

# ファイル名かメソッド名に "analyzer" を含むものだけ実行
godot --headless --path . -s res://tests/run_tests.gd -- --filter=analyzer
```

macOS で Godot.app を使っている場合、`godot` は `/Applications/Godot.app/Contents/MacOS/Godot` です。
新しい `class_name` を追加した直後は、先に `godot --headless --path . --import` を実行してクラスを登録してください。

出力の例:

```
== テスト実行: 11 ファイル ==
OK  test_axis_filter.gd                        8 /   8
NG  test_threshold_rule.gd                    19 /  20
...
---- 失敗一覧 (1) ----
  ✗ test_threshold_rule.gd::test_line_values:84 — 期待値 [1.5] / 実際 [1.4]（説明）

== 結果: 169 件中 168 成功 / 1 失敗（アサーション 1049 回, 950 ms） ==
```

行番号（`:84`）は Godot 4.5 以降でだけ表示されます。

## テストの書き方

`tests/` の下（サブフォルダ可）に `test_*.gd` を作り、`test_case.gd` を継承して `test_` で始まるメソッドを書きます。
ファイルもメソッドも自動で見つかるので、どこかに登録する必要はありません。

```gdscript
extends "res://tests/test_case.gd"
## ThresholdRule のテスト（何のテストかを1行で）

func before_each() -> void:   # 任意。各テストの前に呼ばれる（after_each / before_all / after_all もある）
	pass


func test_positive_rule_fires_at_threshold() -> void:
	var r := ThresholdRule.new(SensorAxis.Id.GZ, 100.0, ThresholdRule.Direction.POSITIVE)
	assert_true(r.exceeds(100.0), "ちょうどしきい値は判定に入る")
	assert_almost_eq(r.line_values()[0], 100.0)
```

- 1つのテストの中でアサーションが失敗しても、そのメソッドは最後まで実行され、失敗はまとめて報告されます。
- 失敗メッセージには「ファイル::メソッド」が付きます。第3引数（または最後の引数）の説明文も添えると原因が分かりやすくなります。
- `class_name` は付けないでください（テスト用クラスがアプリ本体のクラス一覧に混ざるため）。共通処理は `tests/helpers/` に置き、`preload` で使います。

### 使えるアサーション

| メソッド | 内容 |
|---|---|
| `assert_true(cond, msg)` / `assert_false` | 真偽 |
| `assert_eq(actual, expected, msg)` / `assert_ne` | 等しい／等しくない。配列・辞書は中身を再帰的に比較。int と float は数値として比較 |
| `assert_almost_eq(actual, expected, epsilon = 1e-4, msg)` | 浮動小数の比較 |
| `assert_gt` / `assert_ge` / `assert_lt` / `assert_le` | 大小比較 |
| `assert_null` / `assert_not_null` | null かどうか |
| `assert_contains(text, part)` / `assert_not_contains` | 文字列に含まれるか |
| `assert_has(container, item)` | 配列・辞書（キー）に含まれるか |
| `fail(msg)` | 無条件に失敗 |

### ファイルを使うテスト

`make_temp_dir()` で一時フォルダ（`user://__sensor_test_tmp/…`）を作り、その中だけを使います。
テストが終わると自動で消えるので、`user://logs` や `user://thresholds` などアプリの本物のデータは汚しません。

```gdscript
func test_save() -> void:
	var dir := make_temp_dir()
	var path := profile.save_to_dir(dir)        # save() ではなくフォルダ指定版を使う
	var logger := LoggingService.new()
	logger.log_dir = dir                        # LoggingService も保存先を差し替えられる
```

### エンジンのエラーの扱い

Godot 4.5 以降では、テスト中にエンジンのエラー（実行時エラー・`push_error`）が出るとそのテストは失敗になります
（エラーでメソッドが途中終了したのに「成功」と表示されるのを防ぐため）。
わざとエラーを起こすテストでは、先頭で `allow_engine_errors()` を呼んでください。
Godot 4.4 ではこの検出ができないため、出力に `ERROR` が無いかを目で確認してください。

### 合成信号（tests/helpers/signal_gen.gd）

静止ノイズとジェスチャー（半周期の正弦波パルス）を、乱数シード固定で作ります。

```gdscript
const SignalGen := preload("res://tests/helpers/signal_gen.gd")

var gen := SignalGen.new(42)        # シード
gen.gyro_noise = 3.0                # 静止中のノイズ（±deg/s）
var data := gen.rest(3000)          # 静止 3 秒（100Hz）
data.append_array(gen.gesture(150, Vector3.ZERO, Vector3(0, 0, 250)))   # gZ を +250 deg/s 振る
```

## 生成コード（C++ / C#）の等価性チェック

プロファイルから生成するゲーム用の判定コードを実際にコンパイルし、`ThresholdDetector` と同じ判定になるかを比べます。
外部のコンパイラ（clang++ / g++、dotnet）を使うので、上の `run_tests.gd` とは別に実行します。

```bash
tests/snippets/run.sh      # コンパイラが無い言語は SKIP（終了コード 0）
```

詳しくは [`tests/snippets/README.md`](snippets/README.md) を見てください。

## テストファイル一覧

| ファイル | 対象 |
|---|---|
| `test_sensor_axis.gd` | `SensorAxis`（軸キーの往復・値の取り出し・合成値） |
| `test_axis_filter.gd` | `AxisFilter`（移動平均・NaN の扱い） |
| `test_threshold_rule.gd` | `ThresholdRule`（3方向の判定と解除・線の位置・辞書の往復） |
| `test_threshold_detector.gd` | `ThresholdDetector`（ヒステリシス・不応期・ANY/ALL・平滑化・無効ルール・reset） |
| `test_threshold_analyzer.gd` | `ThresholdAnalyzer`（静止測定の自動終了・試行・推奨値の各 quality・向きの推定） |
| `test_analyzer_cancel_restore.gd` | `ThresholdAnalyzer.cancel()` / `restore_measurement()`、`ThresholdProfile.apply_measurement_to()` ほか |
| `test_threshold_profile.gd` | `ThresholdProfile`（JSON 往復・不正入力・保存/一覧/削除・コード生成。生成した GDScript は実際にコンパイルして判定器と一致するか確認） |
| `test_logging_service.gd` | `LoggingService`（軸指定 CSV・既定の6軸） |
| `test_log_replay.gd` | `LogReplay`（P1 形式・軸指定形式・壊れた行） |
| `test_sensor_data_parser.gd` | `SensorDataParser`（CSV/JSON/一部の軸だけの JSON/情報行/CR/ゴミ） |
| `test_mock_sensor_provider.gd` | `MockSensorProvider`（デモデバイスの基本動作） |
| `test_end_to_end.gd` | 合成信号で 測定 → 推奨値 → 判定 を通し、「N 回振って N 回検出・静止で誤検出 0」を複数の軸・向きで確認 |
