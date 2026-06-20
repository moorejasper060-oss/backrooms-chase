extends Node3D
## Procedurally builds a Backrooms-style maze: yellow walls, low ceiling,
## fluorescent lights and thick fog. Also stores the maze graph so the
## monster can pathfind through it in a later milestone.

@export var cols := 12
@export var rows := 12
@export var cell_size := 5.0
@export var wall_height := 3.0
@export var wall_thickness := 0.3
@export var maze_seed := 0  # 0 = random each run
@export var objective_count := 6

const PICKUP_SCENE := preload("res://pickup.tscn")
const MONSTER_SCENE := preload("res://monster.tscn")

# Objective tracking
var _found := 0
var _total := 0
var _obj_label: Label
var _win_label: Label

# Monster / end-game
var _monster: Node3D
var _game_over := false

# Flickering ceiling lights
var _ceiling_lights: Array[OmniLight3D] = []

# Audio + cached player reference
const AUDIO_SCRIPT := preload("res://audio.gd")
var _audio: Node
var _player: Node3D

# Maze edge data (true = a wall exists on that edge)
var _wall_v := []  # vertical walls, size (cols+1) x rows
var _wall_h := []  # horizontal walls, size cols x (rows+1)

# Cell adjacency graph (open passages) — used by the monster later.
# Keyed by Vector2i(cell) -> Array[Vector2i] of reachable neighbours.
var passages := {}

var _rng := RandomNumberGenerator.new()

# Shared materials
var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D

func _ready() -> void:
	if maze_seed != 0:
		_rng.seed = maze_seed
	else:
		_rng.randomize()
	_setup_environment()
	_make_materials()
	_generate_maze()
	_build_geometry()
	_place_player()
	_spawn_pickups()
	_spawn_monster()
	_add_lights()
	_add_hud()
	_player = get_parent().get_node_or_null("Player")
	_audio = AUDIO_SCRIPT.new()
	add_child(_audio)

# --- Atmosphere -------------------------------------------------------------

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.88, 0.6)
	env.ambient_light_energy = 0.07
	env.fog_enabled = true
	env.fog_light_color = Color(0.09, 0.085, 0.05)
	env.fog_density = 0.045
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _make_materials() -> void:
	# Triplanar (world-space) mapping gives consistent texel density on every
	# box regardless of its size, and tiles seamlessly between adjacent walls.
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = _make_wallpaper_texture()
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_world_triplanar = true
	_mat_wall.uv1_scale = Vector3(0.45, 0.45, 0.45)
	_mat_wall.roughness = 0.95

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = _make_carpet_texture()
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_world_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.6, 0.6, 0.6)
	_mat_floor.roughness = 1.0

	_mat_ceiling = StandardMaterial3D.new()
	_mat_ceiling.albedo_texture = _make_ceiling_texture()
	_mat_ceiling.uv1_triplanar = true
	_mat_ceiling.uv1_world_triplanar = true
	_mat_ceiling.uv1_scale = Vector3(0.5, 0.5, 0.5)
	_mat_ceiling.roughness = 0.9

## Dingy yellow wallpaper: subtle vertical pattern + water staining + grain.
func _make_wallpaper_texture() -> ImageTexture:
	var s := 256
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGB8)
	var base := Color(0.83, 0.74, 0.42)
	for y in s:
		for x in s:
			var stripe := 0.05 * sin(float(x) / float(s) * TAU * 8.0)
			var stain := maxf(0.0, 0.10 * sin(float(y) / float(s) * TAU * 1.5 + 1.3))
			var grain := (randf() - 0.5) * 0.06
			var f := 1.0 + stripe - stain + grain
			img.set_pixel(x, y, Color(base.r * f, base.g * f, base.b * f))
	return ImageTexture.create_from_image(img)

