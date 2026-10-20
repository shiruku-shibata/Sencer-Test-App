class_name BleSensorProvider
extends SensorProvider
## BLE（Bluetooth Low Energy）接続の Provider。
##
## Godot には BLE の標準機能が無いため、BLE そのものは別プロセスの
## 「BLEブリッジ」（tools/ble_bridge/ble_bridge.py, Python + bleak）が担当し、
## このクラスはローカル UDP でブリッジと JSON をやり取りするだけにしている。
##
##   M5デバイス --BLE--> ブリッジ(127.0.0.1:47811) --UDP/JSON--> このクラス(127.0.0.1:47810)
##
## 起動の流れ:
##   1. UDP ポートを開き、hello を送って「既に起動しているブリッジ」（手動起動）を探す
##   2. 応答が無ければ Python を探してブリッジを自動起動する（--parent-pid 付き）
##   3. hello が返れば準備完了。以後は ping で生存確認し、落ちたら自動で再起動する
##
## ブリッジは USB シリアルの受信（kind="serial"）もできる。有線をブリッジ経由で使う
## BridgeSerialSensorProvider は、ブリッジの起動・UDP を持つこのクラスに attach_channel() で相乗りする
## （UDP ポートとブリッジのプロセスは1つだけにしたいため）。
##
## Python やブリッジが無い・ポートが使えない等の場合も、例外は出さずに
## status_text() / unavailable_reason() で理由と対処を返す（他の接続方式は普通に使える）。
## プロトコルの詳細は tools/ble_bridge/README.md を参照。

const HOST := "127.0.0.1"
const DEFAULT_APP_PORT := 47810
const DEFAULT_BRIDGE_PORT := 47811
const PROTOCOL_VERSION := 1

const ENV_PYTHON := "SENSOR_BLE_PYTHON"    ## 使う Python を指定する環境変数
const ENV_BRIDGE := "SENSOR_BLE_BRIDGE"    ## ble_bridge.py の場所を指定する環境変数
const ENV_MOCK := "SENSOR_BLE_MOCK"        ## "1" ならブリッジを --mock で起動する
const CMDLINE_MOCK := "--ble-mock"         ## godot ... -- --ble-mock でも同じ
const BRIDGE_DIR_RES := "res://tools/ble_bridge"
const KIND_BLE := "ble"
const BRIDGE_FILE := "ble_bridge.py"

const PROBE_SEC := 0.8               ## 手動起動のブリッジを探す時間
const HELLO_INTERVAL_SEC := 0.3
const START_TIMEOUT_SEC := 15.0      ## 自動起動してから hello が返るまでの上限
const PING_INTERVAL_SEC := 1.0
const LOST_TIMEOUT_SEC := 5.0        ## これだけ何も届かなければブリッジが落ちたとみなす
const BRIDGE_IDLE_TIMEOUT_SEC := 10  ## ブリッジ側: これだけ ping が無ければ自分で終了する
const SCAN_TIMEOUT_SEC := 4.0
const SCAN_GRACE_SEC := 8.0          ## スキャン結果が返らないときに諦めるまでの余裕
const CONNECT_TIMEOUT_SEC := 30.0
const RESTART_DELAY_SEC := 1.0
const MAX_AUTO_RESTARTS := 2         ## 自動再起動の上限（3回続けて落ちたら諦めて手動起動を案内する）
const STABLE_RESET_SEC := 30.0       ## これだけ安定して動けば再起動回数を数え直す
const QUIT_WAIT_MSEC := 600          ## 終了時にブリッジが自分で終わるのを待つ時間
const MAX_PACKETS_PER_POLL := 1000
const RECV_BUFFER_BYTES := 1 << 20
const MAX_LOG_LINES := 30

enum State {
	IDLE,            ## まだ何もしていない（最初のスキャンで開始）
	PROBING,         ## 既に起動しているブリッジを探している
	LAUNCHING,       ## ブリッジを自動起動し、応答を待っている
	RESTART_WAIT,    ## ブリッジが落ちたので、少し待ってから再起動する
	WAITING_MANUAL,  ## 手動起動のブリッジを待っている（自動起動しない）
	READY,           ## ブリッジと通信できている
	FAILED,          ## 使えない（理由は _fail_reason）
}


