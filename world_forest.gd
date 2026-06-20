extends Node3D
## Moonlit, fog-drowned night forest. Start at a cabin, scavenge car parts
## scattered through the woods, repair the dead car, and escape in it — all while
## the entity hunts you. Reuses the same navigation grid + spawn/HUD/end-game
## systems as the Backrooms level (world.gd, left intact) so the monster, player,
## pickups and escape flow work unchanged; only the generated world differs.

@export var cols := 40
@export var rows := 40
@export var cell_size := 3.0          # 40 * 3 = 120 m of forest
@export var part_count := 5           # car parts to find
@export var battery_count := 5        # flashlight batteries scattered
@export var tree_count := 300         # scattered interior trees (denser)
@export var bush_count := 320         # ground-clutter bushes (decoration only)
@export var log_count := 60           # fallen logs (decoration only)
@export var forest_seed := 0          # 0 = random each run

const PICKUP_SCENE := preload("res://pickup.tscn")
const MONSTER_SCENE := preload("res://monster.tscn")
const CAR_SCRIPT := preload("res://car.gd")
const AUDIO_SCRIPT := preload("res://audio.gd")
const PAUSE_SCRIPT := preload("res://pause.gd")

# Realistic car parts the player must recover. First N (part_count) are used.
const PART_NAMES := ["Battery", "Spark Plugs", "Fuel Can", "Front Tire", "Ignition Coil", "Radiator Hose"]

const POST_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float grain = 0.06;
uniform float vignette = 0.55;
void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	vec2 d = SCREEN_UV - 0.5;
	float vig = smoothstep(0.85, 0.2, length(d));
	col *= mix(1.0 - vignette, 1.0, vig);
	float n = fract(sin(dot(SCREEN_UV + fract(TIME), vec2(12.9898, 78.233))) * 43758.5453);
	col += (n - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}
"

# Objective tracking
var _found := 0
var _total := 0
var _obj_label: Label
var _win_label: Label

# Monster / end-game
var _monster: Node3D
var _game_over := false
var _car: Node3D
var _car_ready := false
var _player: Node3D
var _audio: Node
var _spot_cooldown := 0.0

# Navigation grid (open forest: every non-blocked cell connects to its
# 4 neighbours; trees/cabin block cells). Same interface the monster expects.
var _blocked := {}      # Vector2i -> true
var passages := {}      # Vector2i -> Array[Vector2i]
var _reachable := {}
var _spawn_cell := Vector2i(3, 3)

var _rng := RandomNumberGenerator.new()
var _ground_mat: StandardMaterial3D

func _ready() -> void:
	if forest_seed != 0:
		_rng.seed = forest_seed
	else:
		_rng.randomize()
	_setup_environment()
	_make_ground()
	_scatter_trees()
	_scatter_decoration()   # bushes + logs (visual only, after trees)
	_build_passages()
	_reachable = _reachable_from(_spawn_cell)
	_place_player()
	_spawn_parts()
	_spawn_batteries()
	_spawn_monster()
	_spawn_car()
	_add_hud()
	_player = get_parent().get_node_or_null("Player")
	_audio = AUDIO_SCRIPT.new()
	add_child(_audio)
	var pause := PAUSE_SCRIPT.new()
	pause.world = self
	add_child(pause)
	_add_post_processing()

