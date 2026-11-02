extends "test_suite.gd"
## Dual contouring and dual contouring of signed distance data: the QEF maths, closed and
## outward-wound meshes, blocks joining, and sharp corners kept where marching cubes
## bevels them.

const BOX_CENTER := Vector3(11.7, 12.2, 11.9)
const BOX_HALF := Vector3(5.3, 4.6, 5.1)


func run(_has_gpu: bool) -> void:
	_test_qef()
	_test_sphere(DualContouringCpuMesher.new())
	var flat := DualContouringCpuMesher.new()
	flat.flat_shading = true
	_test_sphere(flat)
	_test_sphere(SdfDualContouringCpuMesher.new())
	_test_blocks_join()
	_test_materials()
	_test_sharp_corners()


func _test_qef() -> void:
	print("qef maths")
	var m := PackedFloat64Array([4, 1, 0.5, 1, 3, 0.2, 0.5, 0.2, 2])
	var eigen := Qef.symmetric_eigen(m)
	var worst := 0.0
	for k in 3:
		var v: Vector3 = eigen[1][k]
		var lambda: float = eigen[0][k]
		for r in 3:
			var mv := m[r * 3] * v.x + m[r * 3 + 1] * v.y + m[r * 3 + 2] * v.z
			worst = maxf(worst, absf(mv - lambda * v[r]))
	_check(worst < 1e-5, "eigen decomposition: M v = lambda v (worst %s)" % worst)
	# Three planes through a corner at (1, 2, 3), the crossing points spread along them.
	var corner := Vector3(1, 2, 3)
	var normals := PackedVector3Array([Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3.RIGHT])
	var points := PackedVector3Array([corner + Vector3(0, 0.4, 0.1), corner + Vector3(0.3, 0, -0.2),
			corner + Vector3(-0.2, 0.3, 0), corner + Vector3(0, -0.3, 0.2)])
	var x := Qef.solve(normals, points, 0.05)
	_check(x.distance_to(corner) < 1e-5, "three planes meet at their corner (%s)" % x)
	# Two parallel planes: the free directions stay at the points' average.
	normals = PackedVector3Array([Vector3.UP, Vector3.UP])
	points = PackedVector3Array([Vector3(0, 1, 0), Vector3(2, 1, 4)])
	x = Qef.solve(normals, points, 0.05)
	_check(x.distance_to(Vector3(1, 1, 2)) < 1e-5, "flat planes keep the average along the surface (%s)" % x)


func _test_sphere(mesher: DualMesher) -> void:
	var label: String = mesher.get_script().get_global_name() + (" (flat)" if mesher.flat_shading else "")
	print("%s on a sphere" % label)
	var center := Vector3(10, 10, 10)
	var grid := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
			func(p: Vector3) -> float: return p.distance_to(center) - 6.3)
	var start := Time.get_ticks_usec()
	var mesh := mesher.polygonize(grid)
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	_check(mesh.get_triangle_count() > 100, "%d triangles in %.0f ms" % [mesh.get_triangle_count(), ms])
	_check(_open_edges(mesh.vertices, mesh.indices, 1e-5) == 0, "every edge shared by exactly two triangles")
	var worst_radius := 0.0
	for v in mesh.vertices:
		worst_radius = maxf(worst_radius, absf(v.distance_to(center) - 6.3))
	_check(worst_radius < 0.1, "vertices on the sphere (max error %.3f)" % worst_radius)
	var outward := 0
	for i in mesh.vertices.size():
		if mesh.normals[i].dot((mesh.vertices[i] - center).normalized()) > 0.9:
			outward += 1
	_check(outward == mesh.vertices.size(), "normals point outward (%d/%d)" % [outward, mesh.vertices.size()])
	var facing := 0
	for t in range(0, mesh.indices.size(), 3):
		var a := mesh.vertices[mesh.indices[t]]
		var b := mesh.vertices[mesh.indices[t + 1]]
		var c := mesh.vertices[mesh.indices[t + 2]]
		if (c - a).cross(b - a).dot((a + b + c) / 3.0 - center) > 0.0:
			facing += 1
	_check(facing == mesh.get_triangle_count(), "winding matches Godot front faces (%d/%d)"
			% [facing, mesh.get_triangle_count()])


# A sphere across the boundary of two blocks laid out like terrain chunks (one sample of
# padding each side, shared boundary samples): each block alone is open, together closed,
# and the vertices both blocks make for the shared cells sit in the same place.
func _test_blocks_join() -> void:
	print("dual contouring blocks join")
	var center := Vector3(16, 10, 10)
	var fn := func(p: Vector3) -> float: return p.distance_to(center) - 6.0
	var mesher := DualContouringCpuMesher.new()
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var alone := 0
	for x0 in [0.0, 16.0]:
		var origin := Vector3(x0 - 1.0, -1.0, -1.0)
		var grid := MesherGrid.from_function(Vector3i(19, 23, 23), 1.0,
				func(p: Vector3) -> float: return fn.call(p + origin))
		grid.origin = origin
		grid.cell_begin = Vector3i.ONE
		grid.cell_end = Vector3i(17, 21, 21)
		var mesh := mesher.polygonize(grid)
		alone += _open_edges(mesh.vertices, mesh.indices, 1e-4)
		indices = _offset_concat(indices, mesh.indices, vertices.size())
		vertices += mesh.vertices
	var joined := _open_edges(vertices, indices, 1e-4)
	_check(alone > 0 and joined == 0, "%d open edges in the blocks alone, %d together" % [alone, joined])


