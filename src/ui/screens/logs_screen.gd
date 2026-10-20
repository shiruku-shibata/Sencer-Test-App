class_name LogsScreen
extends VBoxContainer
## S3 ログ管理画面。アプリ管理下フォルダに保存されたCSVを一覧・削除する。

var _logger: LoggingService
var _grid: GridContainer


func setup(logger: LoggingService) -> void:
	_logger = logger
	_logger.recording_stopped.connect(func(_info: Dictionary) -> void: refresh())
	_build()
	refresh()


func _build() -> void:
	add_theme_constant_override("separation", 10)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)

	var refresh_button := Button.new()
	refresh_button.text = UIStrings.BTN_REFRESH
	refresh_button.pressed.connect(refresh)
	toolbar.add_child(refresh_button)

	var open_button := Button.new()
	open_button.text = UIStrings.BTN_OPEN_FOLDER
	open_button.pressed.connect(func() -> void: LoggingService.open_log_folder())
	toolbar.add_child(open_button)

	var path_label := Label.new()
	path_label.text = UIStrings.LOGS_SAVE_DIR % LoggingService.LOG_DIR
	path_label.modulate = Color(1, 1, 1, 0.6)
	toolbar.add_child(path_label)
	add_child(toolbar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	add_child(scroll)


func refresh() -> void:
	if _grid == null:
		return
	for child in _grid.get_children():
		child.queue_free()

	for header in [UIStrings.LOGS_COL_FILE, UIStrings.LOGS_COL_SIZE, UIStrings.LABEL_ACTION]:
		var label := Label.new()
		label.text = header
		label.modulate = Color(1, 1, 1, 0.6)
		_grid.add_child(label)

	var logs := _logger.list_logs()
	if logs.is_empty():
		var empty := Label.new()
		empty.text = UIStrings.LOGS_EMPTY
		empty.modulate = Color(1, 1, 1, 0.6)
		_grid.add_child(empty)
		_grid.add_child(Label.new())
		_grid.add_child(Label.new())
		return

	for log_entry in logs:
		var name_label := Label.new()
		name_label.text = str(log_entry["name"])
		_grid.add_child(name_label)

		var size_label := Label.new()
		size_label.text = "%.1f KB" % (float(log_entry["size"]) / 1024.0)
		_grid.add_child(size_label)

		var delete_button := Button.new()
		delete_button.text = UIStrings.BTN_DELETE
		var path := str(log_entry["path"])
		delete_button.pressed.connect(func() -> void:
			_logger.delete_log(path)
			refresh()
		)
		_grid.add_child(delete_button)
