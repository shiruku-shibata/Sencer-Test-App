class_name UIStrings
extends RefCounted
## UI文言を1箇所に集約する。将来の英語対応・文言修正はこのファイルだけを触ればよい。

const APP_TITLE := "センサーテストアプリ"
const APP_SUBTITLE := "試作版 P2"

const SCREEN_DEVICES := "デバイス管理"
const SCREEN_MONITOR := "モニタリング"
const SCREEN_THRESHOLD := "しきい値測定"
const SCREEN_LOGS := "ログ管理"
const SCREEN_MANUAL := "マニュアル"

const BTN_SCAN := "スキャン"
const BTN_CONNECT := "接続"
const BTN_DISCONNECT := "切断"
const BTN_RECORD_START := "● 記録開始"
const BTN_RECORD_STOP := "■ 記録停止"
const BTN_PAUSE := "一時停止"
const BTN_RESUME := "再開"
const BTN_OPEN_FOLDER := "保存フォルダを開く"
const BTN_REFRESH := "更新"
const BTN_DELETE := "削除"

const LABEL_NICKNAME := "ニックネーム"
const LABEL_MODE := "方式"
const LABEL_ID := "ID（ポート / MAC）"
const LABEL_STATE := "状態"
const LABEL_RATE := "受信"
const LABEL_ACTION := "操作"
const LABEL_CONNECTED := "接続中"
const LABEL_DISCONNECTED := "未接続"
const LABEL_TIME_WINDOW := "時間窓"
const LABEL_TARGET_DEVICE := "対象デバイス"
const LABEL_ACCEL := "加速度 [G]"
const LABEL_GYRO := "ジャイロ [deg/s]"
const LABEL_AXES := "軸"
const LABEL_SMOOTHING := "平滑化"
const LABEL_MOVING_AVERAGE := "移動平均"

const HINT_NO_DEVICE := "接続中のデバイスがありません。「デバイス管理」から接続してください。"
const HINT_RENAME := "ニックネームを入力してEnterで保存"

# ---------------------------------------------------------------- 全体（サイドバー・ステータスバー）

const TOOLTIP_HELP := "使い方を開く"
const STATUS_DEVICES := "接続: %d 台"
const STATUS_RATE := "受信: %.0f Hz"
const STATUS_RECORDING := "記録中 %.1f s（%s）"
const STATUS_NOT_RECORDING := "記録: 停止中"

# ---------------------------------------------------------------- デバイス管理（S1）

const DEV_SCANNING := "スキャン中…"
const DEV_CONNECTING := "接続処理中…"
const DEV_ERROR_SUFFIX := "（エラー）"
const DEV_CANCEL := "中止"
const DEV_BLE_RESTART := "ブリッジ再起動"
const DEV_BLE_RESTART_TIP := "BLEブリッジを起動し直します（bleak を入れた後や、調子が悪いとき）"
const DEV_BLE_MANUAL := "手動起動で接続"
const DEV_BLE_MANUAL_TIP := "アプリからブリッジを起動せず、ターミナルで起動したブリッジにつなぎます（macOS で Bluetooth 権限のエラーが出るとき）"
const DEV_BLE_MANUAL_HINT := "ターミナルで次のコマンドを実行してください（実行したままにしておきます）:"
const DEV_COPY := "コピー"
const DEV_COPIED := "コピーしました"
const DEV_BLE_NOT_READY := "BLE ブリッジの準備ができていません"
const DEV_LABEL_DEVICE_NAME := "機器名"
const DEV_LABEL_RSSI := "電波"

# ---------------------------------------------------------------- ログ管理（S3）

const LOGS_SAVE_DIR := "保存先: %s"
const LOGS_COL_FILE := "ファイル名"
const LOGS_COL_SIZE := "サイズ"
const LOGS_EMPTY := "記録されたログはまだありません。"

# ---------------------------------------------------------------- 軸選択

const AXIS_GROUP_ACCEL := "加速度"
const AXIS_GROUP_GYRO := "ジャイロ"
const AXIS_GROUP_MAGNITUDE := "合成"
const AXIS_LOCKED_RECORDING := "記録中は軸を変更できません"
const AXIS_LOCKED_MEASURING := "測定中は軸を変更できません"

# ---------------------------------------------------------------- モニタリング（S2）