## Damp, grainy carpet.
func _make_carpet_texture() -> ImageTexture:
	var s := 128
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGB8)
	var base := Color(0.45, 0.40, 0.20)
	for y in s:
		for x in s:
			var n := (randf() - 0.5) * 0.13
			img.set_pixel(x, y, Color(
				clampf(base.r + n, 0.0, 1.0),
				clampf(base.g + n, 0.0, 1.0),
				clampf(base.b + n, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

## Drop-ceiling tiles: a grid of darker seams over off-white panels.
func _make_ceiling_texture() -> ImageTexture:
	var s := 128
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGB8)
	var base := Color(0.78, 0.76, 0.68)
	var seam := base * 0.5
	var half := s / 2
	for y in s:
		for x in s:
			if (x % half) < 3 or (y % half) < 3:
				img.set_pixel(x, y, seam)
			else:
				var n := (randf() - 0.5) * 0.05
				img.set_pixel(x, y, Color(base.r + n, base.g + n, base.b + n))
	return ImageTexture.create_from_image(img)

## Drop the player into the start cell, facing down an open corridor so the
## first thing they see is depth, not a wall in their face.
func _place_player() -> void:
	var player: Node3D = get_parent().get_node_or_null("Player")
	if player == null:
		return
	var start := Vector2i(0, 0)
	var spawn := cell_to_world(start)
	spawn.y = 1.0
	player.global_position = spawn
	var open: Array = passages.get(start, [])
	if not open.is_empty():
		var n: Vector2i = open[0]
		var dir := Vector3(n.x - start.x, 0.0, n.y - start.y)
		player.look_at(spawn + dir, Vector3.UP)

# --- Maze generation (recursive backtracker) --------------------------------

func _generate_maze() -> void:
	# Start with every wall present.
	_wall_v = []
	for x in cols + 1:
		var col := []
		for z in rows:
			col.append(true)
		_wall_v.append(col)
	_wall_h = []
	for x in cols:
		var col := []
		for z in rows + 1:
			col.append(true)
		_wall_h.append(col)

	for x in cols:
		for z in rows:
			passages[Vector2i(x, z)] = []

	var visited := {}
	var stack: Array[Vector2i] = []
	var start := Vector2i(0, 0)
	visited[start] = true
	stack.append(start)

	while not stack.is_empty():
		var c: Vector2i = stack.back()
		var neighbours := _unvisited_neighbours(c, visited)
		if neighbours.is_empty():
			stack.pop_back()
		else:
			var n: Vector2i = neighbours[_rng.randi_range(0, neighbours.size() - 1)]
			_remove_wall_between(c, n)
			passages[c].append(n)
			passages[n].append(c)
			visited[n] = true
			stack.append(n)

func _unvisited_neighbours(c: Vector2i, visited: Dictionary) -> Array:
	var result: Array[Vector2i] = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if n.x >= 0 and n.x < cols and n.y >= 0 and n.y < rows and not visited.has(n):
			result.append(n)
	return result

func _remove_wall_between(a: Vector2i, b: Vector2i) -> void:
	if b.x > a.x:
		_wall_v[b.x][a.y] = false
	elif b.x < a.x:
		_wall_v[a.x][a.y] = false
	elif b.y > a.y:
		_wall_h[a.x][b.y] = false
	elif b.y < a.y:
		_wall_h[a.x][a.y] = false

# --- Geometry ---------------------------------------------------------------

func _build_geometry() -> void:
	var w := cols * cell_size
	var d := rows * cell_size

	# Floor and ceiling
	_add_box(Vector3(w, 0.2, d), Vector3(w * 0.5, -0.1, d * 0.5), _mat_floor)
	_add_box(Vector3(w, 0.2, d), Vector3(w * 0.5, wall_height + 0.1, d * 0.5), _mat_ceiling)

	# Vertical walls (run along Z)
	for x in cols + 1:
		for z in rows:
			if _wall_v[x][z]:
				var pos := Vector3(x * cell_size, wall_height * 0.5, z * cell_size + cell_size * 0.5)
				_add_box(Vector3(wall_thickness, wall_height, cell_size), pos, _mat_wall)

	# Horizontal walls (run along X)
	for x in cols:
		for z in rows + 1:
			if _wall_h[x][z]:
				var pos := Vector3(x * cell_size + cell_size * 0.5, wall_height * 0.5, z * cell_size)
				_add_box(Vector3(cell_size, wall_height, wall_thickness), pos, _mat_wall)

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

# --- Lighting ---------------------------------------------------------------

func _add_lights() -> void:
	# Dim, failing fluorescent fixtures — some dead, some buzzing and flickering.
	for x in range(1, cols, 2):
		for z in range(1, rows, 2):
			var light := OmniLight3D.new()
			light.position = Vector3(x * cell_size + cell_size * 0.5, wall_height - 0.35, z * cell_size + cell_size * 0.5)
			light.light_color = Color(0.95, 0.95, 0.85)
			light.omni_range = cell_size * 2.5
			light.shadow_enabled = false
			if _rng.randf() < 0.35:
				light.light_energy = 0.0           # dead tube
				light.set_meta("base", 0.0)
				light.set_meta("flicker", false)
			else:
				var base := _rng.randf_range(0.25, 0.6)
				light.light_energy = base
				light.set_meta("base", base)
				light.set_meta("flicker", _rng.randf() < 0.5)
			_ceiling_lights.append(light)
			add_child(light)

func _process(delta: float) -> void:
	# Cheap fluorescent stutter on the flickering tubes.
	for l in _ceiling_lights:
		if l.get_meta("flicker", false) and _rng.randf() < 0.07:
			l.light_energy = 0.0 if _rng.randf() < 0.5 else l.get_meta("base", 0.4)
	# Audio cues + proximity camera rumble
	if _monster and _player and not _game_over:
		var d := _monster.global_position.distance_to(_player.global_position)
		var chasing: bool = _monster.is_chasing()
		if _audio:
			_audio.update(d, chasing, delta)
		if chasing and d < 7.0 and _player.has_method("add_shake"):
			_player.add_shake((7.0 - d) / 7.0 * 0.6 * delta)

# --- HUD --------------------------------------------------------------------

func _add_hud() -> void:
	var layer := CanvasLayer.new()

	var controls := Label.new()
	controls.text = "WASD: move    Shift: sprint    Mouse: look    Esc: free cursor"
	controls.position = Vector2(16, 16)
	controls.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	layer.add_child(controls)

	_obj_label = Label.new()
	_obj_label.position = Vector2(16, 44)
	_obj_label.add_theme_font_size_override("font_size", 22)
	_obj_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
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

# --- Objectives -------------------------------------------------------------

func _spawn_pickups() -> void:
	var cells := _pick_cells(objective_count, Vector2i(0, 0))
	_total = cells.size()
	_found = 0
	for cell in cells:
		var pickup := PICKUP_SCENE.instantiate()
		var pos := cell_to_world(cell)
		pos.y = 1.1
		pickup.position = pos
		pickup.collected.connect(_on_pickup_collected)
		add_child(pickup)

## Pick `n` distinct open cells (shuffled), excluding the given cell.
func _pick_cells(n: int, exclude: Vector2i) -> Array:
	var all: Array[Vector2i] = []
	for x in cols:
		for z in rows:
			var c := Vector2i(x, z)
			if c != exclude:
				all.append(c)
	# Fisher-Yates shuffle with our seeded RNG
	for i in range(all.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := all[i]
		all[i] = all[j]
		all[j] = tmp
	return all.slice(0, mini(n, all.size()))

func _on_pickup_collected() -> void:
	_found += 1
	_update_objectives_hud()
	if _audio:
		_audio.play_blip()
	if _found >= _total:
		_win()

func _update_objectives_hud() -> void:
	if _obj_label:
		_obj_label.text = "Objectives found: %d / %d" % [_found, _total]

func _win() -> void:
	_end_game("ALL OBJECTIVES FOUND\nYou made it out... this time.\n\nPress R to play again",
		Color(0.6, 1.0, 0.7), false)

# --- Monster & end-game -----------------------------------------------------

func _spawn_monster() -> void:
	_monster = MONSTER_SCENE.instantiate()
	var pos := cell_to_world(Vector2i(cols - 1, rows - 1))  # far corner
	pos.y = 0.2
	_monster.position = pos
	_monster.caught.connect(_on_player_caught)
	add_child(_monster)

func _on_player_caught() -> void:
	# Jumpscare: yank the monster right up to the player's face, then rattle
	# the camera and flash red.
	var p: Node3D = get_parent().get_node_or_null("Player")
	if _monster and p:
		var infront := p.global_position - p.global_transform.basis.z * 1.2
		_monster.global_position = Vector3(infront.x, 0.0, infront.z)
		_monster.look_at(Vector3(p.global_position.x, _monster.global_position.y, p.global_position.z), Vector3.UP)
		if p.has_method("jumpscare"):
			p.jumpscare(_monster.global_position)
	_flash_red()
	if _audio:
		_audio.play_stinger()
	_end_game("CAUGHT\n\nPress R to try again", Color(1.0, 0.3, 0.3), true)

func _flash_red() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.color = Color(0.6, 0.0, 0.0, 0.65)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color", Color(0.6, 0.0, 0.0, 0.0), 1.3)

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

# --- Pathfinding helpers (used by the monster) ------------------------------

## Breadth-first search over the maze graph. Returns the list of cells to walk
## (excluding the start cell), or an empty array if already there / unreachable.
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
	return Vector2i(_rng.randi_range(0, cols - 1), _rng.randi_range(0, rows - 1))

## A cell containing a remaining objective (so the monster can haunt them),
## or a random cell if none are left.
func random_pickup_cell() -> Vector2i:
	var ps := get_tree().get_nodes_in_group("pickup")
	if ps.is_empty():
		return random_cell()
	var p: Node3D = ps[_rng.randi_range(0, ps.size() - 1)]
	return world_to_cell(p.global_position)

# --- Helpers for later milestones (monster pathfinding, item spawns) --------

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * cell_size + cell_size * 0.5, 0.0, cell.y * cell_size + cell_size * 0.5)

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(p.x / cell_size), 0, cols - 1),
		clampi(int(p.z / cell_size), 0, rows - 1))
