extends Area3D
## The dead car in the woods. Inert until every part is found; activate() then
## turns the headlights + engine on and reaching it wins the game. Built from
## primitives for now (reads as a car silhouette in the fog); a CC0 model can be
## dropped in later by replacing _build().

signal escaped
signal part_installed(part_name)

var active := false
var _player: Node = null               # player while inside the install/escape trigger
var _headlights: Array[OmniLight3D] = []
var _lens_mat: StandardMaterial3D

func _ready() -> void:
	add_to_group("car")
	_build()
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _build() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.16, 0.07, 0.08)   # dark rusted red
	body_mat.metallic = 0.55
	body_mat.roughness = 0.55

	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.04, 0.05, 0.06)
	glass_mat.metallic = 0.3
	glass_mat.roughness = 0.15

	var tire_mat := StandardMaterial3D.new()
	tire_mat.albedo_color = Color(0.04, 0.04, 0.045)
	tire_mat.roughness = 0.9

	# Chassis + cabin
	_box(Vector3(2.0, 0.7, 4.3), Vector3(0.0, 0.65, 0.0), body_mat)
	_box(Vector3(1.8, 0.75, 2.1), Vector3(0.0, 1.3, -0.25), body_mat)
	# Windows (a dark band on the cabin)
	_box(Vector3(1.82, 0.5, 1.7), Vector3(0.0, 1.45, -0.25), glass_mat)
	# Wheels
	for sx in [-1.0, 1.0]:
		for sz in [-1.45, 1.45]:
			_cyl(0.46, 0.32, Vector3(sx * 0.98, 0.46, sz), tire_mat, true)

	# Bumpers front + rear
	_box(Vector3(2.05, 0.3, 0.3), Vector3(0.0, 0.5, 2.25), body_mat)
	_box(Vector3(2.05, 0.3, 0.3), Vector3(0.0, 0.5, -2.25), body_mat)

	# Headlight lenses + lights (off until repaired)
	_lens_mat = StandardMaterial3D.new()
	_lens_mat.albedo_color = Color(0.7, 0.68, 0.5)
	_lens_mat.emission_enabled = true
	_lens_mat.emission = Color(1.0, 0.95, 0.8)
	_lens_mat.emission_energy_multiplier = 0.0
	for sx in [-0.65, 0.65]:
		_box(Vector3(0.35, 0.28, 0.1), Vector3(sx, 0.7, 2.18), _lens_mat)
		var l := OmniLight3D.new()
		l.position = Vector3(sx, 0.7, 2.6)
		l.light_color = Color(1.0, 0.95, 0.82)
		l.omni_range = 16.0
		l.light_energy = 0.0
		l.shadow_enabled = false
		add_child(l)
		_headlights.append(l)

	# Walk-into-it trigger
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.2, 2.2, 5.2)
	col.shape = shape
	col.position = Vector3(0.0, 1.1, 0.0)
	add_child(col)

func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _cyl(radius: float, height: float, pos: Vector3, mat: Material, sideways := false) -> void:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	if sideways:
		mi.rotation_degrees = Vector3(0.0, 0.0, 90.0)  # lay the wheel on its side
	add_child(mi)

## Repaired: lights + engine come alive. The final beacon to run for.
func activate() -> void:
	active = true
	_lens_mat.emission_energy_multiplier = 8.0
	for l in _headlights:
		l.light_energy = 4.0

func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	_player = body
	if active:
		escaped.emit()       # repaired already — entering wins

func _on_body_exited(body: Node) -> void:
	if body == _player:
		_player = null

## Press E at the car (before it's repaired) to install the part in hand.
func _unhandled_input(event: InputEvent) -> void:
	if active or _player == null:
		return
	if event.is_action_pressed("interact") and _player.has_method("is_carrying") and _player.is_carrying():
		var part: String = _player.drop_carried()
		part_installed.emit(part)
