extends RefCounted
## Base for the test groups: _check() and the helpers several groups share. Groups run inside
## the runner's SceneTree; [member root], [member process_frame] and [member physics_frame]
## forward to it so tests read like SceneTree scripts.

var tree: SceneTree
var failures := 0

var root: Window:
	get:
		return tree.root
var process_frame: Signal:
	get:
		return tree.process_frame
var physics_frame: Signal:
	get:
		return tree.physics_frame


## Runs the group's tests. GPU tests need a RenderingDevice ([param has_gpu]).
func run(_has_gpu: bool) -> void:
	pass


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FAIL ", message)


func _skip_gpu() -> void:
	print("gpu tests\n  skip no RenderingDevice (run without --headless)")


# Meshes [param grid]: read back from the pool for the indirect mesher.
func _mesh_with(mesher: Mesher, grid: MesherGrid) -> MeshData:
	var indirect := mesher as MarchingCubesGpuIndirectMesher
	if indirect == null:
		return mesher.polygonize(grid)
	var target := indirect.acquire_target(AABB())
	indirect.submit([grid] as Array[MesherGrid], [target] as Array[MesherIndirectTarget])
	await _wait_readbacks(indirect)
	var mesh: MeshData = await indirect.read_target(target)
	indirect.release_target(target)
	return mesh


func _offset_concat(a: PackedInt32Array, b: PackedInt32Array, offset: int) -> PackedInt32Array:
	var out := a.duplicate()
	for k in b:
		out.append(k + offset)
	return out


# Like _open_edges, but ignores edges lying on the faces of [param bounds] (the outside of
# the meshed blocks, open by design).
func _open_edges_inside(vertices: PackedVector3Array, indices: PackedInt32Array, snap: float, bounds: AABB) -> int:
	var ids := PackedInt32Array()
	var lookup := {}
	var positions: Array[Vector3] = []
	for v in vertices:
		var k := Vector3i((v / snap).round())
		if not lookup.has(k):
			lookup[k] = lookup.size()
			positions.append(v)
		ids.append(lookup[k])
	var directed := {}
	for t in range(0, indices.size(), 3):
		for e in 3:
			var a := ids[indices[t + e]]
			var b := ids[indices[t + (e + 1) % 3]]
			if a == b:
				continue
			var k := Vector2i(a, b)
			directed[k] = directed.get(k, 0) + 1
	var bad := 0
	for k: Vector2i in directed:
		if directed[k] == 1 and directed.get(Vector2i(k.y, k.x), 0) == 1:
			continue
		if _on_bounds(positions[k.x], bounds) and _on_bounds(positions[k.y], bounds):
			var shared := false
			for axis in 3:
				for side in [bounds.position[axis], bounds.end[axis]]:
					if absf(positions[k.x][axis] - side) < 1e-3 and absf(positions[k.y][axis] - side) < 1e-3:
						shared = true
			if shared:
				continue
		bad += 1
	return bad


func _on_bounds(p: Vector3, bounds: AABB) -> bool:
	for axis in 3:
		if absf(p[axis] - bounds.position[axis]) < 1e-3 or absf(p[axis] - bounds.end[axis]) < 1e-3:
			return true
	return false


func _compare_meshes(label: String, expected: MeshData, got: MeshData) -> void:
	_check(expected.vertices.size() == got.vertices.size() and expected.indices.size() == got.indices.size(),
			"%s: %d/%d vertices, %d/%d indices" % [label, got.vertices.size(), expected.vertices.size(),
			got.indices.size(), expected.indices.size()])
	var triangles := {}
	for mesh_sign in [1, -1]:
		var mesh: MeshData = expected if mesh_sign == 1 else got
		for t in range(0, mesh.indices.size(), 3):
			var k := _triangle_key(mesh, t)
			triangles[k] = triangles.get(k, 0) + mesh_sign
	var unmatched := 0
	for k in triangles:
		if triangles[k] != 0:
			unmatched += 1
	_check(unmatched == 0, "%s: same triangles with the same winding (%d differ)" % [label, unmatched])
	var by_position := {}
	for i in expected.vertices.size():
		by_position[Vector3i((expected.vertices[i] * 1e4).round())] = i
	var normal_or_material_off := 0
	for i in got.vertices.size():
		var j: int = by_position.get(Vector3i((got.vertices[i] * 1e4).round()), -1)
		if j < 0 or got.normals[i].dot(expected.normals[j]) < 0.9999 or got.colors[i] != expected.colors[j]:
			normal_or_material_off += 1
	_check(normal_or_material_off == 0, "%s: normals and materials match (%d differ)" % [label, normal_or_material_off])


# Triangle as positions rotated to start at the smallest one, so the key keeps the winding.
func _triangle_key(mesh: MeshData, t: int) -> Array[Vector3i]:
	var p: Array[Vector3i] = []
	for e in 3:
		p.append(Vector3i((mesh.vertices[mesh.indices[t + e]] * 1e4).round()))
	var first := 0
	for e in range(1, 3):
		if p[e] < p[first]:
			first = e
	return [p[first], p[(first + 1) % 3], p[(first + 2) % 3]]



func _wait_readbacks(mesher: MarchingCubesGpuIndirectMesher) -> void:
	await process_frame
	while mesher.has_pending_readbacks():
		await process_frame


