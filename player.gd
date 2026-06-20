extends CharacterBody3D
## First-person player controller: mouse look + WASD + sprint.

@export var walk_speed := 4.0
@export var sprint_speed := 7.0
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var _pitch := 0.0

func _ready() -> void:
	_ensure_input_actions()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		head.rotation.x = _pitch
	# Esc toggles the mouse so you can click away / quit
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Movement relative to where we're facing
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

## Registers movement keys at runtime so we don't depend on a fragile
## input map in project.godot. Uses physical key codes (layout-independent).
func _ensure_input_actions() -> void:
	var actions := {
		"move_forward": KEY_W,
		"move_back": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"sprint": KEY_SHIFT,
		"interact": KEY_E,
	}
	for action_name in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			var ev := InputEventKey.new()
			ev.physical_keycode = actions[action_name]
			InputMap.action_add_event(action_name, ev)
