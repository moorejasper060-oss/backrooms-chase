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
	_add_lights()
	_add_hud()

# --- Atmosphere -------------------------------------------------------------

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.88, 0.6)
	env.ambient_light_energy = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.09, 0.085, 0.05)
	env.fog_density = 0.045
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _make_materials() -> void:
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_color = Color(0.83, 0.74, 0.42)  # dingy yellow wallpaper
	_mat_wall.roughness = 0.95

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_color = Color(0.45, 0.40, 0.20)  # moist carpet
	_mat_floor.roughness = 1.0

	_mat_ceiling = StandardMaterial3D.new()
	_mat_ceiling.albedo_color = Color(0.78, 0.76, 0.68)  # ceiling tiles
	_mat_ceiling.roughness = 0.9

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
	# Buzzing fluorescent fixtures every few cells, hung from the ceiling.
	for x in range(1, cols, 3):
		for z in range(1, rows, 3):
			var light := OmniLight3D.new()
			light.position = Vector3(x * cell_size + cell_size * 0.5, wall_height - 0.4, z * cell_size + cell_size * 0.5)
			light.light_color = Color(1.0, 0.97, 0.8)
			light.light_energy = 1.6
			light.omni_range = cell_size * 3.0
			light.shadow_enabled = false
			add_child(light)

# --- HUD --------------------------------------------------------------------

func _add_hud() -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = "WASD: move    Shift: sprint    Mouse: look    Esc: free cursor"
	label.position = Vector2(16, 16)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	layer.add_child(label)
	add_child(layer)

# --- Helpers for later milestones (monster pathfinding, item spawns) --------

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * cell_size + cell_size * 0.5, 0.0, cell.y * cell_size + cell_size * 0.5)

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(int(p.x / cell_size), int(p.z / cell_size))
