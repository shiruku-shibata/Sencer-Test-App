# センサーテストアプリ（Sensor Test App）

ゲーム制作で使う M5 製品（M5StickC Plus2 など）の IMU（加速度・ジャイロ）を PC で受信し、
**「どの軸が、どれくらいの値を超えたら“動作した”とみなすか」＝しきい値** を、
実機を振りながら測定・調整・保存・共有するためのローカルツールです（Godot 4.4 系）。

![しきい値測定画面](docs/images/threshold_screen.png)

## できること

| 機能 | 内容 |
|---|---|
| 接続 | **有線（USBシリアル）** または **BLE**。実機が無くても**デモ**デバイスで一通り試せる |
| 対象機器 | M5StickC Plus2 / Plus / 初代、M5Stack Core2 / CoreS3、AtomS3、ATOM Matrix（[ファームウェア](firmware/m5stick_sender/README.md)） |
| モニタリング | 波形と数値のリアルタイム表示。**指定した軸だけ**表示・CSV記録 |
| デバイス操作 | デバイス管理の「操作…」から一時停止/再開・送信レート（10〜200Hz）変更・情報取得。応答と「実際の受信 Hz / 設定値」を表示（[画面](docs/images/device_commands.png)） |
| **しきい値測定** | ①静止測定（ノイズ）→ ②動作の試行（ピーク）→ ③推奨しきい値と判定品質 → ④判定テスト → ⑤保存・共有 |
| 軸指定 | 加速度 X/Y/Z、ジャイロ X/Y/Z、合成加速度、合成角速度から、使う軸だけを選んで計測・判定 |
| 共有 | しきい値を **JSON プロファイル**で保存・コピー。ゲーム側に貼れる **C++ / GDScript / C# の判定コード**も出力 |
| マニュアル | アプリ内の「マニュアル」画面に手順・軸の選び方・BLE の設定・トラブル対処 |

## ブラウザで試す

ブラウザ版（お試し用）は `sh tools/package_web.sh` で作れます（`build/web-page/`）。
ブラウザでは USB・Bluetooth が使えないため、**デモデバイスだけ**で動きます。日本語フォントはブラウザ版にだけ同梱しています。
デスクトップで同じ見た目を確認するときは `SENSOR_WEB_PREVIEW=1` を付けて起動してください。

## はじめかた（実機なし・5分）

