extends CharacterBody3D
## First-person player: mouse look + WASD + sprint, plus a flashlight with a
## draining battery that collectibles recharge.

@export var walk_speed := 4.0
@export var sprint_speed := 7.0
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0
@export var flashlight_energy := 4.0
@export var battery_drain := 1.1            # percent per second while lit
@export var battery_per_pickup := 35.0
@export var stamina_max := 100.0
@export var sprint_drain := 30.0            # stamina per second while sprinting
@export var stamina_regen := 18.0           # stamina per second while not
@export var exhaust_recover := 30.0         # must reach this before sprinting again

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Camera3D/Flashlight

var _pitch := 0.0
var battery := 100.0
var flashlight_on := true
var carrying := ""   # forest: name of the car part in hand; "" = empty-handed
var _bat_fill: ColorRect
var _shake := 0.0
var stamina := 100.0
var _exhausted := false
var _stam_fill: ColorRect

func _ready() -> void:
	add_to_group("player")
	_ensure_input_actions()
	_make_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens: float = Settings.mouse_sensitivity
		rotate_y(-event.relative.x * sens)
		_pitch = clamp(_pitch - event.relative.y * sens, -1.4, 1.4)
		head.rotation.x = _pitch
	if event.is_action_pressed("flashlight"):
		flashlight_on = not flashlight_on
	# Esc is handled by the pause menu (pause.gd).

func _process(delta: float) -> void:
	if flashlight_on and battery > 0.0:
		battery = maxf(0.0, battery - battery_drain * delta)
	var lit := flashlight_on and battery > 0.0
	if lit:
		var e := flashlight_energy
		if battery < 20.0 and randf() < 0.35:    # sputter when low
			e *= 0.25
		flashlight.light_energy = e
		flashlight.visible = true
	else:
		flashlight.visible = false
	_update_hud()

	# Camera shake (proximity rumble + catch jumpscare)
	_shake = maxf(0.0, _shake - delta * 1.6)
	camera.rotation = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * (_shake * 0.06)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	# Sprint is gated by stamina; emptying it locks you to walking until recovered.
	var sprinting := Input.is_action_pressed("sprint") and direction != Vector3.ZERO \
		and stamina > 0.0 and not _exhausted
	if sprinting:
		stamina = maxf(0.0, stamina - sprint_drain * delta)
		if stamina <= 0.0:
			_exhausted = true
	else:
		stamina = minf(stamina_max, stamina + stamina_regen * delta)
		if _exhausted and stamina >= exhaust_recover:
			_exhausted = false
	var speed := sprint_speed if sprinting else walk_speed

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()

## Called by a pickup when collected — recharges the flashlight.
func collect_pickup() -> void:
	battery = minf(100.0, battery + battery_per_pickup)

# --- Forest: carrying one car part at a time ---
func carry_part(part_name: String) -> void:
	carrying = part_name

func is_carrying() -> bool:
	return carrying != ""

func get_carried() -> String:
	return carrying

func drop_carried() -> String:
	var n := carrying
	carrying = ""
	return n

func add_shake(amount: float) -> void:
	_shake = minf(1.0, _shake + amount)

## Snap to stare at the monster, then rattle the camera — the death jumpscare.
func jumpscare(target_pos: Vector3) -> void:
	var flat := Vector3(target_pos.x, global_position.y, target_pos.z)
	if flat.distance_to(global_position) > 0.05:
		look_at(flat, Vector3.UP)
	_pitch = 0.15
	head.rotation.x = _pitch
	_shake = 1.0

func _make_hud() -> void:
	var layer := CanvasLayer.new()

	var stam_label := Label.new()
	stam_label.text = "Stamina"
	stam_label.position = Vector2(16, 616)
	stam_label.add_theme_font_size_override("font_size", 14)
	stam_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	layer.add_child(stam_label)
	var stam_bg := ColorRect.new()
	stam_bg.color = Color(0.08, 0.08, 0.08, 0.85)
	stam_bg.position = Vector2(16, 638)
	stam_bg.size = Vector2(204, 16)
	layer.add_child(stam_bg)
	_stam_fill = ColorRect.new()
	_stam_fill.color = Color(0.4, 0.8, 1.0)
	_stam_fill.position = Vector2(18, 640)
	_stam_fill.size = Vector2(200, 12)
	layer.add_child(_stam_fill)

	var label := Label.new()
	label.text = "Flashlight: F"
	label.position = Vector2(16, 662)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	layer.add_child(label)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.08, 0.85)
	bg.position = Vector2(16, 684)
	bg.size = Vector2(204, 16)
	layer.add_child(bg)
	_bat_fill = ColorRect.new()
	_bat_fill.color = Color(0.9, 0.85, 0.3)
	_bat_fill.position = Vector2(18, 686)
	_bat_fill.size = Vector2(200, 12)
	layer.add_child(_bat_fill)
	add_child(layer)

func _update_hud() -> void:
	if _bat_fill:
		_bat_fill.size.x = 200.0 * battery / 100.0
		_bat_fill.color = Color(0.9, 0.3, 0.2) if battery < 20.0 else Color(0.9, 0.85, 0.3)
	if _stam_fill:
		_stam_fill.size.x = 200.0 * stamina / stamina_max
		_stam_fill.color = Color(0.9, 0.4, 0.2) if _exhausted else Color(0.4, 0.8, 1.0)

## Registers movement keys at runtime (physical/layout-independent).
func _ensure_input_actions() -> void:
	var actions := {
		"move_forward": KEY_W,
		"move_back": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"sprint": KEY_SHIFT,
		"interact": KEY_E,
		"flashlight": KEY_F,
	}
	for action_name in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			var ev := InputEventKey.new()
			ev.physical_keycode = actions[action_name]
			InputMap.action_add_event(action_name, ev)
