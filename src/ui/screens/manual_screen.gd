class_name ManualScreen
extends HBoxContainer
## S5 マニュアル画面。使用者が多岐にわたるため、使い方はアプリ内で完結させる。

var _body: RichTextLabel


func setup() -> void:
	add_theme_constant_override("separation", 12)

	var nav := VBoxContainer.new()
	nav.custom_minimum_size.x = 200
	nav.add_theme_constant_override("separation", 4)

	var first_page := ""
	for title in UIStrings.MANUAL_PAGES.keys():
		if first_page.is_empty():
			first_page = title
		var button := Button.new()
		button.text = title
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: _show_page(title))
		nav.add_child(button)
	add_child(nav)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = false
	_body.scroll_active = true
	_body.selection_enabled = true   # コマンドやパスをコピーできるように
	panel.add_child(_body)
	add_child(panel)

	_show_page(first_page)


func _show_page(title: String) -> void:
	_body.text = str(UIStrings.MANUAL_PAGES.get(title, ""))
