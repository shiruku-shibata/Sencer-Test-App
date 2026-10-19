# m5stick_sender — センサーテストアプリ用 送信ファームウェア

M5 製品の内蔵 IMU（加速度・ジャイロ）を一定間隔で読み取り、
**USB シリアル** と **BLE（Nordic UART Service）** の両方に CSV で送るファームウェアです。
PC 側の「センサーテストアプリ」（Godot）がこれを受信して波形表示・しきい値測定を行います。

- 通信仕様（アプリとの契約）: [`docs/DESIGN_P2.md`](../../docs/DESIGN_P2.md) の **5.6 BLE プロトコル**
- バージョン: `2.0.0`（`INFO` コマンドの `fw=` で確認できます）

> **はじめて読む人へ**: まず「[書き込みまでの手順](#書き込みまでの手順)」で手元の M5 に書き込み、
> 「[動作確認](#動作確認)」でシリアルモニタに CSV が流れることを確認してください。
> コードを触る人は「[開発者向け](#開発者向け)」へ。

---

## 対応機種

機種は起動時に **M5Unified が自動判別**します。env は「どのチップ・フラッシュ構成でビルドするか」を選ぶものです。

| env 名（`-e`） | 対象 | ボード定義 | IMU | 画面 | 一時停止/再開 | 備考 |
|---|---|---|---|---|---|---|
| `m5stickc_plus2`（既定） | M5StickC Plus2 | `m5stack-stickc-plus2` ※ | MPU6886 | 135×240 | A ボタン（M5 ロゴ） | 本命 |
| `m5stickc_plus` | M5StickC Plus | `m5stack-stickc-plus` ※ | MPU6886 | 135×240 | A ボタン | |
| `m5stickc` | M5StickC（初代） | `m5stick-c` | MPU6886 / SH200Q | 80×160 | A ボタン | |
| `m5stack_core2` | M5Stack Core2 | `m5stack-core2` | MPU6886 / BMI270(v1.1) | 320×240 | 画面下の左タッチボタン | |
| `m5stack_cores3` | M5Stack CoreS3 / CoreS3 SE | `m5stack-cores3` | BMI270 | 320×240 | 画面タップ | SE は IMU 非搭載のため `IMU ERROR` |
| `m5stack_atoms3` | M5Stack AtomS3 | `m5stack-atoms3` | MPU6886 | 128×128 | 画面（ボタン）を押す | USB は S3 内蔵 CDC |
| `m5stack_atom` | ATOM Matrix（MPU6886 搭載の初代 ATOM） | `m5stack-atom` | MPU6886 | 無し（LED で表示） | 画面（ボタン）を押す | ATOM Lite は IMU 無し |

※ `m5stack-stickc-plus2` / `m5stack-stickc-plus` は固定している platform（espressif32 6.13.0）に含まれないため、
  このフォルダの [`boards/`](boards/) に同名のローカル定義を置いています（PlatformIO はプロジェクト内の `boards/` を優先して使います）。

**IMU が無い／初期化に失敗した場合**は、データを送らずに画面に `IMU ERROR`、
シリアル（と BLE）に `# error=imu_not_found` を 5 秒おきに出します。BLE とコマンドは動き続けます。

---

## 書き込みまでの手順

### 必要なもの

- [PlatformIO Core](https://platformio.org/install/cli)（VS Code の PlatformIO 拡張でも可）
  - コマンドが `pio` で見つからない場合は `~/.platformio/penv/bin/pio` を使ってください。
- USB-C ケーブル（**データ通信対応のもの**。充電専用ケーブルではポートが出ません）
- 初回ビルド時はインターネット接続（platform・ライブラリを自動ダウンロードします）

### ビルドと書き込み

```bash
cd firmware/m5stick_sender

# ビルドだけ（既定 = M5StickC Plus2）
pio run

# 機種を指定してビルド
pio run -e m5stack_core2

# 書き込み（ポートは自動検出。複数つないでいるときは --upload-port で指定）
pio run -e m5stickc_plus2 -t upload
pio run -e m5stickc_plus2 -t upload --upload-port /dev/cu.usbserial-XXXX   # macOS の例
pio run -e m5stickc_plus2 -t upload --upload-port COM5                     # Windows の例

# 全機種をまとめてビルド（CI やライブラリ更新時の確認用）
pio run -e m5stickc_plus2 -e m5stickc_plus -e m5stickc -e m5stack_core2 \
        -e m5stack_cores3 -e m5stack_atoms3 -e m5stack_atom
```

### 動作確認

```bash
pio device monitor        # 115200bps。終了は Ctrl+C
```

起動直後（または `INFO` と入力して Enter）に次のような情報行が出て、その後 CSV が流れれば成功です。

```
# model=M5StickCPlus2 name=M5-Sensor-1A2B rate=100 ble=1 fw=2.0.0 imu=MPU6886 sending=1 connected=0 drop_usb=0 drop_ble=0
0.0210,0.9832,-0.0104,12.400,-3.100,0.800
0.0198,0.9841,-0.0099,12.150,-2.950,0.810
...
```

> モニタ中にコマンドを打つと 1 文字ずつ送られ、Enter（改行）で 1 コマンドとして解釈されます。
> 入力した文字は画面にエコー表示されます（platformio.ini の `monitor_echo = yes`）。

---

## 出力形式

| 項目 | 内容 |
|---|---|
| 行の形式 | `ax,ay,az,gx,gy,gz\n`（P1 の有線と同じ。アプリ側 `SensorDataParser` がそのまま読む） |
| 単位 | 加速度 **G**（小数 4 桁）、角速度 **deg/s**（小数 3 桁） |
| 例 | `0.0210,0.9832,-0.0104,12.400,-3.100,0.800` |
| 改行 | LF（`\n`） |
| シリアル | 115200bps, 8N1 |
| 送信レート | 既定 100Hz。`RATE` コマンドで 10〜200Hz に変更可（再起動で 100Hz に戻る） |
| 情報行 | `#` で始まる行。アプリは無視してよい（CSV として解釈できないので自動的に捨てられる） |

値は M5Unified が返す**生の値**（重力分を引かない）です。軸の向きは機種ごとの M5Unified の既定に従います。

### 送信タイミング

`millis()` を基準に「n 回目の送信予定 = 起点 + n×1000/レート」で送るので、
1000/レートが割り切れないレート（例: 30Hz）でも長時間で送信回数がずれません。
画面描画などで少し（100ms 以内）遅れたときは連続送信で追いつき、
それ以上遅れたときはまとめ送りをせずに起点を取り直します。

### USB シリアルが詰まったとき

PC がポートを開いていない・読んでいないときに送信が止まらないよう、
送信バッファ（1024 バイト）に入りきらない行は**待たずに捨てます**（行の途中で切れることはありません）。
捨てた行数は情報行の `drop_usb=` で確認できます。

---

## BLE 仕様

[`docs/DESIGN_P2.md`](../../docs/DESIGN_P2.md) 5.6 の実装です。PC 側は `tools/ble_bridge`（Python + bleak）が受けます。

| 項目 | 値 |
|---|---|
| サービス | Nordic UART Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX（デバイス→PC, **Notify**） | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX（PC→デバイス, **Write / Write Without Response**） | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| デバイス名 | `M5-Sensor-XXXX`（XXXX = BLE アドレスの下位 2 バイトを 16 進大文字。例 `M5-Sensor-1A2B`） |
| 広告パケット | Flags + 128bit サービス UUID（21 / 31 バイト） |
| スキャン応答 | デバイス名（16 / 31 バイト） |
| 同時接続 | 1 台。切断されると自動で広告を再開 |
| 接続パラメータ | 接続後に 15〜30ms 間隔を要望（OS が拒否しても動作する） |

### データの流れ

- **TX の購読（Notify 有効化）をしている間だけ**データを送ります。接続しただけでは送りません。
- 購読が始まると、最初に**情報行**（`# model=... rate=...`）を 1 行送ります。
- データは有線と同じ CSV 行です。**1 通知に複数行が入ることも、1 行が複数通知に分かれることもあります。**
  受信側は通知のバイト列をつなげて、改行（`\n`）で 1 行ずつ取り出してください。
  - 1 通知の最大長は MTU − 3 バイト（最大 244）。行はできるだけ改行の位置で区切って送り、
    1 行が収まらないとき（MTU 23 = 20 バイトのときなど）だけ行の途中で分割します。
- 送信が追いつかないときは**古い行から捨てて**新しい行を優先します（鮮度優先）。
  ただし途中まで送った行は最後まで送るので、受信側で行が壊れることはありません。捨てた行数は `drop_ble=`。
- 切断・再購読のときは、送信待ちのデータは捨てて新しく送り直します。
  **受信側も（再）接続・購読のたびに組み立て途中のバッファを空にしてください。**
- 200Hz は BLE の帯域的にぎりぎりです。安定させたいときは 100Hz 以下を推奨します。

---

## コマンド

USB シリアルと BLE RX の**どちらからでも**同じコマンドが使えます。

- 1 行 1 コマンド、改行（`\n` / `\r` / `\r\n`）で終わる。1 行は最大 64 文字。
- 大文字小文字は区別しない（`rate 50` でも可）。前後の空白は無視。
- 応答は `#` で始まる情報行で、**コマンドが来た経路にだけ**返します。
- 空行と `#` で始まる行は無視します（応答なし）。

| コマンド | 動作 | 応答の例 |
|---|---|---|
| `PAUSE` | 送信を一時停止 | `# ok=PAUSE sending=0` |
| `RESUME` | 送信を再開 | `# ok=RESUME sending=1` |
| `RATE <Hz>` | 送信レートを変更（10〜200 の整数） | `# ok=RATE rate=50` |
| `INFO` | 情報行を返す | `# model=M5StickCPlus2 name=M5-Sensor-1A2B rate=100 ble=1 fw=2.0.0 imu=MPU6886 sending=1 connected=0 drop_usb=0 drop_ble=0` |

### 情報行の項目

| キー | 意味 |
|---|---|
| `model` | M5Unified が判別した機種名（`M5StickCPlus2`, `M5StackCore2`, `M5AtomMatrix` など。不明は `Unknown`） |
| `name` | BLE デバイス名 |
| `rate` | 現在の送信レート [Hz] |
| `ble` | BLE が使えるか（`1` / 初期化失敗なら `0`） |
| `fw` | ファームウェアのバージョン |
| `imu` | IMU の種類（`MPU6886`, `BMI270`, `SH200Q`, `none` など） |
| `sending` | 送信中なら `1`、一時停止中なら `0` |
| `connected` | BLE で接続されていれば `1` |
| `drop_usb` / `drop_ble` | 送信が詰まって捨てた行数（起動からの累計） |

### エラー行

| 行 | 原因 |
|---|---|
| `# error=rate_out_of_range value=5 min=10 max=200` | レートが範囲外（極端に大きい値は `value=999999` と表示） |
| `# error=rate_missing min=10 max=200` | `RATE` の後に数値が無い |
| `# error=rate_not_number min=10 max=200` | 数値でない（`-50`, `+50`, `50.5`, `0x20` なども不可） |
| `# error=unknown_command commands=PAUSE,RESUME,RATE,INFO` | 知らないコマンド |
| `# error=unexpected_argument commands=PAUSE,RESUME,RATE,INFO` | 余計な引数（例 `PAUSE now`） |
| `# error=line_too_long max=64` | 1 行が長すぎる（その行は捨てる） |
| `# error=imu_not_found` | IMU が見つからない（5 秒おき） |
| `# error=ble_init_failed` | BLE の初期化に失敗（起動時。USB シリアルは動く） |

その他、本体のボタンで切り替えたときは両方の経路に `# event=button sending=0` / `sending=1` を出します。

---

## 画面表示

画面のある機種では、状態が変わったときだけ次の内容を描き直します（毎回描くと送信タイミングが乱れるため）。

```
M5-Sensor-1A2B        ← BLE デバイス名（PC でスキャンしたときに見える名前）
SENDING               ← 緑: 送信中 / 橙: PAUSED / 赤: IMU ERROR
100 Hz                ← 送信レート
BLE: advertising      ← advertising（待ち受け中）/ connected（接続のみ）/ streaming（購読中＝送信中）/ off
M5StickCPlus2/MPU6886 ← 判別された機種 / IMU
```

画面の無い ATOM Matrix などでは、内蔵 RGB LED の色で状態を示します（暗めに点灯）。

| LED | 状態 |
|---|---|
| 緑 | 送信中（BLE 購読なし） |
| 青 | BLE で送信中 |
| 橙 | 一時停止 |
| 赤 | IMU エラー |

---

## トラブルシュート

### ポート（`/dev/cu.*` / `COMx`）が出ない

- ケーブルが**充電専用**でないか確認する（別のケーブルで試すのが早い）。
- M5StickC Plus2 は電源が入っていないとポートが出ません。左側面の電源ボタンを短く押して起動する。
- Windows で M5StickC Plus2 / Core2 などが認識されないときは、USB シリアル変換チップ（CH9102 / CP210x）の
  ドライバを入れる（M5Stack 公式サイトのドライバページ）。
- CoreS3 / AtomS3 は S3 内蔵の USB を使うため、書き込みに失敗するときは**ダウンロードモード**にする:
  - AtomS3 / CoreS3: 側面のリセットボタンを、内部の緑 LED が点くまで（2〜3 秒）長押しして離す。
    （細かい手順は M5Stack 公式ドキュメントの各製品ページを参照）
  - 書き込み後はリセットボタンを押して通常起動する。
- macOS: 「システム設定 > プライバシーとセキュリティ」でアクセサリの接続を許可しているか確認する。

### シリアルモニタに何も出ない／文字化けする

- ボーレートが **115200** か確認する（`pio device monitor` は platformio.ini の設定を使う）。
- 起動時の情報行を見逃しても、`INFO` + Enter で再表示できる。
- 画面が `PAUSED` なら A ボタンを押すか `RESUME` を送る。
- `IMU ERROR` が出ている場合は IMU の無い機種（ATOM Lite / CoreS3 SE など）か、env の選択ミスの可能性。
- アプリ側で受信しているときは、同じポートを `pio device monitor` で同時に開けない（どちらかを閉じる）。

### BLE で見つからない

- 画面に `BLE: advertising` と出ているか確認する（`connected` / `streaming` なら**すでに別の PC やスマホが接続中**。同時接続は 1 台）。
- 名前で探すときは `M5-Sensor-` で始まる名前を探す。名前はスキャン応答に入っているので、
  **アクティブスキャン**でないと名前が出ないツールがある（bleak は既定でアクティブスキャン）。
  サービス UUID `6E400001-...` でも絞り込める。
- macOS: ターミナル / Python に Bluetooth の利用許可が必要（「システム設定 > プライバシーとセキュリティ > Bluetooth」）。
- OS の Bluetooth 設定画面から「ペアリング」はしないこと（このファームウェアはペアリング不要。ペアリング済みになって見えなくなった場合は OS 側で登録を削除）。
- 本体をリセット（電源を入れ直す）すると広告をやり直す。

### BLE でデータが来ない・途切れる

- TX（`6E400003-...`）の **Notify を有効化**しているか（接続しただけでは送らない）。
- `INFO` で `drop_ble=` が増えていれば帯域不足。`RATE 50` などレートを下げる。
- PC との距離を縮める・USB 3.0 機器の近くを避ける（2.4GHz 帯の干渉）。

### ビルドが失敗する

- `UnknownBoard: Unknown board ID 'm5stack-stickc-plus2'` → `boards/` フォルダが無いか、別の場所でビルドしている。
  必ず `firmware/m5stick_sender` で `pio run` する。
- `ModuleNotFoundError: No module named 'intelhex'` → PlatformIO の Python 環境に依存パッケージが足りない。
  `~/.platformio/penv/bin/python -m pip install intelhex` で解決する（esptool 4.11 が必要とする）。
- ライブラリのダウンロードに失敗する → ネットワークを確認して `pio pkg install` をやり直す。

### `pio test -e native` が `tapi error: malformed file` / `unknown architecture` で失敗する（macOS）

Command Line Tools の SDK とリンカの組み合わせの問題で、コードの問題ではありません。古い SDK を指定して実行してください。

```bash
ls /Library/Developer/CommandLineTools/SDKs/            # 使える SDK を確認
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk pio test -e native
```

---

## 開発者向け

### フォルダ構成

```
firmware/m5stick_sender/
├── platformio.ini            機種ごとの env・ライブラリのバージョン固定
├── boards/                   platform 6.x に無いボード定義（StickC Plus / Plus2）
├── src/
│   ├── main.cpp              setup()/loop()。IMU 読み取り・コマンド処理・ボタン
│   ├── ble_uart.{h,cpp}      Nordic UART Service（NimBLE-Arduino）
│   └── status_display.{h,cpp} 画面／LED の状態表示
├── lib/sender_core/          ハードウェアに依存しない純粋ロジック（PC でテストできる）
│   └── sender_core.{h,cpp}   コマンド解析・行の組み立て・CSV 整形・BLE 分割・送信タイミング
└── test/test_sender_core/    sender_core の単体テスト（Unity）
```

`lib/sender_core` には Arduino / M5Unified / NimBLE のヘッダを include しないこと（PC でビルドできなくなるため）。

### 単体テスト

```bash
cd firmware/m5stick_sender
pio test -e native
```

コマンド解析（RATE の境界値・不正値）、改行の組み立て（CRLF・長すぎる行）、CSV 整形、
BLE の分割送信（MTU 23 / 185 での分割と再組み立て、キューあふれ時に行が壊れないこと）、
送信タイミング（レートの正確さ・millis() の桁あふれ・遅延時の追いつき）を確認します。

### 依存ライブラリとライセンス

すべて `platformio.ini` でバージョンを固定しています。

| 名前 | バージョン | ライセンス | 用途 |
|---|---|---|---|
| [M5Unified](https://github.com/m5stack/M5Unified) | 0.2.26 | MIT | 機種自動判別・IMU・ボタン・電源 |
| [M5GFX](https://github.com/m5stack/M5GFX) | 0.2.33 | MIT（一部フォントなどは同梱の各ライセンス） | 画面表示（M5Unified の依存） |
| [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) | 2.5.1 | Apache-2.0 | BLE ペリフェラル（NUS） |
| platformio/espressif32 | 6.13.0 | Apache-2.0 | ビルド環境 |
| framework-arduinoespressif32 | 3.20017.241212（Arduino-ESP32 2.0.17） | LGPL-2.1-or-later | Arduino コア |
| Unity（テストのみ） | 2.6.x | MIT | PC 上の単体テスト（PlatformIO が自動取得） |

**BLE ライブラリに NimBLE-Arduino を選んだ理由**: Arduino-ESP32 内蔵の BLE（Bluedroid）に比べてフラッシュ・RAM の使用量が
大幅に少なく（公称でフラッシュ約 50% 減・RAM 約 100KB 減）、4MB フラッシュの StickC / ATOM でも余裕を持って収まるため。
ライセンスは Apache-2.0 で、配布時は著作権表示とライセンス文の同梱が必要です（ファームウェアをバイナリ配布する場合）。

### ライブラリを更新するとき

1. `platformio.ini` のバージョンを書き換える。
2. 全 env をビルドし（上の「全機種をまとめてビルド」）、`pio test -e native` を通す。
3. この README の表を更新する。
4. 可能なら実機（少なくとも M5StickC Plus2）で有線・BLE の両方を確認する。

### 既知の制限

- 送信レートは再起動すると 100Hz に戻る（保存しない）。
- 時刻（タイムスタンプ）は送らない。アプリ側で受信時刻を使う（P1 と同じ）。
- BLE はペアリング・暗号化なし（近くの誰でも接続できる。テスト用途のため）。
- Core2 の画面描画には数十 ms かかるため、状態が変わった瞬間だけ送信が少し詰まることがある（追いつき処理で補う）。