# --- Atmosphere -------------------------------------------------------------

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.016, 0.025)        # near-black blue night
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.38, 0.55)         # cold moonlit ambient
	env.ambient_light_energy = 0.06
	# Thick fog — sight collapses to ~12 m so the entity looms out of nowhere.
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.07, 0.11)
	env.fog_density = 0.085
	env.fog_sky_affect = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_strength = 1.1
	env.glow_bloom = 0.12
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.1
	env.adjustment_saturation = 0.92                          # desaturate toward grey night

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# The moon — a dim, cold directional light raking across the canopy.
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.55, 0.65, 0.95)
	moon.light_energy = 0.45
	moon.rotation_degrees = Vector3(-58.0, 38.0, 0.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 45.0   # fog hides the far field; keeps shadow cost down with many trees
	add_child(moon)

func _make_ground() -> void:
	var w := cols * cell_size
	var d := rows * cell_size
	_ground_mat = StandardMaterial3D.new()
	_ground_mat.albedo_color = Color(0.07, 0.075, 0.06)       # damp dark earth (M1: CC0 texture)
	_ground_mat.roughness = 1.0
	_add_box(Vector3(w + 20.0, 0.4, d + 20.0), Vector3(w * 0.5, -0.2, d * 0.5), _ground_mat)

# --- Forest generation ------------------------------------------------------

## Scatter procedural pines: a dense impassable ring so you can't wander out of
## the woods, then sparse interior trees. Each blocks its grid cell so the
## monster pathfinds around the trunks; the player/monster physically collide.
func _scatter_trees() -> void:
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.05, 0.04, 0.035)
	trunk_mat.roughness = 1.0
	var pine_mat := StandardMaterial3D.new()
	pine_mat.albedo_color = Color(0.03, 0.05, 0.038)    # near-black pine
	pine_mat.roughness = 1.0
	var leafy_mat := StandardMaterial3D.new()
	leafy_mat.albedo_color = Color(0.05, 0.07, 0.045)   # slightly greener broadleaf
	leafy_mat.roughness = 1.0

	# Dense impassable border wall (double ring for a solid edge you can't slip).
	for x in cols:
		for z in rows:
			if x <= 1 or x >= cols - 2 or z <= 1 or z >= rows - 2:
				_place_tree(Vector2i(x, z), trunk_mat, pine_mat, leafy_mat)

	# Denser interior trees.
	var placed := 0
	var attempts := 0
	while placed < tree_count and attempts < tree_count * 6:
		attempts += 1
		var cell := Vector2i(_rng.randi_range(2, cols - 3), _rng.randi_range(2, rows - 3))
		if _blocked.has(cell):
			continue
		if Vector2(cell.x - _spawn_cell.x, cell.y - _spawn_cell.y).length() < 4.0:
			continue  # don't bury the player at spawn
		_place_tree(cell, trunk_mat, pine_mat, leafy_mat)
		placed += 1

func _place_tree(cell: Vector2i, trunk_mat: Material, pine_mat: Material, leafy_mat: Material) -> void:
	_block(cell)
	var base := cell_to_world(cell)
	var body := StaticBody3D.new()
	body.position = Vector3(base.x + _rng.randf_range(-0.9, 0.9), 0.0, base.z + _rng.randf_range(-0.9, 0.9))
	body.rotation.y = _rng.randf_range(0.0, TAU)

	var h := _rng.randf_range(4.5, 8.5)
	var tr := _rng.randf_range(0.16, 0.32)

	var trunk := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = tr * 0.7
	cm.bottom_radius = tr
	cm.height = h * 0.5
	trunk.mesh = cm
	trunk.material_override = trunk_mat
	trunk.position = Vector3(0.0, h * 0.25, 0.0)
	body.add_child(trunk)

	if _rng.randf() < 0.6:
		# Pine: three stacked cones (cylinder with top_radius 0).
		for i in 3:
			var cone := MeshInstance3D.new()
			var con := CylinderMesh.new()
			con.top_radius = 0.0
			con.bottom_radius = (1.8 - i * 0.45) * (tr / 0.22)
			con.height = h * 0.34
			cone.mesh = con
			cone.material_override = pine_mat
			cone.position = Vector3(0.0, h * 0.45 + i * h * 0.2, 0.0)
			body.add_child(cone)
	else:
		# Broadleaf: a cluster of dark canopy blobs.
		for i in 3:
			var blob := MeshInstance3D.new()
			var sm := SphereMesh.new()
			var br := (1.4 - i * 0.25) * (tr / 0.22)
			sm.radius = br
			sm.height = br * 1.7
			blob.mesh = sm
			blob.material_override = leafy_mat
			blob.position = Vector3(_rng.randf_range(-0.5, 0.5), h * 0.6 + i * h * 0.12, _rng.randf_range(-0.5, 0.5))
			body.add_child(blob)

	var col := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = tr + 0.18
	sh.height = h
	col.shape = sh
	col.position = Vector3(0.0, h * 0.5, 0.0)
	body.add_child(col)
	add_child(body)

