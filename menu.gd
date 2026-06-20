extends Control
## Main menu: New Game / Settings / Quit.

const SETTINGS_PANEL := preload("res://settings_panel.gd")
var _settings_panel: Control

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.03, 0.01)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(360, 0)
	v.add_theme_constant_override("separation", 16)
	center.add_child(v)

	var title := Label.new()
	title.text = "BACKROOMS CHASE"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.92, 0.82, 0.32))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)

	var sub := Label.new()
	sub.text = "Find all 6. Don't let it catch you."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	v.add_child(sub)
	v.add_child(_spacer(24))

	v.add_child(_btn("New Game", _on_new_game))
	v.add_child(_btn("Settings", _on_settings))
	v.add_child(_btn("Quit", _on_quit))

func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(cb)
	return b

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _on_new_game() -> void:
	get_tree().change_scene_to_file("res://main.tscn")

func _on_settings() -> void:
	if _settings_panel:
		return
	_settings_panel = SETTINGS_PANEL.new()
	_settings_panel.closed.connect(_on_settings_closed)
	add_child(_settings_panel)

func _on_settings_closed() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null

func _on_quit() -> void:
	get_tree().quit()