1. [Godot 4.4 以降](https://godotengine.org/) でこのフォルダをプロジェクトとして開き、実行（F5）。
2. 「デバイス管理」で **スキャン** → `demo-01` を **接続**。
3. 「しきい値測定」で軸（例: ジャイロ Z）を選び、次の順に進める。
   1. ① **静止測定を開始**（3 秒）。デモは静止測定の間は振りません。
   2. ② **試行開始**（Space キーでも可）→ デモが約 0.4 秒後に 1 回「振る」（波形が大きく跳ねる）→ **試行終了**。これを 5 回。
   3. ③ 品質が「● 良好」になっているのを確かめて **推奨値を適用**。
   4. ④ 判定テスト: デモは約 3.5 秒ごとに 1 回振るので、そのたびにランプが光り、判定回数が 1 つずつ増えます。
4. ⑤で名前を付けて **保存**、または **JSONをコピー / コードをコピー**。

デモデバイスは「静止中の小さな揺れ ＋ 約 3.5 秒ごとの振り」（gZ・gX・aX が動き、合成値 |a| |g| も変わる）を送ります。
振りの強さは毎回少しずつ違うので、「一番弱い振り」から推奨値が決まる様子も確かめられます。

BLE の流れを実機なしで試すときは、BLE ブリッジの疑似デバイスを使います:

```bash
SENSOR_BLE_MOCK=1 /Applications/Godot.app/Contents/MacOS/Godot --path .   # macOS の例
```

デバイス管理画面に `M5-Sensor-MOCK1` / `M5-Sensor-MOCK2`（方式: BLE）が出ます。

## 実機を使う

1. **ファームウェアを書き込む**（PlatformIO）: 手順と機種ごとの env 名は [firmware/m5stick_sender/README.md](firmware/m5stick_sender/README.md)。
   ```bash
   cd firmware/m5stick_sender
   pio run -e m5stickc_plus2 -t upload
   ```
2. **有線**: USB ケーブル（データ通信対応）で接続し、アプリで スキャン → 接続（macOS は `/dev/cu.*`）。
3. **BLE**: 最初に一度だけブリッジをセットアップします（Python 3.9 以上が必要）。
   ```bash
   sh tools/ble_bridge/setup.sh        # Windows は tools\ble_bridge\setup.bat
   ```
   以後はアプリがブリッジを自動起動します。デバイスは `M5-Sensor-XXXX` という名前で見えます。
   macOS で Bluetooth の権限エラーになる場合は、デバイス管理画面の **「手動起動で接続」** に表示されるコマンドをターミナルで実行してください。
   詳しくは [tools/ble_bridge/README.md](tools/ble_bridge/README.md)。

## しきい値の考え方

```
ノイズ上限   = max(静止中の最大値, 平均 + 4σ)
最弱ピーク   = 各試行のピークのうち最も小さいもの
推奨しきい値 = ノイズ上限 + (最弱ピーク − ノイズ上限) × ratio      （ratio は画面のスライダー）
判定品質     = good / tight（余裕が小さい）/ overlap（静止と動作を区別できない）/ insufficient（測定不足）
```

判定は **ヒステリシス**（しきい値付近での連続判定を防ぐ）と **不応期**（1回の動作で1回だけ判定）込みで行い、
保存したプロファイルから出力するゲーム用コードも同じ判定式になります。値は生の値（重力分などを補正しない）です。

## 構成

```
 M5デバイス (firmware/m5stick_sender)   CSV 1行1サンプル "ax,ay,az,gx,gy,gz"
   ├─ USBシリアル ──────────────► PipeSerialSensorProvider / SerialSensorProvider
   └─ BLE (Nordic UART) ─► BLEブリッジ (tools/ble_bridge, Python+bleak) ─UDP─► BleSensorProvider
                                                         │
                         SensorManager ◄─────────────────┘（通信方式の違いはここで吸収）
              ┌──────────────┼───────────────────┐
        MonitorScreen   ThresholdScreen       LoggingService
                              │
        ThresholdAnalyzer / ThresholdDetector / ThresholdProfile / AxisFilter
```

```
src/core/       ロジック層（UIに依存しない）
  sensor_axis.gd            軸の定義（全機能がこれを通して軸を扱う）
  threshold_*.gd            しきい値の解析・判定・ルール・プロファイル
  axis_filter.gd            軸ごとの移動平均
  logging_service.gd / log_replay.gd   軸指定CSV記録と読み込み
  *_provider.gd             通信方式ごとの受信（有線 / BLE / デモ）
  sensor_manager.gd         Provider の集約・配信
src/ui/         画面とウィジェット（コードで組み立て。文言は ui_strings.gd に集約）
tests/          自動テスト（Godot ヘッドレス）
tools/ble_bridge/   BLE ブリッジ（Python）と、そのテスト
firmware/m5stick_sender/   M5 用送信ファームウェア（PlatformIO）
docs/           設計書・画像
```

設計の背景・チーム分担・インターフェース契約は [docs/DESIGN_P2.md](docs/DESIGN_P2.md) を参照してください。

## テスト

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot          # 環境に合わせて
$GODOT --headless --path . -s res://tests/run_tests.gd                         # ロジック（しきい値・ログ・パーサ等）
$GODOT --headless --path . -s res://tools/ble_bridge/tests/godot_ble_smoke.gd  # アプリ ⇔ BLEブリッジ結合
python3 -m unittest discover -s tools/ble_bridge/tests                         # BLEブリッジ単体
cd firmware/m5stick_sender && pio test -e native                               # ファームウェアの純粋ロジック
```

## ビルド（配布用）

### macOS（共有用 zip）

```bash
sh tools/package_macos.sh            # → build/SensorTestApp-macOS-<バージョン>.zip
```

エクスポートテンプレート（エンジンと同じバージョン）が必要です（エディタの「エクスポートテンプレートの管理」で導入）。
スクリプトが 書き出し → BLE ブリッジの同梱 → 説明書の同梱 → アドホック署名と検証 → zip 化 までを行います。

```
SensorTestApp-macOS/
├── Sensor Test App.app        アプリ本体（Apple シリコン / Intel 両対応。デモ・有線はこれだけで動く）
├── ble_bridge/                BLE を使う人だけ、最初に一度 setup.sh を実行
├── はじめにお読みください.txt  受け取った人向けの説明（初回の開き方・使い方・BLE の準備）
└── THIRD_PARTY_LICENSES.md
```

Apple の公証を受けていないため、受け取った人は初回だけ右クリック →「開く」が必要です
（開けない場合は `xattr -dr com.apple.quarantine "Sensor Test App.app"`）。

### Windows / Linux

`export_presets.cfg` にプリセットがあります（`godot --headless --export-release "Windows Desktop" …`）。
BLE を使う場合は、実行ファイルと同じ場所に `tools/ble_bridge/` の中身を `ble_bridge/` として添えてください
（`.venv` は含めない。手順は tools/ble_bridge/README.md）。

## 既知の制限

- 実機（M5 各機種）での BLE 接続・通知・コマンドは未検証（ビルド・単体テスト・疑似デバイスでの結合テストまで実施済み）。
- Windows / Linux での実行は未検証（パス処理などのコード対応のみ）。
- macOS では BLE の ID が Mac ごとに異なる UUID のため、BLE デバイスのニックネームは Mac ごとに付け直しが必要。

## ライセンス

本リポジトリのライセンスは未定です（公開前に決定します）。
サードパーティのライセンスは [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) を参照してください。
