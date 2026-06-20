extends Control
## A settings overlay (volume / sensitivity / difficulty), bound to the global
## Settings singleton. Emits `closed` when the player backs out.

signal closed

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # works even while the game is paused
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.8)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(440, 0)
	v.add_theme_constant_override("separation", 12)
	center.add_child(v)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	v.add_child(_spacer(8))

	v.add_child(_label("Master Volume"))
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = Settings.master_volume
	vol.custom_minimum_size = Vector2(0, 22)
	vol.value_changed.connect(_on_volume)
	v.add_child(vol)

	v.add_child(_label("Mouse Sensitivity"))
	var sens := HSlider.new()
	sens.min_value = 0.0005
	sens.max_value = 0.006
	sens.step = 0.0001
	sens.value = Settings.mouse_sensitivity
	sens.custom_minimum_size = Vector2(0, 22)
	sens.value_changed.connect(_on_sens)
	v.add_child(sens)

	v.add_child(_label("Difficulty"))
	var diff := OptionButton.new()
	diff.add_item("Easy", 0)
	diff.add_item("Normal", 1)
	diff.add_item("Hard", 2)
	diff.selected = Settings.difficulty
	diff.item_selected.connect(_on_diff)
	v.add_child(diff)

	v.add_child(_spacer(8))
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(0, 38)
	back.pressed.connect(_on_back)
	v.add_child(back)

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _on_volume(val: float) -> void:
	Settings.master_volume = val
	Settings.apply_audio()

func _on_sens(val: float) -> void:
	Settings.mouse_sensitivity = val

func _on_diff(idx: int) -> void:
	Settings.difficulty = idx

func _on_back() -> void:
	Settings.save_settings()
	closed.emit()
