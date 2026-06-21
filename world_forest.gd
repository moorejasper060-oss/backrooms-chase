extends Node3D
## Moonlit, fog-drowned night forest. Start at a cabin, scavenge car parts
## scattered through the woods, repair the dead car, and escape in it — all while
## the entity hunts you. Reuses the same navigation grid + spawn/HUD/end-game
## systems as the Backrooms level (world.gd, left intact) so the monster, player,
## pickups and escape flow work unchanged; only the generated world differs.

@export var cols := 64
@export var rows := 64
@export var cell_size := 3.0          # 64 * 3 = 192 m of forest (a big map)
@export var part_count := 5           # car parts to find
@export var battery_count := 3        # flashlight batteries scattered (fewer items)
@export var tree_count := 1700        # dense interior trees (real 3D, chunked for culling)
@export var bush_count := 320         # filler bushes (varied colour; ferns/mushrooms/pebbles on top)
@export var log_count := 0            # replaced by real Poly Haven fallen logs
@export var grass_count := 16000      # GPU-instanced grass tufts (chunked + distance-culled)
@export var forest_seed := 0          # 0 = random each run

# Instances are bucketed into a CHUNK_DIV x CHUNK_DIV grid of MultiMeshInstances
# so Godot frustum-culls whole chunks behind/around the camera — essential for a
# big, dense map. Grass/detail chunks also distance-cull (visibility_range).
const CHUNK_DIV := 10
const GRASS_VIEW := 48.0              # grass/detail beyond this many metres is culled
const TREE_VIEW := 95.0               # whole tree chunks beyond this cull (fog/mountains hide the edge)

# A meandering river carved through the map (channel in the terrain + water mesh).
const RIVER_HALF := 5.0               # half-width of the flat channel bottom
const RIVER_BANK := 5.5               # bank slope width either side
const RIVER_DEPTH := 1.7              # how deep the channel is cut (shallow — wadeable)

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
uniform float dread = 0.0;   // 0..1, driven from entity proximity each frame
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - 0.5;
	// Sickening breathing warp as dread rises.
	uv += d * dread * 0.035 * sin(TIME * 2.7);
	// Chromatic aberration that splits harder the closer it gets.
	float ca = dread * 0.007;
	vec3 col;
	col.r = texture(screen_tex, uv + d * ca).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - d * ca).b;
	// Vignette tightens with dread.
	float vig = smoothstep(0.85, 0.2, length(d));
	col *= mix(1.0 - vignette - dread * 0.22, 1.0, vig);
	// Bleed color toward grey as dread peaks.
	float g = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(g), dread * 0.35);
	float n = fract(sin(dot(SCREEN_UV + fract(TIME), vec2(12.9898, 78.233))) * 43758.5453);
	col += (n - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}
"