## Pure-visual ground clutter for density — bushes + fallen logs. No collision
## and no grid blocking, so they never trap the player or fragment pathfinding.
func _scatter_decoration() -> void:
	var bush_mat := StandardMaterial3D.new()
	bush_mat.albedo_color = Color(0.04, 0.06, 0.04)
	bush_mat.roughness = 1.0
	var log_mat := StandardMaterial3D.new()
	log_mat.albedo_color = Color(0.06, 0.045, 0.035)
	log_mat.roughness = 1.0

	var w := cols * cell_size
	var d := rows * cell_size
	for _i in bush_count:
		_place_bush(Vector3(_rng.randf_range(2.0, w - 2.0), 0.0, _rng.randf_range(2.0, d - 2.0)), bush_mat)
	for _i in log_count:
		_place_log(Vector3(_rng.randf_range(3.0, w - 3.0), 0.0, _rng.randf_range(3.0, d - 3.0)), log_mat)

func _place_bush(pos: Vector3, mat: Material) -> void:
	var clumps := _rng.randi_range(1, 3)
	for _i in clumps:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := _rng.randf_range(0.4, 0.95)
		sm.radius = r
		sm.height = r * 1.1
		mi.mesh = sm
		mi.material_override = mat
		mi.position = pos + Vector3(_rng.randf_range(-0.6, 0.6), r * 0.45, _rng.randf_range(-0.6, 0.6))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