## BLE のサンプルに時刻を付ける。
##
## BLE のデータはブリッジが約20msごとにまとめて送るので、受信した時刻をそのまま使うと
## 同じ時刻のサンプルが2〜4個並んでしまう。そこで、1データグラムの最後のサンプルを受信時刻とし、
## それより前のサンプルは「推定サンプル間隔」ずつさかのぼった時刻にする。
## 推定間隔は直近の受信レート（約1秒ごとに測り直す）から求め、デバイスが知らせるレート
## （情報行や "# ok=RATE rate=50" の rate=）があれば、それを初期値にする。
## 付ける時刻はデバイスごとに必ず単調増加（前のサンプルより最低 1ms 後）にする。
class SampleClock:
	const DEFAULT_INTERVAL_MS := 10.0   ## 何も分からないとき（ファームの既定 100Hz）
	const MIN_INTERVAL_MS := 2.0        ## 500Hz より細かくはしない
	const MAX_INTERVAL_MS := 100.0      ## 10Hz より粗くはしない（ファームの下限）
	const WINDOW_MS := 1000             ## 受信レートを測る区間
	const GAP_MS := 250                 ## これより間が空いたら（一時停止など）測り直す

	var interval_ms := DEFAULT_INTERVAL_MS
	var _last_stamp := -1
	var _last_rx := -1
	var _window_start := -1
	var _window_count := 0

	## count 個のサンプルが now_ms に届いたときの、各サンプルの時刻（古い順）。
	func stamp(count: int, now_ms: int) -> PackedInt64Array:
		_measure(count, now_ms)
		var stamps := PackedInt64Array()
		for i in count:
			var t := int(round(now_ms - (count - 1 - i) * interval_ms))
			if _last_stamp >= 0 and t <= _last_stamp:
				t = _last_stamp + 1
			stamps.append(t)
			_last_stamp = t
		return stamps

	## デバイスが知らせたレート [Hz] を推定の初期値にする。
	func set_rate_hint(rate_hz: float) -> void:
		if rate_hz <= 0.0:
			return
		interval_ms = clampf(1000.0 / rate_hz, MIN_INTERVAL_MS, MAX_INTERVAL_MS)
		_window_start = -1   # 測り直す

	func _measure(count: int, now_ms: int) -> void:
		var gap := _last_rx >= 0 and now_ms - _last_rx > GAP_MS
		_last_rx = now_ms
		if _window_start < 0 or gap:
			# 区間の始まり。このデータグラムの分は区間より前に溜まったものなので数えない
			_window_start = now_ms
			_window_count = 0
			return
		_window_count += count
		var elapsed := now_ms - _window_start
		if elapsed >= WINDOW_MS and _window_count > 0:
			interval_ms = clampf(float(elapsed) / _window_count, MIN_INTERVAL_MS, MAX_INTERVAL_MS)
			_window_start = now_ms
			_window_count = 0

## 設定（BleSensorProvider.new() の直後、最初の scan() より前に変える）
var app_port := DEFAULT_APP_PORT
var bridge_port := DEFAULT_BRIDGE_PORT
var auto_launch := true                       ## false なら手動起動のブリッジだけを使う
var bridge_args := PackedStringArray()        ## ブリッジへ渡す追加引数（例: --mock）
var python_path := ""                         ## 空なら自動で探す
var bridge_script_path := ""                  ## 空なら自動で探す
var scan_timeout_sec := SCAN_TIMEOUT_SEC

var _udp: PacketPeerUDP = null
var _state := State.IDLE
var _state_time := 0.0
var _hello_timer := 0.0
var _ping_timer := 0.0
var _since_rx := 0.0
var _pid := -1                                ## 自分が起動したブリッジの pid（手動起動なら -1）
var _pid_exited := false                      ## _pid の終了を確認済みか
var _launch_python := ""
var _bridge_info: Dictionary = {}             ## 直近の hello の内容
var _ble_error_code := ""                     ## ブリッジは動いているが BLE が使えない理由
var _ble_error_message := ""
var _fail_code := ""
var _fail_reason := ""
var _crash_count := 0
var _manual_only := false                     ## 「手動起動したブリッジに接続」中
var _scan_requested := false
var _scanning := false
var _scan_elapsed := 0.0
var _scan_error := ""
var _known: Dictionary = {}                   ## address -> {name, rssi}
var _connected: Dictionary = {}               ## address -> true
var _connecting: Dictionary = {}              ## address -> 経過秒
var _cancelled: Dictionary = {}               ## 接続中に切断を押された address -> true
var _device_errors: Dictionary = {}           ## address -> 直近のエラー文
var _device_info: Dictionary = {}             ## address -> 直近の情報行（# model=... を含む行だけ）
var _device_replies: Dictionary = {}          ## address -> 直近のその他の '#' 行（# ok= / # error= / # event=）
var _clocks: Dictionary = {}                  ## address -> SampleClock
var _logs := PackedStringArray()
var _channels: Dictionary = {}                ## kind -> WeakRef（ブリッジを共用する Provider）
var _is_shut_down := false


func _init() -> void:
	if OS.get_environment(ENV_MOCK) == "1" or OS.get_cmdline_user_args().has(CMDLINE_MOCK):
		bridge_args.append("--mock")


func get_mode() -> SensorDevice.Mode:
	return SensorDevice.Mode.BLE


# --- SensorProvider の実装 ---------------------------------------------------

## 既に分かっているデバイスをすぐ返し、スキャン結果は devices_discovered で後から知らせる。
func scan() -> Array:
	start()
	if _state == State.READY:
		_send_scan()
	else:
		_scan_requested = true
	provider_status_changed.emit()
	return _known_devices()


func open_device(device_id: String) -> bool:
	if _is_shut_down:
		return false
	if _connected.has(device_id):
		return true
	if _state != State.READY or not _ble_error_code.is_empty():
		return false
	_cancelled.erase(device_id)
	_device_errors.erase(device_id)
	_connecting[device_id] = 0.0
	_send({"cmd": "connect", "address": device_id})
	provider_status_changed.emit()
	return true   # 結果は connection_changed で届く


