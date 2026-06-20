extends Area3D
## The escape door. Inert and dark until every objective is collected, then it
## lights up green and the player must reach it to win.

signal escaped

var active := false
var _sign_mat: StandardMaterial3D
var _light: OmniLight3D

func _ready() -> void:
	add_to_group("exit")
	_build()
	body_entered.connect(_on_body_entered)

func _build() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.06, 0.06, 0.07)
	frame_mat.roughness = 0.8

	# Door frame: two posts + a lintel, plus a dark slab so it reads as a doorway
	_box(Vector3(0.25, 2.6, 0.4), Vector3(-0.95, 1.3, 0.0), frame_mat)
	_box(Vector3(0.25, 2.6, 0.4), Vector3(0.95, 1.3, 0.0), frame_mat)
	_box(Vector3(2.15, 0.3, 0.4), Vector3(0.0, 2.75, 0.0), frame_mat)
	_box(Vector3(1.7, 2.5, 0.08), Vector3(0.0, 1.3, 0.16), frame_mat)

	# EXIT sign — emissive, starts switched off
	_sign_mat = StandardMaterial3D.new()
	_sign_mat.albedo_color = Color(0.1, 0.5, 0.2)
	_sign_mat.emission_enabled = true
	_sign_mat.emission = Color(0.25, 1.0, 0.45)
	_sign_mat.emission_energy_multiplier = 0.0
	_box(Vector3(1.4, 0.45, 0.12), Vector3(0.0, 3.15, 0.0), _sign_mat)

	# Green light, off until activated
	_light = OmniLight3D.new()
	_light.position = Vector3(0.0, 2.2, 1.0)
	_light.light_color = Color(0.3, 1.0, 0.5)
	_light.omni_range = 9.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)

	# Trigger volume in the doorway (no solid collision — you walk through it)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.7, 2.4, 1.3)
	col.shape = shape
	col.position = Vector3(0.0, 1.3, 0.0)
	add_child(col)

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi

func activate() -> void:
	active = true
	_sign_mat.emission_energy_multiplier = 6.0
	_light.light_energy = 2.5

func _on_body_entered(body: Node) -> void:
	if active and body.is_in_group("player"):
		escaped.emit()
