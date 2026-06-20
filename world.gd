extends Node3D
## Procedurally builds a Backrooms-style maze: yellow walls, low ceiling,
## fluorescent lights and thick fog. Also stores the maze graph so the
## monster can pathfind through it in a later milestone.

@export var cols := 22
@export var rows := 22
@export var cell_size := 4.5
@export var wall_height := 3.0
@export var wall_thickness := 0.3
@export var maze_seed := 0  # 0 = random each run
@export var objective_count := 8
@export var interior_wall_chance := 0.16  # more partial-room structure (less empty)
@export var column_step := 3              # support-pillar grid spacing (in cells)

const PICKUP_SCENE := preload("res://pickup.tscn")
const MONSTER_SCENE := preload("res://monster.tscn")
const EXIT_SCENE := preload("res://exit.tscn")

# Objective tracking
var _found := 0
var _total := 0
var _obj_label: Label
var _win_label: Label

# Monster / end-game
var _monster: Node3D
var _game_over := false
var _exit: Node3D
var _exit_active := false

# Flickering ceiling lights
var _ceiling_lights: Array[OmniLight3D] = []

# Audio + cached player reference
const AUDIO_SCRIPT := preload("res://audio.gd")
const PAUSE_SCRIPT := preload("res://pause.gd")

const POST_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float grain = 0.05;
uniform float vignette = 0.5;
void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	vec2 d = SCREEN_UV - 0.5;
	float vig = smoothstep(0.85, 0.25, length(d));
	col *= mix(1.0 - vignette, 1.0, vig);
	float n = fract(sin(dot(SCREEN_UV + fract(TIME), vec2(12.9898, 78.233))) * 43758.5453);
	col += (n - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}
"
var _audio: Node
var _player: Node3D
var _spot_cooldown := 0.0

# Maze edge data (true = a wall exists on that edge)
var _wall_v := []  # vertical walls, size (cols+1) x rows
var _wall_h := []  # horizontal walls, size cols x (rows+1)

# Cell adjacency graph (open passages) — used by the monster for pathfinding.
# Keyed by Vector2i(cell) -> Array[Vector2i] of reachable neighbours.
var passages := {}
var _reachable := {}  # cells reachable from the spawn (for valid spawns/pickups)

var _rng := RandomNumberGenerator.new()

# Shared materials
var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D
var _mat_pillar: StandardMaterial3D

func _ready() -> void:
	if maze_seed != 0:
		_rng.seed = maze_seed
	else:
		_rng.randomize()
	_setup_environment()
	_make_materials()
	_generate_layout()
	_reachable = _reachable_from(Vector2i(0, 0))
	_build_geometry()
	_add_columns()
	_place_player()
	_spawn_pickups()
	_spawn_monster()
	_spawn_exit()
	_add_lights()
	_add_hud()
	_player = get_parent().get_node_or_null("Player")
	_audio = AUDIO_SCRIPT.new()
	add_child(_audio)
	var pause := PAUSE_SCRIPT.new()
	pause.world = self
	add_child(pause)
	_add_post_processing()

## Full-screen film grain + vignette. Placed on a layer below the HUD so the
## interface stays crisp.
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

	# Realism: contact shadows (SSAO), bloom on bright lights/eyes, a touch
	# more contrast and saturation.
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.1
	env.glow_bloom = 0.1
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.1

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _make_materials() -> void:
	# Triplanar (world-space) mapping gives consistent texel density on every
	# box regardless of its size, and tiles seamlessly between adjacent walls.
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = _make_wallpaper_texture()
	_mat_wall.normal_enabled = true
	_mat_wall.normal_texture = _make_wall_normal()
	_mat_wall.normal_scale = 0.6
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_world_triplanar = true
	_mat_wall.uv1_scale = Vector3(0.45, 0.45, 0.45)
	_mat_wall.roughness = 0.95

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = _make_carpet_texture()
	_mat_floor.normal_enabled = true
	_mat_floor.normal_texture = _make_carpet_normal()
	_mat_floor.normal_scale = 0.8
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_world_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.6, 0.6, 0.6)
	_mat_floor.roughness = 1.0

	_mat_ceiling = StandardMaterial3D.new()
	_mat_ceiling.albedo_texture = _make_ceiling_texture()
	_mat_ceiling.normal_enabled = true
	_mat_ceiling.normal_texture = _make_ceiling_normal()
	_mat_ceiling.normal_scale = 0.7
	_mat_ceiling.uv1_triplanar = true
	_mat_ceiling.uv1_world_triplanar = true
	_mat_ceiling.uv1_scale = Vector3(0.5, 0.5, 0.5)
	_mat_ceiling.roughness = 0.9

	_mat_pillar = StandardMaterial3D.new()
	_mat_pillar.albedo_texture = _make_wallpaper_texture()
	_mat_pillar.uv1_triplanar = true
	_mat_pillar.uv1_world_triplanar = true
	_mat_pillar.uv1_scale = Vector3(0.6, 0.6, 0.6)
	_mat_pillar.roughness = 0.9

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