func close_device(device_id: String) -> void:
	if _connecting.has(device_id):
		_connecting.erase(device_id)
		_cancelled[device_id] = true
	if _state == State.READY:
		_send({"cmd": "disconnect", "address": device_id})
	# 画面がすぐ反応するよう、ブリッジの返事を待たずに切断扱いにする
	if _connected.erase(device_id):
		connection_changed.emit(device_id, false)
	provider_status_changed.emit()


func send_command(device_id: String, line: String) -> bool:
	if _state != State.READY or not _connected.has(device_id):
		return false
	var text := line.strip_edges()
	if text.is_empty() or text.contains("\n"):
		return false
	_send({"cmd": "send", "address": device_id, "line": text})
	return true


func poll(delta: float) -> void:
	if _is_shut_down or _state == State.IDLE:
		return
	_receive()
	_state_time += delta
	match _state:
		State.PROBING:
			_tick_hello(delta, HELLO_INTERVAL_SEC)
			if _state_time >= PROBE_SEC:
				if auto_launch and not _manual_only:
					_launch()
				else:
					_set_state(State.WAITING_MANUAL)
		State.LAUNCHING:
			_tick_hello(delta, HELLO_INTERVAL_SEC)
			if not _owned_process_running():
				_on_bridge_gone("ブリッジが起動直後に終了しました")
			elif _state_time >= START_TIMEOUT_SEC:
				_kill_owned_process()
				_fail("no_response", "BLEブリッジが応答しません（%s）。「ブリッジ再起動」を試すか、ターミナルから手動起動してください"
						% _launch_python)
		State.RESTART_WAIT:
			if _state_time >= RESTART_DELAY_SEC:
				_launch()
		State.WAITING_MANUAL:
			_tick_hello(delta, 1.0)
		State.READY:
			_tick_ready(delta)


## アプリ終了時: 自動起動したブリッジは quit で終わらせ、終わらなければ kill する。
## 手動起動のブリッジには bye を送ってデバイスだけ切断してもらう（ブリッジは次のアプリを待つ）。
func shutdown() -> void:
	if _is_shut_down:
		return
	_is_shut_down = true
	_stop_bridge(false)
	_state = State.IDLE   # 終了処理中なのでシグナルは出さない
	_scan_requested = false
	if _udp != null:
		_udp.close()
		_udp = null


func is_available() -> bool:
	if _state == State.FAILED:
		return false
	return _state != State.READY or _ble_error_code != "bleak_missing"


func unavailable_reason() -> String:
	if is_available():
		return ""
	return status_text()


func is_scanning() -> bool:
	if _scanning:
		return true
	# ブリッジの起動待ちの間も、スキャンを頼まれていれば「スキャン中」と見せる
	return _scan_requested and _state in [State.PROBING, State.LAUNCHING, State.RESTART_WAIT]


func is_connecting(device_id: String) -> bool:
	return _connecting.has(device_id)


## 状態をひとことで。困っている場合は対処方法まで含める。
func status_text() -> String:
	match _state:
		State.IDLE:
			return "BLE: 未起動（スキャンするとブリッジを起動します）"
		State.PROBING:
			return "BLE: ブリッジを確認中…"
		State.LAUNCHING:
			return "BLE: ブリッジ起動中…"
		State.RESTART_WAIT:
			return "BLE: ブリッジが終了したため再起動します…"
		State.WAITING_MANUAL:
			return "BLE: 手動起動したブリッジを待っています（ターミナルで次のコマンドを実行してください）"
		State.FAILED:
			return "BLE: " + _fail_reason
		State.READY:
			if not _ble_error_code.is_empty():
				return "BLE: " + _ble_error_text(_ble_error_code, _ble_error_message)
			var head := "BLE: スキャン中…" if is_scanning() else "BLE: 準備完了"
			var detail := "ブリッジ v%s・%s・%s" % [
				str(_bridge_info.get("version", "?")),
				"疑似デバイス(--mock)" if str(_bridge_info.get("backend", "")) == "mock" else "bleak",
				"自動起動" if is_bridge_owned() else "手動起動",
			]
			var text := "%s（%s）" % [head, detail]
			if not _scan_error.is_empty():
				text += "\n" + _scan_error
			return text
	return ""


# --- BLE 固有の操作（デバイス管理画面から使う） ---------------------------------

## ブリッジとの通信を始める（多重に呼んでも安全）。
func start() -> void:
	if _is_shut_down or _state != State.IDLE:
		return
	if not _open_socket():
		return
	_set_state(State.PROBING)
	_send_hello()


## ブリッジを再起動する（bleak を入れた後・調子が悪いとき用）。自動起動に戻す。
func restart_bridge() -> void:
	if _is_shut_down:
		return
	_stop_bridge(true)
	_crash_count = 0
	_manual_only = false
	_clear_errors()
	_set_state(State.IDLE)
	_scan_requested = true
	start()


## 自動起動をやめ、ターミナルから手動起動したブリッジを待って接続する。
## （macOS で、アプリから起動した Python が Bluetooth 権限で落ちる場合の回避策）
func use_manual_bridge() -> void:
	if _is_shut_down:
		return
	_stop_bridge(true)
	_crash_count = 0
	_manual_only = true
	_clear_errors()
	_set_state(State.IDLE)
	_scan_requested = true
	if _open_socket():
		_set_state(State.WAITING_MANUAL)
		_send_hello()


