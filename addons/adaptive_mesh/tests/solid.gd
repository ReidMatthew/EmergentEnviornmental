extends "test_suite.gd"
## Solid and the shapes on their own: building from meshes, welding, closedness,
## transforms, drawing.


func run() -> void:
	_test_from_mesh()
	_test_box_shape()
	_test_sphere_shape()
	_test_mirror_keeps_outward()
	_test_build_surfaces()
	_test_edge_length()
	_test_swept()
	_test_repair()


func _test_from_mesh() -> void:
	print("solid from a mesh")
	var plain := BoxMesh.new()
	var solid := Solid.from_mesh(plain)
	_check(solid.get_triangle_count() == 12, "box: %d triangles" % solid.get_triangle_count())
	_check(solid.count_open_edges() == 0, "box with UV seams comes out closed")
	_check(solid.uvs.size() == solid.positions.size(), "UVs kept, one per vertex")
	var two := ArrayMesh.new()
	for s in 2:
		var arrays := plain.surface_get_arrays(0)
		var shifted: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in shifted.size():
			shifted[i] += Vector3(s * 3, 0, 0)
		arrays[Mesh.ARRAY_VERTEX] = shifted
		two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tagged := Solid.from_mesh(two, 4)
	_check(_count_tag(tagged, 4) == 12 and _count_tag(tagged, 5) == 12, "surface s gets tag first_tag + s")


func _test_box_shape() -> void:
	print("box shape")
	# SolidBox scales a unit box instead of making a BoxMesh each time: the same solid, to
	# within rounding (corners exactly +-size / 2).
	var same := true
	for size: Vector3 in [Vector3.ONE, Vector3(3, 0.01, 7.5), Vector3(0.123, 45.6, 0.0789), Vector3(1e-3, 1e3, 2)]:
		var shape := SolidBox.new()
		shape.size = size
		shape.tag = 3
		var box := BoxMesh.new()
		box.size = size
		var made := Solid.from_mesh(box)
		made.tags.fill(3)
		var solid := shape.get_solid()
		same = same and solid.indices == made.indices and solid.tags == made.tags and solid.uvs == made.uvs 				and solid.positions.size() == made.positions.size()
		for i in mini(solid.positions.size(), made.positions.size()):
			var off := (solid.positions[i] - made.positions[i]).abs()
			var limit := size.abs() * 1e-6
			same = same and off.x <= limit.x and off.y <= limit.y and off.z <= limit.z 					and solid.positions[i].abs() == size.abs() * 0.5
	_check(same, "SolidBox is the solid of a BoxMesh that size, corners at exactly half its size")


