class_name DeviceCommand
extends RefCounted
## デバイスへのコマンド（PAUSE / RESUME / RATE <Hz> / INFO）と、デバイスが返す '#' 行の扱い。
## 仕様は firmware/m5stick_sender/README.md の「コマンド」「情報行の項目」「エラー行」。
##
##   ・コマンド文字列を作る（rate_command など）
##   ・'#' 行を key=value に分けて種類を判定する（parse_fields / kind_of）
##   ・実機ファームと同じ規則でコマンドに答える（emulate。デモデバイスが使う）

const PAUSE := "PAUSE"
const RESUME := "RESUME"
const RATE := "RATE"
const INFO := "INFO"
const RATE_MIN := 10
const RATE_MAX := 200
const RATE_DEFAULT := 100
const MAX_LENGTH := 64
const COMMAND_LIST := "PAUSE,RESUME,RATE,INFO"
## コマンドと関係なくデバイスが出すエラー（コマンドの応答とはみなさない）
const SPONTANEOUS_ERRORS := ["imu_not_found", "ble_init_failed"]

## '#' 行の種類
const KIND_OK := "ok"            ## # ok=PAUSE sending=0 など（コマンド成功）
const KIND_ERROR := "error"      ## # error=rate_out_of_range ... など
const KIND_EVENT := "event"      ## # event=button sending=0 など（本体操作）
const KIND_INFO := "info"        ## # model=... rate=... の情報行（INFO の応答・起動時）
const KIND_OTHER := "other"


static func rate_command(hz: int) -> String:
	return "%s %d" % [RATE, hz]


## "# model=M5StickCPlus2 rate=100 ..." の key=value を辞書にする（値の無い語は無視）。
## BleSensorProvider.parse_info_fields と同じ規則。
static func parse_fields(text: String) -> Dictionary:
	var fields := {}
	for word in text.strip_edges().trim_prefix("#").strip_edges().split(" ", false):
		var eq := word.find("=")
		if eq > 0:
			fields[word.substr(0, eq)] = word.substr(eq + 1)
	return fields


## '#' 行の種類（KIND_*）。
static func kind_of(text: String) -> String:
	var fields := parse_fields(text)
	if fields.has("error"):
		return KIND_ERROR
	if fields.has("ok"):
		return KIND_OK
	if fields.has("event"):
		return KIND_EVENT
	if fields.has("model"):
		return KIND_INFO
	return KIND_OTHER


## 行から分かるデバイスの設定（"rate": int / "sending": bool）。分からない項目は入れない。
static func settings_from(text: String) -> Dictionary:
	var fields := parse_fields(text)
	var settings := {}
	if fields.has("rate") and str(fields["rate"]).is_valid_int():
		settings["rate"] = int(fields["rate"])
	if fields.has("sending") and str(fields["sending"]) in ["0", "1"]:
		settings["sending"] = str(fields["sending"]) == "1"
	return settings


## text がコマンド command（"PAUSE" / "RATE 50" など）への応答とみなせるか。
## 成功応答（# ok=<コマンド名>、INFO なら情報行）とコマンドのエラー行が応答。
## 本体操作の # event=… や、コマンドと無関係に出るエラー（# error=imu_not_found など）は応答ではない。
static func is_reply_to(command: String, text: String) -> bool:
	var cmd := command.strip_edges().get_slice(" ", 0).to_upper()
	var fields := parse_fields(text)
	if fields.has("error"):
		return not str(fields["error"]) in SPONTANEOUS_ERRORS
	if cmd == INFO:
		return fields.has("model")
	return str(fields.get("ok", "")).to_upper() == cmd


## 実機ファームと同じ規則でコマンドを解釈し、応答行を返す（応答しない行は空文字）。
## state は {"rate": int, "sending": bool}。コマンドが成功すると書き換える。
## info_line は INFO の応答（呼び出し側が state から作る）を返す関数。
static func emulate(line: String, state: Dictionary, info_line: Callable) -> String:
	if line.replace("\r", "").replace("\n", "").length() > MAX_LENGTH:
		return "# error=line_too_long max=%d" % MAX_LENGTH
	var text := line.strip_edges()
	if text.is_empty() or text.begins_with("#"):
		return ""
	var tokens := text.split(" ", false)
	var command := tokens[0].to_upper()
	if command == RATE:
		if tokens.size() < 2:
			return "# error=rate_missing min=%d max=%d" % [RATE_MIN, RATE_MAX]
		if tokens.size() > 2:
			return "# error=unexpected_argument commands=%s" % COMMAND_LIST
		var arg := tokens[1]
		for c in arg:
			if not c in "0123456789":
				return "# error=rate_not_number min=%d max=%d" % [RATE_MIN, RATE_MAX]
		var value := 999999 if arg.length() > 6 else mini(arg.to_int(), 999999)
		if value < RATE_MIN or value > RATE_MAX:
			return "# error=rate_out_of_range value=%d min=%d max=%d" % [value, RATE_MIN, RATE_MAX]
		state["rate"] = value
		return "# ok=RATE rate=%d" % value
	if not command in [PAUSE, RESUME, INFO]:
		return "# error=unknown_command commands=%s" % COMMAND_LIST
	if tokens.size() > 1:
		return "# error=unexpected_argument commands=%s" % COMMAND_LIST
	if command == PAUSE:
		state["sending"] = false
		return "# ok=PAUSE sending=0"
	if command == RESUME:
		state["sending"] = true
		return "# ok=RESUME sending=1"
	return str(info_line.call())