## ブリッジを手動起動するためのコマンド（画面に表示してコピーしてもらう）。
func manual_command() -> String:
	var script := find_bridge_script()
	if script.is_empty():
		script = "tools/ble_bridge/" + BRIDGE_FILE
	var python := find_python(script.get_base_dir())
	var exe: String = str(python.get("path", "python3"))
	var parts := PackedStringArray([_shell_quote(exe)])
	for arg in python.get("args", PackedStringArray()):
		parts.append(arg)
	parts.append(_shell_quote(script))
	if bridge_port != DEFAULT_BRIDGE_PORT:
		parts.append("--port %d" % bridge_port)
	if app_port != DEFAULT_APP_PORT:
		parts.append("--app-port %d" % app_port)
	for arg in bridge_args:
		parts.append(arg)
	return " ".join(parts)


func state() -> State:
	return _state


func is_ready() -> bool:
	return _state == State.READY


## 自分が起動したブリッジを使っているか（手動起動のブリッジなら false）。
func is_bridge_owned() -> bool:
	return _pid > 0


func bridge_pid() -> int:
	return int(_bridge_info.get("pid", _pid))


func is_manual_mode() -> bool:
	return _manual_only


# --- ブリッジの共用（有線のブリッジ経由など） ---------------------------------------

## ブリッジを共用する Provider を登録する。kind が一致するメッセージ（scanning/devices/status/data）と、
## ブリッジ全体の出来事を受け取る。受け取り側は次のメソッドを持つこと:
##   _on_bridge_hello(message: Dictionary) / _on_bridge_pong(message: Dictionary)
##   _on_bridge_message(message: Dictionary) / _on_bridge_reset(notify: bool)
## 循環参照にならないよう WeakRef で持つ。
func attach_channel(kind: String, receiver: Object) -> void:
	_channels[kind] = weakref(receiver)


## ブリッジへコマンドを送る（共用する Provider 用）。準備ができていなければ false。
func bridge_send(message: Dictionary) -> bool:
	if _is_shut_down or _state != State.READY:
		return false
	_send(message)
	return true


## ブリッジが使えない理由（FAILED のとき）。使える・準備中なら空。
func bridge_problem() -> String:
	return _fail_reason if _state == State.FAILED else ""


## ブリッジが使えないと確定しているか（Python が無い・ポート使用中など）。
func is_bridge_failed() -> bool:
	return _state == State.FAILED


func _channel(kind: String) -> Object:
	var ref: WeakRef = _channels.get(kind)
	return ref.get_ref() if ref != null else null


func _notify_channels(method: String, arg: Variant) -> void:
	for kind in _channels.keys():
		var receiver := _channel(kind)
		if receiver != null:
			receiver.call(method, arg)


## 何か問題が起きているか（利用不可・BLE のエラー・スキャン失敗）。画面の警告色に使う。
func has_problem() -> bool:
	return _state == State.FAILED or not _ble_error_code.is_empty() or not _scan_error.is_empty()


## 手動起動（ターミナルからブリッジを起動）を案内すべき状況か。
func suggests_manual_launch() -> bool:
	if _manual_only or _state == State.WAITING_MANUAL:
		return true
	if _state == State.FAILED:
		return _fail_code in ["crashed", "no_response", "launch_failed"]
	return _ble_error_code == "unauthorized"


## そのデバイスで直近に起きたエラー（接続失敗・切断理由）。無ければ空。
func device_error(device_id: String) -> String:
	return str(_device_errors.get(device_id, ""))


## デバイスが送ってきた情報行（例 "# model=M5StickCPlus2 rate=100"）。無ければ空。
## `model=` を含む行だけを覚えるので、コマンド応答などでは上書きされない。
func device_info(device_id: String) -> String:
	return str(_device_info.get(device_id, ""))


## デバイスが送ってきた直近の応答・イベント・エラー行（例 "# ok=RATE rate=50"、"# error=imu_not_found"）。
func device_reply(device_id: String) -> String:
	return str(_device_replies.get(device_id, ""))


## ブリッジから届いたログ（新しいものが最後）。
func recent_logs() -> PackedStringArray:
	return _logs


# --- Python / スクリプトの探索 ---------------------------------------------------

## ble_bridge.py の絶対パス。見つからなければ空。
## 探索順: 設定値 → 環境変数 SENSOR_BLE_BRIDGE → （エディタ実行時）res://tools/ble_bridge
##        → 実行ファイルと同じ場所の ble_bridge/（macOS は .app の隣と Contents/Resources も）
## 設定値・環境変数で指定された場合は、それだけを使う（間違いに気づけるように）。
func find_bridge_script() -> String:
	for explicit: String in [bridge_script_path, OS.get_environment(ENV_BRIDGE)]:
		if not explicit.is_empty():
			return explicit if FileAccess.file_exists(explicit) else ""
	var candidates := PackedStringArray()
	if OS.has_feature("editor"):
		candidates.append(ProjectSettings.globalize_path(BRIDGE_DIR_RES).path_join(BRIDGE_FILE))
	var exe_dir := OS.get_executable_path().get_base_dir()
	candidates.append(exe_dir.path_join("ble_bridge").path_join(BRIDGE_FILE))
	if OS.get_name() == "macOS":
		# X.app/Contents/MacOS/実行ファイル
		candidates.append(exe_dir.get_base_dir().path_join("Resources/ble_bridge").path_join(BRIDGE_FILE))
		candidates.append(exe_dir.get_base_dir().get_base_dir().get_base_dir()
				.path_join("ble_bridge").path_join(BRIDGE_FILE))
	for path in candidates:
		if not path.is_empty() and FileAccess.file_exists(path):
			return path
	return ""


