extends CharacterBody3D
## Hunts the player through the maze. Wanders until it sees or hears the
## player, then pathfinds to them via the maze graph. Catches on contact.

signal caught

enum State { WANDER, CHASE }

@export var wander_speed := 2.5
@export var chase_speed := 5.0
@export var sight_range := 20.0
@export var hear_radius := 4.0
@export var give_up_time := 4.0
@export var catch_distance := 1.5
@export var gravity := 18.0

@onready var head: Node3D = $Head

var active := true
var world: Node          # the World node (maze graph + helpers)
var player: Node3D

var _state: State = State.WANDER
var _path: Array[Vector2i] = []
var _repath := 0.0
var _lose := 0.0
var _wander_target = null  # Vector2i, or null when we need a new one

func _ready() -> void:
	add_to_group("monster")
	world = get_parent()
	_setup_appearance()

func _physics_process(delta: float) -> void:
	if not active:
		return
	# Player may not have joined its group yet on the very first frame.
	if player == null:
		player = get_tree().get_first_node_in_group("player")
		if player == null:
			return

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	_update_state(delta)

	_repath -= delta
	if _repath <= 0.0:
		_repath = 0.4
		_recompute_path()

	_follow_path()
	move_and_slide()
	_check_catch()

func _update_state(delta: float) -> void:
	var dist := global_position.distance_to(player.global_position)
	var sees := dist <= sight_range and _can_see_player()
	if _state == State.CHASE:
		if sees or dist <= hear_radius:
			_lose = give_up_time
		else:
			_lose -= delta
			if _lose <= 0.0:
				_state = State.WANDER
				_wander_target = null
				_path.clear()
	else:
		if sees or dist <= hear_radius:
			_state = State.CHASE
			_lose = give_up_time
			_path.clear()

func _recompute_path() -> void:
	var my_cell: Vector2i = world.world_to_cell(global_position)
	var target_cell: Vector2i
	if _state == State.CHASE:
		target_cell = world.world_to_cell(player.global_position)
	else:
		if _wander_target == null or my_cell == _wander_target:
			_wander_target = world.random_cell()
		target_cell = _wander_target
	_path = world.find_path(my_cell, target_cell)

func _follow_path() -> void:
	var speed := chase_speed if _state == State.CHASE else wander_speed
	if _path.is_empty():
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)
		return
	var target: Vector3 = world.cell_to_world(_path[0])
	var to := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)
	if to.length() < 0.6:
		_path.pop_front()
		return
	var dir := to.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	# Face where we're heading so the eyes point at our prey.
	look_at(Vector3(global_position.x + dir.x, global_position.y, global_position.z + dir.z), Vector3.UP)

func _check_catch() -> void:
	if global_position.distance_to(player.global_position) <= catch_distance:
		active = false
		velocity = Vector3.ZERO
		caught.emit()

func _can_see_player() -> bool:
	var from: Vector3 = head.global_position
	var to: Vector3 = player.global_position + Vector3(0.0, 1.4, 0.0)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	return (hit.collider as Node).is_in_group("player")

func _setup_appearance() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.04, 0.04, 0.05)
	body_mat.roughness = 1.0
	$Body.material_override = body_mat

	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(1, 0, 0)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(1.0, 0.12, 0.12)
	eye_mat.emission_energy_multiplier = 4.0
	$EyeL.material_override = eye_mat
	$EyeR.material_override = eye_mat

	$Light.light_color = Color(1.0, 0.25, 0.25)
