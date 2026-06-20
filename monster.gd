extends CharacterBody3D
## Hunts the player through the maze. Wanders until it sees or hears the
## player, then pathfinds to them via the maze graph. Catches on contact.

signal caught
signal spotted   # emitted the moment it locks onto the player

enum State { WANDER, CHASE }

@export var wander_speed := 2.5
@export var chase_speed := 4.0   # Normal = the player's walk speed (sprint escapes)
@export var sight_range := 24.0
@export var hear_radius := 5.0
@export var give_up_time := 6.0
@export var catch_distance := 1.6
@export var gravity := 18.0
@export var lunge_bonus := 1.2   # brief speed burst the moment it spots you
@export var lunge_time := 1.0

@onready var head: Node3D = $Head

const DEMON_PATH := "res://models/demon.glb"
const GAUNT_RATIO := 0.48        # horizontal scale vs vertical — keeps it tall and thin
const CEILING_CLEARANCE := 0.25  # gap kept below the ceiling so it can never clip through
const EYE_COLOR := Color(1.0, 0.05, 0.02)

var active := true
var world: Node          # the World node (maze graph + helpers)
var player: Node3D

var _state: State = State.WANDER
var _path: Array[Vector2i] = []
var _repath := 0.0
var _lose := 0.0
var _lunge_timer := 0.0
var _chase_time := 0.0
var _last_seen := Vector2i.ZERO
var _has_seen := false
var _wander_target = null  # Vector2i, or null when we need a new one

# Animated body parts
var _mesh_root: Node3D
var _head_pivot: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _anim_t := 0.0
var _model: Node3D
var _anim: AnimationPlayer

# Anti-stuck
var _last_pos := Vector3.ZERO
var _stuck := 0.0
var _unstick_timer := 0.0
var _unstick_dir := Vector3.ZERO

func _ready() -> void:
	add_to_group("monster")
	world = get_parent()
	_apply_difficulty()
	_build_body()

func _apply_difficulty() -> void:
	match Settings.difficulty:
		0:  # Easy — slower than your walk
			chase_speed = 3.2
			sight_range = 18.0
			hear_radius = 4.0
			give_up_time = 4.0
		2:  # Hard — faster than your walk, relentless
			chase_speed = 5.6
			sight_range = 30.0
			hear_radius = 6.0
			give_up_time = 9.0
		_:
			pass  # Normal keeps the exported defaults (4.0 = walk speed)

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
	_chase_time = (_chase_time + delta) if _state == State.CHASE else 0.0

	_repath -= delta
	if _repath <= 0.0:
		_repath = 0.4
		_recompute_path()

	_detect_stuck(delta)
	_follow_path()
	move_and_slide()
	_update_anim()
	_check_catch()

## If it's pressed against a wall making no progress, slide it along the wall
## for a moment (and force a repath) so it never wedges in a corner.
func _detect_stuck(delta: float) -> void:
	var moved := global_position.distance_to(_last_pos)
	_last_pos = global_position
	if _unstick_timer > 0.0:
		_unstick_timer -= delta
		return
	var wants_move := _state == State.CHASE or not _path.is_empty()
	if wants_move and is_on_wall() and moved < 0.02:
		_stuck += delta
		if _stuck > 0.3:
			_stuck = 0.0
			_unstick_timer = 0.45
			var n := get_wall_normal()
			var tangent := Vector3(-n.z, 0.0, n.x)
			if randf() < 0.5:
				tangent = -tangent
			_unstick_dir = (tangent + n * 0.35).normalized()
			_repath = 0.0
			_wander_target = null
	else:
		_stuck = maxf(0.0, _stuck - delta)

func _update_state(delta: float) -> void:
	var dist := global_position.distance_to(player.global_position)
	var sees := dist <= sight_range and _can_see_player()
	if sees:
		_last_seen = world.world_to_cell(player.global_position)
		_has_seen = true
	if _state == State.CHASE:
		if sees or dist <= hear_radius:
			_lose = give_up_time
		else:
			_lose -= delta
			if _lose <= 0.0:
				_state = State.WANDER
				_wander_target = null
				_has_seen = false
				_path.clear()
	else:
		if sees or dist <= hear_radius:
			_state = State.CHASE
			_lose = give_up_time
			_lunge_timer = lunge_time  # burst of speed on first sighting
			_path.clear()
			spotted.emit()

func _recompute_path() -> void:
	var my_cell: Vector2i = world.world_to_cell(global_position)
	var target_cell: Vector2i
	if _state == State.CHASE:
		if _can_see_player():
			target_cell = world.world_to_cell(player.global_position)
		elif _has_seen:
			target_cell = _last_seen  # investigate where we last saw them
		else:
			target_cell = world.world_to_cell(player.global_position)
	else:
		if _wander_target == null or my_cell == _wander_target:
			# Half the time, go lurk near an objective the player still needs.
			_wander_target = world.random_pickup_cell() if randf() < 0.5 else world.random_cell()
		target_cell = _wander_target
	_path = world.find_path(my_cell, target_cell)

func is_chasing() -> bool:
	return _state == State.CHASE

## Play the attack clip (used for the catch jumpscare).
func play_attack() -> void:
	if _anim:
		_anim.play("CharacterArmature|Punch")