func _test_sphere_shape() -> void:
	print("icosphere shape")
	for subdivisions in 4:
		var solid := _sphere(2.0, subdivisions).get_solid()
		var expected := 20 * int(pow(4, subdivisions))
		var worst := 0.0
		for p in solid.positions:
			worst = maxf(worst, absf(p.length() - 2.0))
		_check(solid.get_triangle_count() == expected and solid.count_open_edges() == 0 and worst < 1e-5,
				"subdivisions %d: %d triangles, closed, on the sphere" % [subdivisions, solid.get_triangle_count()])
	var shape := _sphere(1.0, 1)
	shape.tag = 7
	_check(_count_tag(shape.get_solid(), 7) == 80, "faces get the shape's tag")
	shape.radius = 3.0
	_check(is_equal_approx(shape.get_solid().positions[0].length(), 3.0), "changing a property rebuilds the solid")
	# Winding: Godot's own normals from our triangles must point outward.
	var tool := SurfaceTool.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = shape.get_solid().positions
	arrays[Mesh.ARRAY_INDEX] = shape.get_solid().indices
	tool.create_from_arrays(arrays)
	tool.generate_normals()
	var out := tool.commit_to_arrays()
	var outward := 0
	var vertices: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = out[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		if normals[i].dot(vertices[i].normalized()) > 0.9:
			outward += 1
	_check(outward == vertices.size(), "winding matches Godot front faces (%d/%d outward)" % [outward, vertices.size()])


func _test_mirror_keeps_outward() -> void:
	print("transforms")
	var solid := _sphere(1.0, 1).get_solid()
	var mirrored := solid.transformed(Transform3D(Basis.from_scale(Vector3(-1, 2, 1)), Vector3(5, 0, 0)))
	var arrays: Array = mirrored.build_surfaces(40.0)[0][1]
	var outward := 0
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		if normals[i].dot(vertices[i] - Vector3(5, 0, 0)) > 0.0:
			outward += 1
	_check(outward == vertices.size() and mirrored.count_open_edges() == 0,
			"mirrored copy stays closed and outward (%d/%d)" % [outward, vertices.size()])
	_check(solid.positions[0] != mirrored.positions[0], "the original is untouched")


func _test_build_surfaces() -> void:
	print("drawing")
	var box := Solid.from_mesh(BoxMesh.new())
	var box_arrays: Array = box.build_surfaces(40.0)[0][1]
	_check((box_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 24,
			"box corners split at the 90 degree creases (24 vertices)")
	var sphere := _sphere(1.0, 2).get_solid()
	var sphere_arrays: Array = sphere.build_surfaces(40.0)[0][1]
	_check((sphere_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == sphere.positions.size(),
			"sphere shaded smooth (one vertex per position)")
	var mixed := Solid.from_mesh(BoxMesh.new())
	for t in 4:
		mixed.tags[t] = 3
	var surfaces := mixed.build_surfaces(40.0)
	_check(surfaces.size() == 2 and surfaces[0][0] == 0 and surfaces[1][0] == 3, "one surface per tag, sorted")
	_check(mixed.build_surfaces(40.0, PackedInt32Array([3])).size() == 1, "skipped tags aren't drawn")
	_check(mixed.get_faces(PackedInt32Array([3])).size() == 8 * 3, "skipped tags have no collision faces")


func _test_edge_length() -> void:
	print("sphere edge length")
	var sphere := _sphere(1.0, 2)
	_check(sphere.get_subdivisions() == 2, "off (0): uses subdivisions")
	sphere.edge_length = 0.3
	var levels := []
	for radius in [0.3, 1.0, 2.0, 4.0]:
		sphere.radius = radius
		levels.append(sphere.get_subdivisions())
	_check(levels == [0, 2, 3, 4], "levels follow the radius (radius 0.3, 1, 2, 4 -> %s)" % [levels])
	sphere.radius = 2.0
	var solid := sphere.get_solid()
	var total := 0.0
	for t in solid.get_triangle_count():
		total += solid.positions[solid.indices[t * 3]].distance_to(solid.positions[solid.indices[t * 3 + 1]])
	var average := total / solid.get_triangle_count()
	_check(absf(average - 0.3) < 0.08, "built with the picked level (average edge %.3f)" % average)


func _test_swept() -> void:
	print("swept shapes")
	var sphere := _sphere(1.0, 2).get_solid()
	var offset := Vector3(3, 1, -2)
	for rows in [1, 4]:
		var capsule := sphere.swept(offset, rows)
		var outward := 0
		var arrays: Array = capsule.build_surfaces(40.0)[0][1]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			# Outward from the segment's nearest point.
			var along := clampf((vertices[i]).dot(offset) / offset.length_squared(), 0.0, 1.0)
			if normals[i].dot(vertices[i] - offset * along) > 0.0:
				outward += 1
		var worst := 0.0
		for p in capsule.positions:
			var along := clampf(p.dot(offset) / offset.length_squared(), 0.0, 1.0)
			worst = maxf(worst, absf(p.distance_to(offset * along) - 1.0))
		_check(capsule.count_open_edges() == 0 and outward == vertices.size() and worst < 0.05,
				"sphere swept with %d band row(s): closed, outward, a capsule (%d triangles, worst radius error %.3f)"
				% [rows, capsule.get_triangle_count(), worst])
	var box := Solid.from_mesh(BoxMesh.new())
	var swept_box := box.swept(Vector3(2, 0.5, 0))
	_check(swept_box.count_open_edges() == 0 and swept_box.get_aabb().size.is_equal_approx(Vector3(3, 1.5, 1)),
			"box swept: closed, covers start to end")
	_check(sphere.swept(Vector3.ZERO).get_triangle_count() == sphere.get_triangle_count(), "zero offset: the shape itself")


func _test_repair() -> void:
	print("repairing an imported sheet")
	# A 4 x 4 grid sheet facing up, split into two pieces whose shared border is a little
	# apart, like a terrain exported one material per piece.
	var sheet := Solid.new()
	for piece in 2:
		var base := sheet.positions.size()
		for z in 5:
			for x in 3:
				var gx := x + piece * 2
				var jitter := Vector3(0.003, -0.002, 0.004) if piece == 1 and x == 0 else Vector3.ZERO
				sheet.positions.append(Vector3(gx, sin(gx * 0.7) * cos(z * 0.5), z) + jitter)
		for z in 4:
			for x in 2:
				var a := base + z * 3 + x
				# Clockwise from above: a, a+1, a+4, a+3.
				sheet.indices.append_array([a, a + 1, a + 4, a, a + 4, a + 3])
				sheet.tags.append_array([piece, piece])
	_check(sheet.get_boundary_loops().size() == 2, "two pieces: two open loops")
	var merged := sheet.merge_close(0.01)
	_check(merged == 5 and sheet.get_boundary_loops().size() == 1, "merge_close joins the border (%d merged): one loop" % merged)
	var closed := sheet.duplicate(true) as Solid
	_check(closed.close_to_floor(-3.0, 9) and closed.count_open_edges() == 0, "close_to_floor: closed")
	var volume := 0.0
	for t in closed.get_triangle_count():
		var a := closed.positions[closed.indices[t * 3]]
		volume += a.dot(closed.positions[closed.indices[t * 3 + 2]].cross(closed.positions[closed.indices[t * 3 + 1]])) / 6.0
	_check(volume > 4.0 * 4.0 * 2.0, "outward-facing, volume %.1f" % volume)
	_check(_count_tag(closed, 9) > 0 and _count_tag(closed, 0) == 16 and _count_tag(closed, 1) == 16, "walls and floor get the tag; the sheet keeps its tags")
	# A T-junction: the right piece's border has a vertex halfway along the left piece's edge.
	var t_sheet := Solid.new()
	t_sheet.positions = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 2), Vector3(0, 0, 2),
			Vector3(1, 0, 1), Vector3(2, 0, 0), Vector3(2, 0, 2)])
	# Left: one quad (0, 1, 2, 3) with no vertex at (1, 0, 1). Right: (1, 5, 6, 2) fanned
	# around 4 at (1, 0, 1).
	t_sheet.indices = PackedInt32Array([0, 1, 2, 0, 2, 3, 1, 5, 4, 5, 6, 4, 6, 2, 4])
	t_sheet.tags = PackedInt32Array([0, 0, 1, 1, 1])
	var loops_before := t_sheet._open_edges().size()
	var splits := t_sheet.fix_t_junctions(0.001)
	_check(splits == 1 and t_sheet.get_boundary_loops().size() == 1 and t_sheet._open_edges().size() < loops_before,
			"fix_t_junctions splits the edge the vertex sits on (%d split, one loop)" % splits)
	_check(t_sheet.close_to_floor(-1.0, 9) and t_sheet.count_open_edges() == 0, "and the result closes")