func _test_materials() -> void:
	print("dual contouring materials")
	var mesh := DualContouringCpuMesher.new().polygonize(_noise_grid())
	var ids := {}
	for c in mesh.colors:
		ids[c.r8] = true
	var valid := true
	for id: int in ids:
		valid = valid and id >= 0 and id <= 3
	_check(not mesh.is_empty() and ids.size() > 1 and valid, "noise chunk: %d triangles, material ids %s"
			% [mesh.get_triangle_count(), ids.keys()])


# A rotated box off the grid: how close does each mesher get to its eight corners?
func _test_sharp_corners() -> void:
	print("sharp corners (rotated box, distance from each corner to the nearest vertex)")
	var basis := Basis.from_euler(Vector3(0.3, 0.5, 0.2))
	var sdf := func(p: Vector3) -> float: return _box_sdf(basis.transposed() * (p - BOX_CENTER))
	var grid := MesherGrid.from_function(Vector3i(25, 25, 25), 1.0, sdf)
	var corners := PackedVector3Array()
	for k in 8:
		corners.append(BOX_CENTER + basis * (BOX_HALF * Vector3(1 if k & 1 else -1, 1 if k & 2 else -1, 1 if k & 4 else -1)))

	var exact := DualContouringCpuMesher.new()
	exact.gradient_function = func(p: Vector3) -> Vector3:
		var h := 1e-3
		return Vector3(sdf.call(p + Vector3(h, 0, 0)) - sdf.call(p - Vector3(h, 0, 0)),
				sdf.call(p + Vector3(0, h, 0)) - sdf.call(p - Vector3(0, h, 0)),
				sdf.call(p + Vector3(0, 0, h)) - sdf.call(p - Vector3(0, 0, h)))
	var results := {}
	for entry in [["marching cubes", MarchingCubesCpuMesher.new()],
			["dual contouring, exact normals", exact],
			["dual contouring, normals from samples", DualContouringCpuMesher.new()],
			["dual contouring of signed distance data", SdfDualContouringCpuMesher.new()]]:
		var start := Time.get_ticks_usec()
		var mesh: MeshData = entry[1].polygonize(grid)
		var ms := (Time.get_ticks_usec() - start) / 1000.0
		var worst := 0.0
		var total := 0.0
		for c in corners:
			var nearest := INF
			for v in mesh.vertices:
				nearest = minf(nearest, v.distance_to(c))
			worst = maxf(worst, nearest)
			total += nearest
		results[entry[0]] = total / 8.0
		print("  %s: mean %.3f, worst %.3f, %d triangles, %d edges not shared by exactly two, %.0f ms" % [entry[0], total / 8.0, worst,
				mesh.get_triangle_count(), _open_edges_by_index(mesh.indices), ms])
	# Not zero: a corner can poke into a cell that holds none of the box's samples, and no
	# dual method puts a vertex in a cell the surface doesn't cross between samples.
	_check(results["dual contouring, exact normals"] < 0.25, "dual contouring with exact normals finds the corners")
	_check(results["dual contouring, exact normals"] < results["marching cubes"] * 0.5,
			"dual contouring beats marching cubes at the corners")
	_check(results["dual contouring of signed distance data"] < results["dual contouring, normals from samples"],
			"signed distance data beats plain dual contouring when only samples are known")


# Edges not shared by exactly two triangles, counted on vertex ids: one of the box's samples
# is within 1e-6 of the surface, so a few vertices coincide and merging by position would
# report edges that aren't open. That sample also makes an ambiguous cell face, where the
# dual meshers join the same two cells twice (a non-manifold edge, not a hole: one vertex
# per cell can't do better; see the README).
func _open_edges_by_index(indices: PackedInt32Array) -> int:
	var directed := {}
	for t in range(0, indices.size(), 3):
		for e in 3:
			var k := Vector2i(indices[t + e], indices[t + (e + 1) % 3])
			directed[k] = directed.get(k, 0) + 1
	var bad := 0
	for k: Vector2i in directed:
		if directed[k] != 1 or directed.get(Vector2i(k.y, k.x), 0) != 1:
			bad += 1
	return bad


func _box_sdf(local: Vector3) -> float:
	var d := local.abs() - BOX_HALF
	return d.max(Vector3.ZERO).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0)
