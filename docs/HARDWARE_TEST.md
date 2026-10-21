# 実機検証チェックリスト（P2）

P2 のファームウェア・BLE・各機種対応は、**実機なし**（ビルド・単体テスト・疑似デバイス）で作りました。
この文書は、M5 の実機を手にした人が **上から順に試して結果を記録する** ためのチェックリストです。

- 所要時間の目安: 準備 30 分 ＋ 1 機種あたり 20〜30 分 ＋ BLE 30 分 ＋ しきい値シナリオ 30 分
- 全部やる必要はありません。**最低限**は ★ の付いた項目（M5StickC Plus2 で 0 → 1 → 2 → 3 → 4）です。
- 結果は各表の「結果」欄に `OK` / `NG` / `-`（未実施・対象外）、気づいたことは「メモ」欄に書きます。
  NG は [6. NG のときの切り分け](#6-ng-のときの切り分け) に沿って原因を絞り、[7. 報告に添える情報](#7-報告に添える情報) を付けて報告してください。

関連文書（仕様はこちらが正。この文書と食い違っていたら報告してください）:

| 文書 | 内容 |
|---|---|
| [firmware/m5stick_sender/README.md](../firmware/m5stick_sender/README.md) | 対応機種・書き込み・出力形式・BLE 仕様・コマンド・画面表示 |
| [tools/ble_bridge/README.md](../tools/ble_bridge/README.md) | BLE ブリッジのセットアップ・使い方・トラブルシュート |
| [docs/DESIGN_P2.md](DESIGN_P2.md) 5.6 | BLE プロトコル（ファームとブリッジの契約） |
| アプリの「マニュアル」画面（`src/ui/ui_strings.gd`） | 接続・記録・しきい値測定・軸の選び方 |

---

## 0. 準備

### 0-1. 用意するもの

- 検証する M5 製品（下の 7 env のうち手元にあるもの）。まずは **M5StickC Plus2**。
- **データ通信対応**の USB ケーブル（充電専用ケーブルではポートが出ません）
- PC（macOS / Windows / Linux。どの OS で試したかを必ず記録）
- 可能ならスマートフォンの BLE ツール（nRF Connect / LightBlue など。BLE の切り分け用。無くても可）

### 0-2. 記録しておく環境情報

| 項目 | 確認方法 | 記入 |
|---|---|---|
| 試したコミット | `git rev-parse --short HEAD` | |
| OS とバージョン | macOS: `sw_vers` / Windows: `winver` | |
| Godot のバージョン | エディタの「ヘルプ > バージョン情報」 | |
| PlatformIO のバージョン | `pio --version`（無ければ `~/.platformio/penv/bin/pio --version`） | |
| Python / bleak のバージョン | `tools/ble_bridge/.venv/bin/python -m pip show bleak`（Windows は `.venv\Scripts\python`） | |
| 起動方法 | Godot エディタから / 書き出したアプリ | |

### 0-3. 準備の確認

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★P-1 | `cd firmware/m5stick_sender && pio run`（初回は platform とライブラリをダウンロード） | `m5stickc_plus2  SUCCESS` | | |
| P-2 | 全 env をビルド（コマンドは firmware README「ビルドと書き込み」） | 7 env すべて `SUCCESS` | | |
| P-3 | `pio test -e native` | `24 test cases: 24 succeeded` | | |
| ★P-4 | `sh tools/ble_bridge/setup.sh`（Windows は `tools\ble_bridge\setup.bat`）をリポジトリのルートで実行 | `tools/ble_bridge/.venv/` が作られ、bleak が入る | | |
| P-5 | `python3 -m unittest discover -s tools/ble_bridge/tests` | すべて OK | | |
| ★P-6 | Godot でプロジェクトを開いて実行（F5）→「デバイス管理」でスキャン → `demo-01` に接続 | 「モニタリング」で波形が流れる（アプリ自体が動くことの確認） | | |

> `pio run` が `No module named 'intelhex'` で失敗する、`pio test` が macOS で `tapi error` になる、などは
> firmware README の「トラブルシュート」に対処があります。

### 0-4. 書き込み

```bash
cd firmware/m5stick_sender
pio run -e <env名> -t upload            # 例: pio run -e m5stickc_plus2 -t upload
pio device monitor                      # 115200bps。終了は Ctrl+C
```

- ポートが複数あるときは `--upload-port` で指定します（firmware README 参照）。
- **CoreS3 / AtomS3** で書き込みに失敗したら、リセットボタンを内部の緑 LED が点くまで長押ししてダウンロードモードにします。書き込み後はリセットボタンを押して通常起動します。
- アプリと `pio device monitor` は**同じポートを同時に開けません**。片方を閉じてから使ってください。

---

## 1. 機種ごとの確認

### 1-1. 機種一覧と期待値

env 名と、起動時に出るはずの値です（`model=` / `imu=` は M5Unified の自動判別結果）。

| env | 対象 | 期待する `model=` | 期待する `imu=` | 画面 / LED | 一時停止・再開の操作 |
|---|---|---|---|---|---|
| `m5stickc_plus2` | M5StickC Plus2 | `M5StickCPlus2` | `MPU6886` | 画面 135×240（横向きで表示） | A ボタン（前面の M5 ロゴのボタン） |
| `m5stickc_plus` | M5StickC Plus | `M5StickCPlus` | `MPU6886` | 画面 135×240 | A ボタン |
| `m5stickc` | M5StickC（初代） | `M5StickC` | `MPU6886`（初期ロットは `SH200Q`） | 画面 80×160 | A ボタン |
| `m5stack_core2` | M5Stack Core2 | `M5StackCore2` | `MPU6886`（v1.1 は `BMI270`） | 画面 320×240 | 画面下の左のタッチボタン |
| `m5stack_cores3` | M5Stack CoreS3 | `M5StackCoreS3` | `BMI270` | 画面 320×240 | 画面をタップ |
| `m5stack_cores3` | M5Stack CoreS3 SE | `M5StackCoreS3SE` | `none`（IMU 非搭載） | 画面に `IMU ERROR` | 画面をタップ |
| `m5stack_atoms3` | AtomS3 | `M5AtomS3` | `MPU6886` | 画面 128×128 | 画面（ボタン）を押す |
| `m5stack_atom` | ATOM Matrix | `M5AtomMatrix` | `MPU6886`（新しいロットは `BMI270`） | 画面なし。5×5 LED の色 | 画面（ボタン）を押す |
| `m5stack_atom` | ATOM Lite（IMU 無し。エラー表示の確認用） | `M5AtomLite` | `none` | LED 赤 | ボタン |

### 1-2. 起動と表示（機種ごとに実施）

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★M-1 | 書き込み後に起動し、`pio device monitor` を開いて `INFO` + Enter | `# model=<上の表> name=M5-Sensor-XXXX rate=100 ble=1 fw=2.0.0 imu=<上の表> sending=1 connected=0 drop_usb=0 drop_ble=0` の 1 行が返る（入力した文字はエコー表示される） | | |
| ★M-2 | そのまま CSV を眺める | `0.0210,0.9832,-0.0104,12.400,-3.100,0.800` の形の行が 1 秒に約 100 行流れる。加速度は小数 4 桁、ジャイロは小数 3 桁 | | |
| ★M-3 | 本体の画面を見る（画面のある機種） | 5 行表示: ① `M5-Sensor-XXXX` ② 緑の `SENDING` ③ `100 Hz` ④ `BLE: advertising` ⑤ `<model>/<imu>`。文字が画面からはみ出さない（⑤は StickC 初代で右端が少し切れてもよい） | | |
| ★M-4 | M-1 の `name=` と画面の 1 行目を比べる | 同じ `M5-Sensor-XXXX`（XXXX は 16 進大文字 4 桁）。電源を入れ直しても変わらない | | |
| ★M-5 | 一時停止の操作（1-1 の表）を 1 回 | 画面が橙の `PAUSED` に変わり、CSV が止まる。モニタに `# event=button sending=0` | | |
| ★M-6 | もう 1 回同じ操作 | 緑の `SENDING` に戻り CSV が再開。モニタに `# event=button sending=1` | | |
| M-7 | 操作を素早く 5 回 | 1 回押すごとに 1 回だけ切り替わる（2 回切り替わったり、反応しなかったりしない） | | |
| M-8 | （ATOM Matrix）LED を見る | 送信中=緑、一時停止=橙、BLE で送信中=青、IMU エラー=赤（暗めに点灯） | | |
| M-9 | （CoreS3 SE / ATOM Lite など IMU の無い機種） | 画面に赤の `IMU ERROR` / LED 赤。モニタに `# error=imu_not_found` が 5 秒おき。CSV は出ない。`INFO` には応答する（`imu=none`） | | |
| M-10 | 起動から 10 分放置 | 送信が止まらない・再起動しない。本体が異常に熱くならない | | |

### 1-3. IMU の値の符号と向き（機種ごとに実施）

**基本のルール**: 加速度センサーは静止中に重力の反対向き（上向き）の力を感じます。
そのため **軸の＋方向を「真上」に向けて静止させると、その軸が約 +1G** になり、真下に向けると約 −1G になります。
軸の向きは機種（IMU チップの載せ方）ごとに違うので、**下の 6 姿勢で実測して表を埋めて**ください。
これが後でしきい値の軸を選ぶときの手がかりになり、ゲーム側にもそのまま使えます。

測り方: アプリの「モニタリング」画面（軸ボタンで aX / aY / aZ / |a| を表示）か、`pio device monitor` の CSV を見ます。
各姿勢で 2〜3 秒静止させて読みます。

```
  M5StickC 系の例（画面がある面を「表」、USB 端子のある端を「下端」と呼ぶ）

   姿勢①: 表を上にして机に置く        姿勢②: 表を下にして机に置く
        ┌──────────────┐                    ┌──────────────┐
        │ [ 画面 ] (A) │ ← 上から見た図      │   (裏面)     │
        └──────────────┘                    └──────────────┘
   ─────────────── 机 ───────────────   ─────────────── 机 ───────────────

   姿勢③: 下端（USB）を下にして立てる   姿勢④: 下端（USB）を上にして立てる
   姿勢⑤: 左側面を下にして立てる        姿勢⑥: 右側面を下にして立てる
   （左右は「表を自分に向け、USB を下にした」ときの左右）
```

Core2 / CoreS3 は「表 = 画面」「下端 = USB 端子のある側面」、AtomS3 / ATOM Matrix は「表 = 画面 / LED 面」「下端 = USB 端子のある側面」とします。

**期待値（どの機種でも成り立つこと）**

- 各姿勢で、**1 つの軸だけが約 ±1G**（±0.08G 以内）、残り 2 軸は約 0（±0.10G 以内）
- 姿勢①と②、③と④、⑤と⑥で、**同じ軸の符号が逆**になる
- `|a|`（合成加速度）はどの姿勢でも約 1.00G（0.95〜1.05）
- 静止中のジャイロ gX / gY / gZ は 0 付近（目安 ±10 deg/s 以内。値はチップの個体差。記録しておく）

**予想（実機未確認）**: 画面のある機種は、姿勢①（表を上）で aZ ≈ +1G になると予想しています
（ATOM Matrix は M5Unified が X 軸と Z 軸を反転して補正しているため、LED 面を上で aZ ≈ +1G の予想）。
X / Y の向きは予想していません。実測で埋めてください。

| 機種 | 姿勢① 表を上 | 姿勢② 表を下 | 姿勢③ 下端を下 | 姿勢④ 下端を上 | 姿勢⑤ 左側面を下 | 姿勢⑥ 右側面を下 | 静止中の gX/gY/gZ | 結果 |
|---|---|---|---|---|---|---|---|---|
| 記入例 | aZ +1.00 | aZ −1.00 | aY +0.99 | aY −1.00 | aX −0.99 | aX +1.01 | 0.5 / −1.2 / 0.3 | OK |
| M5StickC Plus2 | | | | | | | | |
| M5StickC Plus | | | | | | | | |
| M5StickC | | | | | | | | |
| Core2 | | | | | | | | |
| CoreS3 | | | | | | | | |
| AtomS3 | | | | | | | | |
| ATOM Matrix | | | | | | | | |

**ジャイロの符号（右手の法則）**: 姿勢①で aZ が +1G になった機種なら、机に置いたまま**上から見て反時計回り**に回すと gZ が＋になるはずです。
同じように「＋1G になった軸の＋方向を上に向けて、上から見て反時計回りに回す」と、その軸のジャイロが＋になります。

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★M-11 | 上の 6 姿勢の表を埋める | 「期待値」の 4 条件を満たす | | |
| M-12 | 3 軸それぞれについて、＋方向を上に向けて上から見て反時計回りにゆっくり回す | 回した軸のジャイロが＋（数十〜数百 deg/s）、ほかの 2 軸はほぼ 0。時計回りでは− | | |
| M-13 | 強く振る | 加速度は最大 ±16G、ジャイロは最大 ±2000 deg/s 程度まで出て、値が途中で固まったり 0 に飛んだりしない | | |

---

## 2. 有線（USB シリアル）

### 2-1. アプリで受信

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★W-1 | `pio device monitor` を閉じる → アプリの「デバイス管理」でスキャン | 方式「有線」のデバイスが出る。macOS の例: StickC Plus2 / Core2 は `/dev/cu.usbserial-…` か `/dev/cu.wchusbserial…`、CoreS3 / AtomS3 は `/dev/cu.usbmodem…`（`/dev/tty.*` ではなく `/dev/cu.*`） | | |
| ★W-2 | 接続 | 状態「接続中」、「受信」列が約 100 Hz（95〜105） | | |
| ★W-3 | 「モニタリング」で全軸を表示し、本体を動かす | 波形が遅れなく追従する。1-3 の表どおりの軸が動く | | |
| W-4 | 本体のボタンで一時停止 → 再開 | 一時停止中は波形が止まり、「受信」が 0 Hz 付近になる。再開で約 100 Hz に戻る | | |
| W-5 | 接続中に USB ケーブルを抜く → 挿し直す → スキャン → 接続 | 抜くと切断扱いになる。挿し直して再接続すると受信が再開する（アプリの再起動は不要） | | |
| W-6 | 「モニタリング」で軸を aX と gZ だけ選んで 30 秒記録 →「ログ管理」で CSV を開く | 1 行目 `# device_id=… nickname=… axes=ax,gz`、2 行目 `timestamp_ms,ax,gz`、データ行は約 3000 行（100Hz × 30 秒） | | |

### 2-2. コマンドと 200Hz

**アプリで確認**（「デバイス管理」で接続中の行の **操作…** を押す。画面の例: [device_commands.png](images/device_commands.png)）:

| ID | 操作 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★A-1 | **情報を取得（INFO）** | 「応答」に `→ INFO の応答: # model=… rate=100 … sending=1 …`（M-1 と同じ形）。「デバイス情報」に機種・ファームウェア・IMU などが並ぶ | | |
| ★A-2 | **一時停止（PAUSE）** | `# ok=PAUSE sending=0`。本体が `PAUSED`、波形が止まり、一覧の状態が「接続中（一時停止中）」 | | |
| ★A-3 | **再開（RESUME）** | `# ok=RESUME sending=1`。受信が約 100 Hz に戻る | | |
| ★A-4 | 送信レートを 50 にして **適用（RATE）** | `# ok=RATE rate=50`。本体の表示が `50 Hz`。数秒後、ダイアログの「実際の受信」と一覧の「受信」が `50 Hz（設定 50）` 前後 | | |
| A-5 | 送信レートを 200 にして適用 | `# ok=RATE rate=200`、「実際の受信」が約 200 Hz（足りなければ黄色の注意が出る。値をメモ） | | |
| A-6 | 応答待ちの間（「応答待ち…」表示中）にボタンを押す | 押せない（二重送信しない）。応答が来るか 3 秒たつと押せるようになる | | |
| A-7 | ダイアログを開いたまま USB ケーブルを抜く | 「未接続です」と出てボタンが押せなくなる。応答待ちだった場合は「切断されたため…応答待ちをやめました」 | | |
| A-8 | 本体のボタンで一時停止 → 再開 | ダイアログ下の「デバイスから届いた '#' 行」に `# event=button sending=0` / `sending=1`（薄い色）、送信状態の表示も追従 | | |
| A-9 | 最後に 100 にして適用 | 以降の確認のために 100 Hz に戻す | | |

アプリのボタンは正しいコマンドしか送らないので、エラー応答（C-6〜C-9）は下の手入力で確認します。
エラー応答がアプリで警告色（橙）になることは、デモデバイスや BLE の疑似デバイスで確認済み。

**補助: 手入力で確認**（アプリで切断してから `pio device monitor` で 1 行ずつ打って Enter）:

| ID | 入力 | 期待する応答 | 結果 | メモ |
|---|---|---|---|---|
| ★C-1 | `INFO` | `# model=… rate=100 … sending=1 …`（M-1 と同じ形） | | |
| ★C-2 | `PAUSE` | `# ok=PAUSE sending=0`。CSV が止まり、本体が `PAUSED` | | |
| ★C-3 | `RESUME` | `# ok=RESUME sending=1`。CSV が再開 | | |
| ★C-4 | `RATE 50` | `# ok=RATE rate=50`。本体の表示が `50 Hz` | | |
| C-5 | `rate 10` / `Rate 200` | `# ok=RATE rate=10` / `# ok=RATE rate=200`（大文字小文字を区別しない） | | |
| C-6 | `RATE 5` / `RATE 201` | `# error=rate_out_of_range value=5 min=10 max=200`（201 も同様）。レートは変わらない | | |
| C-7 | `RATE` / `RATE abc` / `RATE 50.5` | `# error=rate_missing min=10 max=200` / `# error=rate_not_number min=10 max=200`（50.5 も not_number） | | |
| C-8 | `HELLO` / `PAUSE now` | `# error=unknown_command commands=PAUSE,RESUME,RATE,INFO` / `# error=unexpected_argument commands=…` | | |
| C-9 | 65 文字以上の文字列 | `# error=line_too_long max=64`。その後の `INFO` は正常に応答 | | |
| C-10 | 本体の電源を入れ直して `INFO` | `rate=100`（レートは保存されず 100Hz に戻る） | | |

**スクリプトで確認**（レートの実測と 200Hz の取りこぼし）。PlatformIO に入っている pyserial を使います。
`<ポート>` は W-1 で見たポート名（例 `/dev/cu.usbserial-XXXX`、Windows は `COM5`）。アプリと `pio device monitor` は閉じておきます。

```bash
~/.platformio/penv/bin/python - <ポート> <<'EOF'
import sys, time, serial
s = serial.Serial(sys.argv[1], 115200, timeout=0.2)
time.sleep(2.0)
def cmd(text, wait=0.8):
    s.reset_input_buffer()
    s.write((text + "\n").encode())
    end, buf = time.monotonic() + wait, b""
    while time.monotonic() < end:
        buf += s.read(s.in_waiting or 1)
    print("> %-9s -> %s" % (text, [l.decode(errors="replace").strip() for l in buf.split(b"\n") if l.startswith(b"#")]))
for c in ["INFO", "PAUSE", "RESUME", "RATE 5", "RATE abc", "HELLO"]:
    cmd(c)
for rate in (100, 200):
    cmd("RATE %d" % rate)
    s.reset_input_buffer()
    buf, n, bad, first, t0 = b"", 0, 0, True, time.monotonic()
    while time.monotonic() - t0 < 10.0:
        buf += s.read(4096)
        *done, buf = buf.split(b"\n")
        for raw in done:
            t = raw.decode(errors="replace").strip()
            if first:            # 読み始めの 1 行は途中から読んでいる可能性があるので数えない
                first = False
                continue
            if not t or t.startswith("#"):
                continue
            n += 1
            bad += len(t.split(",")) != 6
    print("RATE %d: %.1f 行/秒, 壊れた行 %d" % (rate, n / 10.0, bad))
cmd("RATE 100")
cmd("INFO")
EOF
```

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| ★S-1 | スクリプトのコマンド応答 | C-1〜C-8 と同じ応答が `->` の右に出る | | |
| ★S-2 | `RATE 100` の行/秒 | 99〜101、壊れた行 0 | | |
| S-3 | `RATE 200` の行/秒 | 195〜201、壊れた行 0。115200bps の 8 割前後を使うため、ここが本命の確認 | | |
| S-4 | 最後の `INFO` の `drop_usb=` | `0`（1 以上なら、送信バッファがあふれて捨てた行がある） | | |
| S-5 | ポートを開いたとき本体が再起動したか | 再起動しない（画面が起動直後の状態に戻らない）。再起動する機種があればメモ | | |
| S-6 | （アプリ）`RATE 200` にした後でアプリから接続し、「受信」列を見る | 約 200 Hz。100 Hz なら、ポートを開いたときに本体が再起動した可能性があるので S-5 にメモ | | |

---

## 3. BLE

前提: P-4（ブリッジのセットアップ）が済んでいること。BLE は **同時に 1 台の PC（1 アプリ）としか接続しません**。

### 3-1. スキャンと接続（アプリ）

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★B-1 | `tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py --scan-once` | `1 台見つかりました（M5センサーのみ。全機器は --all）` と、`M5-Sensor-XXXX  RSSI -xx NUS` の行。XXXX は M-4 と同じ | | |
| B-2 | （Windows / Linux）B-1 のアドレスの末尾 4 桁と XXXX を比べる | 一致する（XXXX は BLE アドレスの下位 2 バイト）。macOS はアドレスが UUID なので比べられない | | |
| ★B-3 | アプリを起動 →「デバイス管理」の BLE 欄を見る | `準備完了（ブリッジ v… ・bleak・自動起動）`。それ以外の表示は tools/ble_bridge/README「使い方」の表で対処 | | |
| ★B-4 | スキャン | 方式「BLE」で `M5-Sensor-XXXX` が出る。RSSI が出る | | |
| ★B-5 | 接続 | 状態「接続中」、「受信」約 100 Hz。本体の画面が `BLE: streaming`（ATOM Matrix は LED 青） | | |
| B-6 | 機器名にマウスを乗せる（ツールチップ） | `# model=… name=M5-Sensor-XXXX rate=100 ble=1 fw=2.0.0 …` の情報行が出る | | |
| ★B-7 | 「モニタリング」で本体を動かす | 有線（W-3）と同じように追従する。体感できるほどの遅れや、まとまってカクつく動きがない | | |
| B-8 | 本体のボタンで一時停止 → 再開 | 波形が止まる → 再開。ツールチップに `# event=button sending=0` などが出る | | |
| B-9 | 接続中に、USB でつないで `pio device monitor` も開く | BLE と USB の両方に同じデータが流れる（ファームは両方へ送る） | | |

### 3-2. 切断・再広告・再接続

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| ★B-10 | アプリで「切断」 | 本体が数秒以内に `BLE: advertising` に戻る | | |
| ★B-11 | もう一度スキャン → 接続 | 見つかり、接続でき、受信が再開する（アプリの再起動は不要） | | |
| B-12 | 接続中に本体の電源を切る | アプリが切断扱いになる（ブリッジのエラーは `link_lost`）。電源を入れてスキャン → 接続で復帰 | | |
| B-13 | 接続中に本体を離していく（別の部屋など） | 切れたら切断扱いになる。戻ってスキャン → 接続で復帰。切れた距離をメモ | | |
| B-14 | 切断 → 再接続を 10 回繰り返す | 毎回接続でき、本体の再起動は不要。受信レートも毎回 約 100 Hz | | |
| B-15 | アプリを終了 | 本体が `BLE: advertising` に戻る。ブリッジのプロセスが残らない（macOS / Linux: `ps aux \| grep ble_bridge`、Windows: タスクマネージャー） | | |

### 3-3. コマンド・MTU・200Hz

**アプリで確認**: BLE で接続した行の **操作…** から、2-2 の A-1〜A-9 と同じ操作をします（応答は BLE 経由で返る）。

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| ★B-16a | A-1〜A-4（INFO / PAUSE / RESUME / RATE 50） | 有線と同じ応答が「応答」欄に出る。INFO の `connected=1` | | |
| B-16b | A-5（RATE 200）の「実際の受信」 | 目安 190 Hz 以上。足りなければ INFO の `drop_ble=` をメモ | | |

**補助: スクリプトで確認**（MTU・通知の長さ・壊れた行の数など、アプリでは見えない項目）。
ブリッジ用の Python 環境（bleak 入り）でデバイスに直接つなぎます。
**アプリで接続中だとつながらない**ので、先にアプリで切断するか、アプリを終了してください。

```bash
tools/ble_bridge/.venv/bin/python - M5-Sensor-XXXX <<'EOF'
import asyncio, sys, time
from bleak import BleakClient, BleakScanner
TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NAME = sys.argv[1] if len(sys.argv) > 1 else "M5-Sensor-"

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (ad.local_name or d.name or "").startswith(NAME), timeout=10.0)
    if dev is None:
        print("見つかりません:", NAME)
        return 1
    print("見つかった:", dev.address, dev.name)
    buf, lines, stat = bytearray(), [], {"n": 0, "max": 0}
    def on_notify(_sender, data):
        stat["n"] += 1
        stat["max"] = max(stat["max"], len(data))
        buf.extend(data)
        while b"\n" in buf:
            i = buf.index(b"\n")
            lines.append(buf[:i].decode(errors="replace").strip())
            del buf[: i + 1]
    async with BleakClient(dev) as client:
        print("MTU:", client.mtu_size)
        await client.start_notify(TX, on_notify)
        await asyncio.sleep(1.0)
        print("購読直後の情報行:", [l for l in lines if l.startswith("#")][:1])
        async def cmd(text, wait=1.0):
            start = len(lines)
            await client.write_gatt_char(RX, (text + "\n").encode(), response=False)
            await asyncio.sleep(wait)
            print("> %-9s -> %s" % (text, [l for l in lines[start:] if l.startswith("#")]))
        for c in ["INFO", "PAUSE", "RESUME", "RATE 5", "RATE abc", "HELLO"]:
            await cmd(c)
        for rate in (100, 200):
            await cmd("RATE %d" % rate)
            del lines[:]
            stat["n"] = 0
            t0 = time.monotonic()
            await asyncio.sleep(10.0)
            dt = time.monotonic() - t0
            data = [l for l in lines[1:] if l and not l.startswith("#")]
            bad = sum(1 for l in data if len(l.split(",")) != 6)
            print("RATE %d: %.1f 行/秒, 通知 %.1f 回/秒, 最大通知長 %d バイト, 壊れた行 %d"
                  % (rate, len(data) / dt, stat["n"] / dt, stat["max"], bad))
        await cmd("RATE 100")
        await cmd("INFO")
    return 0

sys.exit(asyncio.run(main()))
EOF
```

（Windows は `tools\ble_bridge\.venv\Scripts\python`。ヒアドキュメントが使えないので、`EOF` までの中身を `nus_check.py` などに保存して `python nus_check.py M5-Sensor-XXXX` で実行します。）

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| ★B-16 | `購読直後の情報行` | `['# model=… name=M5-Sensor-XXXX rate=100 … connected=1 …']`（購読すると最初に情報行が来る） | | |
| ★B-17 | コマンドの応答 | 有線の C-1〜C-8 と同じ応答が `->` の右に出る | | |
| B-18 | `MTU:` | 23 より大きい（macOS は 185 前後、Windows は 247 前後が多い）。Linux は値が出ないことがある。値をメモ | | |
| B-19 | `最大通知長` | MTU − 3 以下（MTU 247 なら最大 244）。MTU が 23 のときは 20 で、1 行が複数通知に分かれる | | |
| ★B-20 | `RATE 100` の行/秒 | 98〜101、壊れた行 0 | | |
| B-21 | `RATE 200` の行/秒 | 目安 190 以上、壊れた行 0。足りない場合は最後の `INFO` の `drop_ble=` をメモ（BLE の帯域不足で捨てた行数。200Hz は ぎりぎりの想定） | | |
| B-22 | 最後の `INFO` | `rate=100 … drop_ble=<数>`。`drop_ble` が 100Hz の間に増えていないこと | | |
| B-23 | （スマホの nRF Connect などがあれば）`M5-Sensor-XXXX` に接続し、TX（6E400003）の通知を ON | CSV の行が流れてくる。RX（6E400002）に `INFO` + 改行（`0A`）を書くと情報行が来る | | |

### 3-4. 複数台・権限

| ID | 手順 | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| B-24 | 2 台を BLE で同時に接続 | 名前が違う（XXXX が別）。両方とも「受信」約 100 Hz。片方を切断しても、もう片方は流れ続ける | | |
| B-25 | 2 台にニックネームを付けて、アプリを再起動 | ニックネームが残っている（macOS では BLE の ID が Mac ごとに違うので、別の Mac では付け直しになる） | | |
| B-26 | 1 台を有線、もう 1 台を BLE で同時に接続 | 両方受信できる | | |
| B-27 | （macOS・Godot エディタから実行）スキャン | 動けば OK。ブリッジが落ちる場合は、3 回目でアプリが「手動起動で接続」を案内する（tools/ble_bridge/README「macOS の注意」） | | |
| B-28 | （macOS）「手動起動で接続」→ 表示されたコマンドをターミナルで実行 → アプリでスキャン | 初回は Bluetooth の許可ダイアログ（ターミナルに対して）。許可するとスキャン・接続できる | | |
| B-29 | （macOS・書き出したアプリ）初回スキャン | アプリに対する Bluetooth の許可ダイアログが出る。許可すると自動起動のまま使える | | |
| B-30 | Bluetooth をオフにしてスキャン | デバイス管理画面に Bluetooth がオフである旨と対処が出る（アプリは落ちない） | | |

---

## 4. しきい値測定の実地シナリオ

各シナリオは**有線で 1 回、BLE で 1 回**行い、値が大きく違わないかも比べます（同じ持ち方・同じ人で）。
手順の詳細はアプリの「マニュアル」→「しきい値の測り方」「軸の選び方」にあります。
軸名はアプリの表記（aX / aY / aZ / gX / gY / gZ / |a| / |g|）です。下の軸は**例**で、1-3 で調べた向きに合わせて読み替えてください。

### シナリオ A: 剣を振る（ジャイロ、例: gZ）

1. 本体を剣の柄のように握る（持ち方をメモ。例「表を左に向け、USB を下にして握る」）。
2. 「モニタリング」で振ってみて、いちばん大きく動くジャイロ軸を選ぶ（例: gZ）。
3. 「しきい値測定」で対象デバイスとその軸を選ぶ。
4. ① 静止測定（3 秒）: 剣を構えた姿勢でじっとする。
5. ② 試行 × 5: 強い振り 3 回 ＋ **判定してほしい一番弱い振り** 2 回（Space キーで開始 / 終了）。
6. ③ 推奨値を見て「推奨値を適用」。④ 判定テストで、振る・構え直す・歩く を試す。

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| T-A1 | ① のノイズ（σ・範囲） | gZ の範囲が ±10 deg/s 程度に収まる | | |
| T-A2 | ③ の向き・ノイズ上限・最弱ピーク・推奨値・判定品質 | 向きが振った方向（＋方向 か −方向）に自動で選ばれる。品質「● 良好」。最弱ピークは数百 deg/s | | |
| T-A3 | ④ 振る × 10 回 | 判定回数 10（1 回の振りで 2 回以上数えない） | | |
| T-A4 | ④ 構え直す・歩く 30 秒 | 判定 0 回（出たら回数をメモ） | | |
| T-A5 | ⑤ 名前「剣を振る」で保存 →「JSONをコピー」→ テキストエディタに貼る | `rules` に `"axis": "gz"` などが入っている。`sample_rate_hz` が約 100 | | |

### シナリオ B: ジャンプ（合成加速度 |a|）

1. 本体を手に握るか、ポケット / ベルトに固定する（どちらかをメモ）。
2. 軸 `|a|` を選ぶ。① 静止測定は、立ったままじっとする。
3. ② 試行 × 5: その場で軽いジャンプ 2 回 ＋ 普通のジャンプ 3 回。
4. ④ 判定テストで、ジャンプ・歩く・小走り を試す。

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| T-B1 | ① の \|a\| の平均 | 約 1.0G（重力。0 ではない） | | |
| T-B2 | ③ の判定品質と推奨値 | 品質「● 良好」か「● ぎりぎり」。推奨値は 1G より大きい（目安 1.5〜3G） | | |
| T-B3 | ④ ジャンプ × 10 回 | 判定回数 10。着地の衝撃で 1 回のジャンプが 2 回数えられたら、不応期を伸ばして再確認してメモ | | |
| T-B4 | ④ 歩く・小走り 30 秒 | 歩くでは判定 0 回。小走りは出てもよい（回数をメモ。誤検出の目安になる） | | |

### シナリオ C: 傾ける（加速度、例: aX）

1. 本体を水平に持つ（1-3 の姿勢①）。傾けると ±1G に向かって変わる軸（例: aX。1-3 の姿勢⑤⑥で ±1G になった軸）を選ぶ。
2. ① 静止測定: 水平に持ったままじっとする。
3. ② 試行 × 5: 右に 90° 傾けて戻す（一番弱い試行は 45° くらい）。
4. ④ 判定テストで、45°・90° 傾ける、ゆっくり傾ける、を試す。

| ID | 確認すること | 期待値 | 結果 | メモ（実測値） |
|---|---|---|---|---|
| T-C1 | ① の aX の平均 | 約 0G（水平なので）。持ち方で ±0.1G くらいずれるのは正常 | | |
| T-C2 | ③ の向き・最弱ピーク・推奨値 | 向きは傾けた方向の＋方向か−方向。90° 傾けると ±1.0G、45° だと約 ±0.7G。推奨値は 0.3〜0.7G くらい | | |
| T-C3 | ④ 90° 傾けて止める × 10 回 | 傾けている間ランプが点き、判定回数 10（傾けたまま止めても 1 回だけ） | | |
| T-C4 | ④ ゆっくり傾ける | しきい値の角度を越えたところで判定する（速さに関係なく判定される。加速度は「向き」を測っているため） | | |
| T-C5 | 反対側（左）に傾ける | 向きが＋方向 / −方向なら判定しない。「絶対値」なら判定する | | |

### シナリオ共通

| ID | 確認すること | 期待値 | 結果 | メモ |
|---|---|---|---|---|
| T-1 | 同じシナリオの 有線 と BLE の推奨値を比べる | ほぼ同じ（目安 ±15% 以内）。大きく違えば両方の値をメモ | | |
| T-2 | ⑤「コードをコピー」（C++） | M5 / Arduino 向けの判定コードが貼れる。しきい値・ヒステリシス・不応期の数値がプロファイルと一致 | | |
| T-3 | 保存したプロファイルを「読み込み」 | 軸・しきい値・平滑化が保存時のとおりに戻る | | |

---

## 5. 結果のまとめ表

機種ごとの結果をここに集約します（詳細は各表の「結果」欄）。

| 機種 | OS | 1 起動・表示 (M-1〜10) | 1-3 向き (M-11〜13) | 2 有線 (W / C / S) | 3 BLE (B-1〜30) | 4 しきい値 (T) | 総合 | 試した人・日付 | メモ |
|---|---|---|---|---|---|---|---|---|---|
| M5StickC Plus2 | | | | | | | | | |
| M5StickC Plus | | | | | | | | | |
| M5StickC | | | | | | | | | |
| Core2 | | | | | | | | | |
| CoreS3 | | | | | | | | | |
| CoreS3 SE（IMU 無し） | | | | | | - | | | |
| AtomS3 | | | | | | | | | |
| ATOM Matrix | | | | | | | | | |
| ATOM Lite（IMU 無し） | | | | | | - | | | |

NG 一覧（見つけた順に）:

| # | 項目 ID | 機種 / OS | 起きたこと | 再現手順 | 再現率（例 3/5） | 切り分け結果（6 章） | 報告先・Issue |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |

---

## 6. NG のときの切り分け

**下流から上流へ**ではなく、**デバイスに近いところから順に**確かめると早く絞れます。

```
 ① ファーム単体     pio device monitor で CSV と INFO が出るか
        │ NG → ファーム／書き込み／機種判別の問題（6-1）
        ▼ OK
 ② 有線 + アプリ    アプリで有線接続して波形が出るか
        │ NG → アプリの有線受信（ポート・権限）の問題（6-2）
        ▼ OK
 ③ BLE 単体         bleak スクリプト（3-3）で情報行・CSV・コマンド応答が来るか
        │ NG → ファームの BLE か PC の Bluetooth の問題（6-3）
        ▼ OK
 ④ ブリッジ単体     手動起動のブリッジ（ターミナル）＋ --scan-once で見えるか
        │ NG → ブリッジ・bleak・OS 権限の問題（6-4）
        ▼ OK
 ⑤ BLE + アプリ     アプリで BLE 接続して波形が出るか
          NG → アプリ ⇔ ブリッジ（UDP）の問題（6-4）
```

### 6-1. ファーム単体（①）が NG

| 症状 | 確認すること |
|---|---|
| ポートが出ない | ケーブル（データ通信対応か）、電源（StickC Plus2 は電源ボタンを短く押す）、Windows はドライバ（CH9102 / CP210x）。firmware README「トラブルシュート」 |
| 書き込みに失敗 | CoreS3 / AtomS3 はダウンロードモード（0-4）。`--upload-port` の指定。ATOM は env の `upload_speed = 115200` |
| 何も出ない | ボーレート 115200。画面が `PAUSED` なら `RESUME`。`INFO` + Enter で情報行が出るか |
| `model=Unknown` / 機種名が違う | env の選び間違い（StickC Plus2 に `m5stickc` を書いた等）。正しい env で書き直す |
| `imu=none` / `IMU ERROR`（IMU のある機種なのに） | env の選び間違い。電源を完全に切って入れ直す。`model=` が正しいか |
| 値がおかしい（6 姿勢の表が成り立たない） | 1-3 の表を添えて報告。`imu=` の種類も |
| `drop_usb` が増える | PC 側が読み切れていない。`RATE` を下げて再確認。USB ハブを外して直結 |

### 6-2. 有線 + アプリ（②）が NG

- `pio device monitor` を閉じたか（同じポートは同時に開けない）。
- macOS は `/dev/cu.*` を使う（`/dev/tty.*` ではない）。
- アプリの「受信」が 0 Hz なのに ① は OK → アプリのログ（Godot の出力パネル）を添えて報告。

### 6-3. BLE 単体（③）が NG

| 症状 | 確認すること |
|---|---|
| 見つからない | 本体の画面が `BLE: advertising` か（`connected` / `streaming` なら別の PC やアプリがつないでいる）。スマホの nRF Connect で見えるか（見えれば PC 側の問題） |
| 見つかるがつながらない | 本体を再起動。PC の Bluetooth をオフ → オン。OS の Bluetooth 設定でペアリングしていないか（不要。登録されていたら削除） |
| つながるが情報行も CSV も来ない | TX（6E400003）の通知を ON にしているか（スクリプトは自動で ON にする）。本体の画面が `BLE: streaming` になるか |
| `RATE 200` で行が足りない | `drop_ble` の値、MTU、PC と本体の距離をメモ。100Hz で足りていれば仕様の範囲（200Hz は BLE ではぎりぎり） |

### 6-4. ブリッジ・アプリ（④⑤）が NG

- デバイス管理画面の BLE 欄の表示を tools/ble_bridge/README「使い方」の表と照らし合わせる。
- 「手動起動で接続」でターミナルからブリッジを起動すると、ブリッジのログがターミナルに出ます（`[ble_bridge] …` の行）。NG を再現させてログを保存してください。
- `tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py --scan-once --all` で周囲の機器が 1 台も見えなければ、Bluetooth 自体（権限・オフ・アダプタ）の問題です。

---

## 7. 報告に添える情報

NG を報告するときは、次をできるだけ添えてください（Issue / PR のコメント / チャットのどれでも）。

| 情報 | 取り方 |
|---|---|
| 項目 ID と期待値・実際の結果 | この文書の表から |
| 環境情報 | 0-2 の表 |
| 機種とロット・購入時期 | 本体の型番シール、わかれば購入時期（IMU のチップがロットで違うことがあるため） |
| **INFO の出力** | `pio device monitor` で `INFO` + Enter、または 3-3 のスクリプトの最後の行。`model` / `imu` / `rate` / `drop_usb` / `drop_ble` が入っている |
| 起動直後のシリアル出力 | 本体のリセット直後から `pio device monitor` の数行（`# error=…` の行があれば必ず） |
| **CSV ログ** | アプリの「モニタリング」で記録（2-1 W-6）→「ログ管理」→「保存フォルダを開く」でファイルを添付。macOS の保存場所は `~/Library/Application Support/Godot/app_userdata/Sensor Test App/logs` |
| **ブリッジのログ**（BLE の NG） | 手動起動のブリッジをターミナルで動かして再現し、ターミナルの出力をコピー。デバイス管理画面の BLE 欄の表示と、機器名のツールチップ（情報行・直近の応答）も |
| スクリプトの出力 | 2-2 / 3-3 のスクリプトを実行した結果をそのまま |
| 写真・スクリーンショット | 本体の画面（または LED の色）と、アプリの画面 |
| 再現手順と再現率 | 「何をしたら」「何回中何回」起きたか |
