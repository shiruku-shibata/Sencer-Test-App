# P2 設計書：しきい値測定・BLE接続・軸指定計測

この文書は P2 の開発を4人のチーム（＋リード）で並行して進めるための「契約」です。
後から参加した人は、まずこの文書と README を読めば全体像がつかめるようにしています。

## 1. 目的

ゲーム制作で使う M5 製品（M5StickC Plus2 など）の IMU について、
**「どの軸が、どれくらいの値を超えたら“動作した”とみなすか」＝しきい値** を、
実機を振りながら測定・調整・保存・共有できるようにする。

| 要件 | 内容 |
|---|---|
| しきい値測定 | 静止状態のノイズと、動作時のピークを測り、推奨しきい値を算出する |
| 判定テスト | 決めたしきい値で実際に判定が出るかをリアルタイムに確認する |
| 軸指定 | 加速度 X/Y/Z・ジャイロ X/Y/Z・合成値のうち、指定した軸だけで計測・判定・記録する |
| 接続方法 | 有線（USBシリアル）または BLE |
| 対象機器 | M5StickC Plus2 を主に、M5Unified が対応する IMU 付き M5 製品 |
| 共有 | しきい値を JSON プロファイルとして保存し、他の人やゲーム側コードに渡せる |

## 2. 全体構成

```
 M5デバイス (firmware/m5stick_sender)
   │  CSV 1行1サンプル  "ax,ay,az,gx,gy,gz\n"
   ├── USBシリアル ───────────────► PipeSerialSensorProvider / SerialSensorProvider
   └── BLE (Nordic UART Service)
          └─► BLEブリッジ (tools/ble_bridge, Python+bleak)
                 └─ UDP(localhost) ─► BleSensorProvider
                                            │
                    SensorManager ◄─────────┘  （通信方式の違いはここで吸収）
                         │ reading_received(SensorReading)
        ┌────────────────┼─────────────────────┐
   MonitorScreen    ThresholdScreen        LoggingService
   (軸指定表示)      (測定・判定テスト)      (軸指定CSV記録)
                         │
          ThresholdAnalyzer / ThresholdDetector / ThresholdProfile
```

Godot には BLE の標準機能が無く、GDExtension のバイナリ同梱はライセンス・配布が複雑になるため、
**BLE は別プロセスのブリッジ（Python + bleak, MIT）で受け、ローカル UDP でアプリに渡す**方式にする。
ブリッジはアプリから自動起動するが、macOS の Bluetooth 権限の都合で起動できない場合は
ターミナルから手動起動しても同じように動く設計とする。

## 3. 共通ルール

- エンジン: **Godot 4.4 系互換**で書く（開発機には 4.7 もあるが、4.5 以降の新APIは使わない）。
- UI はコードで組み立てる（既存方針）。UI 文言は `src/ui/ui_strings.gd` に集約する。
- コメント・UI 文言は日本語。既存コードの書き方（`##` ドキュメントコメント、型付き変数）に合わせる。
- 軸は必ず `SensorAxis`（`src/core/sensor_axis.gd`）経由で扱う。キー文字列（`ax`, `amag` 等）は保存形式なので変更禁止。
- 自動テストは `tests/` に置き、次のコマンドで実行できること（終了コード 0 = 成功）:
  ```bash
  godot --headless --path . -s res://tests/run_tests.gd
  ```
- 構文チェック: `godot --headless --path . --import` でエラーが出ないこと。

## 4. 担当とファイル所有

並行作業で衝突しないよう、**ファイル単位で担当を分ける**。担当外のファイルを変更したいときはリードに依頼する。

| 担当 | 役割 | 所有ファイル |
|---|---|---|
| A ファームウェア | M5 各機種対応、BLE送信、コマンド受付 | `firmware/**` |
| B 接続(BLE) | BLEブリッジ、BleSensorProvider、デバイス管理画面 | `tools/ble_bridge/**`, `src/core/ble_*.gd`, `src/core/sensor_provider.gd`, `src/core/sensor_manager.gd`, `src/core/sensor_device.gd`, `src/core/device_registry.gd`, `src/core/*serial*.gd`, `src/ui/screens/devices_screen.gd`, `export_presets.cfg`, `THIRD_PARTY_LICENSES.md` |
| C しきい値ロジック | 解析・判定・プロファイル・軸指定ログ・自動テスト | `src/core/threshold_*.gd`, `src/core/axis_filter.gd`, `src/core/log_replay.gd`, `src/core/logging_service.gd`, `src/core/sensor_reading.gd`, `src/core/sensor_data_parser.gd`, `tests/**` |
| D UI | しきい値測定画面、軸選択、波形ウィジェット、マニュアル | `src/ui/**`（`devices_screen.gd` を除く） |
| リード | 設計・統合・README・レビュー | `docs/**`, `README.md`, `src/core/sensor_axis.gd`, `.gitignore`, `project.godot` |