## ブリッジを動かす Python。{path: 実行ファイル, args: 先頭に付ける引数} を返す。見つからなければ空。
## 探索順: 設定値 → 環境変数 SENSOR_BLE_PYTHON → ブリッジ横の .venv → PATH 上の python3 / python
## （Windows は .venv → py -3 → python）。設定値・環境変数で指定された場合は、それだけを使う。
func find_python(bridge_dir: String) -> Dictionary:
	var windows := OS.get_name() == "Windows"
	for explicit: String in [python_path, OS.get_environment(ENV_PYTHON)]:
		if explicit.is_empty():
			continue
		var resolved := _resolve_executable(explicit)
		if resolved.is_empty():
			return {}   # 指定された Python が無い（別の Python で代用しない）
		return {"path": resolved, "args": PackedStringArray()}
	if not bridge_dir.is_empty():
		var venv := bridge_dir.path_join(".venv")
		var venv_candidates := [venv.path_join("Scripts/python.exe")] if windows \
				else [venv.path_join("bin/python3"), venv.path_join("bin/python")]
		for path in venv_candidates:
			if FileAccess.file_exists(path):
				return {"path": path, "args": PackedStringArray()}
	if windows:
		# py ランチャーを優先（python.exe は Microsoft Store の案内だけの場合がある）
		var py := _resolve_executable("py.exe")
		if not py.is_empty():
			return {"path": py, "args": PackedStringArray(["-3"])}
		var python := _resolve_executable("python.exe")
		if not python.is_empty():
			return {"path": python, "args": PackedStringArray()}
		return {}
	for name: String in ["python3", "python"]:
		var found := _resolve_executable(name)
		if not found.is_empty():
			return {"path": found, "args": PackedStringArray()}
	return {}