const SKY_SHADER := "
shader_type sky;
uniform vec3 moon_dir;
void sky() {
	vec3 d = normalize(EYEDIR);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 col = mix(vec3(0.02, 0.03, 0.055), vec3(0.0, 0.006, 0.02), up);
	float md = dot(d, normalize(moon_dir));
	col += vec3(0.9, 0.93, 1.0) * smoothstep(0.9965, 0.9978, md);    // moon disc
	col += vec3(0.35, 0.45, 0.7) * smoothstep(0.95, 1.0, md) * 0.6;  // soft halo
	vec2 g = floor((d.xz / max(abs(d.y), 0.2)) * 30.0);
	float h = fract(sin(dot(g, vec2(12.9898, 78.233))) * 43758.5453);
	col += vec3(0.7) * step(0.9975, h) * up;                         // sparse stars
	COLOR = col;
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
var _post_mat: ShaderMaterial
var _dread := 0.0
var _lantern: OmniLight3D    # warm cabin beacon; flickers like a flame
var _time := 0.0
var _quality := 2            # mirrors Settings.quality (0 low, 1 med, 2 high)

# Navigation grid (open forest: every non-blocked cell connects to its
# 4 neighbours; trees/cabin block cells). Same interface the monster expects.
var _blocked := {}      # Vector2i -> true
var passages := {}      # Vector2i -> Array[Vector2i]
var _reachable := {}
var _spawn_cell := Vector2i(5, 5)

var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
const GROUND_AMP := 2.4   # terrain hill height (± metres)
var _mat_ground: StandardMaterial3D
var _mat_bark: StandardMaterial3D
var _mat_cabin: StandardMaterial3D
var _mat_foliage: StandardMaterial3D

func _ready() -> void:
	if forest_seed != 0:
		_rng.seed = forest_seed
	else:
		_rng.randomize()
	_noise.seed = _rng.randi()
	_noise.frequency = 0.012
	_noise.fractal_octaves = 3
	_apply_quality()
	_setup_environment()
	_make_materials()
	_make_ground()
	_build_river()          # water mesh in the carved channel
	_scatter_grass()        # dense ground-cover so the floor never reads as flat
	_scatter_trees()
	_build_perimeter_walls()  # invisible barrier so you can't slip off the map edge
	_build_mountains()        # a ring of peaks around the horizon
	_scatter_decoration()   # primitive filler bushes
	_scatter_props()        # real CC0 rocks / logs / ferns / branches
	_build_cabin()          # start landmark (blocks its footprint cells)
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

## Scale the heaviest costs (volumetric fog, grass + tree density) to the
## player's graphics-quality setting. Volumetric fog dominates GPU cost, so Low
## drops it entirely; density counts shrink to thin the alpha-billboard overdraw
## that tanks FPS when looking across the whole forest.
func _apply_quality() -> void:
	_quality = Settings.quality
	match _quality:
		0:  # Low — favour FPS
			grass_count = int(grass_count * 0.30)
			tree_count = int(tree_count * 0.55)
		1:  # Medium — balanced
			grass_count = int(grass_count * 0.65)
			tree_count = int(tree_count * 0.85)
		_:  # High — full density (volfog handled in _setup_environment)
			pass

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.background_color = Color(0.005, 0.007, 0.013)        # (unused with BG_SKY)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.38, 0.55)         # cold moonlit ambient
	env.ambient_light_energy = 0.022                          # darker — lean on the flashlight
	# Lighter fog so the forest is visible, but the night is darker overall.
	env.fog_enabled = true
	env.fog_light_color = Color(0.035, 0.05, 0.08)
	env.fog_density = 0.014                                   # thinner so the big map + mountains read
	env.fog_sky_affect = 0.2                                  # keep the sky/moon/peaks visible above the fog
	# Volumetric fog is the dominant GPU cost — scale it to graphics quality:
	# Low turns it off, Medium runs it thinner/shorter, High keeps the full mist.
	env.volumetric_fog_enabled = _quality >= 1
	if _quality == 1:
		env.volumetric_fog_density = 0.010
		env.volumetric_fog_length = 26.0
	else:
		env.volumetric_fog_density = 0.016
		env.volumetric_fog_length = 40.0
	env.volumetric_fog_albedo = Color(0.5, 0.6, 0.8)
	env.volumetric_fog_emission = Color(0.007, 0.01, 0.018)
	env.volumetric_fog_detail_spread = 2.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = _quality >= 1     # screen-space AO is a real cost — off on Low
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
	moon.light_color = Color(0.5, 0.6, 0.92)
	moon.light_energy = 0.32
	moon.rotation_degrees = Vector3(-48.0, 38.0, 0.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 30.0 if _quality == 0 else 50.0
	add_child(moon)

	# Night sky with a real moon + halo + stars, drawn in the sky shader so the
	# distance fog can't erase it; aligned with the moonlight direction.
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	var sky_shader := Shader.new()
	sky_shader.code = SKY_SHADER
	sky_mat.shader = sky_shader
	sky_mat.set_shader_parameter("moon_dir", moon.transform.basis.z)
	sky.sky_material = sky_mat
	env.sky = sky

## Real CC0 PBR textures (Poly Haven), triplanar world-mapped so they tile over
## any surface. Loaded at runtime from textures/ via Image.load (no import step).
func _make_materials() -> void:
	_mat_ground = _pbr_material("res://textures/forestfloor_", Vector3(0.16, 0.16, 0.16))
	_mat_ground.albedo_color = Color(0.72, 0.74, 0.7)    # gentle knock-down for night
	_mat_bark = _pbr_material("res://textures/bark_", Vector3(0.5, 0.5, 0.5))
	_mat_bark.albedo_color = Color(0.6, 0.58, 0.54)
	_mat_bark.vertex_color_use_as_albedo = true          # per-tree MultiMesh tint
	_mat_cabin = _pbr_material("res://textures/cabin_", Vector3(0.45, 0.45, 0.45))
	_mat_cabin.albedo_color = Color(0.6, 0.58, 0.55)
	_mat_foliage = _pbr_material("res://textures/foliage_", Vector3(0.85, 0.85, 0.85))
	_mat_foliage.albedo_color = Color(0.32, 0.42, 0.22)  # darker night green
	_mat_foliage.vertex_color_use_as_albedo = true       # per-tree tint variety
	_mat_foliage.backlight_enabled = true                # moonlight bleeds through
	_mat_foliage.backlight = Color(0.06, 0.1, 0.04)

func _pbr_material(prefix: String, uv_scale: Vector3) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var albedo := _load_tex(prefix + "color.jpg")
	if albedo:
		m.albedo_texture = albedo
	var nrm := _load_tex(prefix + "normal.jpg")
	if nrm:
		m.normal_enabled = true
		m.normal_texture = nrm
		m.normal_scale = 1.2
	var rgh := _load_tex(prefix + "rough.jpg")
	if rgh:
		m.roughness_texture = rgh
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = uv_scale
	return m

func _load_tex(path: String) -> ImageTexture:
	var img := Image.new()
	if img.load(ProjectSettings.globalize_path(path)) != OK:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Terrain height at a world xz — gentle rolling hills, flattened around the
## spawn/cabin clearing so the start area isn't on a slope. Used to build the
## ground mesh AND to seat every spawned object on it.
func _ground_height(x: float, z: float) -> float:
	var h := _noise.get_noise_2d(x, z) * GROUND_AMP
	var sw := cell_to_world(_spawn_cell)
	var flat := clampf((Vector2(x - sw.x, z - sw.z).length() - 6.0) / 11.0, 0.0, 1.0)
	h *= flat
	# Carve the meandering river channel into the terrain.
	var dist := absf(x - _river_x(z))
	h -= RIVER_DEPTH * (1.0 - smoothstep(RIVER_HALF, RIVER_HALF + RIVER_BANK, dist))
	return h

## River centreline X for a given Z — a gentle S winding down the map.
func _river_x(z: float) -> float:
	var w := cols * cell_size
	return w * 0.5 + sin(z / w * TAU * 1.3) * (w * 0.16)

## Undulating 3D heightmap ground (real terrain, not a flat plane), triplanar-
## textured, with a trimesh collider the player/monster walk on.
func _make_ground() -> void:
	var w := cols * cell_size
	var d := rows * cell_size
	var res := 2.0
	var nx := int(w / res)
	var nz := int(d / res)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in nz:
		for ix in nx:
			var x0 := ix * res
			var x1 := (ix + 1) * res
			var z0 := iz * res
			var z1 := (iz + 1) * res
			var p00 := Vector3(x0, _ground_height(x0, z0), z0)
			var p10 := Vector3(x1, _ground_height(x1, z0), z0)
			var p01 := Vector3(x0, _ground_height(x0, z1), z1)
			var p11 := Vector3(x1, _ground_height(x1, z1), z1)
			# Wind front-faces UP (CCW from above) so the terrain isn't
			# back-face culled into a void — this also points generate_normals()
			# skyward for correct lighting.
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mat_ground
	add_child(mi)
	mi.create_trimesh_collision()

# --- Ground cover (grass) ---------------------------------------------------

## A procedural grass-tuft texture: several green blades on transparent, drawn
## once at startup so we need no asset files. Used as an alpha-scissor cutout on
## crossed quads, then GPU-instanced thousands of times to carpet the floor.
func _make_grass_texture() -> ImageTexture:
	var W := 96
	var H := 128
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var br := RandomNumberGenerator.new()
	br.seed = 92731
	var blades := 11
	for _b in blades:
		var base_x := br.randf_range(W * 0.12, W * 0.88)
		var height := br.randf_range(H * 0.42, H * 0.96)
		var lean := br.randf_range(-W * 0.22, W * 0.22)
		var base_col := Color(0.07, 0.17, 0.04)
		var tip_col := Color(0.34, 0.55, 0.14)
		var hue := br.randf_range(-0.05, 0.07)
		var steps := int(height)
		for s in steps:
			var t := float(s) / float(maxi(steps, 1))   # 0 at base, 1 at tip
			var y := H - 1 - s                           # grow upward
			var cx := base_x + lean * (t * t)            # curve toward the tip
			var half_w := lerpf(2.8, 0.5, t)
			var col := base_col.lerp(tip_col, t)
			col.g = clampf(col.g + hue, 0.0, 1.0)
			for x in range(maxi(0, int(cx - half_w)), mini(W, int(cx + half_w) + 1)):
				if y < 0 or y >= H:
					continue
				var edge := 1.0 - absf((float(x) + 0.5 - cx) / (half_w + 0.5))
				var a := clampf(edge * 1.7, 0.0, 1.0)
				if a > 0.05 and a > img.get_pixel(x, y).a:
					img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Grass tuft = three crossed quads (volume from any angle), pivoted at the base
## so it sits on the ground. One material reused across the whole MultiMesh.
func _build_grass_mesh() -> ArrayMesh:
	var w := 0.75
	var h := 0.55
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _make_grass_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true     # MultiMesh per-instance tint
	mat.albedo_color = Color(0.85, 0.9, 0.75)
	mat.roughness = 1.0
	mat.backlight_enabled = true              # moon/flashlight bleeds through blades
	mat.backlight = Color(0.12, 0.18, 0.07)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	for ang in [0.0, PI / 3.0, 2.0 * PI / 3.0]:
		st.append_from(q, 0, Transform3D(Basis(Vector3.UP, ang), Vector3(0.0, h * 0.5, 0.0)))
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)
	return mesh

## Carpet the walkable forest with grass tufts. Chunked + distance-culled so a
## big map can carry far more total grass while only the nearby chunks render.
func _scatter_grass() -> void:
	if grass_count <= 0:
		return
	var w := cols * cell_size
	var d := rows * cell_size
	var xf := []
	for _i in grass_count:
		var x := _rng.randf_range(3.0, w - 3.0)
		var z := _rng.randf_range(3.0, d - 3.0)
		var pos := Vector3(x, _ground_height(x, z) - 0.05, z)
		var yaw := _rng.randf_range(0.0, TAU)
		var s := _rng.randf_range(0.7, 1.7)
		var sy := s * _rng.randf_range(0.8, 1.6)
		xf.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, sy, s)), pos))
	_chunked_multimesh(_build_grass_mesh(), xf, "grass", GRASS_VIEW)

