extends "test_suite.gd"
## Marching cubes and Transvoxel: tables, winding, transition cells closing coarse/fine
## seams, and the GPU meshers against the CPU one.


func run(has_gpu: bool) -> void:
	_test_sphere_is_closed_and_wound_like_godot()
	await _test_transition_cells_close_the_seam(MarchingCubesCpuMesher.new())
	if not has_gpu:
		_skip_gpu()
		return
	var gpu := MarchingCubesGpuMesher.new()
	_test_gpu_matches_cpu(gpu)
	await _test_byte_samples_match_floats(gpu)
	await _test_indirect_mesher_matches_cpu()
	await _test_skirts_match_across_meshers(gpu)
	await _test_transition_cells_close_the_seam(gpu)
	await _test_transition_cells_close_the_seam(MarchingCubesGpuIndirectMesher.new())
	await _test_transitions_match_across_meshers(gpu)


func _test_sphere_is_closed_and_wound_like_godot() -> void:
	print("cpu mesher on a sphere")
	var center := Vector3(10, 10, 10)
	var grid := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
			func(p: Vector3) -> float: return p.distance_to(center) - 6.3)
	var mesh := MarchingCubesCpuMesher.new().polygonize(grid)
	_check(mesh.get_triangle_count() > 100, "%d triangles" % mesh.get_triangle_count())
	_check(_open_edges(mesh.vertices, mesh.indices, 0.0) == 0, "every edge shared by exactly two triangles")

	var worst_radius := 0.0
	for v in mesh.vertices:
		worst_radius = maxf(worst_radius, absf(v.distance_to(center) - 6.3))
	_check(worst_radius < 0.1, "vertices on the sphere (max error %.3f)" % worst_radius)

	var outward := 0
	for i in mesh.vertices.size():
		if mesh.normals[i].dot((mesh.vertices[i] - center).normalized()) > 0.95:
			outward += 1
	_check(outward == mesh.vertices.size(), "gradient normals point outward (%d/%d)" % [outward, mesh.vertices.size()])

	# Let Godot compute face normals from our winding; they must agree with the gradient.
	var tool := SurfaceTool.new()
	var arrays := mesh.get_surface_arrays()
	arrays[Mesh.ARRAY_NORMAL] = null
	arrays[Mesh.ARRAY_COLOR] = null
	tool.create_from_arrays(arrays)
	tool.generate_normals()
	var godot_normals: PackedVector3Array = tool.commit_to_arrays()[Mesh.ARRAY_NORMAL]
	var agree := 0
	for i in godot_normals.size():
		if godot_normals[i].dot(mesh.normals[i]) > 0.5:
			agree += 1
	_check(agree == godot_normals.size(), "winding matches Godot front faces (%d/%d)" % [agree, godot_normals.size()])


# Coarse blocks (spacing 2, 8 cells) next to fine ones (spacing 1, 16 cells) in several
# layouts. With transition cells on the coarse faces that touch fine blocks, everything must
# join with no open edge inside the layout, and every shared edge must run opposite ways in
# its two triangles (consistent winding).
func _test_transition_cells_close_the_seam(mesher: Mesher) -> void:
	print("transition cells close the seam (%s)" % mesher.get_script().get_global_name())
	var fine := 1.0
	var coarse := 2.0
	# [name, [[from, spacing, transition faces], ...]]; faces: 1 = +x, 3 = +y, 5 = +z, 4 = -z.
	var layouts := [
		["fine across x", [[Vector3(0, -8, 0), coarse, [1]], [Vector3(16, -8, 0), fine, []]]],
		["fine across x, z and the diagonal", [[Vector3(0, -8, 0), coarse, [1, 5]], [Vector3(16, -8, 0), fine, []],
				[Vector3(0, -8, 16), fine, []], [Vector3(16, -8, 16), fine, []]]],
		["two coarse side by side, fine across x of both", [[Vector3(0, -8, 0), coarse, [1]],
				[Vector3(0, -8, 16), coarse, [1]], [Vector3(16, -8, 0), fine, []], [Vector3(16, -8, 16), fine, []]]],
		["coarse with coarse neighbours, fine only diagonally", [[Vector3(0, -8, 0), coarse, []],
				[Vector3(16, -8, 0), coarse, [5]], [Vector3(0, -8, 16), coarse, [1]], [Vector3(16, -8, 16), fine, []]]],
		["fine above", [[Vector3(0, -16, 0), coarse, [3]], [Vector3(0, 0, 0), fine, []]]],
	]
	for layout: Array in layouts:
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		var plain_vertices := PackedVector3Array()
		var plain_indices := PackedInt32Array()
		var bounds := AABB()
		var added := 0
		for block: Array in layout[1]:
			var spacing: float = block[1]
			var cells := roundi(16.0 / spacing)
			var mesh: MeshData = await _seam_block(mesher, block[0], cells, spacing, block[2])
			var plain: MeshData = await _seam_block(mesher, block[0], cells, spacing, [])
			added += mesh.get_triangle_count() - plain.get_triangle_count()
			indices = _offset_concat(indices, mesh.indices, vertices.size())
			vertices += mesh.vertices
			plain_indices = _offset_concat(plain_indices, plain.indices, plain_vertices.size())
			plain_vertices += plain.vertices
			var box := AABB(block[0], Vector3.ONE * 16.0)
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
		var before := _open_edges_inside(plain_vertices, plain_indices, 1e-3, bounds)
		var after := _open_edges_inside(vertices, indices, 1e-3, bounds)
		_check(before > 0 and after == 0, "%s: %d open edges without transition cells, %d with them (%d triangles added)"
				% [layout[0], before, after, added])


