extends CharacterBody3D
## First-person player: mouse look + WASD + sprint, plus a flashlight with a
## draining battery that collectibles recharge.

@export var walk_speed := 4.0
@export var sprint_speed := 7.0
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0
@export var flashlight_energy := 6.0
@export var battery_drain := 1.1            # percent per second while lit
@export var battery_per_pickup := 35.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Camera3D/Flashlight

var _pitch := 0.0
var battery := 100.0
var flashlight_on := true
var _bat_fill: ColorRect

func _ready() -> void:
	add_to_group("player")
	_ensure_input_actions()
	_make_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		head.rotation.x = _pitch
	if event.is_action_pressed("flashlight"):
		flashlight_on = not flashlight_on
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

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

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed

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

func _make_hud() -> void:
	var layer := CanvasLayer.new()
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