# --- Forest generation ------------------------------------------------------

## Scatter procedural pines: a dense impassable ring so you can't wander out of
## the woods, then sparse interior trees. Each blocks its grid cell so the
## monster pathfinds around the trunks; the player/monster physically collide.
func _scatter_trees() -> void:
	var conifer_x := []     # real 3D layered pines (the majority)
	var broadleaf_x := []   # rounded-crown trees for species variety
	var colliders := []

	# Dense impassable border wall (2-cell-thick) — all conifers, block nav so you
	# can't wander out of the woods.
	for x in cols:
		for z in rows:
			if x <= 1 or x >= cols - 2 or z <= 1 or z >= rows - 2:
				var c := cell_to_world(Vector2i(x, z))
				_block(Vector2i(x, z))
				_add_tree_at(c.x + _rng.randf_range(-1.0, 1.0), c.z + _rng.randf_range(-1.0, 1.0), conifer_x, broadleaf_x, colliders, 0.0)

	# Dense interior trees at continuous positions. They do NOT block nav cells,
	# so the grid stays open (monster/player thread between trunks) and the forest
	# can be genuinely dense without fragmenting pathfinding — thin trunk colliders
	# handle physical collision.
	var w := cols * cell_size
	var d := rows * cell_size
	var sw := cell_to_world(_spawn_cell)
	var placed := 0
	var attempts := 0
	while placed < tree_count and attempts < tree_count * 4:
		attempts += 1
		var x := _rng.randf_range(7.0, w - 7.0)
		var z := _rng.randf_range(7.0, d - 7.0)
		if Vector2(x - sw.x, z - sw.z).length() < 9.0:
			continue  # keep the spawn/cabin clearing open
		if absf(x - _river_x(z)) < RIVER_HALF + RIVER_BANK + 1.0:
			continue  # keep trees out of the river channel
		_add_tree_at(x, z, conifer_x, broadleaf_x, colliders, 0.4)
		placed += 1

	# Two real-3D species, each chunked + GPU-instanced → genuine volume from every
	# angle, with whole chunks culling when they leave the view.
	_chunked_multimesh(_build_conifer_mesh(), conifer_x, "tree", TREE_VIEW)
	_chunked_multimesh(_build_broadleaf_mesh(), broadleaf_x, "tree", TREE_VIEW)
	for pos in colliders:
		_tree_collider(pos)