func _test_gpu_matches_cpu(gpu: MarchingCubesGpuMesher) -> void:
	print("gpu mesher matches cpu")
	var cpu := MarchingCubesCpuMesher.new()
	var center := Vector3(10, 10, 10)
	var sphere := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
			func(p: Vector3) -> float: return p.distance_to(center) - 6.3)
	_compare_meshes("sphere", cpu.polygonize(sphere), gpu.polygonize(sphere))
	var noise := _noise_grid()
	_compare_meshes("noise chunk with materials and padding", cpu.polygonize(noise), gpu.polygonize(noise))
	var empty := MesherGrid.from_function(Vector3i(8, 8, 8), 1.0, func(_p: Vector3) -> float: return 1.0)
	_check(gpu.polygonize(empty).is_empty(), "all-air grid gives an empty mesh")

	# One batch with mixed sizes and an empty grid; results must come back in order.
	var grids: Array[MesherGrid] = [noise, empty, sphere, noise]
	var batch := gpu.polygonize_batch(grids)
	_check(batch.size() == 4 and batch[1].is_empty(), "batch returns one result per grid, in order")
	for i in [0, 2, 3]:
		_compare_meshes("batch entry %d" % i, cpu.polygonize(grids[i]), batch[i])


func _test_byte_samples_match_floats(gpu: MarchingCubesGpuMesher) -> void:
	print("byte samples decode like floats")
	var floats := _noise_grid()
	var bytes := MesherGrid.new()
	bytes.size = floats.size
	bytes.cell_begin = floats.cell_begin
	bytes.cell_end = floats.cell_end
	bytes.origin = floats.origin
	bytes.materials = floats.materials
	bytes.byte_center = 127.5
	bytes.byte_scale = 1.0 / 127.5
	bytes.bytes.resize(floats.values.size())
	for i in floats.values.size():
		bytes.bytes[i] = _encode(floats.values[i], 1.0)
	var cpu := MarchingCubesCpuMesher.new()
	var expected := cpu.polygonize(floats)
	_compare_meshes("cpu mesher, bytes vs floats", expected, cpu.polygonize(bytes))
	_compare_meshes("gpu readback mesher, bytes vs cpu floats", expected, gpu.polygonize(bytes))
	var indirect := MarchingCubesGpuIndirectMesher.new()
	indirect.max_slots = 1
	var target := indirect.acquire_target(AABB())
	indirect.submit([bytes] as Array[MesherGrid], [target] as Array[MesherIndirectTarget])
	await _wait_readbacks(indirect)
	_compare_unindexed("gpu indirect mesher, bytes vs cpu floats", expected, await indirect.read_target(target))
	indirect.release_target(target)


