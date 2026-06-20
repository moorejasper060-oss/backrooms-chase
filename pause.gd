extends CanvasLayer
## In-game pause menu (Esc): Resume / Settings / Main Menu / Quit.
## Runs even while the tree is paused.

const SETTINGS_PANEL := preload("res://settings_panel.gd")

var world: Node            # set by the world, used to suppress pause on game over
var _paused := false
var _panel: Control
var _settings_panel: Control

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_panel.visible = false

func _build() -> void:
	_panel = Control.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(320, 0)
	v.add_theme_constant_override("separation", 14)
	center.add_child(v)

	var t := Label.new()
	t.text = "PAUSED"
	t.add_theme_font_size_override("font_size", 40)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)

	v.add_child(_btn("Resume", _on_resume))
	v.add_child(_btn("Settings", _on_settings))
	v.add_child(_btn("Main Menu", _on_menu))
	v.add_child(_btn("Quit", _on_quit))

func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(cb)
	return b

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if world and world._game_over:
			return
		_toggle()

func _toggle() -> void:
	_paused = not _paused
	get_tree().paused = _paused
	_panel.visible = _paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _paused else Input.MOUSE_MODE_CAPTURED

func _on_resume() -> void:
	_toggle()

func _on_settings() -> void:
	if _settings_panel:
		return
	_settings_panel = SETTINGS_PANEL.new()
	_settings_panel.closed.connect(_on_settings_closed)
	_panel.add_child(_settings_panel)

func _on_settings_closed() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null

func _on_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://menu.tscn")

func _on_quit() -> void:
	get_tree().quit()
