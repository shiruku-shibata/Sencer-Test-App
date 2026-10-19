# BLE ブリッジ（tools/ble_bridge）

センサーテストアプリ（Godot）と M5 デバイスを **BLE（Bluetooth Low Energy）** でつなぐための小さな常駐プロセスです。

Godot には BLE の標準機能が無く、GDExtension のバイナリを同梱するとライセンスと配布が複雑になるため、
BLE は Python + [bleak](https://github.com/hbldh/bleak)（MIT）で受け、**ローカル UDP** でアプリに渡します。

```
 M5デバイス (firmware/m5stick_sender)
   │ BLE: Nordic UART Service（CSV 行 "ax,ay,az,gx,gy,gz\n" を Notify）
   ▼
 ble_bridge.py  ── UDP 127.0.0.1:47811 で待受
   │  JSON 1個 = UDP 1データグラム
   ▼
 BleSensorProvider (src/core/ble_sensor_provider.gd) ── UDP 127.0.0.1:47810 で待受
   │  SensorReading
   ▼
 SensorManager → 各画面・記録
```

- アプリはブリッジを**自動で起動**します（`--parent-pid` 付き。アプリが終わればブリッジも終わる）。
- 自動起動がうまくいかない環境（主に macOS の Bluetooth 権限）では、**ターミナルから手動起動**したブリッジにも同じようにつながります。
- 実機も bleak も無しで動く **`--mock`** モードがあり、疑似デバイス2台（`M5-Sensor-MOCK1/2`）が 100Hz で波形を送ります。

## ファイル

| ファイル | 内容 |
|---|---|
| `ble_bridge.py` | ブリッジ本体（Python 3.9 以上、標準ライブラリ＋bleak） |
| `requirements.txt` | 依存（`bleak>=0.22.3,<2`） |
| `setup.sh` / `setup.bat` | `.venv` を作って bleak を入れる（macOS・Linux / Windows） |
| `tests/` | 単体テスト・UDP 結合テスト（Python）と Godot との結合テスト |

## セットアップ

Python 3.9 以上が必要です（macOS は標準の `/usr/bin/python3` で可）。

```bash
# macOS / Linux（リポジトリのルートで）
sh tools/ble_bridge/setup.sh

# Windows（コマンドプロンプト）
tools\ble_bridge\setup.bat
```

`tools/ble_bridge/.venv/` が作られ、そこに bleak が入ります。アプリはこの `.venv` の Python を自動で使います。
（`.venv` は Git に含めません。Godot エディタが中を読まないよう `.venv/.gdignore` も作ります）

動作確認（M5 デバイスの電源を入れて近くに置く）:

```bash
tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py --scan-once        # M5 センサーだけ
tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py --scan-once --all  # 周囲の BLE 機器すべて
```

## 使い方

### ふつうに使う（自動起動）

アプリを起動してデバイス管理画面で **スキャン** を押すだけです。BLE の枠に状態が表示されます。

| 表示 | 意味・対処 |
|---|---|
| 準備完了（ブリッジ v… ・bleak・自動起動） | 使えます。BLE デバイスが一覧に出ます |
| bleak 未インストール | `setup.sh`（Windows は `setup.bat`）を実行し、「ブリッジ再起動」を押す |
| Python 3 が見つかりません | Python 3.9 以上を入れて `setup.sh` を実行 |
| Bluetooth の使用が許可されていません | OS の設定で許可するか、「手動起動で接続」 |
| ブリッジが（起動直後に）終了しました（3 回続けて終了） | macOS の権限の可能性大。下の「macOS の注意」を参照 |
| UDP ポート 47810 を開けません | アプリを2つ起動していないか確認 |

### 手動起動

デバイス管理画面の **「手動起動で接続」** を押すと、アプリはブリッジを起動せずに待ち受け、実行すべきコマンドを表示します。
それをターミナルで実行してください（実行したままにしておきます）。

```bash
tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py
```

手動起動のブリッジは、アプリが終了しても終わりません（接続中のデバイスだけ切断して次のアプリを待ちます）。
止めるときは Ctrl+C です。「ブリッジ再起動」を押すと自動起動に戻ります。

### 実機なしで試す（--mock）

```bash
# 1) アプリに --mock 付きで自動起動させる
SENSOR_BLE_MOCK=1 godot --path .
godot --path . -- --ble-mock          # 同じ意味

# 2) または手動起動
python3 tools/ble_bridge/ble_bridge.py --mock
```

疑似デバイスは `PAUSE` / `RESUME` / `RATE <Hz>` / `INFO` に反応します。
通知は**わざと行の途中で分割**して届くので、行の組み立て処理の確認にも使えます。
`--all` でスキャンすると、接続できない無関係な機器（`Other-Headphones`）も出ます。
テスト用に `MOCK_DROP` を送ると「電波が途切れた」状態を再現します。

### コマンドライン引数

| 引数 | 既定 | 内容 |
|---|---|---|
| `--port N` | 47811 | ブリッジが待ち受ける UDP ポート |
| `--app-port N` | 47810 | アプリの UDP ポート（最初の hello の送り先。以後はコマンドの送り元へ返す） |
| `--mock` | | bleak を使わず疑似デバイスで動かす |
| `--all` | | スキャン結果を M5 センサーに絞らない |
| `--scan-timeout S` | 4 | スキャン時間の既定値（秒） |
| `--idle-timeout S` | 10 | アプリから何も届かない時間がこれを超えたら、自動起動なら終了／手動起動ならデバイスを切断。0 で無効 |
| `--parent-pid PID` | | 起動元アプリの pid。指定すると「自動起動」扱いになり、そのプロセスが終わると一緒に終了する |
| `--flush-ms N` | 20 | 受信した行をまとめて送る間隔 |
| `--scan-once` | | UDP を使わず1回スキャンして表示し終了（動作確認用） |

### アプリ側の環境変数

| 変数 | 内容 |
|---|---|
| `SENSOR_BLE_PYTHON` | ブリッジを動かす Python の場所（指定するとそれだけを使う） |
| `SENSOR_BLE_BRIDGE` | `ble_bridge.py` の場所（指定するとそれだけを使う） |
| `SENSOR_BLE_MOCK=1` | ブリッジを `--mock` で起動する |

アプリが Python を探す順番: `SENSOR_BLE_PYTHON` → `tools/ble_bridge/.venv`（Windows は `.venv\Scripts\python.exe`）→ PATH 上の `python3` / `python`
（Windows は `py -3` → `python`。Finder から起動した macOS アプリは PATH が短いので `/opt/homebrew/bin` などもあわせて探す）。

ブリッジを探す順番: `SENSOR_BLE_BRIDGE` → （エディタ実行時）`res://tools/ble_bridge/ble_bridge.py`
→ 実行ファイルと同じ場所の `ble_bridge/ble_bridge.py`（macOS は `.app` の隣と `.app/Contents/Resources/ble_bridge/` も）。

## プロトコル（アプリ ⇔ ブリッジ）

- トランスポート: UDP、`127.0.0.1` のみ。**1データグラム = UTF-8 の JSON オブジェクト1個**。
- アプリ → ブリッジ は `"cmd"`、ブリッジ → アプリ は `"type"` で種類を表す。
- ブリッジは、最後にコマンドを送ってきたアドレス（＝アプリのポート）へ返信する。
- アプリは送り元が `127.0.0.1:<ブリッジのポート>` 以外のデータを無視する。
- プロトコル版は `1`（`hello` の `protocol`）。互換性のない変更をしたら上げる。

### アプリ → ブリッジ（コマンド）

| cmd | 項目 | 内容 | 返事 |
|---|---|---|---|
| `hello` | `protocol`, `client` | 生存確認・初回のあいさつ | `hello` |
| `ping` | | 生存確認（アプリは1秒ごとに送る） | `pong` |
| `scan` | `timeout`（秒, 1〜30）, `all`（bool） | 数秒スキャンする。実行中に再度送っても1回分だけ返る | `scanning` → `devices` |
| `connect` | `address` | 接続して TX の通知を購読 | `status`（connecting → connected / エラー） |
| `disconnect` | `address` | 切断 | `status`（disconnected） |
| `send` | `address`, `line` | デバイスの RX に `line + "\n"` を書く（`PAUSE` / `RESUME` / `RATE <Hz>` / `INFO`、64文字まで） | 失敗時のみ `log` |
| `bye` | | アプリ終了（手動起動のブリッジ向け）。全デバイスを切断し、ブリッジは待機を続ける | |
| `quit` | | 全デバイスを切断してブリッジを終了（自動起動したブリッジ向け） | `bye` |

### ブリッジ → アプリ（通知）

| type | 項目 | 内容 |
|---|---|---|
| `hello` | `version`, `protocol`, `backend`（`bleak`/`mock`）, `pid`, `managed`（自動起動か）, `connected`（アドレス配列）, `ready`, `error`?, `message`? | 起動時と `hello` への返事。`ready=false` なら BLE が使えない（`error` に理由） |
| `pong` | `connected`, `scanning` | `ping` への返事。アプリは `connected` で接続状態を突き合わせる |
| `scanning` | `active`, `timeout` | スキャンを始めた |
| `devices` | `devices: [{address, name, rssi, nus}]`, `all`, `error`?, `message`? | スキャン結果（RSSI の強い順） |
| `status` | `address`, `connected`, `state`（`connecting`/`connected`/`disconnected`）, `error`?, `message`? | 接続状態の変化。予期しない切断は `error: "link_lost"` |
| `data` | `address`, `lines: [...]` | 通知を改行で組み立てた**完全な行**（`#` で始まる情報行も含む）。20ms ごとにまとめ、1データグラム最大64行 |
| `log` | `level`（`info`/`warn`/`error`）, `message` | 参考情報 |
| `bye` | `reason` | ブリッジが終了する |

### エラーコード

| error | 意味 | アプリの表示 |
|---|---|---|
| `bleak_missing` | bleak が import できない | bleak 未インストール: setup.sh を実行 |
| `unauthorized` | OS が Bluetooth の使用を許可していない | 設定で許可 or 手動起動 |
| `bluetooth_off` | Bluetooth がオフ | オンにする |
| `no_adapter` | Bluetooth アダプタが無い | |
| `scan_failed` / `connect_failed` / `send_failed` | 各操作の失敗（`message` に詳細） | |
| `not_connected` | 未接続のデバイスへの操作 | |
| `link_lost` | 接続中に切れた（電源・距離） | |

### 例

```text
app → {"cmd":"hello","protocol":1,"client":"SensorTestApp"}
br  → {"type":"hello","version":"1.0.0","protocol":1,"backend":"bleak","pid":4242,"managed":true,"connected":[],"ready":true}
app → {"cmd":"scan","timeout":4}
br  → {"type":"scanning","active":true,"timeout":4}
br  → {"type":"devices","devices":[{"address":"0D3C…","name":"M5-Sensor-1A2B","rssi":-52,"nus":true}],"all":false}
app → {"cmd":"connect","address":"0D3C…"}
br  → {"type":"status","address":"0D3C…","connected":false,"state":"connecting"}
br  → {"type":"status","address":"0D3C…","connected":true,"state":"connected"}
br  → {"type":"data","address":"0D3C…","lines":["0.0123,0.9811,-0.0210,1.250,-0.500,0.125","…"]}
app → {"cmd":"send","address":"0D3C…","line":"RATE 50"}
```

BLE のアドレスは bleak が返すもの（macOS は機器ごとの UUID、Windows / Linux は MAC アドレス）で、
アプリではこれがデバイスの ID になります（macOS の UUID は Mac ごとに異なります）。

## プロセスの寿命（孤児プロセスを残さない仕組み）

| 状況 | 動き |
|---|---|
| アプリが普通に終了 | 自動起動: `quit` を送り、0.6 秒で終わらなければ kill。手動起動: `bye`（デバイスだけ切断） |
| アプリが強制終了・クラッシュ | 自動起動のブリッジは `--parent-pid` の消滅を 0.5 秒ごとに確認して終了 |
| アプリからの連絡が 10 秒途絶えた | 自動起動: 終了。手動起動: デバイスを切断して次のアプリを待つ |
| ブリッジが落ちた | アプリは接続中のデバイスを切断扱いにし、自動起動なら最大2回まで起動し直す |
| ポートが使用中 | ブリッジは終了コード 2 で終わる／アプリは理由を表示（他の接続方式は使える） |

## macOS の注意（Bluetooth の権限）

macOS では、Bluetooth を使うプロセスの「責任元のアプリ」が `Info.plist` に `NSBluetoothAlwaysUsageDescription` を持ち、
ユーザーが許可している必要があります。条件を満たさないと、Python が Bluetooth に触れた瞬間に **OS に強制終了**されます
（エラーメッセージは出ません）。

- **書き出したアプリ**: `export_presets.cfg` で `NSBluetoothAlwaysUsageDescription` を追加済みです。初回スキャン時に許可ダイアログが出ます。
- **Godot エディタから実行**: Godot.app の Info.plist にはこのキーが無いため、エディタから起動した Python は落ちることがあります。
  アプリは2回まで自動で起動し直し、3回続けて落ちたら自動起動をやめて「手動起動で接続」を案内します。
- **ターミナルから手動起動**: ターミナル（Terminal.app / iTerm など）に Bluetooth の許可が必要です。
  初回に許可ダイアログが出るか、「システム設定 > プライバシーとセキュリティ > Bluetooth」でターミナルを許可してください。

## 配布するとき

- `export_presets.cfg` は `tools/*` を書き出しから除外しています（pck の中の Python は実行できないため）。
- BLE を使う配布物では、`tools/ble_bridge/` から `ble_bridge.py`・`requirements.txt`・`setup.sh`・`setup.bat`・`README.md` を
  **実行ファイルと同じ場所の `ble_bridge/` フォルダ**にコピーしてください（macOS は `.app` の隣）。`.venv` や `tests` は含めません。
- 受け取った人はそのフォルダで `setup.sh`（Windows は `setup.bat`）を実行します。bleak とその依存は同梱しません
  （`THIRD_PARTY_LICENSES.md` 参照）。

## テスト

```bash
# Python の単体テスト・UDP 結合テスト（bleak 不要、--mock を使う）
python3 -m unittest discover -s tools/ble_bridge/tests

# Godot との結合テスト（自動起動・手動起動・失敗系。実機・bleak 不要）
godot --headless --path . -s res://tools/ble_bridge/tests/godot_ble_smoke.gd
```

Godot 側のテストはポート 47830〜47867 を使います。

## トラブルシュート

| 症状 | 確認すること |
|---|---|
| BLE デバイスが一覧に出ない | デバイスの電源・距離。ファームウェアが BLE 送信版か（名前 `M5-Sensor-XXXX`、NUS を広告）。`--scan-once --all` で周囲の機器が見えるか |
| 「ブリッジが起動直後に終了しました」 | ターミナルで `python3 tools/ble_bridge/ble_bridge.py` を実行してエラーを見る。macOS なら上の権限の注意 |
| 「ブリッジが応答しません」 | セキュリティソフトがローカル UDP（127.0.0.1:47810/47811）を止めていないか |
| 接続できない（connect_failed） | 他の PC・スマホがそのデバイスに接続していないか。デバイスを再起動 |
| すぐ切れる（link_lost） | 距離・電池。USB ハブの Bluetooth ドングルは PC 本体から離す |
| 「UDP ポート 47811 を開けません」（ブリッジ） | 別のブリッジが動いている（`ps aux \| grep ble_bridge` / タスクマネージャー） |
| Windows で `python` を実行するとストアが開く | python.org から Python を入れるか、`SENSOR_BLE_PYTHON` で場所を指定 |
| Linux で権限エラー | BlueZ が動いているか（`systemctl status bluetooth`）、ユーザーが `bluetooth` グループにいるか |

## ライセンス

`ble_bridge.py` などこのフォルダのコードはアプリ本体と同じ扱いです。
bleak（MIT）とその依存はユーザー環境に pip で導入するもので、アプリには同梱しません。