const MONITOR_RECORD_TARGET := "記録対象: %s"
const MONITOR_RECORDING_AXES := "記録中の軸: %s"
const MONITOR_READOUT_AXIS := "軸"
const MONITOR_READOUT_NOW := "現在"
const MONITOR_READOUT_MAX := "最大"
const MONITOR_READOUT_MIN := "最小"
const MONITOR_SAMPLE_COUNT := "サンプル数"
const MONITOR_READOUT_NOTE := "最大・最小は表示中の時間窓の値"
const MONITOR_DEVICE_LOCKED := "記録中は対象デバイスを変更できません"
const MONITOR_RECORD_LOST := "記録中のデバイス（%s）が切断されたため、記録を停止しました（%d 行）"

# ---------------------------------------------------------------- しきい値測定（S4）

const SMOOTHING_NONE := "なし"
const SMOOTHING_SAMPLES := "%d サンプル"
const TH_SMOOTHING_TOOLTIP := "直近Nサンプルの移動平均。測定・判定・表示のすべてに同じ設定が使われ、プロファイルにも保存されます。"
const TH_DETECTING := "判定中"

const TH_STEP1_TITLE := "① 静止測定"
const TH_STEP1_DESC := "ゲームで「何もしていない」ときと同じ持ち方で、なるべく動かさずに測ります。静止中の揺れ（ノイズ）の大きさを調べます。"
const TH_BASELINE_SECONDS := "測定時間"
const TH_SECONDS := "%d 秒"
const TH_BASELINE_START := "▶ 静止測定を開始"
const TH_BASELINE_RUNNING := "測定中…動かさないで"
const TH_BASELINE_EMPTY := "まだ測定していません。"
const TH_COL_AXIS := "軸"
const TH_COL_MEAN := "平均"
const TH_COL_STDDEV := "σ"
const TH_COL_RANGE := "範囲（最小〜最大）"

const TH_STEP2_TITLE := "② 動作測定（試行）"
const TH_STEP2_DESC := "試行開始 → 動作を1回 → 試行終了 を繰り返します。判定してほしい「いちばん弱い動き」も混ぜてください。"
const TH_TRIAL_START := "▶ 試行開始（Space）"
const TH_TRIAL_STOP := "■ 試行終了（Space）"
const TH_TRIAL_COUNT := "試行 %d 回 / 目安 %d 回"
const TH_TRIAL_ENOUGH := "試行 %d 回（目安 %d 回に到達）"
const TH_TRIAL_EMPTY := "まだ試行がありません。"
const TH_TRIAL_CLEAR := "試行をすべて消去"
const TH_TRIAL_DELETE_TOOLTIP := "この試行を削除"
const TH_TRIAL_PEAK_NOTE := "表の値は③で選んだ向きのピーク（＋方向=最大、−方向=最小、絶対値=絶対値の最大）"

const TH_STEP3_TITLE := "③ 推奨しきい値"
const TH_STEP3_DESC := "静止中のノイズ上限と、試行のうち最も弱いピークの間に推奨値を置きます。"
const TH_RATIO_EASY := "検出しやすさ"
const TH_RATIO_STRICT := "誤検出しにくさ"
const TH_RATIO_VALUE := "位置 %.2f"
const TH_RATIO_TOOLTIP := "0.0 = ノイズ上限ぎりぎり（弱い動きも拾うが誤検出しやすい）\n1.0 = 最も弱い試行のピーク（誤検出しにくいが、それより弱い動きは見逃す）"
const TH_DIRECTION := "向き"
const TH_NOISE_LEVEL := "ノイズ上限"
const TH_WEAKEST_PEAK := "最弱ピーク"
const TH_RECOMMENDED := "推奨値"
const TH_APPLY := "推奨値を適用"
const TH_APPLIED := "推奨値を④に適用しました。"
const TH_APPLY_NOTHING := "適用できる推奨値がありません（静止測定と試行が必要です）。"

const QUALITY_LABELS := {
	"good": "● 良好",
	"tight": "● ぎりぎり",
	"overlap": "● 重なり",
	"insufficient": "● データ不足",
}
const QUALITY_DESCRIPTIONS := {
	"good": "静止中の揺れと動作のピークに十分な差があります。推奨値をそのまま使えます。",
	"tight": "差が小さめです。弱い動きの見逃しや、ちょっとした揺れでの誤検出が起きるかもしれません。判定テストで確かめてください。",
	"overlap": "静止中の揺れが動作のピークと重なっています。この軸・向きでは区別できません。別の軸や向きを試すか、動作を大きくしてください。",
	"insufficient": "静止測定と試行（1回以上）が必要です。",
}

