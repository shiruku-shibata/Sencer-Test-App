class_name SerialPortAdapter
extends RefCounted
## シリアル通信アドオン（GdSerial / SerialPort クラス）への薄いラッパー。
##
## アドオン依存のコードをこのファイル1枚に閉じ込めることで、
##   - アドオン未導入でもアプリが起動できる（デモモードで動作）
##   - アドオンを差し替える場合の修正箇所がここだけで済む
## という利点を得る。
##
## [注意] 実機接続前に、導入したアドオンのAPI名（open/read/write等）と
## 下記の呼び出しが一致しているか確認すること。

const ADDON_CLASS := "SerialPort"
const READ_CHUNK := 4096

var _port: Object = null
var _buffer := ""


## アドオンが導入されているか。
static func is_addon_available() -> bool:
	return ClassDB.class_exists(ADDON_CLASS)


## 接続候補のポート一覧。
## アドオンが一覧APIを持つ場合はそれを使い、無ければ /dev を走査する（macOS/Linux）。
static func list_ports() -> PackedStringArray:
	var ports := PackedStringArray()
	if is_addon_available():
		var probe: Object = ClassDB.instantiate(ADDON_CLASS)
		if probe != null and probe.has_method("list_ports"):
			var result: Variant = probe.call("list_ports")
			if result is PackedStringArray:
				return result
			if result is Array:
				for item in result:
					ports.append(str(item))
				return ports
	return _scan_dev_ports()


## macOS/Linux 向けのフォールバック。macOS では /dev/cu.* を使う。
static func _scan_dev_ports() -> PackedStringArray:
	var ports := PackedStringArray()
	var dir := DirAccess.open("/dev")
	if dir == null:
		return ports
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("cu.") or name.begins_with("ttyUSB") or name.begins_with("ttyACM"):
			ports.append("/dev/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	ports.sort()
	return ports


func open(port_path: String, baudrate: int = 115200) -> bool:
	if not is_addon_available():
		return false
	_port = ClassDB.instantiate(ADDON_CLASS)
	if _port == null:
		return false
	_set_if_present("port", port_path)
	_set_if_present("baudrate", baudrate)
	if _port.has_method("open"):
		return bool(_port.call("open"))
	push_warning("シリアルアドオンに open() が見つかりません。APIを確認してください。")
	return false


func close() -> void:
	if _port != null and _port.has_method("close"):
		_port.call("close")
	_port = null
	_buffer = ""


func is_open() -> bool:
	if _port == null:
		return false
	if _port.has_method("is_open"):
		return bool(_port.call("is_open"))
	return true


## 受信済みのデータから、改行で区切れた完全な行だけを取り出す。
func read_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	if _port == null:
		return lines

	var chunk := ""
	if _port.has_method("read_string"):
		chunk = str(_port.call("read_string", READ_CHUNK))
	elif _port.has_method("read"):
		var raw: Variant = _port.call("read", READ_CHUNK)
		if raw is PackedByteArray:
			chunk = (raw as PackedByteArray).get_string_from_utf8()
		else:
			chunk = str(raw)
	if chunk.is_empty():
		return lines

	_buffer += chunk
	var parts := _buffer.split("\n")
	for i in range(parts.size() - 1):
		lines.append(parts[i].strip_edges())
	_buffer = parts[parts.size() - 1]   # 未完の行は次回に持ち越す
	return lines


func _set_if_present(property: String, value: Variant) -> void:
	if _port == null:
		return
	for info in _port.get_property_list():
		if info.get("name", "") == property:
			_port.set(property, value)
			return
