extends CharacterBody3D
## Hunts the player through the maze. Wanders until it sees or hears the
## player, then pathfinds to them via the maze graph. Catches on contact.

signal caught

enum State { WANDER, CHASE }

@export var wander_speed := 2.5
@export var chase_speed := 5.5
@export var sight_range := 24.0
@export var hear_radius := 5.0
@export var give_up_time := 6.0
@export var catch_distance := 1.6
@export var gravity := 18.0
@export var lunge_bonus := 1.6   # brief speed burst the moment it spots you
@export var lunge_time := 1.0

@onready var head: Node3D = $Head

var active := true
var world: Node          # the World node (maze graph + helpers)
var player: Node3D

var _state: State = State.WANDER
var _path: Array[Vector2i] = []
var _repath := 0.0
var _lose := 0.0
var _lunge_timer := 0.0
var _wander_target = null  # Vector2i, or null when we need a new one

# Animated body parts
var _mesh_root: Node3D
var _head_pivot: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _anim_t := 0.0

func _ready() -> void:
	add_to_group("monster")
	world = get_parent()
	_build_body()

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
	_lunge_timer = maxf(0.0, _lunge_timer - delta)

	_repath -= delta
	if _repath <= 0.0:
		_repath = 0.4
		_recompute_path()

	_follow_path()
	move_and_slide()
	_animate(delta)
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
			_lunge_timer = lunge_time  # burst of speed on first sighting
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
	if _lunge_timer > 0.0:
		speed += lunge_bonus

	# When it can actually see the player, ditch the grid and home straight in
	# on their real position — otherwise it would stall at the cell centre.
	var chasing_visible := _state == State.CHASE and _can_see_player()

	var target: Vector3
	if chasing_visible:
		target = player.global_position
	elif not _path.is_empty():
		target = world.cell_to_world(_path[0])
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)
		return

	var to := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)

	# Advance to the next waypoint once we reach this one (grid navigation only).
	if not chasing_visible and to.length() < 0.6:
		_path.pop_front()
		return
	if to.length() < 0.05:
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

## Builds a tall, thin, hunched humanoid out of primitives, with pivots for
## the limbs and head so we can animate a lurching walk and head-tracking.
func _build_body() -> void:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.03, 0.03, 0.04)
	dark.roughness = 1.0

	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(1, 0, 0)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(1.0, 0.05, 0.05)
	eye_mat.emission_energy_multiplier = 6.0

	_mesh_root = Node3D.new()
	add_child(_mesh_root)

	# Torso, hunched slightly forward
	var torso := _box(Vector3(0.42, 1.25, 0.26), Vector3(0, 1.42, 0), dark)
	torso.rotation.x = 0.12
	_mesh_root.add_child(torso)

	# Head (tracks the player) with glowing eyes on its front (-Z)
	_head_pivot = Node3D.new()
	_head_pivot.position = Vector3(0, 2.02, 0)
	_mesh_root.add_child(_head_pivot)
	_head_pivot.add_child(_box(Vector3(0.28, 0.32, 0.28), Vector3(0, 0.16, 0), dark))
	_head_pivot.add_child(_sphere(0.055, Vector3(-0.08, 0.17, -0.15), eye_mat))
	_head_pivot.add_child(_sphere(0.055, Vector3(0.08, 0.17, -0.15), eye_mat))

	# Long arms hanging from the shoulders
	_arm_l = Node3D.new()
	_arm_l.position = Vector3(-0.3, 1.9, 0)
	_mesh_root.add_child(_arm_l)
	_arm_l.add_child(_box(Vector3(0.11, 1.05, 0.11), Vector3(0, -0.5, 0), dark))
	_arm_r = Node3D.new()
	_arm_r.position = Vector3(0.3, 1.9, 0)
	_mesh_root.add_child(_arm_r)
	_arm_r.add_child(_box(Vector3(0.11, 1.05, 0.11), Vector3(0, -0.5, 0), dark))

	# Legs
	_leg_l = Node3D.new()
	_leg_l.position = Vector3(-0.13, 0.95, 0)
	_mesh_root.add_child(_leg_l)
	_leg_l.add_child(_box(Vector3(0.14, 0.95, 0.14), Vector3(0, -0.47, 0), dark))
	_leg_r = Node3D.new()
	_leg_r.position = Vector3(0.13, 0.95, 0)
	_mesh_root.add_child(_leg_r)
	_leg_r.add_child(_box(Vector3(0.14, 0.95, 0.14), Vector3(0, -0.47, 0), dark))

	$Light.light_color = Color(1.0, 0.15, 0.15)

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	return mi

func _sphere(r: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	return mi

## Lurching walk cycle (scaled by speed) + a head that swivels toward the player.
func _animate(delta: float) -> void:
	var spd := Vector2(velocity.x, velocity.z).length()
	_anim_t += delta * (4.0 + spd * 1.2)
	var swing := sin(_anim_t) * clampf(spd * 0.13, 0.0, 0.7)
	if _arm_l: _arm_l.rotation.x = swing
	if _arm_r: _arm_r.rotation.x = -swing
	if _leg_l: _leg_l.rotation.x = -swing
	if _leg_r: _leg_r.rotation.x = swing
	if _mesh_root: _mesh_root.position.y = absf(sin(_anim_t)) * 0.05
	if _head_pivot and player:
		var to := player.global_position - _head_pivot.global_position
		var local := global_transform.basis.inverse() * to
		var yaw := atan2(local.x, -local.z)
		_head_pivot.rotation.y = clampf(yaw, -1.1, 1.1)
