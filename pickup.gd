extends Area3D
## A glowing collectible. Spins and bobs so it catches the eye in the fog,
## and reports back when the player walks into it.

signal collected

@export var glow_color := Color(0.45, 1.0, 0.65)
@export var spin_speed := 1.5
@export var bob_height := 0.12
@export var bob_speed := 2.2
# Forest additions (defaults preserve the Backrooms level's behaviour exactly):
# a Backrooms orb both refills the flashlight AND counts as an objective.
@export var recharges := true            # refill flashlight battery on pickup
@export var counts_as_objective := true  # tick the objective/part counter
@export var part_name := ""              # car-part label shown in the HUD

@onready var mesh: MeshInstance3D = $Mesh
@onready var light: OmniLight3D = $Light

var _base_y := 0.0
var _t := 0.0

func _ready() -> void:
	# Objectives (Backrooms orbs + forest car-parts) live in "pickup" so the
	# monster lurks near them; pure battery cans live in "battery".
	add_to_group("pickup" if counts_as_objective else "battery")
	_base_y = position.y

	var mat := StandardMaterial3D.new()
	mat.albedo_color = glow_color
	mat.emission_enabled = true
	mat.emission = glow_color
	mat.emission_energy_multiplier = 2.5
	mesh.material_override = mat
	light.light_color = glow_color

	body_entered.connect(_on_body_entered)

func _process(delta: float) -> void:
	_t += delta
	rotate_y(spin_speed * delta)
	position.y = _base_y + sin(_t * bob_speed) * bob_height

func _on_body_entered(body: Node) -> void:
	# Only the player collects (the monster, also a CharacterBody3D, won't).
	if body.is_in_group("player"):
		if recharges and body.has_method("collect_pickup"):
			body.collect_pickup()
		collected.emit()
		queue_free()