## Builds a tangent-space normal map from a height field (wrapping at edges).
func _normal_from_heights(h: PackedFloat32Array, size: int, strength: float) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var hl := h[y * size + (x - 1 + size) % size]
			var hr := h[y * size + (x + 1) % size]
			var hu := h[((y - 1 + size) % size) * size + x]
			var hd := h[((y + 1) % size) * size + x]
			var n := Vector3((hl - hr) * strength, (hu - hd) * strength, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	return ImageTexture.create_from_image(img)

func _make_wall_normal() -> ImageTexture:
	var s := 256
	var h := PackedFloat32Array()
	h.resize(s * s)
	for y in s:
		for x in s:
			h[y * s + x] = sin(float(x) / float(s) * TAU * 8.0) * 0.5 + randf() * 0.12
	return _normal_from_heights(h, s, 2.0)

func _make_carpet_normal() -> ImageTexture:
	var s := 128
	var h := PackedFloat32Array()
	h.resize(s * s)
	for y in s:
		for x in s:
			h[y * s + x] = randf()
	return _normal_from_heights(h, s, 1.6)

func _make_ceiling_normal() -> ImageTexture:
	var s := 128
	var half := s / 2
	var h := PackedFloat32Array()
	h.resize(s * s)
	for y in s:
		for x in s:
			h[y * s + x] = -1.0 if ((x % half) < 3 or (y % half) < 3) else 0.0  # recessed seams
	return _normal_from_heights(h, s, 1.5)

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

# --- Open layout generation -------------------------------------------------

## Mostly-open space: solid perimeter + a few sparse interior walls. Pillars
## (added separately) supply the grid structure. Far more open than a maze,
## and with no 1-wide corridors the monster doesn't snag on walls.
func _generate_layout() -> void:
	_wall_v = []
	for x in cols + 1:
		var col := []
		for z in rows:
			col.append(false)
		_wall_v.append(col)
	_wall_h = []
	for x in cols:
		var col := []
		for z in rows + 1:
			col.append(false)
		_wall_h.append(col)

	# Perimeter walls
	for z in rows:
		_wall_v[0][z] = true
		_wall_v[cols][z] = true
	for x in cols:
		_wall_h[x][0] = true
		_wall_h[x][rows] = true

	# Sparse interior walls (partial dividers, not a maze)
	for x in range(1, cols):
		for z in rows:
			if _rng.randf() < interior_wall_chance:
				_wall_v[x][z] = true
	for x in cols:
		for z in range(1, rows):
			if _rng.randf() < interior_wall_chance:
				_wall_h[x][z] = true

	# Keep the spawn corner clear so the player isn't boxed in
	_wall_v[1][0] = false
	_wall_h[0][1] = false

	_build_passages()

func _build_passages() -> void:
	passages = {}
	for x in cols:
		for z in rows:
			passages[Vector2i(x, z)] = []
	for x in cols:
		for z in rows:
			var c := Vector2i(x, z)
			if x + 1 < cols and not _wall_v[x + 1][z]:
				passages[c].append(Vector2i(x + 1, z))
			if x - 1 >= 0 and not _wall_v[x][z]:
				passages[c].append(Vector2i(x - 1, z))
			if z + 1 < rows and not _wall_h[x][z + 1]:
				passages[c].append(Vector2i(x, z + 1))
			if z - 1 >= 0 and not _wall_h[x][z]:
				passages[c].append(Vector2i(x, z - 1))

## Flood-fill of every cell reachable from `start` (so we never spawn pickups
## or the monster in an accidentally-sealed pocket).
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

## The reachable cell farthest from `from` (used to spawn the monster away).
func _far_reachable_cell(from: Vector2i) -> Vector2i:
	var best := from
	var best_d := -1.0
	for c in _reachable:
		var d := Vector2(c.x - from.x, c.y - from.y).length()
		if d > best_d:
			best_d = d
			best = c
	return best

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

## Backrooms support columns on a regular grid (placed at cell corners so they
## never sit on the cell-centre lines the monster walks along).
func _add_columns() -> void:
	for ix in range(column_step, cols, column_step):
		for iz in range(column_step, rows, column_step):
			var pos := Vector3(ix * cell_size, wall_height * 0.5, iz * cell_size)
			_add_box(Vector3(0.7, wall_height, 0.7), pos, _mat_pillar)

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
	# Dim, failing fluorescents — spaced out, with many missing (dark gaps).
	# Dead tubes are skipped entirely (not created) to keep the light count low.
	for x in range(2, cols, 3):
		for z in range(2, rows, 3):
			if _rng.randf() < 0.4:
				continue
			var light := OmniLight3D.new()
			light.position = Vector3(x * cell_size + cell_size * 0.5, wall_height - 0.35, z * cell_size + cell_size * 0.5)
			light.light_color = Color(0.95, 0.95, 0.85)
			light.omni_range = cell_size * 2.2
			light.shadow_enabled = false
			var base := _rng.randf_range(0.3, 0.7)
			light.light_energy = base
			light.set_meta("base", base)
			light.set_meta("flicker", _rng.randf() < 0.45)
			_ceiling_lights.append(light)
			add_child(light)

func _process(delta: float) -> void:
	_spot_cooldown = maxf(0.0, _spot_cooldown - delta)
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

	# Once the exit is live, the objective HUD becomes a distance guide.
	if _exit_active and _exit and _player and _obj_label and not _game_over:
		var ed := _player.global_position.distance_to(_exit.global_position)
		_obj_label.text = "REACH THE EXIT  —  %dm" % int(ed)

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
			if c != exclude and _reachable.has(c):
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
	if _found >= _total and not _exit_active:
		_open_exit()

func _update_objectives_hud() -> void:
	if _obj_label:
		_obj_label.text = "Objectives found: %d / %d" % [_found, _total]

## All objectives collected: power on the exit and enrage the monster.
func _open_exit() -> void:
	_exit_active = true
	if _exit:
		_exit.activate()
	if _monster and _monster.has_method("enrage"):
		_monster.enrage()
	if _audio:
		_audio.play_spotted()
	_flash(Color(0.0, 0.5, 0.2, 0.3), 0.6)
	if _obj_label:
		_obj_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))

