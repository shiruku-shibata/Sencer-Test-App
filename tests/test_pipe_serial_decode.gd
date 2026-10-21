extends "res://tests/test_case.gd"
## 有線（stty / cat）で受け取ったバイト列を1行ずつ文字にする処理のテスト。


func test_ascii_line() -> void:
	assert_eq(PipeSerialSensorProvider.decode_line("0.1,0.2,0.3,1,2,3\r".to_ascii_buffer()), "0.1,0.2,0.3,1,2,3")


func test_valid_utf8_line() -> void:
	assert_eq(PipeSerialSensorProvider.decode_line("# 情報 ok".to_utf8_buffer()), "# 情報 ok")


func test_garbage_is_dropped_quietly() -> void:
	# 起動直後のノイズや速度違いで読んだときのような、UTF-8 として壊れたバイト列
	var garbage := PackedByteArray([0x65, 0xD7, 0x81, 0x4A, 0xFF, 0xA6, 0x88, 0xE4, 0x2A])
	assert_eq(PipeSerialSensorProvider.decode_line(garbage), "")


func test_truncated_multibyte_is_rejected() -> void:
	var bytes := "あ".to_utf8_buffer()
	bytes.resize(2)   # 3バイト文字の途中で切れている
	assert_eq(PipeSerialSensorProvider.decode_line(bytes), "")