func _place_log(pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	var r := _rng.randf_range(0.18, 0.3)
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = _rng.randf_range(1.8, 3.4)
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos + Vector3(0.0, r, 0.0)
	mi.rotation = Vector3(0.0, _rng.randf_range(0.0, TAU), PI * 0.5)   # laid on its side
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _block(cell: Vector2i) -> void:
	if cell.x >= 0 and cell.x < cols and cell.y >= 0 and cell.y < rows:
		_blocked[cell] = true

## 4-neighbour adjacency across every non-blocked cell.
func _build_passages() -> void:
	passages = {}
	for x in cols:
		for z in rows:
			var c := Vector2i(x, z)
			if _blocked.has(c):
				continue
			var nbrs: Array[Vector2i] = []
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + off
				if n.x >= 0 and n.x < cols and n.y >= 0 and n.y < rows and not _blocked.has(n):
					nbrs.append(n)
			passages[c] = nbrs

func _reachable_from(start: Vector2i) -> Dictionary:
	var seen := {start: true}
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for nb in passages.get(c, []):
			if not seen.has(nb):
				seen[nb] = true
				stack.append(nb)
	return seen

func _far_reachable_cell(from: Vector2i) -> Vector2i:
	var best := from
	var best_d := -1.0
	for c in _reachable:
		var dd := Vector2(c.x - from.x, c.y - from.y).length()
		if dd > best_d:
			best_d = dd
			best = c
	return best

func _random_reachable_far(from: Vector2i, min_dist: float) -> Vector2i:
	var cands: Array[Vector2i] = []
	for c in _reachable:
		if Vector2(c.x - from.x, c.y - from.y).length() >= min_dist:
			cands.append(c)
	if cands.is_empty():
		return _far_reachable_cell(from)
	return cands[_rng.randi_range(0, cands.size() - 1)]

func _add_box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	add_child(body)

# --- Player / spawns --------------------------------------------------------

func _place_player() -> void:
	var player: Node3D = get_parent().get_node_or_null("Player")
	if player == null:
		return
	var spawn := cell_to_world(_spawn_cell)
	spawn.y = 1.0
	player.global_position = spawn
	# Face into the woods (toward the map centre).
	var centre := cell_to_world(Vector2i(cols / 2, rows / 2))
	player.look_at(Vector3(centre.x, 1.0, centre.z), Vector3.UP)

func _spawn_parts() -> void:
	var cells := _pick_cells(part_count, _spawn_cell)
	_total = cells.size()
	_found = 0
	for i in cells.size():
		var part := PICKUP_SCENE.instantiate()
		part.recharges = false                 # parts don't refill the torch
		part.counts_as_objective = true
		part.part_name = PART_NAMES[i % PART_NAMES.size()]
		part.glow_color = Color(1.0, 0.55, 0.2) # warm amber so parts read apart from batteries
		var pos := cell_to_world(cells[i])
		pos.y = 1.1
		part.position = pos
		part.collected.connect(_on_part_collected)
		add_child(part)

func _spawn_batteries() -> void:
	var cells := _pick_cells(battery_count, _spawn_cell)
	for cell in cells:
		var bat := PICKUP_SCENE.instantiate()
		bat.recharges = true
		bat.counts_as_objective = false
		bat.glow_color = Color(0.4, 0.85, 1.0) # cold blue battery cans
		var pos := cell_to_world(cell)
		pos.y = 1.0
		bat.position = pos
		add_child(bat)

func _pick_cells(n: int, exclude: Vector2i) -> Array:
	var all: Array[Vector2i] = []
	for c in _reachable:
		if c != exclude and Vector2(c.x - exclude.x, c.y - exclude.y).length() > 4.0:
			all.append(c)
	for i in range(all.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := all[i]
		all[i] = all[j]
		all[j] = tmp
	return all.slice(0, mini(n, all.size()))

func _spawn_monster() -> void:
	_monster = MONSTER_SCENE.instantiate()
	var pos := cell_to_world(_random_reachable_far(_spawn_cell, cols * 0.45))
	pos.y = 0.0
	_monster.position = pos
	_monster.caught.connect(_on_player_caught)
	_monster.spotted.connect(_on_spotted)
	add_child(_monster)

func _spawn_car() -> void:
	_car = CAR_SCRIPT.new()
	var pos := cell_to_world(_far_reachable_cell(_spawn_cell))
	pos.y = 0.0
	_car.position = pos
	_car.escaped.connect(_on_escaped)
	add_child(_car)

# --- Objectives -------------------------------------------------------------

func _on_part_collected() -> void:
	_found += 1
	_update_objectives_hud()
	if _audio:
		_audio.play_blip()
	if _found >= _total and not _car_ready:
		_repair_car()

func _update_objectives_hud() -> void:
	if _obj_label:
		_obj_label.text = "Car parts: %d / %d" % [_found, _total]

## Last part recovered: the car roars to life, the entity goes berserk, and the
## HUD becomes a beacon toward the only way out.
func _repair_car() -> void:
	_car_ready = true
	if _car and _car.has_method("activate"):
		_car.activate()
	if _monster and _monster.has_method("enrage"):
		_monster.enrage()
	if _audio:
		_audio.play_spotted()
	_flash(Color(0.7, 0.5, 0.1, 0.3), 0.7)
	if _obj_label:
		_obj_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))

func _on_escaped() -> void:
	_end_game("YOU ESCAPED\n\nPress R to play again", Color(0.6, 1.0, 0.7), false)

# --- HUD --------------------------------------------------------------------

func _add_hud() -> void:
	var layer := CanvasLayer.new()
	var controls := Label.new()
	controls.text = "WASD: move   Shift: sprint   F: flashlight   Esc: menu"
	controls.position = Vector2(16, 16)
	controls.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	layer.add_child(controls)

	_obj_label = Label.new()
	_obj_label.position = Vector2(16, 44)
	_obj_label.add_theme_font_size_override("font_size", 22)
	_obj_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.35))
	layer.add_child(_obj_label)

	_win_label = Label.new()
	_win_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_win_label.add_theme_font_size_override("font_size", 40)
	_win_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_win_label.visible = false
	layer.add_child(_win_label)

	add_child(layer)
	_update_objectives_hud()

func _add_post_processing() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = POST_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	rect.material = mat
	layer.add_child(rect)

# --- Per-frame: monster audio/rumble + escape beacon ------------------------