const TH_STEP4_TITLE := "④ 判定テスト"
const TH_STEP4_DESC := "実際に動かして判定ランプが光るか確かめます。波形の赤い線をドラッグしても調整できます。"
const TH_ENABLED := "有効"
const TH_THRESHOLD := "しきい値"
const TH_HYSTERESIS := "ヒステリシス"
const TH_REFRACTORY := "不応期"
const TH_HYSTERESIS_TOOLTIP := "判定後、しきい値からこの量だけ戻るまで解除しない幅（チャタリング防止）"
const TH_REFRACTORY_TOOLTIP := "一度判定したら、この時間（ms）は次の判定をしない"
const TH_COMBINE := "組み合わせ"
const TH_COMBINE_ANY := "どれか1軸が超えたら"
const TH_COMBINE_ALL := "すべての軸が同時に超えたら"
const TH_LAMP := "判定"
const TH_TRIGGER_COUNT := "判定回数: %d"
const TH_RESET := "リセット"
const TH_LINE_LABEL := "しきい値"
const TH_STATUS_COUNT := "判定: %d 回"

const TH_STEP5_TITLE := "⑤ 保存と共有"
const TH_PROFILE_NAME := "名前"
const TH_PROFILE_NAME_PLACEHOLDER := "例: 剣を振る"
const TH_PROFILE_NOTE := "メモ"
const TH_PROFILE_NOTE_PLACEHOLDER := "持ち方・動作の説明など"
const TH_SAVE := "保存"
const TH_LOAD := "読み込み"
const TH_PROFILE_EMPTY := "（保存済みのプロファイルなし）"
const TH_COPY_JSON := "JSONをコピー"
const TH_COPY_CODE := "コードをコピー"
const TH_CODE_LANGS := [["C++", "cpp"], ["GDScript", "gdscript"], ["C#", "csharp"]]
const TH_MSG_NAME_REQUIRED := "名前を入力してください。"
const TH_MSG_SAVED := "保存しました: %s"
const TH_MSG_SAVE_FAILED := "保存できませんでした。"
const TH_MSG_LOADED := "読み込みました: %s"
const TH_MSG_LOAD_FAILED := "読み込めませんでした（ファイルが壊れているか、形式が違います）。"
const TH_MSG_DELETED := "削除しました: %s"
const TH_MSG_JSON_COPIED := "JSONをクリップボードにコピーしました。"
const TH_MSG_CODE_COPIED := "%s のコードをクリップボードにコピーしました。"

const TH_STEP6_TITLE := "⑥ ログで判定テスト"
const TH_STEP6_DESC := "ログ管理に保存した CSV に、今のしきい値で判定をかけます。しきい値を動かすとすぐ判定し直すので、実機なしでしきい値を詰められます。"
const TH_LOG_OPEN := "表示"
const TH_LOG_EMPTY := "（記録されたログなし）"
const TH_LOG_NOT_OPEN := "ログを選んで「表示」を押すと、左の波形がログ全体の表示に切り替わります。"
const TH_LOG_OPENED := "ログを表示しています: %s"
const TH_LOG_LOAD_FAILED := "ログを読み込めませんでした（データ行が足りないか、形式が違います）。"
const TH_LOG_BANNER := "ログ表示中: %s　（波形を左右にドラッグすると範囲を選べます）"
const TH_LOG_BACK_TO_LIVE := "ライブ表示に戻る"
const TH_LOG_INFO := "%s ・ %.1f 秒 ・ %d サンプル ・ 列: %s"
const TH_LOG_SELECTION := "選択範囲: %.2f 〜 %.2f 秒（%d サンプル）"
const TH_LOG_RANGE := "範囲 %s 〜 %s"
const TH_LOG_MISSING := "このログには %s の列がありません（0 として判定されます）。"
const TH_LOG_MISSING_MAG_HINT := "合成値には元の3軸（ax,ay,az / gx,gy,gz）の列が必要です（合成値の列だけでは再現できません）。"
const TH_LOG_COUNT := "ログでの判定回数: %d"
const TH_LOG_NO_FIRE := "このしきい値では、ログの中で一度も判定されませんでした。"
const TH_LOG_FIRES := "判定位置: %s"
const TH_LOG_FIRES_MORE := " ほか %d 件"
const TH_LOG_IMPORT_HINT := "ログの一部を①静止測定・②試行として取り込めます（波形を左右にドラッグして範囲を選ぶ。選ばなければログ全体）。"
const TH_LOG_IMPORT_BASELINE := "ログ全体を静止測定に"
const TH_LOG_IMPORT_TRIAL := "ログ全体を試行に"
const TH_LOG_IMPORT_BASELINE_SEL := "選択範囲を静止測定に"
const TH_LOG_IMPORT_TRIAL_SEL := "選択範囲を試行に"
const TH_LOG_IMPORT_MISSING := "取り込めません: このログには %s の列がありません。"
const TH_LOG_IMPORT_TOO_SHORT := "範囲が短すぎます。もう少し広く選んでください。"
const TH_LOG_IMPORTED_BASELINE := "ログの %.2f 〜 %.2f 秒を静止測定として取り込みました。"
const TH_LOG_IMPORTED_TRIAL := "ログの %.2f 〜 %.2f 秒を試行として取り込みました。"