## コマンド名を PATH から探して絶対パスにする。絶対パスならそのまま存在確認する。
## Finder から起動したアプリは PATH が最小限なので、よくある場所も探す。
static func _resolve_executable(name: String) -> String:
	if name.is_absolute_path():
		return name if FileAccess.file_exists(name) else ""
	var windows := OS.get_name() == "Windows"
	var dirs := Array(OS.get_environment("PATH").split(";" if windows else ":", false))
	if not windows:
		dirs.append_array(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
	for dir in dirs:
		# Windows の PATH は \ 区切り・末尾 \・引用符付きのことがあるので整える
		var base := str(dir).strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
		if base.is_empty():
			continue
		var path := base.path_join(name)
		if FileAccess.file_exists(path):
			return path
	return ""


# --- 内部処理 ---------------------------------------------------------------

func _open_socket() -> bool:
	if _udp != null:
		return true
	var udp := PacketPeerUDP.new()
	var err := udp.bind(app_port, HOST, RECV_BUFFER_BYTES)
	if err != OK:
		_fail("port_in_use", "UDP ポート %d を開けません（このアプリが2つ起動していないか確認してください。エラー %d）"
				% [app_port, err])
		return false
	udp.set_dest_address(HOST, bridge_port)
	_udp = udp
	return true


func _set_state(new_state: State) -> void:
	_state = new_state
	_state_time = 0.0
	_hello_timer = 0.0
	provider_status_changed.emit()


func _fail(code: String, reason: String) -> void:
	_fail_code = code
	_fail_reason = reason
	_scan_requested = false
	_scanning = false
	push_warning("BLE: " + reason)
	_set_state(State.FAILED)


func _clear_errors() -> void:
	_fail_code = ""
	_fail_reason = ""
	_ble_error_code = ""
	_ble_error_message = ""
	_scan_error = ""


func _launch() -> void:
	var script := find_bridge_script()
	if script.is_empty():
		_fail("script_missing", "BLEブリッジ（%s）が見つかりません。アプリと同じ場所に ble_bridge フォルダを置くか、環境変数 %s で場所を指定してください%s"
				% [BRIDGE_FILE, ENV_BRIDGE, _explicit_note(bridge_script_path, ENV_BRIDGE)])
		return
	var python := find_python(script.get_base_dir())
	if python.is_empty():
		_fail("python_missing", "Python 3 が見つかりません。Python 3.9 以上をインストールし、%s（Windows は setup.bat）を実行してください（環境変数 %s で指定も可）%s"
				% [script.get_base_dir().path_join("setup.sh"), ENV_PYTHON, _explicit_note(python_path, ENV_PYTHON)])
		return
	# ブリッジ用のポートを、hello に答えない別のプログラムが使っていないか先に確かめる
	# （そのまま起動するとブリッジがすぐ終了し、原因が分かりにくいため）
	var probe := PacketPeerUDP.new()
	var probe_err := probe.bind(bridge_port, HOST)
	probe.close()
	if probe_err != OK:
		_fail("bridge_port_in_use", "UDP ポート %d を別のプログラムが使っています。そのプログラムを終了してから「ブリッジ再起動」を押してください"
				% bridge_port)
		return
	var args := PackedStringArray(python.get("args", PackedStringArray()))
	args.append_array(PackedStringArray([
		"-u", script,
		"--port", str(bridge_port),
		"--app-port", str(app_port),
		"--parent-pid", str(OS.get_process_id()),
		"--idle-timeout", str(BRIDGE_IDLE_TIMEOUT_SEC),
	]))
	args.append_array(bridge_args)
	_launch_python = python["path"]
	var pid := OS.create_process(_launch_python, args)
	if pid <= 0:
		_fail("launch_failed", "BLEブリッジを起動できませんでした（%s）" % _launch_python)
		return
	_pid = pid
	_pid_exited = false
	_set_state(State.LAUNCHING)
	_send_hello()


## 自分が起動したブリッジがまだ動いているか。
## 一度終了を確認した pid は二度と問い合わせない（回収済みの pid を問い合わせるとエラーになるため）。
func _owned_process_running() -> bool:
	if _pid <= 0 or _pid_exited:
		return false
	if not OS.is_process_running(_pid):
		_pid_exited = true
	return not _pid_exited


func _kill_owned_process() -> void:
	if _owned_process_running():
		OS.kill(_pid)
	_pid = -1
	_pid_exited = false


## ブリッジとの関係を終える。restarting=true のときは接続中デバイスの切断を画面に知らせる。
func _stop_bridge(notify: bool) -> void:
	if _udp != null and (_state == State.READY or _state == State.LAUNCHING):
		_send({"cmd": "quit" if is_bridge_owned() else "bye"})
	if _pid > 0:
		var waited := 0
		while _owned_process_running() and waited < QUIT_WAIT_MSEC:
			OS.delay_msec(20)
			waited += 20
		_kill_owned_process()
	_bridge_info = {}
	_drop_all_connections(notify)


func _drop_all_connections(notify: bool) -> void:
	var lost := _connected.keys()
	_connected.clear()
	_connecting.clear()
	_cancelled.clear()
	_scanning = false
	if notify:
		for address in lost:
			connection_changed.emit(address, false)
	_notify_channels("_on_bridge_reset", notify)


## ブリッジが落ちた・応答しなくなったとき。
func _on_bridge_gone(reason: String) -> void:
	var owned := _pid > 0
	_kill_owned_process()
	_bridge_info = {}
	_drop_all_connections(true)
	_log("warn", reason)
	if owned:
		_crash_count += 1
		if auto_launch and not _manual_only and _crash_count <= MAX_AUTO_RESTARTS:
			_scan_requested = true
			_set_state(State.RESTART_WAIT)
			return
		var hint := ""
		if OS.get_name() == "macOS":
			hint = "macOS では、アプリから起動した Python が Bluetooth の権限で強制終了されることがあります。「手動起動で接続」を押し、表示されたコマンドをターミナルで実行してください"
		else:
			hint = "ターミナルから手動起動してエラー内容を確認してください"
		_fail("crashed", "%s（%d 回続けて終了）。%s" % [reason, _crash_count, hint])
	elif _manual_only or not auto_launch:
		_set_state(State.WAITING_MANUAL)
	else:
		# 手動起動のブリッジが居なくなった: 次は自動起動を試す
		_set_state(State.PROBING)
		_send_hello()


func _tick_hello(delta: float, interval: float) -> void:
	_hello_timer += delta
	if _hello_timer >= interval:
		_hello_timer = 0.0
		_send_hello()


func _tick_ready(delta: float) -> void:
	_since_rx += delta
	if _crash_count > 0 and _state_time >= STABLE_RESET_SEC:
		_crash_count = 0   # しばらく安定して動いたら「続けて落ちた」回数を数え直す
	_ping_timer += delta
	if _ping_timer >= PING_INTERVAL_SEC:
		_ping_timer = 0.0
		_send({"cmd": "ping"})
	if _pid > 0 and not _owned_process_running():
		_on_bridge_gone("BLEブリッジが終了しました")
		return
	if _since_rx >= LOST_TIMEOUT_SEC:
		_on_bridge_gone("BLEブリッジから %.0f 秒間応答がありません" % LOST_TIMEOUT_SEC)
		return
	if _scanning:
		_scan_elapsed += delta
		if _scan_elapsed >= scan_timeout_sec + SCAN_GRACE_SEC:
			_scanning = false
			_scan_error = "スキャン結果が返ってきませんでした。もう一度スキャンしてください"
			provider_status_changed.emit()
	for address in _connecting.keys():
		_connecting[address] = float(_connecting[address]) + delta
		if _connecting[address] >= CONNECT_TIMEOUT_SEC:
			_connecting.erase(address)
			_device_errors[address] = "接続がタイムアウトしました"
			_send({"cmd": "disconnect", "address": address})
			connection_changed.emit(address, false)


func _send_hello() -> void:
	_send({"cmd": "hello", "protocol": PROTOCOL_VERSION, "client": "SensorTestApp"})


func _send_scan() -> void:
	_scan_requested = false
	if not _ble_error_code.is_empty() and _ble_error_code == "bleak_missing":
		return
	_scanning = true
	_scan_elapsed = 0.0
	_send({"cmd": "scan", "timeout": scan_timeout_sec})


func _send(message: Dictionary) -> void:
	if _udp == null:
		return
	_udp.put_packet(JSON.stringify(message).to_utf8_buffer())


func _receive() -> void:
	if _udp == null:
		return
	var count := 0
	while _udp.get_available_packet_count() > 0 and count < MAX_PACKETS_PER_POLL:
		count += 1
		var packet := _udp.get_packet()
		# ブリッジ（ローカルの bridge_port）以外からのデータは無視する
		if _udp.get_packet_ip() != HOST or _udp.get_packet_port() != bridge_port:
			continue
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			_since_rx = 0.0
			_handle_message(parsed)


func _handle_message(message: Dictionary) -> void:
	var type := str(message.get("type", ""))
	# BLE 以外（kind="serial" など）の個別メッセージは、登録された Provider へ渡す
	var kind := str(message.get("kind", KIND_BLE))
	if kind != KIND_BLE and type in ["scanning", "devices", "status", "data"]:
		var receiver := _channel(kind)
		if receiver != null:
			receiver.call("_on_bridge_message", message)
		return
	match type:
		"hello":
			_on_hello(message)
		"pong":
			_sync_connected(message.get("connected", []))
			_notify_channels("_on_bridge_pong", message)
		"scanning":
			_scanning = true
			provider_status_changed.emit()
		"devices":
			_on_devices(message)
		"status":
			_on_status(message)
		"data":
			_on_data(message)
		"log":
			_log(str(message.get("level", "info")), str(message.get("message", "")))
		"bye":
			if _state == State.READY:
				_on_bridge_gone("BLEブリッジが終了しました（%s）" % str(message.get("reason", "")))


func _on_hello(message: Dictionary) -> void:
	if _state == State.FAILED or _state == State.IDLE:
		return   # 諦めた後・停止後に届いた古い応答
	_bridge_info = message
	if int(message.get("protocol", 0)) != PROTOCOL_VERSION:
		_log("warn", "ブリッジのプロトコル版が違います（アプリ %d / ブリッジ %s）"
				% [PROTOCOL_VERSION, str(message.get("protocol", "?"))])
	# 自分が起動していないブリッジが答えた場合は、手動起動のブリッジとして扱う
	if _pid > 0 and int(message.get("pid", -1)) != _pid:
		_kill_owned_process()
	if bool(message.get("ready", true)):
		_ble_error_code = ""
		_ble_error_message = ""
	else:
		_ble_error_code = str(message.get("error", "unknown"))
		_ble_error_message = str(message.get("message", ""))
	var was_ready := _state == State.READY
	if not was_ready:
		_since_rx = 0.0
		_ping_timer = 0.0
		_set_state(State.READY)
	_sync_connected(message.get("connected", []))
	if _scan_requested:
		_send_scan()
	_notify_channels("_on_bridge_hello", message)
	provider_status_changed.emit()


func _on_devices(message: Dictionary) -> void:
	_scanning = false
	_scan_error = ""
	if message.has("error"):
		var code := str(message.get("error", ""))
		var text := _ble_error_text(code, str(message.get("message", "")))
		if code in ["bleak_missing", "unauthorized", "bluetooth_off", "no_adapter"]:
			_ble_error_code = code
			_ble_error_message = str(message.get("message", ""))
		_scan_error = text
	else:
		# スキャンが成功したなら BLE は使える状態
		_ble_error_code = ""
		_ble_error_message = ""
		var seen := {}
		for entry in message.get("devices", []):
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var address := str(entry.get("address", ""))
			if address.is_empty():
				continue
			seen[address] = true
			_known[address] = {"name": str(entry.get("name", "")), "rssi": int(entry.get("rssi", 0))}
		# 今回見つからなかったものは電波強度を「不明」にする（一覧からは消さない）
		for address in _known.keys():
			if not seen.has(address):
				_known[address]["rssi"] = 0
	devices_discovered.emit(_known_devices())
	provider_status_changed.emit()


func _on_status(message: Dictionary) -> void:
	var address := str(message.get("address", ""))
	if address.is_empty():
		return
	var state_name := str(message.get("state", ""))
	if state_name == "connecting":
		return
	if bool(message.get("connected", false)):
		_connecting.erase(address)
		if _cancelled.has(address):
			# 接続待ちの間に「切断」が押されていた
			_cancelled.erase(address)
			_send({"cmd": "disconnect", "address": address})
			return
		_mark_connected(address)
	else:
		var was_connecting := _connecting.erase(address)
		_cancelled.erase(address)
		if message.has("error"):
			_device_errors[address] = str(message.get("message", message.get("error", "")))
		var was_connected := _connected.erase(address)
		if was_connected or was_connecting:
			connection_changed.emit(address, false)
	provider_status_changed.emit()


func _mark_connected(address: String) -> void:
	if _connected.has(address):
		return
	if not _known.has(address):
		# 手動起動のブリッジが既に接続していた機器など、スキャンしていない機器
		_known[address] = {"name": "", "rssi": 0}
		devices_discovered.emit(_known_devices())
	_connected[address] = true
	_device_errors.erase(address)
	_device_replies.erase(address)
	_clocks[address] = SampleClock.new()   # 接続のたびに時刻の推定をやり直す
	connection_changed.emit(address, true)


## ブリッジが把握している接続中一覧と、こちらの認識を合わせる。
func _sync_connected(list: Variant) -> void:
	if typeof(list) != TYPE_ARRAY:
		return
	var remote := {}
	for item in list:
		remote[str(item)] = true
	for address in remote.keys():
		if not _connected.has(address) and not _cancelled.has(address):
			_connecting.erase(address)
			_mark_connected(address)
	for address in _connected.keys():
		if not remote.has(address):
			_connected.erase(address)
			connection_changed.emit(address, false)


func _on_data(message: Dictionary) -> void:
	var address := str(message.get("address", ""))
	if not _connected.has(address):
		return   # 切断後に遅れて届いたデータ
	var lines: Variant = message.get("lines", [])
	if typeof(lines) != TYPE_ARRAY:
		return
	var readings: Array[SensorReading] = []
	for line in lines:
		var text := str(line)
		if text.begins_with("#"):
			_on_info_line(address, text)
			continue
		var reading := SensorDataParser.parse_line(text, address)
		if reading != null:
			readings.append(reading)
	if readings.is_empty():
		return
	# 1データグラムに数サンプルまとめて届くので、受信時刻から逆算した時刻に付け替える
	var clock: SampleClock = _clocks.get(address)
	if clock == null:
		clock = SampleClock.new()
		_clocks[address] = clock
	var stamps := clock.stamp(readings.size(), Time.get_ticks_msec())
	for i in readings.size():
		readings[i].timestamp_ms = stamps[i]
		reading_received.emit(readings[i])


## デバイスからの '#' 行（情報行・コマンド応答・イベント・エラー）を振り分ける。
func _on_info_line(address: String, text: String) -> void:
	_record_device_line(address, text)   # 基底の記録（デバイス操作画面の応答表示に使う）
	var fields := parse_info_fields(text)
	if fields.has("model"):
		_device_info[address] = text          # 機種などの情報行だけを覚える
	else:
		_device_replies[address] = text       # # ok=… / # error=… / # event=…
	if fields.has("rate") and str(fields["rate"]).is_valid_int():
		var clock: SampleClock = _clocks.get(address)
		if clock == null:
			clock = SampleClock.new()
			_clocks[address] = clock
		clock.set_rate_hint(float(int(fields["rate"])))


## "# model=M5StickCPlus2 rate=100 ..." の key=value を辞書にする（値の無い語は無視）。
static func parse_info_fields(text: String) -> Dictionary:
	var fields := {}
	for word in text.trim_prefix("#").strip_edges().split(" ", false):
		var eq := word.find("=")
		if eq > 0:
			fields[word.substr(0, eq)] = word.substr(eq + 1)
	return fields


func _known_devices() -> Array:
	var devices: Array = []
	for address in _known.keys():
		var info: Dictionary = _known[address]
		var device := SensorDevice.new(address, SensorDevice.Mode.BLE, str(info.get("name", "")))
		device.rssi = int(info.get("rssi", 0))
		device.connected = _connected.has(address)
		devices.append(device)
	return devices


func _log(level: String, message: String) -> void:
	if message.is_empty():
		return
	_logs.append("[%s] %s" % [level, message])
	if _logs.size() > MAX_LOG_LINES:
		_logs = _logs.slice(_logs.size() - MAX_LOG_LINES)
	if level == "error" or level == "warn":
		print("BLE %s: %s" % [level, message])


## ブリッジのエラーコードを、対処方法つきの文言にする。
static func _ble_error_text(code: String, detail: String) -> String:
	match code:
		"bleak_missing":
			return "bleak 未インストール: tools/ble_bridge/setup.sh（Windows は setup.bat）を実行してから「ブリッジ再起動」を押してください"
		"unauthorized":
			return "Bluetooth の使用が許可されていません: システム設定 > プライバシーとセキュリティ > Bluetooth で許可するか、「手動起動で接続」でターミナルから起動してください"
		"bluetooth_off":
			return "Bluetooth がオフです: Bluetooth をオンにしてからもう一度スキャンしてください"
		"no_adapter":
			return "Bluetooth アダプタが見つかりません: PC が BLE に対応しているか確認してください"
	if detail.is_empty():
		return "BLE エラー（%s）" % code
	return "BLE エラー: %s" % detail


## 指定されたパスが見つからなかったときの補足。
static func _explicit_note(setting: String, env_name: String) -> String:
	if not setting.is_empty():
		return "（指定: %s）" % setting
	var env := OS.get_environment(env_name)
	if not env.is_empty():
		return "（%s=%s）" % [env_name, env]
	return ""


static func _shell_quote(text: String) -> String:
	if OS.get_name() == "Windows":
		return "\"%s\"" % text
	if text.is_empty() or text.contains(" ") or text.contains("'") or text.contains("\""):
		return "'%s'" % text.replace("'", "'\\''")
	return text