func _on_escaped() -> void:
	_end_game("YOU ESCAPED\n\nPress R to play again", Color(0.5, 1.0, 0.6), false)

# --- Monster & end-game -----------------------------------------------------

func _spawn_monster() -> void:
	_monster = MONSTER_SCENE.instantiate()
	var pos := cell_to_world(_random_reachable_far(Vector2i(0, 0), cols * 0.45))
	pos.y = 0.2
	_monster.position = pos
	_monster.caught.connect(_on_player_caught)
	_monster.spotted.connect(_on_spotted)
	add_child(_monster)

func _spawn_exit() -> void:
	_exit = EXIT_SCENE.instantiate()
	var pos := cell_to_world(_far_reachable_cell(Vector2i(0, 0)))  # far corner
	pos.y = 0.0
	_exit.position = pos
	_exit.escaped.connect(_on_escaped)
	add_child(_exit)

## A random reachable cell at least `min_dist` cells from `from`.
func _random_reachable_far(from: Vector2i, min_dist: float) -> Vector2i:
	var cands: Array[Vector2i] = []
	for c in _reachable:
		if Vector2(c.x - from.x, c.y - from.y).length() >= min_dist:
			cands.append(c)
	if cands.is_empty():
		return _far_reachable_cell(from)
	return cands[_rng.randi_range(0, cands.size() - 1)]

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

## The monster just locked onto the player — screech + jolt (rate-limited).
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
