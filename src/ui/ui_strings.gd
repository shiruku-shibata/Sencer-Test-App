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

const TH_CONFIRM_TITLE := "確認"
const BTN_OK := "OK"
const BTN_CANCEL := "キャンセル"
const TH_CONFIRM_AXES := "軸を変更すると、静止測定と試行の結果が消えます。よろしいですか？"
const TH_CONFIRM_SMOOTHING := "平滑化を変更すると、静止測定と試行の結果が消えます（平滑化が違う値は比べられないため）。よろしいですか？"
const TH_CONFIRM_DEVICE := "対象デバイスを変更すると、静止測定と試行の結果が消えます。よろしいですか？"
const TH_CONFIRM_LOAD := "このプロファイルを読み込むと軸または平滑化が変わり、静止測定と試行の結果が消えます。よろしいですか？"
const TH_CONFIRM_DELETE := "プロファイル「%s」を削除します。よろしいですか？"

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