## Assign a tree to the conifer or broadleaf batch and record its transform +
## trunk collider. broadleaf_chance 0 forces a conifer (the dense pine border).
func _add_tree_at(x: float, z: float, conifer_x: Array, broadleaf_x: Array, colliders: Array, broadleaf_chance: float) -> void:
	var pos := Vector3(x, _ground_height(x, z), z)
	var yaw := _rng.randf_range(0.0, TAU)
	if _rng.randf() < broadleaf_chance:
		var sb := _rng.randf_range(0.7, 1.25)
		broadleaf_x.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(sb, sb * _rng.randf_range(0.9, 1.2), sb)), pos))
	else:
		var sc := _rng.randf_range(0.7, 1.4)
		conifer_x.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(sc, sc * _rng.randf_range(0.9, 1.3), sc)), pos))
	colliders.append(pos)

## Bucket instances into a CHUNK_DIV x CHUNK_DIV grid of MultiMeshInstances so
## chunks behind/around the camera frustum-cull away (vital on a big map).
## tint: "none" | "grass" | "tree" picks the per-instance colour scheme.
## vis_range > 0 also distance-culls the chunk (grass/detail near the player only).
func _chunked_multimesh(mesh: Mesh, xforms: Array, tint: String, vis_range: float) -> void:
	if xforms.is_empty():
		return
	var cs := (cols * cell_size) / float(CHUNK_DIV)
	var buckets := {}
	for xf in xforms:
		var o: Vector3 = xf.origin
		var key := Vector2i(clampi(int(o.x / cs), 0, CHUNK_DIV - 1), clampi(int(o.z / cs), 0, CHUNK_DIV - 1))
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(xf)
	var use_col := tint != "none"
	for key in buckets:
		var arr: Array = buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = use_col
		mm.mesh = mesh
		mm.instance_count = arr.size()
		for i in arr.size():
			mm.set_instance_transform(i, arr[i])
			if use_col:
				mm.set_instance_color(i, _tint_color(tint))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if vis_range > 0.0:
			mmi.visibility_range_end = vis_range
		add_child(mmi)

func _tint_color(kind: String) -> Color:
	if kind == "grass":
		return Color(_rng.randf_range(0.55, 1.0), _rng.randf_range(0.7, 1.0), _rng.randf_range(0.4, 0.8))
	var v := _rng.randf_range(0.72, 1.08)   # "tree"
	return Color(v * _rng.randf_range(0.85, 1.0), v, v * _rng.randf_range(0.78, 0.95))

## Invisible containment wall just inside the dense border ring — the border
## trees have only thin trunk colliders with walkable gaps, so without this you
## can squeeze through and walk off the edge of the terrain into the void.
func _build_perimeter_walls() -> void:
	var w := cols * cell_size
	var lo := 2.0
	var hi := w - 2.0
	var span := hi - lo
	var h := 12.0
	var t := 1.0
	var cy := 4.0
	var mid := (lo + hi) * 0.5
	_wall(Vector3(span, h, t), Vector3(mid, cy, lo))
	_wall(Vector3(span, h, t), Vector3(mid, cy, hi))
	_wall(Vector3(t, h, span), Vector3(lo, cy, mid))
	_wall(Vector3(t, h, span), Vector3(hi, cy, mid))

func _wall(size: Vector3, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	body.add_child(col)
	add_child(body)

## A square FRAME of mountains hugging just OUTSIDE the terrain edge — beyond the
## perimeter wall, so you can never reach them — several rows deep and taller
## further out. They overlap the edge so there's no void: look any direction off
## the map and you see a wall of peaks. Merged into ONE mesh (~2 draw calls).
func _build_mountains() -> void:
	var w := cols * cell_size
	var rock_st := SurfaceTool.new()
	rock_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var snow_st := SurfaceTool.new()
	snow_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along := 30          # peaks along each side
	var depth_rows := 3      # rows marching outward (taller & further each row)
	for side in 4:
		for i in along:
			# Overshoot the corners (-14 .. w+14) so adjacent sides overlap there.
			var t := lerpf(-14.0, w + 14.0, (float(i) + _rng.randf_range(0.15, 0.85)) / float(along))
			for row in depth_rows:
				var depth := 6.0 + row * 26.0 + _rng.randf_range(0.0, 10.0)   # metres beyond the edge
				var h := _rng.randf_range(34.0, 56.0) + row * 18.0
				var br := _rng.randf_range(24.0, 40.0) + row * 7.0
				var px := 0.0
				var pz := 0.0
				match side:
					0:
						px = t
						pz = -depth          # south edge (z < 0)
					1:
						px = t
						pz = w + depth       # north edge
					2:
						px = -depth          # west edge
						pz = t
					_:
						px = w + depth       # east edge
						pz = t
				_append_mountain(rock_st, snow_st, px, pz, h, br)

	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.1, 0.11, 0.15)
	rock_mat.roughness = 1.0
	var snow_mat := StandardMaterial3D.new()
	snow_mat.albedo_color = Color(0.58, 0.62, 0.72)
	snow_mat.roughness = 0.9

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rock_st.commit_to_arrays())
	mesh.surface_set_material(0, rock_mat)
	var snow_arrays := snow_st.commit_to_arrays()
	if not (snow_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, snow_arrays)
		mesh.surface_set_material(1, snow_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _append_mountain(rock_st: SurfaceTool, snow_st: SurfaceTool, px: float, pz: float, h: float, br: float) -> void:
	var yaw := _rng.randf_range(0.0, TAU)
	var ybase := -18.0     # buried base so peaks rise cleanly with no floating gap
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = br
	cone.height = h
	cone.radial_segments = _rng.randi_range(5, 7)
	rock_st.append_from(cone, 0, Transform3D(Basis(Vector3.UP, yaw), Vector3(px, ybase + h * 0.5, pz)))
	if h > 52.0:
		var cap := CylinderMesh.new()
		cap.top_radius = 0.0
		cap.bottom_radius = br * 0.3
		cap.height = h * 0.22
		cap.radial_segments = cone.radial_segments
		snow_st.append_from(cap, 0, Transform3D(Basis(Vector3.UP, yaw), Vector3(px, ybase + h - cap.height * 0.5, pz)))

func _tree_collider(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var col := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = 0.5            # thin trunk collider regardless of canopy scale
	sh.height = 6.0
	col.shape = sh
	col.position = Vector3(0.0, 3.0, 0.0)
	body.add_child(col)
	add_child(body)

## Water surface for the river — a strip of quads following the carved channel,
## sitting just below the banks. Translucent, smooth and faintly lit so it catches
## the moon/flashlight.
func _build_river() -> void:
	var d := rows * cell_size
	var wh := RIVER_HALF * 0.9
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 3.0
	var z := 6.0
	while z < d - 6.0:
		var z2 := z + step
		var rx0 := _river_x(z)
		var rx1 := _river_x(z2)
		var y0 := _water_y(z)
		var y1 := _water_y(z2)
		var l0 := Vector3(rx0 - wh, y0, z)
		var r0 := Vector3(rx0 + wh, y0, z)
		var l1 := Vector3(rx1 - wh, y1, z2)
		var r1 := Vector3(rx1 + wh, y1, z2)
		st.add_vertex(l0); st.add_vertex(r1); st.add_vertex(l1)
		st.add_vertex(l0); st.add_vertex(r0); st.add_vertex(r1)
		z = z2
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.09, 0.13, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic = 0.35
	mat.emission_enabled = true
	mat.emission = Color(0.03, 0.06, 0.1)
	mat.emission_energy_multiplier = 0.5
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _water_y(z: float) -> float:
	return _ground_height(_river_x(z), z) + RIVER_DEPTH * 0.55

## Real-tree billboard: two crossed quads textured with a photo-scanned tree
## impostor (alpha-scissor cutout), GPU-instanced so the whole forest is ~one
## draw call yet looks like real trees instead of primitives.
func _build_impostor_tree_mesh() -> ArrayMesh:
	var w := 4.21
	var hgt := 3.41
	var mat := StandardMaterial3D.new()
	var tex := _load_tex("res://textures/tree1_impostor.png")
	if tex:
		mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.6, 0.64, 0.58)   # slight dark night tint
	mat.roughness = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var q := QuadMesh.new()
	q.size = Vector2(w, hgt)
	st.append_from(q, 0, Transform3D(Basis(), Vector3(0.0, hgt * 0.5, 0.0)))
	st.append_from(q, 0, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.0, hgt * 0.5, 0.0)))
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)
	return mesh

