class_name UIStrings
extends RefCounted
## UI文言を1箇所に集約する。将来の英語対応・文言修正はこのファイルだけを触ればよい。

const APP_TITLE := "センサーテストアプリ"
const APP_SUBTITLE := "試作版 P1"

const SCREEN_DEVICES := "デバイス管理"
const SCREEN_MONITOR := "モニタリング"
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
const LABEL_MOVING_AVERAGE := "移動平均"

const HINT_NO_DEVICE := "接続中のデバイスがありません。「デバイス管理」から接続してください。"
const HINT_RENAME := "ニックネームを入力してEnterで保存"

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

## マニュアル（S5）の本文。BBCode で表示する。
const MANUAL_PAGES := {
	"はじめての接続": """[b]はじめての接続[/b]

1. M5StickC Plus2 をUSBケーブルでPCに接続します。
2. 「デバイス管理」画面で [b]スキャン[/b] を押します。
3. 一覧に出たデバイスの [b]接続[/b] を押します。状態が「接続中」になれば成功です。
4. 複数台使うときは、ニックネーム欄に名前を入力してEnterを押すと見分けやすくなります。

実機やシリアル通信アドオンが無い場合は、[b]デモ[/b]と表示されるデバイス（demo-01 など）に接続すると、
ダミーデータで一通りの操作を試せます。""",

	"記録のしかた": """[b]記録のしかた[/b]

1. 「モニタリング」画面で波形が流れていることを確認します。
2. [b]● 記録開始[/b] を押すと記録が始まり、画面下の表示が「記録中」に変わります。
3. 試したい動作を行い、終わったら [b]■ 記録停止[/b] を押します。
4. 記録したCSVは「ログ管理」画面の一覧に表示されます。

CSVの列は timestamp_ms, ax, ay, az, gx, gy, gz です。""",

	"困ったときは": """[b]困ったときは[/b]

[b]有線でポートが出てこない[/b]
macOSでは /dev/cu.* を使用します（/dev/tty.* ではありません）。
USBケーブルが充電専用でないか、デバイスの電源が入っているかも確認してください。

[b]波形が流れない[/b]
デバイス側の送信フォーマットが CSV（ax,ay,az,gx,gy,gz）または JSON になっているか確認してください。

[b]値が飛ぶ・波形が乱れる[/b]
サンプリング間隔を長くするか、移動平均を有効にしてください。""",

	"送信フォーマット仕様": """[b]送信フォーマット仕様[/b]

デバイス側からは、1行1サンプルで次のいずれかの形式を送信します。

[b]CSV形式[/b]
ax,ay,az,gx,gy,gz
0.02,0.98,-0.01,12.4,-3.1,0.8

[b]JSON形式[/b]
{"ax":0.02,"ay":0.98,"az":-0.01,"gx":12.4,"gy":-3.1,"gz":0.8}

ボーレート: 115200 / 改行: LF
サンプル用ファームウェアは firmware/m5stick_sender（PlatformIOプロジェクト）に入っています。"""
}
