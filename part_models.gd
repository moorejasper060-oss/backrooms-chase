## Shared builders for car-part / item models, used by BOTH the held viewmodel
## (player.gd) and the world pickups (pickup.gd) so they always match.
## Preloaded (not class_name) so it resolves in headless/script runs too.

## Build a small model node for a named part. Unknown names → a generic crate.
static func build(part: String) -> Node3D:
	var root := Node3D.new()
	match part:
		"Battery":
			root.add_child(_box(Vector3(0.22, 0.16, 0.14), Vector3.ZERO, _mat(Color(0.05, 0.05, 0.07), 0.5)))
			root.add_child(_box(Vector3(0.04, 0.05, 0.04), Vector3(-0.06, 0.1, 0.0), _mat(Color(0.5, 0.06, 0.05), 0.4, 0.4)))
			root.add_child(_box(Vector3(0.04, 0.05, 0.04), Vector3(0.06, 0.1, 0.0), _mat(Color(0.1, 0.1, 0.12), 0.4, 0.4)))
		"Spark Plugs":
			var steel := _mat(Color(0.62, 0.62, 0.64), 0.3, 0.7)
			var ceramic := _mat(Color(0.85, 0.83, 0.78), 0.5)
			for i in 4:
				var x := (float(i) - 1.5) * 0.045
				root.add_child(_cyl(0.012, 0.16, Vector3(x, 0.0, 0.0), ceramic))
				root.add_child(_cyl(0.017, 0.06, Vector3(x, -0.08, 0.0), steel))
		"Fuel Can":
			var red := _mat(Color(0.45, 0.07, 0.05), 0.5)
			root.add_child(_box(Vector3(0.2, 0.24, 0.12), Vector3.ZERO, red))
			root.add_child(_cyl(0.02, 0.1, Vector3(0.08, 0.17, 0.0), red))
		"Front Tire":
			var tire := _cyl(0.16, 0.09, Vector3.ZERO, _mat(Color(0.04, 0.04, 0.05), 0.9))
			tire.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			root.add_child(tire)
			var hub := _cyl(0.06, 0.1, Vector3.ZERO, _mat(Color(0.5, 0.5, 0.53), 0.4, 0.6))
			hub.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			root.add_child(hub)
		"Ignition Coil":
			var blk := _mat(Color(0.08, 0.08, 0.1), 0.5)
			root.add_child(_box(Vector3(0.1, 0.14, 0.1), Vector3.ZERO, blk))
			root.add_child(_cyl(0.02, 0.06, Vector3(0.0, 0.1, 0.0), _mat(Color(0.5, 0.45, 0.2), 0.5, 0.5)))
		"Radiator Hose":
			var rub := _mat(Color(0.06, 0.06, 0.08), 0.85)
			var c1 := _cyl(0.025, 0.15, Vector3(-0.05, 0.0, 0.0), rub)
			c1.rotation_degrees = Vector3(0.0, 0.0, 38.0)
			root.add_child(c1)
			var c2 := _cyl(0.025, 0.15, Vector3(0.05, 0.02, 0.0), rub)
			c2.rotation_degrees = Vector3(0.0, 0.0, -38.0)
			root.add_child(c2)
		_:
			root.add_child(_box(Vector3(0.16, 0.16, 0.16), Vector3.ZERO, _mat(Color(0.4, 0.4, 0.4), 0.5)))
	return root

static func _mat(color: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m

static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	return mi

static func _cyl(radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	return mi