## A layered conifer as one 2-surface mesh (trunk=bark, foliage=leaves) so the
## whole forest renders via MultiMesh in a couple of draw calls. Many drooping
## cone skirts give a full, three-dimensional canopy instead of one flat cone.
func _build_conifer_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var ts := SurfaceTool.new()
	ts.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.10
	trunk.bottom_radius = 0.24
	trunk.height = 3.4
	trunk.radial_segments = 8
	ts.append_from(trunk, 0, Transform3D(Basis(), Vector3(0.0, 1.7, 0.0)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ts.commit_to_arrays())
	mesh.surface_set_material(0, _mat_bark)

	var fs := SurfaceTool.new()
	fs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var layers := 9
	for i in layers:
		var f := float(i) / float(layers - 1)
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = lerpf(2.5, 0.35, f)
		cone.height = 1.5
		cone.radial_segments = 10
		fs.append_from(cone, 0, Transform3D(Basis(), Vector3(0.0, 2.4 + i * 0.62, 0.0)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fs.commit_to_arrays())
	mesh.surface_set_material(1, _mat_foliage)
	return mesh

## A broadleaf as one 2-surface mesh: taller trunk + a rounded cluster crown.
func _build_broadleaf_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var ts := SurfaceTool.new()
	ts.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.14
	trunk.bottom_radius = 0.26
	trunk.height = 4.2
	trunk.radial_segments = 8
	ts.append_from(trunk, 0, Transform3D(Basis(), Vector3(0.0, 2.1, 0.0)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ts.commit_to_arrays())
	mesh.surface_set_material(0, _mat_bark)

	var fs := SurfaceTool.new()
	fs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var blobs := [
		[Vector3(0.0, 5.2, 0.0), 2.0],
		[Vector3(1.2, 4.6, 0.4), 1.4],
		[Vector3(-1.0, 4.7, -0.6), 1.4],
		[Vector3(0.3, 5.9, -0.8), 1.2],
		[Vector3(-0.5, 5.6, 0.9), 1.3],
	]
	for b in blobs:
		var sm := SphereMesh.new()
		sm.radius = b[1]
		sm.height = float(b[1]) * 1.9
		sm.radial_segments = 8
		sm.rings = 4
		fs.append_from(sm, 0, Transform3D(Basis(), b[0]))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fs.commit_to_arrays())
	mesh.surface_set_material(1, _mat_foliage)
	return mesh

## Pure-visual ground clutter for density — bushes + fallen logs. No collision
## and no grid blocking, so they never trap the player or fragment pathfinding.
func _scatter_decoration() -> void:
	# A palette of shared bush materials so bushes vary in colour (deep green,
	# olive, dusty) instead of one flat near-black.
	var bush_mats: Array[StandardMaterial3D] = []
	for c in [Color(0.06, 0.11, 0.05), Color(0.1, 0.13, 0.06), Color(0.09, 0.1, 0.045), Color(0.12, 0.115, 0.06)]:
		var bm := StandardMaterial3D.new()
		bm.albedo_color = c
		bm.roughness = 1.0
		bush_mats.append(bm)

	var w := cols * cell_size
	var d := rows * cell_size
	for _i in bush_count:
		var bx := _rng.randf_range(2.0, w - 2.0)
		var bz := _rng.randf_range(2.0, d - 2.0)
		_place_bush(Vector3(bx, _ground_height(bx, bz), bz), bush_mats[_rng.randi() % bush_mats.size()])

	# Extra ground variety: mushroom clusters + scattered pebbles.
	_scatter_mushrooms()
	_scatter_pebbles()

func _place_bush(pos: Vector3, mat: Material) -> void:
	var clumps := _rng.randi_range(1, 4)
	for _i in clumps:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := _rng.randf_range(0.35, 1.0)
		sm.radius = r
		sm.height = r * _rng.randf_range(0.7, 1.4)   # some flat & sprawling, some round
		sm.radial_segments = 8
		sm.rings = 4
		mi.mesh = sm
		mi.material_override = mat
		mi.position = pos + Vector3(_rng.randf_range(-0.7, 0.7), sm.height * 0.4, _rng.randf_range(-0.7, 0.7))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

## Mushroom clusters in three species — red-cap, brown, and a pale glowing kind
## that gives the woods an eerie bioluminescent flicker. Each species is one
## GPU-instanced batch (2-surface mesh: pale stem + coloured cap).
func _scatter_mushrooms() -> void:
	var species := [
		{"cap": Color(0.5, 0.08, 0.07), "glow": 0.0},   # fly-agaric red
		{"cap": Color(0.32, 0.21, 0.12), "glow": 0.0},  # earthy brown
		{"cap": Color(0.35, 0.55, 0.62), "glow": 1.6},  # pale glowing
	]
	var w := cols * cell_size
	var d := rows * cell_size
	for sp in species:
		var mesh := _build_mushroom_mesh(sp["cap"], sp["glow"])
		var xf := []
		for _c in 34:
			var cx := _rng.randf_range(4.0, w - 4.0)
			var cz := _rng.randf_range(4.0, d - 4.0)
			for _m in _rng.randi_range(2, 5):
				var mx := cx + _rng.randf_range(-0.6, 0.6)
				var mz := cz + _rng.randf_range(-0.6, 0.6)
				var s := _rng.randf_range(0.7, 1.6)
				xf.append(Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(s, s, s)), Vector3(mx, _ground_height(mx, mz), mz)))
		_chunked_multimesh(mesh, xf, "none", GRASS_VIEW)