func _test_indirect_mesher_matches_cpu() -> void:
	print("indirect mesher matches cpu")
	var mesher := MarchingCubesGpuIndirectMesher.new()
	mesher.max_slots = 4
	var cpu := MarchingCubesCpuMesher.new()
	var center := Vector3(10, 10, 10)
	var sphere := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
			func(p: Vector3) -> float: return p.distance_to(center) - 6.3)
	sphere.materials.resize(21 * 21 * 21)
	for i in sphere.materials.size():
		sphere.materials[i] = i % 4
	var small := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
			func(p: Vector3) -> float: return p.distance_to(center) - 3.1)
	var a := mesher.acquire_target(AABB(Vector3.ZERO, Vector3.ONE * 21))
	var b := mesher.acquire_target(AABB(Vector3.ZERO, Vector3.ONE * 21))
	_check(a != null and b != null and a.vertex_base != b.vertex_base, "two targets get separate slots")
	mesher.submit([sphere, small] as Array[MesherGrid], [a, b] as Array[MesherIndirectTarget])
	await _wait_readbacks(mesher)
	_check(a.triangle_count == cpu.polygonize(sphere).get_triangle_count(), "triangle count read back (%d)" % a.triangle_count)
	_compare_unindexed("sphere with materials", cpu.polygonize(sphere), await mesher.read_target(a))
	_compare_unindexed("second slot", cpu.polygonize(small), await mesher.read_target(b))
	mesher.submit([small] as Array[MesherGrid], [a] as Array[MesherIndirectTarget])
	await _wait_readbacks(mesher)
	_compare_unindexed("slot reused for a different mesh", cpu.polygonize(small), await mesher.read_target(a))
	_check(mesher.take_overflowed().is_empty(), "nothing overflowed")
	var c := mesher.acquire_target(AABB())
	var d := mesher.acquire_target(AABB())
	_check(c != null and d != null and mesher.acquire_target(AABB()) == null, "pool of 4 slots refuses a 5th target")
	mesher.release_target(d)
	_check(mesher.acquire_target(AABB()) != null, "released slot can be acquired again")

	var tiny := MarchingCubesGpuIndirectMesher.new()
	tiny.slot_triangles = 64
	tiny.max_slots = 1
	var t := tiny.acquire_target(AABB())
	t.user_data = Vector3i(1, 2, 3)
	tiny.submit([sphere] as Array[MesherGrid], [t] as Array[MesherIndirectTarget])
	await _wait_readbacks(tiny)
	var over := tiny.take_overflowed()
	_check(over.size() == 1 and over[0].user_data == Vector3i(1, 2, 3), "overflow reported with its user data")
	_check((await tiny.read_target(t)).get_triangle_count() == 64, "overflowed slot keeps exactly its capacity")


func _test_skirts_match_across_meshers(gpu: MarchingCubesGpuMesher) -> void:
	print("skirts match across meshers")
	var grid := _noise_grid()
	grid.skirt_depth = 1.5
	var expected := MarchingCubesCpuMesher.new().polygonize(grid)
	var no_skirt := _noise_grid()
	var base := MarchingCubesCpuMesher.new().polygonize(no_skirt).get_triangle_count()
	_check(expected.get_triangle_count() > base, "skirts add %d triangles to %d" % [expected.get_triangle_count() - base, base])
	_check_close("gpu readback with skirts", expected, gpu.polygonize(grid), 0.002)
	var indirect := MarchingCubesGpuIndirectMesher.new()
	indirect.max_slots = 1
	var target := indirect.acquire_target(AABB())
	indirect.submit([grid] as Array[MesherGrid], [target] as Array[MesherIndirectTarget])
	await _wait_readbacks(indirect)
	# Indirect normals are 8-bit, and skirt bottoms sit 1.5 voxels along them.
	_check_close("gpu indirect with skirts", expected, await indirect.read_target(target), 0.05)
	indirect.release_target(target)


# The GPU meshers' transition cells match the CPU mesher's, triangle for triangle (within
# float precision; the indirect one stores normals and materials packed).
func _test_transitions_match_across_meshers(gpu: MarchingCubesGpuMesher) -> void:
	print("transition cells match across meshers")
	var grid := _seam_block_grid(Vector3(0, -8, 0), 8, 2.0, [1, 5, 2])
	grid.skirt_depth = 0.5
	var expected := MarchingCubesCpuMesher.new().polygonize(grid)
	_check_close("gpu readback with transition cells", expected, gpu.polygonize(grid), 0.002)
	var indirect := MarchingCubesGpuIndirectMesher.new()
	indirect.max_slots = 1
	_check_close("gpu indirect with transition cells", expected, await _mesh_with(indirect, grid), 0.05)