## 5. インターフェース契約

### 5.1 SensorAxis（実装済み・リード）

`src/core/sensor_axis.gd` を参照。主なAPI:

```gdscript
enum Id { AX, AY, AZ, GX, GY, GZ, ACCEL_MAG, GYRO_MAG }
const ALL: Array[int]; const RAW: Array[int]
static func key(axis) -> String            # "ax" … "amag","gmag"
static func from_key(key) -> int           # 不明は -1
static func label(axis) / short_label(axis) / unit(axis) -> String
static func color(axis) -> Color
static func is_accel(axis) / is_magnitude(axis) -> bool
static func default_range(axis) -> float
static func value_of(reading: SensorReading, axis) -> float
static func keys_of(axes: Array) -> PackedStringArray
```

### 5.2 しきい値ロジック（C が実装、D が利用）

```gdscript
class_name AxisFilter extends RefCounted
## 軸ごとの移動平均。window=1 で素通し。解析・判定・表示で同じ平滑化を使うための共通部品。
func _init(window: int = 1)
var window: int
func push(axis: int, value: float) -> float      # 平滑化後の値を返す
func reset() -> void

class_name ThresholdRule extends RefCounted
enum Direction { POSITIVE, NEGATIVE, ABSOLUTE }
var axis: int                    # SensorAxis.Id
var enabled := true
var threshold: float = 0.0       # POSITIVE/NEGATIVE: 波形上の実際の値（NEGATIVE なら通常マイナス）
                                 # ABSOLUTE: 正の大きさ（±threshold を超えたら判定）
var direction: int = Direction.ABSOLUTE
var hysteresis: float = 0.0      # 判定解除はしきい値からこの量だけ戻ったとき（チャタリング防止）
var refractory_ms: int = 200     # 一度判定したら、この時間は次の判定をしない
func exceeds(value: float) -> bool
func released(value: float) -> bool
func line_values() -> PackedFloat32Array   # 波形に引く線（ABSOLUTE は [t, -t]）
func to_dict() -> Dictionary
static func from_dict(d: Dictionary) -> ThresholdRule
static func direction_label(direction: int) -> String   # "＋方向" / "−方向" / "絶対値"

class_name ThresholdDetector extends RefCounted
enum Combine { ANY, ALL }        # ANY: どれか1軸が超えたら / ALL: 全軸が同時に超えたら
signal fired(timestamp_ms: int, values: Dictionary)   # values: axis -> 値
var rules: Array[ThresholdRule]
var combine: int = Combine.ANY
var smoothing_window: int = 1
var trigger_count: int = 0
func configure(rules: Array, combine: int, smoothing_window: int = 1) -> void
func feed(reading: SensorReading) -> bool       # 判定が立ち上がった瞬間だけ true（fired も発火）
func is_active() -> bool                         # 組み合わせ条件を満たしている最中か
func axis_active(axis: int) -> bool
func last_value(axis: int) -> float              # 平滑化後の直近値
func reset() -> void                             # 状態とカウントをクリア

class_name ThresholdAnalyzer extends RefCounted
enum Phase { IDLE, BASELINE, TRIAL }
signal phase_changed(phase: int)
signal baseline_finished(stats: Dictionary)          # axis -> {mean, stddev, min, max, count}
signal trial_finished(index: int, result: Dictionary)  # axis -> {max, min, peak_abs, count, duration_ms}
var axes: Array[int]
var smoothing_window: int = 1
func set_axes(axes: Array) -> void                   # 変更時は全結果をクリア
func start_baseline(duration_ms: int = 3000) -> void # 受信サンプルの時刻で自動終了
func start_trial(max_duration_ms: int = 0) -> void   # 0 = stop() まで
func stop() -> void                                  # 実行中のフェーズを終了（結果確定）
func feed(reading: SensorReading) -> void
func phase() -> int
func progress() -> float                             # 0..1（BASELINE / 時間指定TRIAL）
func baseline() -> Dictionary                        # 未測定なら空
func trials() -> Array                               # Array[Dictionary]
func remove_trial(index: int) -> void
func clear_trials() -> void
func clear_all() -> void
func suggest_direction(axis: int) -> int             # 試行結果から向きを推定
func recommend(axis: int, direction: int, ratio: float = 0.5) -> Dictionary
    # 戻り値 {threshold, hysteresis, noise_level, weakest_peak, margin, quality}
    # ratio: 0.0=ノイズ上限ぎりぎり（検出しやすい）〜 1.0=最も弱い試行のピーク（誤検出しにくい）
    # quality: "good" | "tight" | "overlap" | "insufficient"（静止測定 or 試行が無い）
func build_rule(axis: int, direction: int, ratio: float = 0.5) -> ThresholdRule

class_name ThresholdProfile extends RefCounted
const DIR := "user://thresholds"
const FORMAT_VERSION := 1
var name: String
var device_name: String
var rules: Array[ThresholdRule]
var combine: int
var smoothing_window: int
var sample_rate_hz: float
var measurement: Dictionary      # 任意: {baseline: {...}, trials: [...]}（軸キーで保存）
var created_at: String
var note: String
func to_dict() -> Dictionary
static func from_dict(d: Dictionary) -> ThresholdProfile
func to_json() -> String
static func from_json(text: String) -> ThresholdProfile   # 不正なら null
func save() -> String                                      # 保存先パスを返す（失敗は ""）
static func load_file(path: String) -> ThresholdProfile
static func list_files() -> Array                          # [{name, path, modified}]
static func delete_file(path: String) -> void
static func open_folder() -> void
func to_code_snippet(lang: String) -> String               # "cpp" | "gdscript" | "csharp"
```