func _build_mushroom_mesh(cap_color: Color, glow: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var stem_mat := StandardMaterial3D.new()
	stem_mat.albedo_color = Color(0.82, 0.79, 0.7)
	stem_mat.roughness = 1.0
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = cap_color
	cap_mat.roughness = 0.85
	if glow > 0.0:
		cap_mat.emission_enabled = true
		cap_mat.emission = cap_color
		cap_mat.emission_energy_multiplier = glow
	var ss := SurfaceTool.new()
	ss.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem := CylinderMesh.new()
	stem.top_radius = 0.03
	stem.bottom_radius = 0.045
	stem.height = 0.16
	stem.radial_segments = 6
	ss.append_from(stem, 0, Transform3D(Basis(), Vector3(0.0, 0.08, 0.0)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ss.commit_to_arrays())
	mesh.surface_set_material(0, stem_mat)
	var cs := SurfaceTool.new()
	cs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cap := SphereMesh.new()
	cap.radius = 0.09
	cap.height = 0.1
	cap.radial_segments = 8
	cap.rings = 4
	cs.append_from(cap, 0, Transform3D(Basis(), Vector3(0.0, 0.17, 0.0)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cs.commit_to_arrays())
	mesh.surface_set_material(1, cap_mat)
	return mesh

## Small dark pebbles scattered in clusters — low rock detail to vary the floor.
func _scatter_pebbles() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.2, 0.22)
	mat.roughness = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.24
	sm.radial_segments = 6
	sm.rings = 3
	st.append_from(sm, 0, Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)

	var w := cols * cell_size
	var d := rows * cell_size
	var xf := []
	for _c in 90:
		var cx := _rng.randf_range(4.0, w - 4.0)
		var cz := _rng.randf_range(4.0, d - 4.0)
		for _p in _rng.randi_range(2, 5):
			var px := cx + _rng.randf_range(-0.9, 0.9)
			var pz := cz + _rng.randf_range(-0.9, 0.9)
			var s := _rng.randf_range(0.5, 1.5)
			xf.append(Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(s, s * 0.6, s)), Vector3(px, _ground_height(px, pz), pz)))
	_chunked_multimesh(mesh, xf, "none", GRASS_VIEW)

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

## Real CC0 Poly Haven props (loaded at runtime from models/): solid rocks that
## block navigation, plus visual-only fallen logs, ferns and branches. Each is
## loaded once into a template, then cheap duplicates are scattered.
func _scatter_props() -> void:
	var rocks := _templates(["boulder_01/boulder_01_1k.gltf", "rock_01/rock_01_1k.gltf"])
	var logs := _templates(["dead_tree_trunk/dead_tree_trunk_1k.gltf", "dead_tree_trunk_02/dead_tree_trunk_02_1k.gltf"])
	var ferns := _templates(["fern_02/fern_02_1k.gltf"])
	var branches := _templates(["dry_branches_medium_01/dry_branches_medium_01_1k.gltf"])

	# The photoscan rocks ship a bright clean granite that pops out of the dark
	# woods — knock them down to a dark mossy grey-green (keeps the texture detail,
	# just darkens it) so they sit in the forest instead of glowing.
	for r in rocks:
		_tint_meshes(r, Color(0.34, 0.4, 0.34))

	# Rocks: solid obstacles → block the cell + a simple collider. Wide size range
	# (small stones to big boulders) and partially sunk into the ground.
	if not rocks.is_empty():
		var placed := 0
		var tries := 0
		while placed < 46 and tries < 700:
			tries += 1
			var cell := Vector2i(_rng.randi_range(2, cols - 3), _rng.randi_range(2, rows - 3))
			if _blocked.has(cell):
				continue
			if Vector2(cell.x - _spawn_cell.x, cell.y - _spawn_cell.y).length() < 4.0:
				continue
			_block(cell)
			var base := cell_to_world(cell)
			var s := _rng.randf_range(0.5, 2.2)
			var body := StaticBody3D.new()
			body.position = Vector3(base.x, _ground_height(base.x, base.z) - 0.18 * s, base.z)  # sink in
			body.rotation = Vector3(_rng.randf_range(-0.2, 0.2), _rng.randf_range(0.0, TAU), _rng.randf_range(-0.2, 0.2))
			var vis: Node3D = rocks[_rng.randi() % rocks.size()].duplicate()
			vis.scale = Vector3(s, s, s)
			_no_shadow(vis)
			body.add_child(vis)
			var col := CollisionShape3D.new()
			var sh := SphereShape3D.new()
			sh.radius = 0.8 * s
			col.shape = sh
			col.position = Vector3(0.0, 0.6 * s, 0.0)
			body.add_child(col)
			add_child(body)
			placed += 1

	# Visual-only ground clutter (no collision / no grid block) — scaled for the big map.
	_scatter_visual(logs, 55, 0.9, 1.6)
	_scatter_visual(ferns, 190, 0.6, 1.7)
	_scatter_visual(branches, 95, 0.8, 1.7)

	for t in rocks + logs + ferns + branches:
		t.free()   # templates done — duplicates own their own copies