const TH_PHASE_BASELINE := "静止測定"
const TH_PHASE_TRIAL := "試行"
const TH_PHASE_CANCEL := "中止"
const TH_PHASE_CANCEL_TOOLTIP := "実行中の測定を、結果を残さずに止めます（それまでの結果は残ります）"
const TH_MSG_PHASE_CANCELLED := "%sを中止しました（この回の結果は残していません）。"
const TH_MSG_PHASE_INTERRUPTED := "%sを中止しました: データが %.1f 秒途切れました（この回の結果は残していません）。デバイスが一時停止していないか（本体のボタン・PAUSE）、電波が届いているか確認して、もう一度測ってください。"
const TH_MSG_TRIAL_DISCARDED :="サンプルが届かなかったため、この試行は記録しませんでした（デバイスの送信が止まっていないか確認してください）。"
const TH_MSG_RULES_SKIPPED := "（同じ軸のルールが複数あったため %d 件を省略しました）"
const TH_MSG_DEVICE_LOST := "計測中のデバイス（%s）が切断されました。測定結果が混ざらないよう、別のデバイスには自動で切り替えません。"
const TH_HINT_DEVICE_LOST := "計測していたデバイスが切断されました。再接続すると自動で選び直します。別のデバイスで続けるときは「対象デバイス」から選んでください（測定結果は消えます）。"

const TH_CONFIRM_TITLE := "確認"
const BTN_OK := "OK"
const BTN_CANCEL := "キャンセル"
const TH_CONFIRM_AXES := "軸を変更すると、静止測定と試行の結果が消えます。よろしいですか？"
const TH_CONFIRM_SMOOTHING := "平滑化を変更すると、静止測定と試行の結果が消えます（平滑化が違う値は比べられないため）。よろしいですか？"
const TH_CONFIRM_DEVICE := "対象デバイスを変更すると、静止測定と試行の結果が消えます。よろしいですか？"
const TH_CONFIRM_LOAD := "このプロファイルを読み込むと、今の静止測定と試行の結果は消え、プロファイルに保存されている結果（あれば）に置き換わります。よろしいですか？"
const TH_CONFIRM_DELETE := "プロファイル「%s」を削除します。よろしいですか？"
const TH_CONFIRM_OVERWRITE := "プロファイル「%s」は既に保存されています。上書きしますか？"