# Rolling ground with a pit straddling x = 16: half-unit features, so a coarse mesh alone
# would not meet a fine one there.
func _seam_shape(p: Vector3) -> float:
	var ground := p.y - 2.5 * sin(p.x * 0.35 + 0.3) * cos(p.z * 0.3) - 1.2 * sin(p.z * 0.7 + p.x * 0.2)
	return maxf(ground, 3.2 - p.distance_to(Vector3(16.3, -0.5, 7.7)))


# A block of [param cells] cells of [param spacing] from [param from], padded like a
# terrain chunk, sampled as bytes ([param sdf_range] per byte range).
func _seam_grid(from: Vector3, cells: int, spacing: float, sdf_range: float) -> MesherGrid:
	var grid := MesherGrid.new()
	grid.size = Vector3i.ONE * (cells + 3)
	grid.spacing = spacing
	grid.origin = from - Vector3.ONE * spacing
	grid.cell_begin = Vector3i.ONE
	grid.cell_end = Vector3i.ONE * (cells + 1)
	grid.byte_center = 127.5
	grid.byte_scale = 1.0 / 127.5
	grid.bytes.resize(grid.get_sample_count())
	for z in grid.size.z:
		for y in grid.size.y:
			for x in grid.size.x:
				var d := _seam_shape(grid.origin + Vector3(x, y, z) * spacing)
				grid.bytes[grid.index_of(x, y, z)] = _encode(d, sdf_range)
	return grid


# Transition samples for [param face] of [param grid], from the shape at half its spacing.
func _seam_transition(grid: MesherGrid, face: int, sdf_range: float) -> MesherTransition:
	var t := MesherTransition.new()
	t.face = face
	var axes := MesherTransition.axes(face)
	var dims := MesherTransition.dimensions(grid, face)
	var end := grid.get_cell_end()
	t.bytes.resize(dims.x * dims.y * 3)
	for layer in range(-1, 2):
		for j in range(-1, dims.y - 1):
			for i in range(-1, dims.x - 1):
				var g := Vector3.ZERO
				g[axes.x] = (end[axes.x] if face & 1 else grid.cell_begin[axes.x]) + layer * 0.5
				g[axes.y] = grid.cell_begin[axes.y] + i * 0.5
				g[axes.z] = grid.cell_begin[axes.z] + j * 0.5
				var d := _seam_shape(grid.origin + g * grid.spacing)
				t.bytes[MesherTransition.index_of(dims, i, j, layer)] = _encode(d, sdf_range)
	return t


# A block of [param cells] cells from [param from] with transition cells on [param faces]
# (face indexes), sampled from the shape; the coarse samples on those faces come from the
# fine ones, as a chunked caller would do it.
func _seam_block(mesher: Mesher, from: Vector3, cells: int, spacing: float, faces: Array) -> MeshData:
	return await _mesh_with(mesher, _seam_block_grid(from, cells, spacing, faces))


func _seam_block_grid(from: Vector3, cells: int, spacing: float, faces: Array) -> MesherGrid:
	var sdf_range := spacing * 2.0
	var grid := _seam_grid(from, cells, spacing, sdf_range)
	for face: int in faces:
		var t := _seam_transition(grid, face, sdf_range * 0.5)
		grid.transitions.append(t)
		var axes := MesherTransition.axes(face)
		var dims := MesherTransition.dimensions(grid, face)
		for b in cells + 1:
			for a in cells + 1:
				var g := Vector3i.ZERO
				g[axes.x] = grid.cell_end[axes.x] if face & 1 else grid.cell_begin[axes.x]
				g[axes.y] = grid.cell_begin[axes.y] + a
				g[axes.z] = grid.cell_begin[axes.z] + b
				var d := _decode(t.bytes[MesherTransition.index_of(dims, a * 2, b * 2, 0)], sdf_range * 0.5)
				grid.bytes[grid.index_of(g.x, g.y, g.z)] = _encode(d, sdf_range)
	return grid