# Like _compare_meshes but for unindexed GPU read-backs: same triangles and winding, normals
# within the 8-bit octahedral packing, same materials.
func _compare_unindexed(label: String, expected: MeshData, got: MeshData) -> void:
	var triangles := {}
	for mesh_sign in [1, -1]:
		var mesh: MeshData = expected if mesh_sign == 1 else got
		for t in range(0, mesh.indices.size(), 3):
			var k := _triangle_key(mesh, t)
			triangles[k] = triangles.get(k, 0) + mesh_sign
	var unmatched := 0
	for k in triangles:
		if triangles[k] != 0:
			unmatched += 1
	var by_position := {}
	for i in expected.vertices.size():
		by_position[Vector3i((expected.vertices[i] * 1e4).round())] = i
	var worst := 1.0
	var material_off := 0
	for i in got.vertices.size():
		var j: int = by_position.get(Vector3i((got.vertices[i] * 1e4).round()), -1)
		if j < 0:
			worst = -1.0
			continue
		worst = minf(worst, got.normals[i].dot(expected.normals[j]))
		if got.colors[i] != expected.colors[j]:
			material_off += 1
	_check(unmatched == 0 and worst > 0.999 and material_off == 0,
			"%s: %d triangles, %d differ, worst normal dot %.5f, %d materials differ"
			% [label, got.get_triangle_count(), unmatched, worst, material_off])


# Same triangles with the same winding, vertices matched within [param tolerance]. For
# meshes whose vertices legitimately differ by more than rounding (skirt bottoms sit along
# the normal, so normal precision moves them).
func _check_close(label: String, expected: MeshData, got: MeshData, tolerance: float) -> void:
	var cell := maxf(tolerance * 4.0, 0.01)
	var buckets := {}
	var used := {}
	for t in range(0, expected.indices.size(), 3):
		var c := (expected.vertices[expected.indices[t]] + expected.vertices[expected.indices[t + 1]]
				+ expected.vertices[expected.indices[t + 2]]) / 3.0
		var b := Vector3i((c / cell).floor())
		if not buckets.has(b):
			buckets[b] = []
		buckets[b].append(t)
	var unmatched := 0
	for t in range(0, got.indices.size(), 3):
		var g := [got.vertices[got.indices[t]], got.vertices[got.indices[t + 1]], got.vertices[got.indices[t + 2]]]
		var c: Vector3 = (g[0] + g[1] + g[2]) / 3.0
		var base := Vector3i((c / cell).floor())
		var found := false
		for o in 27:
			var b := base + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1)
			for et: int in buckets.get(b, []):
				if used.has(et):
					continue
				var e := [expected.vertices[expected.indices[et]], expected.vertices[expected.indices[et + 1]],
						expected.vertices[expected.indices[et + 2]]]
				for r in 3:
					if (e[0] as Vector3).distance_to(g[r]) <= tolerance 							and (e[1] as Vector3).distance_to(g[(r + 1) % 3]) <= tolerance 							and (e[2] as Vector3).distance_to(g[(r + 2) % 3]) <= tolerance:
						found = true
						break
				if found:
					used[et] = true
					break
			if found:
				break
		if not found:
			unmatched += 1
	_check(unmatched == 0 and got.get_triangle_count() == expected.get_triangle_count(),
			"%s: %d of %d triangles, %d unmatched within %.3f" % [label, got.get_triangle_count(),
			expected.get_triangle_count(), unmatched, tolerance])


## Number of edges not shared by exactly two triangles in opposite directions. Positions are
## merged within [param snap] so separate chunk meshes can be checked as one surface.
func _open_edges(vertices: PackedVector3Array, indices: PackedInt32Array, snap: float) -> int:
	var ids := PackedInt32Array()
	var lookup := {}
	for v in vertices:
		var k: Variant = v if snap <= 0.0 else Vector3i((v / snap).round())
		if not lookup.has(k):
			lookup[k] = lookup.size()
		ids.append(lookup[k])
	var directed := {}
	for t in range(0, indices.size(), 3):
		for e in 3:
			var a := ids[indices[t + e]]
			var b := ids[indices[t + (e + 1) % 3]]
			if a == b:
				continue
			var k := Vector2i(a, b)
			directed[k] = directed.get(k, 0) + 1
	var bad := 0
	for k: Vector2i in directed:
		if directed[k] != 1 or directed.get(Vector2i(k.y, k.x), 0) != 1:
			bad += 1
	return bad


# A padded 32^3 block of noisy ground with a material per height band, laid out like a
# chunk a terrain would mesh: samples from -1, cells 1..33. Values are rounded to byte steps
# (see [method _encode]), so a byte copy of the grid meshes exactly the same.
func _noise_grid() -> MesherGrid:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.03
	var grid := MesherGrid.from_function(Vector3i.ONE * 35, 1.0, func(p: Vector3) -> float:
		return _decode(_encode((p.y - 17.0 - 12.0 * noise.get_noise_3dv(p)) / 2.0, 1.0), 1.0))
	grid.materials.resize(grid.get_sample_count())
	for i in grid.materials.size():
		grid.materials[i] = clampi(((i / 35) % 35) / 8, 0, 3)
	grid.cell_begin = Vector3i.ONE
	grid.cell_end = Vector3i.ONE * 33
	grid.origin = -Vector3.ONE
	return grid


# Distance to a byte the way byte grids are usually filled: [param sdf_range] either side of
# the surface spread over 0..255, surface at 127.5 (byte_center 127.5, byte_scale 1/127.5).
func _encode(sdf: float, sdf_range: float) -> int:
	return clampi(roundi(sdf / sdf_range * 127.5 + 127.5), 0, 255)


func _decode(value: int, sdf_range: float) -> float:
	return (value - 127.5) / 127.5 * sdf_range