func _process(delta: float) -> void:
	_spot_cooldown = maxf(0.0, _spot_cooldown - delta)
	if _monster and _player and not _game_over:
		var dd := _monster.global_position.distance_to(_player.global_position)
		var chasing: bool = _monster.is_chasing()
		if _audio:
			_audio.update(dd, chasing, delta)
		if chasing and dd < 7.0 and _player.has_method("add_shake"):
			_player.add_shake((7.0 - dd) / 7.0 * 0.6 * delta)
	if _car_ready and _car and _player and _obj_label and not _game_over:
		var cd := _player.global_position.distance_to(_car.global_position)
		_obj_label.text = "CAR REPAIRED  —  GET TO IT  —  %dm" % int(cd)

# --- Monster reactions & end-game (same as the Backrooms level) -------------

func _on_player_caught() -> void:
	var p: Node3D = get_parent().get_node_or_null("Player")
	if _monster and p:
		var infront := p.global_position - p.global_transform.basis.z * 1.2
		_monster.global_position = Vector3(infront.x, 0.0, infront.z)
		_monster.look_at(Vector3(p.global_position.x, _monster.global_position.y, p.global_position.z), Vector3.UP)
		if _monster.has_method("play_attack"):
			_monster.play_attack()
		if p.has_method("jumpscare"):
			p.jumpscare(_monster.global_position)
	_flash_red()
	if _audio:
		_audio.play_stinger()
	_end_game("CAUGHT\n\nPress R to try again", Color(1.0, 0.3, 0.3), true)

func _flash(color: Color, dur: float) -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	var faded := color
	faded.a = 0.0
	var tw := create_tween()
	tw.tween_property(rect, "color", faded, dur)
	tw.tween_callback(layer.queue_free)

func _flash_red() -> void:
	_flash(Color(0.6, 0.0, 0.0, 0.7), 1.3)

func _on_spotted() -> void:
	if _game_over or _spot_cooldown > 0.0:
		return
	_spot_cooldown = 6.0
	if _audio:
		_audio.play_spotted()
	if _player and _player.has_method("add_shake"):
		_player.add_shake(0.6)
	_flash(Color(0.5, 0.0, 0.0, 0.35), 0.5)

func _end_game(message: String, color: Color, freeze_player: bool) -> void:
	if _game_over:
		return
	_game_over = true
	if _monster:
		_monster.active = false
	if _win_label:
		_win_label.text = message
		_win_label.add_theme_color_override("font_color", color)
		_win_label.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if freeze_player:
		var p: Node = get_parent().get_node_or_null("Player")
		if p:
			p.set_physics_process(false)
			p.set_process_unhandled_input(false)

func _unhandled_input(event: InputEvent) -> void:
	if _game_over and (event.is_action_pressed("ui_accept") \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R)):
		get_tree().reload_current_scene()

# --- Navigation interface (used verbatim by the monster) --------------------

func find_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	if start == goal:
		return []
	var frontier: Array[Vector2i] = [start]
	var came_from := {start: start}
	var i := 0
	while i < frontier.size():
		var cur: Vector2i = frontier[i]
		i += 1
		if cur == goal:
			break
		for nb in passages.get(cur, []):
			if not came_from.has(nb):
				came_from[nb] = cur
				frontier.append(nb)
	if not came_from.has(goal):
		return []
	var path: Array[Vector2i] = []
	var c: Vector2i = goal
	while c != start:
		path.push_front(c)
		c = came_from[c]
	return path

func random_cell() -> Vector2i:
	# A random reachable cell (so wander targets are never inside a tree).
	if _reachable.is_empty():
		return _spawn_cell
	var keys := _reachable.keys()
	return keys[_rng.randi_range(0, keys.size() - 1)]

func random_pickup_cell() -> Vector2i:
	var ps := get_tree().get_nodes_in_group("pickup")
	if ps.is_empty():
		return random_cell()
	var p: Node3D = ps[_rng.randi_range(0, ps.size() - 1)]
	return world_to_cell(p.global_position)

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * cell_size + cell_size * 0.5, 0.0, cell.y * cell_size + cell_size * 0.5)

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(p.x / cell_size), 0, cols - 1),
		clampi(int(p.z / cell_size), 0, rows - 1))
