@tool
extends MeshInstance3D
## Draws a shape's outline: the domain of a [WaterSim] or the region of a
## [WaterSimVolume], in the editor (and in game when asked). Made by those nodes as an
## internal child; not saved with the scene.

const SEGMENTS := 24


func _init() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = false
	material_override = material
	mesh = ImmediateMesh.new()


## shape: a [enum WaterSim.Shape]. size: full size for a box; radius in x and height in y
## for the round ones. offset: where the shape's centre is.
func draw(shape: int, size: Vector3, color: Color, offset := Vector3.ZERO) -> void:
	var lines := mesh as ImmediateMesh
	lines.clear_surfaces()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	lines.surface_set_color(color)
	match shape:
		WaterSim.Shape.SPHERE:
			var r := size.x
			_circle(lines, offset, Vector3.RIGHT * r, Vector3.FORWARD * r)
			_circle(lines, offset, Vector3.RIGHT * r, Vector3.UP * r)
			_circle(lines, offset, Vector3.FORWARD * r, Vector3.UP * r)
		WaterSim.Shape.CAPSULE, WaterSim.Shape.CYLINDER:
			var r := size.x
			var half := size.y * 0.5
			if shape == WaterSim.Shape.CAPSULE:
				half = maxf(half - r, 0.0)
			for y in [-half, half]:
				_circle(lines, offset + Vector3(0, y, 0), Vector3.RIGHT * r, Vector3.FORWARD * r)
			for side in [Vector3.RIGHT * r, Vector3.LEFT * r, Vector3.FORWARD * r, Vector3.BACK * r]:
				lines.surface_add_vertex(offset + side + Vector3(0, -half, 0))
				lines.surface_add_vertex(offset + side + Vector3(0, half, 0))
			if shape == WaterSim.Shape.CAPSULE:
				for y in [-1.0, 1.0]:
					var cap := offset + Vector3(0, half * y, 0)
					_arc(lines, cap, Vector3.RIGHT * r, Vector3.UP * r * y)
					_arc(lines, cap, Vector3.FORWARD * r, Vector3.UP * r * y)
		_:
			var h := size * 0.5
			for a in 3:
				var u := (a + 1) % 3
				var v := (a + 2) % 3
				for corner in 4:
					var p := Vector3()
					p[u] = h[u] if corner & 1 else -h[u]
					p[v] = h[v] if corner & 2 else -h[v]
					p[a] = -h[a]
					var q := p
					q[a] = h[a]
					lines.surface_add_vertex(offset + p)
					lines.surface_add_vertex(offset + q)
	lines.surface_end()


func _circle(lines: ImmediateMesh, centre: Vector3, a: Vector3, b: Vector3) -> void:
	for i in SEGMENTS:
		var t0 := TAU * i / SEGMENTS
		var t1 := TAU * (i + 1) / SEGMENTS
		lines.surface_add_vertex(centre + a * cos(t0) + b * sin(t0))
		lines.surface_add_vertex(centre + a * cos(t1) + b * sin(t1))


# Half circle from -a to a through b.
func _arc(lines: ImmediateMesh, centre: Vector3, a: Vector3, b: Vector3) -> void:
	for i in SEGMENTS / 2:
		var t0 := PI * i / (SEGMENTS / 2)
		var t1 := PI * (i + 1) / (SEGMENTS / 2)
		lines.surface_add_vertex(centre + a * cos(t0) + b * sin(t0))
		lines.surface_add_vertex(centre + a * cos(t1) + b * sin(t1))