## Endgame rage: once the exit opens it always knows where you are and is a
## touch faster — the final dash has to be earned.
func enrage() -> void:
	sight_range = 100000.0
	hear_radius = 100000.0
	give_up_time = 100000.0
	chase_speed += 0.6
	_state = State.CHASE
	_lose = give_up_time
	_lunge_timer = lunge_time

func _follow_path() -> void:
	var speed := wander_speed
	if _state == State.CHASE:
		speed = chase_speed + minf(_chase_time * 0.1, 1.0)  # escalates gently the longer it hunts
	if _lunge_timer > 0.0:
		speed += lunge_bonus

	# Breaking free of a wall: drive along the stored tangent for a moment.
	if _unstick_timer > 0.0:
		velocity.x = _unstick_dir.x * speed
		velocity.z = _unstick_dir.z * speed
		return

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

## Loads the rigged demon model (CC0, Quaternius) and restyles it dark + tall/
## gaunt to kill the cartoon cuteness. Its Walk/Run/Idle clips are driven by
## _update_anim() each frame.
func _build_body() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(DEMON_PATH, state) != OK:
		return
	_model = doc.generate_scene(state)
	add_child(_model)
	_model.scale = Vector3.ONE
	_model.rotation.y = 0.0                      # model already faces our -Z forward

	# Fit the figure under the ceiling so it can never poke through the roof.
	# Measure the model's natural size, then scale so it stands `_target_height()`
	# tall — close enough to scrape the ceiling to loom, but always inside it.
	var box := _model_aabb(_model)
	var native_h: float = maxf(box.size.y, 0.001)
	var s_y := _target_height() / native_h
	var s_xz := s_y * GAUNT_RATIO                 # stays narrow -> tall and gaunt
	_model.scale = Vector3(s_xz, s_y, s_xz)
	# Plant the feet on the floor (the model's origin may sit above its lowest point).
	_model.position.y = -box.position.y * s_y

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.03, 0.03)   # near-black so the eyes burn against a silhouette
	mat.roughness = 0.95
	_recolor(_model, mat)

	_add_eyes()

	_anim = _find_anim_node(_model)
	if _anim:
		_anim.play("CharacterArmature|Idle")

## Tallest the monster may stand: just under the ceiling so it looms but never
## clips through the roof. Falls back to 2.75 if the world has no wall_height.
func _target_height() -> float:
	var ceiling := 3.0
	if world and "wall_height" in world:
		ceiling = world.wall_height
	return maxf(1.6, ceiling - CEILING_CLEARANCE)

## Combined axis-aligned bounds of every mesh in the model, in the model's own
## local space (called while the model is at scale 1, so this is its natural size).
func _model_aabb(root: Node3D) -> AABB:
	var inv := root.global_transform.affine_inverse()
	var acc := AABB()
	var started := false
	for mi in _collect_meshes(root):
		if mi.mesh == null:
			continue
		var b: AABB = (inv * mi.global_transform) * mi.mesh.get_aabb()
		if started:
			acc = acc.merge(b)
		else:
			acc = b
			started = true
	return acc

func _collect_meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_collect_meshes(c))
	return out

## Two unshaded, emissive eyes plus a faint red glow at the head. The eyes burn
## through the dark and bloom (the world has glow enabled), so a silhouette with
## two red points reads as a monster long before you can make out its body.
func _add_eyes() -> void:
	var h := _target_height()
	var eye_mat := StandardMaterial3D.new()
	eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mat.albedo_color = EYE_COLOR
	eye_mat.emission_enabled = true
	eye_mat.emission = EYE_COLOR
	eye_mat.emission_energy_multiplier = 8.0

	var eye_y := h * 0.86      # head height
	var eye_z := -0.2          # just in front of the face (monster faces -Z)
	var eye_dx := 0.09         # half the gap between the eyes
	add_child(_sphere(0.05, Vector3(-eye_dx, eye_y, eye_z), eye_mat))
	add_child(_sphere(0.05, Vector3(eye_dx, eye_y, eye_z), eye_mat))

	# Faint red glow so the figure emerges from the dark as it closes in.
	var glow := OmniLight3D.new()
	glow.position = Vector3(0.0, eye_y, eye_z)
	glow.light_color = EYE_COLOR
	glow.light_energy = 1.2
	glow.omni_range = 3.5
	glow.shadow_enabled = false
	add_child(glow)

func _recolor(n: Node, mat: Material) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		for i in (n as MeshInstance3D).mesh.get_surface_count():
			(n as MeshInstance3D).set_surface_override_material(i, mat)
	for c in n.get_children():
		_recolor(c, mat)

func _find_anim_node(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_node(c)
		if r:
			return r
	return null

func _build_arm(pivot: Node3D, mat: Material) -> void:
	pivot.add_child(_capsule(0.07, 1.45, Vector3(0, -0.68, 0), mat))   # long thin arm
	for i in 3:                                                        # claw fingers
		pivot.add_child(_capsule(0.018, 0.28, Vector3((i - 1) * 0.05, -1.5, 0.0), mat))

func _capsule(radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = height
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	return mi

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

## Drive the rigged model's clips from movement state: Idle when still, Walk
## when wandering, Run when chasing.
func _update_anim() -> void:
	if _anim == null:
		return
	var spd := Vector2(velocity.x, velocity.z).length()
	var want := "CharacterArmature|Idle"
	if spd > 0.4:
		want = "CharacterArmature|Run" if _state == State.CHASE else "CharacterArmature|Walk"
	if _anim.current_animation != want:
		_anim.play(want)