推奨しきい値の考え方（POSITIVE の場合）:

```
ノイズ上限   noise   = max(静止中の最大値, 平均 + 4σ)
最弱ピーク   weakest = 各試行の最大値のうち最小のもの
推奨値       threshold = noise + (weakest - noise) * ratio
余裕         margin = weakest - noise   （<= 0 なら overlap: 静止と動作を区別できない）
```

NEGATIVE は符号を反転して同様、ABSOLUTE は絶対値で同様に扱う。値は**生の値**（重力分を引かない）で扱い、
ゲーム側で同じ式をそのまま使えるようにする。

### 5.3 ログ（C）

```gdscript
LoggingService.start(device: SensorDevice, axes: Array = []) -> bool   # 空 = 生の6軸
# CSV: 1行目 "# device_id=… nickname=… axes=ax,gz"  2行目 "timestamp_ms,ax,gz"
LogReplay.load_csv(path: String) -> Array     # Array[SensorReading]。欠けた列は 0。合成列は無視
LogReplay.axes_in(path: String) -> Array      # そのCSVに含まれる軸
```

### 5.4 波形ウィジェット（D）

`WaveformView` を拡張: しきい値線（ドラッグ可）、判定マーカー、ノイズ帯の描画、`signal line_dragged(id, value)`。

### 5.5 接続（B）

- `SensorProvider` に `signal devices_discovered(devices: Array)`（非同期スキャン結果）と `func shutdown()` を追加。
  `SensorManager` は `devices_discovered` を受けてレジストリへ反映し、終了時に全 Provider を `shutdown()` する。
- `SensorDevice` に広告名などの `label`（ニックネーム未設定時の表示名）と `rssi` を追加。
- BLE デバイスの ID は bleak が返すアドレス（macOS では UUID、Windows/Linux では MAC）。

### 5.6 BLE プロトコル（A と B の契約）

| 項目 | 値 |
|---|---|
| サービス | Nordic UART Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX（デバイス→PC, Notify） | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX（PC→デバイス, Write） | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| デバイス名 | `M5-Sensor-XXXX`（XXXX = MAC 下位2バイトの16進） |
| 広告 | 広告パケットにサービスUUID、スキャン応答にデバイス名 |
| データ | 有線と同じ CSV 行 `ax,ay,az,gx,gy,gz\n`。1通知に複数行／1行が複数通知に分割される場合があるため、受信側は改行で組み立てる |
| 情報行 | `#` で始まる行は情報（例 `# model=M5StickCPlus2 rate=100`）。アプリは無視してよい |
| コマンド（有線・BLE共通, 改行終端） | `PAUSE` / `RESUME` / `RATE <Hz>`（10〜200）/ `INFO` |

### 5.7 アプリ ⇔ BLEブリッジ（B 内部）

ローカル UDP、1データグラム = 1 JSON。アプリ側 `127.0.0.1:47810`、ブリッジ側 `127.0.0.1:47811`。
詳細は `tools/ble_bridge/README.md`（B が作成）。ブリッジには実機なしで動く `--mock` モードを用意する。

## 6. 受け入れ条件

1. 実機なし（デモデバイス）で、しきい値測定の一連の流れ（静止測定 → 試行×数回 → 推奨値 → 判定テスト → 保存）ができる。
2. 軸を1つだけ（例: ジャイロ Z）選んで、測定・判定・記録ができる。CSV にはその軸の列だけが出る。
3. BLE ブリッジの `--mock` モードで、BLE デバイスとしてスキャン・接続・波形表示ができる。
4. bleak / Python が無い環境でもアプリは起動し、BLE が使えない理由と対処がデバイス管理画面に出る。
5. ファームウェアが M5StickC Plus2 向けにビルドできる（`pio run`）。
6. `tests/run_tests.gd` が成功する。