func _templates(paths: Array) -> Array:
	var out := []
	for p in paths:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file("res://models/" + p, st) == OK:
			out.append(doc.generate_scene(st))
	return out

func _scatter_visual(templates: Array, count: int, smin: float, smax: float) -> void:
	if templates.is_empty():
		return
	var w := cols * cell_size
	var d := rows * cell_size
	for _i in count:
		var inst: Node3D = templates[_rng.randi() % templates.size()].duplicate()
		var px := _rng.randf_range(2.0, w - 2.0)
		var pz := _rng.randf_range(2.0, d - 2.0)
		inst.position = Vector3(px, _ground_height(px, pz), pz)
		inst.rotation.y = _rng.randf_range(0.0, TAU)
		var s := _rng.randf_range(smin, smax)
		inst.scale = Vector3(s, s, s)
		_no_shadow(inst)
		add_child(inst)

func _no_shadow(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_no_shadow(c)

## Multiply every mesh material's albedo by a tint (darken/recolour a loaded
## model in place) while keeping its texture detail.
func _tint_meshes(n: Node, tint: Color) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var mi := n as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			if m is BaseMaterial3D:
				(m as BaseMaterial3D).albedo_color = tint
	for c in n.get_children():
		_tint_meshes(c, tint)

## A dark wooden cabin behind the spawn — your starting landmark. Its door faces
## the player (who spawns just outside it, looking into the woods). Footprint
## cells are blocked so the entity pathfinds around it.
func _build_cabin() -> void:
	var spawn_world := cell_to_world(_spawn_cell)
	var centre_world := cell_to_world(Vector2i(cols / 2, rows / 2))
	var outward := spawn_world - centre_world
	outward.y = 0.0
	outward = outward.normalized() if outward.length() > 0.1 else Vector3(0, 0, -1)
	var cabin_pos := spawn_world + outward * 5.5
	cabin_pos.y = _ground_height(cabin_pos.x, cabin_pos.z)

	var wood: Material = _mat_cabin   # real wood-plank PBR
	var roof_mat := StandardMaterial3D.new()
	roof_mat.albedo_color = Color(0.05, 0.045, 0.045)
	roof_mat.roughness = 1.0

	var cabin := StaticBody3D.new()
	cabin.position = cabin_pos
	cabin.rotation.y = atan2(-outward.x, -outward.z)   # front (+Z) faces the player
	add_child(cabin)

	var hw := 2.4   # half width (x)
	var hd := 2.1   # half depth (z)
	var wh := 2.6   # wall height
	var t := 0.2
	# Back wall + two side walls
	_sbox(cabin, Vector3(hw * 2.0, wh, t), Vector3(0.0, wh * 0.5, -hd), wood)
	_sbox(cabin, Vector3(t, wh, hd * 2.0), Vector3(-hw, wh * 0.5, 0.0), wood)
	_sbox(cabin, Vector3(t, wh, hd * 2.0), Vector3(hw, wh * 0.5, 0.0), wood)
	# Front wall with a doorway gap (1.2 wide)
	var seg := (hw * 2.0 - 1.2) * 0.5
	_sbox(cabin, Vector3(seg, wh, t), Vector3(-(0.6 + seg * 0.5), wh * 0.5, hd), wood)
	_sbox(cabin, Vector3(seg, wh, t), Vector3(0.6 + seg * 0.5, wh * 0.5, hd), wood)
	_sbox(cabin, Vector3(1.2, wh - 2.1, t), Vector3(0.0, wh - (wh - 2.1) * 0.5, hd), wood)  # lintel
	# Pitched gable roof — a triangular prism whose ridge runs front-to-back, so a
	# pointed gable faces the player. Solid (no gaps), overhanging the walls.
	var ridge_h := 1.6
	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(hw * 2.0 + 0.7, ridge_h, hd * 2.0 + 0.7)
	roof.mesh = prism
	roof.material_override = roof_mat
	roof.position = Vector3(0.0, wh + ridge_h * 0.5, 0.0)
	# PrismMesh already points its apex up (+Y) and extrudes along Z, so the ridge
	# runs front-to-back and a pointed gable faces the player — no rotation needed.
	cabin.add_child(roof)

	# A warm lantern by the door — a beacon to find your way back to base through
	# the fog. Flickers in _process via _lantern.
	var lantern_mat := StandardMaterial3D.new()
	lantern_mat.albedo_color = Color(0.95, 0.65, 0.3)
	lantern_mat.emission_enabled = true
	lantern_mat.emission = Color(1.0, 0.72, 0.36)
	lantern_mat.emission_energy_multiplier = 6.0
	var lant := MeshInstance3D.new()
	var lbox := BoxMesh.new()
	lbox.size = Vector3(0.2, 0.32, 0.2)
	lant.mesh = lbox
	lant.material_override = lantern_mat
	lant.position = Vector3(hw - 0.28, 1.95, hd + 0.14)
	lant.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cabin.add_child(lant)
	_lantern = OmniLight3D.new()
	_lantern.position = Vector3(hw - 0.28, 1.98, hd + 0.35)
	_lantern.light_color = Color(1.0, 0.73, 0.4)
	_lantern.light_energy = 2.6
	_lantern.omni_range = 11.0
	_lantern.shadow_enabled = false
	cabin.add_child(_lantern)

	# Block the footprint for navigation
	for x in cols:
		for z in rows:
			var wc := cell_to_world(Vector2i(x, z))
			if Vector2(wc.x - cabin_pos.x, wc.z - cabin_pos.z).length() < 3.4:
				_block(Vector2i(x, z))

func _sbox(body: StaticBody3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	col.position = pos
	body.add_child(col)

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
	spawn.y = _ground_height(spawn.x, spawn.z) + 1.0
	player.global_position = spawn
	# Face into the woods (toward the map centre).
	var centre := cell_to_world(Vector2i(cols / 2, rows / 2))
	player.look_at(Vector3(centre.x, spawn.y, centre.z), Vector3.UP)

func _spawn_parts() -> void:
	var cells := _pick_cells(part_count, _spawn_cell)
	_total = cells.size()
	_found = 0
	for i in cells.size():
		var part := PICKUP_SCENE.instantiate()
		part.recharges = false                 # parts don't refill the torch
		part.counts_as_objective = true        # in "pickup" group so the entity lurks near them
		part.must_carry = true                 # pick up + carry to the car to install
		part.part_name = PART_NAMES[i % PART_NAMES.size()]
		part.glow_color = Color(1.0, 0.55, 0.2) # warm amber so parts read apart from batteries
		var pos := cell_to_world(cells[i])
		pos.y = _ground_height(pos.x, pos.z) + 1.1
		part.position = pos
		add_child(part)

func _spawn_batteries() -> void:
	var cells := _pick_cells(battery_count, _spawn_cell)
	for cell in cells:
		var bat := PICKUP_SCENE.instantiate()
		bat.recharges = true
		bat.counts_as_objective = false
		bat.glow_color = Color(0.4, 0.85, 1.0) # cold blue battery cans
		var pos := cell_to_world(cell)
		pos.y = _ground_height(pos.x, pos.z) + 1.0
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
	pos.y = _ground_height(pos.x, pos.z) + 0.5
	_monster.position = pos
	_monster.caught.connect(_on_player_caught)
	_monster.spotted.connect(_on_spotted)
	add_child(_monster)
	# Forest tuning: persistent enough to be scary, but escapable. Breaking line of
	# sight and putting trees between you lets it lose you in ~7s, and it never
	# outruns your sprint (no chase-speed bonus) — so a clean dash gets away.
	_monster.hear_radius = maxf(_monster.hear_radius, 6.5)
	_monster.give_up_time = maxf(_monster.give_up_time, 7.0)
	_monster.sight_range = maxf(_monster.sight_range, 24.0)

func _spawn_car() -> void:
	_car = CAR_SCRIPT.new()
	var pos := cell_to_world(_far_reachable_cell(_spawn_cell))
	pos.y = _ground_height(pos.x, pos.z)
	_car.position = pos
	_car.escaped.connect(_on_escaped)
	_car.part_installed.connect(_on_part_installed)
	add_child(_car)

# --- Objectives -------------------------------------------------------------

func _on_part_installed(_part_name: String) -> void:
	_found += 1
	_update_objectives_hud()
	if _audio:
		_audio.play_blip()
	_flash(Color(0.3, 0.5, 0.2, 0.18), 0.4)   # brief green confirm
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
	_post_mat = mat
	layer.add_child(rect)

# --- Per-frame: monster audio/rumble + escape beacon ------------------------

func _process(delta: float) -> void:
	_spot_cooldown = maxf(0.0, _spot_cooldown - delta)
	_time += delta
	if _lantern:
		_lantern.light_energy = 2.4 + sin(_time * 6.3) * 0.16 + _rng.randf_range(-0.14, 0.14)
	var target_dread := 0.0
	if _monster and _player and not _game_over:
		var dd := _monster.global_position.distance_to(_player.global_position)
		var chasing: bool = _monster.is_chasing()
		if _audio:
			_audio.update(dd, chasing, delta)
		if chasing and dd < 7.0 and _player.has_method("add_shake"):
			_player.add_shake((7.0 - dd) / 7.0 * 0.6 * delta)
		# Dread rises as it nears, harder while it's actively hunting.
		var prox := clampf(1.0 - dd / 14.0, 0.0, 1.0)
		target_dread = (0.25 + prox * 0.75) if chasing else prox * 0.6
	if _post_mat:
		_dread = lerpf(_dread, target_dread, clampf(delta * 3.0, 0.0, 1.0))
		_post_mat.set_shader_parameter("dread", _dread)
	if _car_ready and _car and _player and _obj_label and not _game_over:
		var cd := _player.global_position.distance_to(_car.global_position)
		_obj_label.text = "CAR REPAIRED  —  GET TO IT  —  %dm" % int(cd)
	elif _obj_label and _player and _car and not _game_over:
		if _player.has_method("is_carrying") and _player.is_carrying():
			var cd2 := int(_player.global_position.distance_to(_car.global_position))
			_obj_label.text = "Carrying %s — to the car: %dm (press E)   [%d/%d]" % [_player.get_carried(), cd2, _found, _total]
		else:
			_obj_label.text = "Find a car part: %d / %d installed" % [_found, _total]

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