## マニュアル（S5）の本文。BBCode で表示する。
const MANUAL_PAGES := {
	"はじめての接続": """[b]はじめての接続[/b]

1. M5StickC Plus2 をUSBケーブルでPCに接続します。
2. 「デバイス管理」画面で [b]スキャン[/b] を押します。
3. 一覧に出たデバイスの [b]接続[/b] を押します。状態が「接続中」になれば成功です。
4. 複数台使うときは、ニックネーム欄に名前を入力してEnterを押すと見分けやすくなります。

ケーブルを使わずに接続したいときは「BLEで接続する」ページを見てください。

実機やシリアル通信アドオンが無い場合は、[b]デモ[/b]と表示されるデバイス（demo-01 など）に接続すると、
ダミーデータで一通りの操作を試せます。""",

	"BLEで接続する": """[b]BLEで接続する[/b]

Godot には Bluetooth の機能が無いため、本アプリは [b]BLEブリッジ[/b]（Python で書かれた小さな補助プログラム）を通して BLE デバイスと通信します。

[b]準備（最初の1回だけ）[/b]
1. Python 3 を用意します。
2. ターミナルでアプリのフォルダに移動し、次を実行します（Windows は tools\\ble_bridge\\setup.bat）。
	[code]tools/ble_bridge/setup.sh[/code]
	ブリッジ専用の環境（tools/ble_bridge/.venv）が作られ、必要なライブラリ（bleak）が入ります。
3. M5 デバイスに BLE 対応のファームウェアを書き込みます（「対応機種とファームウェア」ページ）。

[b]接続のしかた[/b]
1. アプリを起動すると、BLEブリッジが自動で起動します。
2. 「デバイス管理」画面で [b]スキャン[/b] を押すと、[b]M5-Sensor-XXXX[/b] という名前のデバイスが方式「BLE」で表示されます（XXXX は機体ごとに違う英数字）。
3. [b]接続[/b] を押します。そのあとの操作は有線と同じです。

[b]うまくいかないとき[/b]
・[b]macOS でスキャンしても何も出ない／Bluetooth の許可が出ない[/b]
	macOS では、アプリから起動したブリッジに Bluetooth の権限が付かないことがあります。
	ターミナルから手動で起動してください（Bluetooth の許可を求められたら「許可」を押します）。
	[code]tools/ble_bridge/.venv/bin/python tools/ble_bridge/ble_bridge.py[/code]
	このコマンドは「デバイス管理」画面の [b]手動起動で接続[/b] からも表示・コピーできます。
	ターミナルを開いたままアプリでスキャンすれば、自動起動のときと同じように使えます。
・「システム設定 → プライバシーとセキュリティ → Bluetooth」で、ターミナル（または本アプリ）が許可されているか確認してください。
・デバイス管理画面に BLE が使えない理由（Python や bleak が無い など）が出ている場合は、その案内に従ってください。
・デバイスが他の PC やスマートフォンと接続中だと見つかりません。
・BLE は有線より受信レートが下がることがあります。しきい値は使う接続方法で測るのがおすすめです。

[b]実機なしで試す[/b]
環境変数 SENSOR_BLE_MOCK=1 を付けてアプリを起動すると、ブリッジが模擬モード（--mock）で起動し、
M5-Sensor-MOCK1 / M5-Sensor-MOCK2 という BLE デバイスが見えるようになります。

[b]仕組み（参考）[/b]
デバイスは Nordic UART Service（NUS）で、有線と同じ CSV 行を送ります。
ブリッジはそれを PC 内部の通信（127.0.0.1 の UDP）でアプリに渡します。""",

	"記録のしかた": """[b]記録のしかた[/b]

1. 「モニタリング」画面の上部で、記録したい[b]軸[/b]を選びます（aX〜|g| のボタン。少なくとも1つ）。
2. 波形が流れていることを確認します。
3. [b]● 記録開始[/b] を押すと記録が始まり、画面下の表示が「記録中」に変わります。記録中は軸を変更できません。
4. 試したい動作を行い、終わったら [b]■ 記録停止[/b] を押します。
5. 記録したCSVは「ログ管理」画面の一覧に表示されます。

[b]CSVの形式[/b]
1行目: 情報行（# device_id=… nickname=… axes=ax,gz）
2行目: 列名（timestamp_ms と、選んだ軸のキー）
軸のキーは ax, ay, az, gx, gy, gz, amag（合成加速度）, gmag（合成角速度）です。""",

	"しきい値の測り方": """[b]しきい値の測り方[/b]

しきい値とは「この値を超えたら“動作した”とみなす」境目の値です。
「しきい値測定」画面では、[b]静止中の揺れ（ノイズ）[/b]と[b]動作したときのピーク[/b]を測り、その間に推奨値を置きます。

[b]手順[/b]
1. 上部で対象デバイスと、判定に使う軸を選びます（迷ったら「軸の選び方」ページ）。
2. [b]① 静止測定[/b]: ゲームで「何もしていない」ときと同じ持ち方で、なるべく動かさずに [b]静止測定を開始[/b] を押します。机に置くより、手で構えた状態で測るほうが実際に近い値になります。
3. [b]② 動作測定[/b]: [b]試行開始[/b]（スペースキーでも可）→ 動作を1回 → [b]試行終了[/b] を、5回ほど繰り返します。
	強い動きだけでなく、[b]判定してほしい一番弱い動き[/b]も混ぜてください。失敗した試行は × で消せます。
	測定中は [b]中止[/b] で、その回の結果を残さずに止められます。データが 0.5 秒以上途切れたとき（本体のボタンで一時停止した・電波が途切れた など）も、その回は自動で中止になります。
4. [b]③ 推奨しきい値[/b]: 軸ごとに推奨値と判定品質が出ます。向き（＋方向／−方向／絶対値）は試行結果から自動で選ばれますが、変えることもできます。
	[b]推奨値を適用[/b] を押すと ④ に反映されます。
5. [b]④ 判定テスト[/b]: 実際に動かして、ランプが光るか・判定回数が合うかを確かめます。
	波形の赤い線をドラッグするか、数値を入力して微調整できます。
6. [b]⑤ 保存と共有[/b]: 名前を付けて保存します（「プロファイルの共有」ページ）。

[b]⑥ ログで判定テスト（実機なしで詰める）[/b]
モニタリング画面で記録した CSV を使って、しきい値を机の上で調整できます。
1. ⑥ でログを選んで [b]表示[/b] を押すと、左の波形がログ全体の表示に変わり、今のしきい値で判定した位置に赤い縦線が出ます。
2. 波形の赤い線をドラッグしたり ④ の数値を変えたりすると、すぐに判定し直します。⑥ に判定回数と判定位置（秒）が出るので、
	「振った回数」と合うようにしきい値を詰めます。ライブの判定回数（④）には影響しません。
3. 波形を左右にドラッグして範囲を選ぶと、その範囲を [b]静止測定[/b] や [b]試行[/b] として取り込めます（選ばなければログ全体）。
	取り込んだ結果は ① ② に入り、③ の推奨値にも使われます。
4. [b]ライブ表示に戻る[/b] で通常の表示に戻ります。
・判定に使う軸の列がログに無いと警告が出ます。合成値（|a| |g|）は元の3軸の列から計算するので、
	記録するときは加速度なら aX aY aZ、ジャイロなら gX gY gZ を選んでおくと安心です。

[b]判定品質の見方[/b]
[color=#5cc77a]● 良好[/color]　静止中の揺れと動作のピークに十分な差があります。
[color=#e8c547]● ぎりぎり[/color]　差が小さめ。見逃し・誤検出が起きやすいので、判定テストでよく確かめてください。
[color=#e85d5d]● 重なり[/color]　静止中の揺れが動作のピークに届いています。この軸・向きでは区別できません。別の軸や向きを試すか、動作を大きくしてください。
[color=#999999]● データ不足[/color]　静止測定と試行（1回以上）が必要です。

[b]「検出しやすさ ⇔ 誤検出しにくさ」スライダー[/b]
推奨値は次の式で決まります（＋方向の場合）。
	[code]推奨値 = ノイズ上限 + (最弱ピーク − ノイズ上限) × 位置[/code]
・[b]ノイズ上限[/b] = 静止中の最大値 と 平均＋4σ の大きいほう
・[b]最弱ピーク[/b] = 各試行の最大値のうち、いちばん小さいもの
・左（0.0）に寄せる: ノイズ上限ぎりぎり。弱い動きも拾えるが、ちょっとした揺れで誤検出しやすい。
・右（1.0）に寄せる: 最も弱かった試行のピークちょうど。誤検出は減るが、それより弱い動きは見逃す。
・まずは真ん中（0.5）から始めるのがおすすめです。
−方向は符号を反転して、絶対値は絶対値で同じように計算します。

[b]用語[/b]
・[b]ヒステリシス[/b]: 判定したあと、しきい値からこの量だけ戻るまでは「解除」しない幅。1回の動作で何度も判定される（チャタリング）のを防ぎます。
・[b]不応期[/b]: 判定してからこの時間（ms）は次の判定をしない。
・[b]平滑化[/b]: 直近Nサンプルの移動平均。値が細かく揺れるときに使います。測定・判定・表示のすべてで同じ設定が使われ、プロファイルにも保存されます。ゲーム側でも同じ平滑化をしてください。""",

	"軸の選び方": """[b]軸の選び方[/b]

[b]動きの種類と向いている軸[/b]
・[b]振る・ひねる[/b]（剣を振る、ハンドルを切る、手首を返す）→ [b]ジャイロ X/Y/Z[/b]（角速度）。
	重力の影響を受けず、静止中はほぼ 0 なので扱いやすい軸です。
・[b]揺さぶる・叩く・ジャンプ[/b]など、向きが決まらない動き → [b]合成加速度 |a|[/b]。どの向きで持っていても同じように反応します。
・[b]向きがはっきりした直線的な動き[/b]（前に突く、持ち上げる）→ その方向の [b]加速度 X/Y/Z[/b]。
・回転の向きを問わず「回した」ことだけ知りたい → [b]合成角速度 |g|[/b]。

[b]重力に注意[/b]
加速度センサーは、静止していても重力（1G）を感じます。
・下を向いている軸は、静止中でも約 +1G または −1G になります。持ち方を変えると値がずれます。
・加速度 X/Y/Z を使う場合は、静止測定を[b]ゲーム中と同じ持ち方[/b]で行ってください。
・合成加速度 |a| は、静止中は約 1G です（0 ではありません）。
・本アプリは重力分を引かずに[b]生の値[/b]で判定します。ゲーム側でも生の値で比べれば同じ結果になります。

[b]コツ[/b]
・軸の向き（どちらが X か）は機種や持ち方で変わります。モニタリング画面でデバイスを動かし、どの線が大きく動くかを見てから選ぶと確実です。
・最初は候補の軸をいくつか選んで測定し、判定品質が「良好」になる軸を残すと選びやすくなります。
・複数の軸を選んだときは、④ の「組み合わせ」で「どれか1軸が超えたら」か「すべての軸が同時に超えたら」を選べます。誤検出が多いときは「すべて」にすると減ります。
・軸を変えると測定結果は消えます（測定済みなら確認が出ます）。""",

	"プロファイルの共有": """[b]プロファイルの共有[/b]

「しきい値測定」画面の ⑤ で保存したしきい値は、[b]プロファイル[/b]（JSONファイル）になります。

[b]保存場所[/b]
user://thresholds フォルダ（⑤ の [b]保存フォルダを開く[/b] で開けます）。
macOS では ~/Library/Application Support/Godot/app_userdata/Sensor Test App/thresholds です。
ファイルを他の人に渡し、相手の同じフォルダに置けば「読み込み」の一覧に出ます。

[b]中身[/b]
・name / note: 名前とメモ
・device_name / sample_rate_hz: 測定に使ったデバイスと受信レート
・smoothing_window: 平滑化（移動平均のサンプル数。1 = なし）
・combine: 組み合わせ（どれか1軸 / すべて同時）
・rules: 軸ごとの設定（axis, direction, threshold, hysteresis, refractory_ms, enabled）
・measurement: 測定結果（静止中のノイズと各試行のピーク）
軸は ax, ay, az, gx, gy, gz, amag（合成加速度）, gmag（合成角速度）のキーで書かれます。

[b]ゲーム側で使う[/b]
・[b]JSONをコピー[/b]: プロファイルの JSON をクリップボードにコピーします。
・[b]コードをコピー[/b]: C++（M5 / Arduino）、GDScript（Godot）、C#（Unity など）向けの判定コードをコピーします。
ゲーム側では、生の値（重力を引かない値）に同じ平滑化をかけ、[b]測定したときと同じ頻度[/b]で比べてください。アプリの判定テストと同じ結果になります。
平滑化はサンプル数で数えるので、読む頻度が違うと効き方が変わります。生成コードには測定時のサンプルレートと読む間隔（SAMPLE_INTERVAL_MS）が入っていて、
update() を使えば、ゲームのループが速く回っていてもその間隔でだけ値を読みます。""",

	"対応機種とファームウェア": """[b]対応機種とファームウェア[/b]

IMU（6軸センサー）付きの M5 製品で使えます。機種は起動時にファームウェアが自動で判別します。
書き込むときは、機種に合った「環境名（env）」を選びます。

[table=3][cell padding=0,2,24,2][b]機種[/b][/cell][cell padding=0,2,24,2][b]環境名（-e）[/b][/cell][cell padding=0,2,0,2][b]一時停止/再開の操作[/b][/cell][cell padding=0,2,24,2]M5StickC Plus2（主な対象）[/cell][cell padding=0,2,24,2]m5stickc_plus2（既定）[/cell][cell padding=0,2,0,2]A ボタン（M5 ロゴ）[/cell][cell padding=0,2,24,2]M5StickC Plus[/cell][cell padding=0,2,24,2]m5stickc_plus[/cell][cell padding=0,2,0,2]A ボタン[/cell][cell padding=0,2,24,2]M5StickC（初代）[/cell][cell padding=0,2,24,2]m5stickc[/cell][cell padding=0,2,0,2]A ボタン[/cell][cell padding=0,2,24,2]M5Stack Core2[/cell][cell padding=0,2,24,2]m5stack_core2[/cell][cell padding=0,2,0,2]画面下の左タッチボタン[/cell][cell padding=0,2,24,2]M5Stack CoreS3[/cell][cell padding=0,2,24,2]m5stack_cores3[/cell][cell padding=0,2,0,2]画面をタップ[/cell][cell padding=0,2,24,2]M5Stack AtomS3[/cell][cell padding=0,2,24,2]m5stack_atoms3[/cell][cell padding=0,2,0,2]画面（ボタン）を押す[/cell][cell padding=0,2,24,2]ATOM Matrix[/cell][cell padding=0,2,24,2]m5stack_atom[/cell][cell padding=0,2,0,2]画面（ボタン）を押す[/cell][/table]

[color=#e8c547]注意[/color]: [b]CoreS3 SE[/b] と [b]ATOM Lite[/b] は IMU を積んでいないため使えません。
書き込むと画面に [b]IMU ERROR[/b]（ATOM は LED が赤）と出て、データの代わりに「# error=imu_not_found」という情報行を5秒おきに送ります。

[b]ファームウェアの書き込み[/b]
1. PC に PlatformIO（VS Code の拡張機能、または pio コマンド）を入れます。
2. USB ケーブル（データ通信対応のもの）でデバイスをつなぎます。
3. ターミナルで firmware/m5stick_sender に移動し、機種の環境名を指定して書き込みます。
	[code]pio run -e m5stickc_plus2 -t upload[/code]
	複数台つないでいるときは、末尾に --upload-port /dev/cu.usbserial-XXXX（Windows は COM5 など）を付けます。
4. 書き込むと、有線（USBシリアル）と BLE の両方でデータを送り始めます。
	画面には BLE のデバイス名（M5-Sensor-XXXX）・送信状態・レートが出ます。
・CoreS3 / AtomS3 で書き込みに失敗するときは、側面のリセットボタンを2〜3秒長押しして書き込みモードにしてから、もう一度実行します。
・詳しい手順やトラブル対処は firmware/m5stick_sender/README.md にあります。

[b]機種による違い[/b]
・本体の操作（上の表）で送信を一時停止／再開できます。一時停止中は画面に PAUSED と出ます。
・軸の向きは機種によって違います。モニタリング画面で確かめてください。
・センサーには個体差があります。しきい値は、ゲームで使う機種（できれば同じ個体）で測るのがおすすめです。
・プロファイルには、測定に使ったデバイス名と受信レートが記録されます。""",

	"困ったときは": """[b]困ったときは[/b]

[b]有線でポートが出てこない[/b]
macOSでは /dev/cu.* を使用します（/dev/tty.* ではありません）。
USBケーブルが充電専用でないか、デバイスの電源が入っているかも確認してください。

[b]デバイスの画面に IMU ERROR と出る（波形が流れない）[/b]
IMU の無い機種（CoreS3 SE / ATOM Lite）か、書き込むときの環境名の選び間違いです。「対応機種とファームウェア」ページを見てください。

[b]デバイスの画面に PAUSED と出る[/b]
本体のボタン（機種による）で一時停止しています。もう一度押すと再開します。

[b]BLE のデバイスが出てこない[/b]
「BLEで接続する」ページの「うまくいかないとき」を見てください。

[b]波形が流れない[/b]
デバイス側の送信フォーマットが CSV（ax,ay,az,gx,gy,gz）または JSON になっているか確認してください。

[b]値が飛ぶ・波形が乱れる[/b]
モニタリング画面の「移動平均」や、しきい値測定画面の「平滑化」を使ってください。

[b]判定品質がいつも「重なり」になる[/b]
静止測定中に動いていないか、試行で動作をしっかり行えているかを確認してください。
それでも重なる場合は、別の軸を試してください（「軸の選び方」ページ）。

[b]測定中・記録中にデバイスが切断された[/b]
しきい値測定: 途中の静止測定・試行は記録されません（それまでの結果は残ります）。別のデバイスには自動で切り替わらないので、再接続すると元のデバイスで続けられます。
モニタリング: 記録はその時点で止まり、そこまでの CSV が保存されます。

[b]1回の動作で何回も判定される[/b]
④ 判定テストの「ヒステリシス」か「不応期」を大きくしてください。""",

	"送信フォーマット仕様": """[b]送信フォーマット仕様[/b]

デバイス側からは、1行1サンプルで次のいずれかの形式を送信します。

[b]CSV形式[/b]
ax,ay,az,gx,gy,gz
0.02,0.98,-0.01,12.4,-3.1,0.8

[b]JSON形式[/b]
{"ax":0.02,"ay":0.98,"az":-0.01,"gx":12.4,"gy":-3.1,"gz":0.8}

単位: 加速度 G / 角速度 deg/s
ボーレート: 115200 / 改行: LF
サンプル用ファームウェアは firmware/m5stick_sender（PlatformIOプロジェクト）に入っています。

[b]情報行[/b]
「#」で始まる行は情報です（例: # model=M5StickCPlus2 rate=100）。アプリはデータとしては扱いません。

[b]コマンド（PC → デバイス、有線・BLE共通、改行で終わる）[/b]
・PAUSE: 送信を一時停止
・RESUME: 送信を再開
・RATE <Hz>: 送信レートを変更（10〜200）。例: RATE 50
・INFO: 機種やレートなどの情報行を送り返す

[b]BLE[/b]
・サービス: Nordic UART Service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
・TX（デバイス → PC, Notify）: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E
・RX（PC → デバイス, Write）: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E
・デバイス名: M5-Sensor-XXXX（XXXX は MAC アドレス下位2バイトの16進）
・データは有線と同じ CSV 行です。1回の通知に複数行が入ったり、1行が複数の通知に分かれたりするため、受信側は改行で区切って組み立てます。"""
}
