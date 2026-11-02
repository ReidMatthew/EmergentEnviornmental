extends SceneTree
## Tests for the Manifold backend and the native geometry core (AdaptiveMeshKernel, used
## through adaptive_mesh's NativeKernel): the core must give exactly what the GDScript gives. From the project folder:
##   godot --headless -s res://addons/adaptive_mesh_native/tests/run_tests.gd
## Each boolean is run with both backends and must give the same solid (triangles,
## volume, tags) as Godot's CSG, which uses the same library; then it's timed against CSG.
## adaptive_mesh's own tests run on this backend whenever this add-on is installed (it's
## the default then), and on CSG without it. Exits with code 1 if anything fails.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check(ManifoldBooleanBackend.is_available(), "the native library loaded (Manifold %s)" % ManifoldBooleanBackend.get_manifold_version())
	if not ManifoldBooleanBackend.is_available():
		quit(1)
		return
	_check(AdaptiveMesh.get_default_backend() is ManifoldBooleanBackend, "adaptive meshes use it by default")
	_check(ManifoldBooleanBackend.new().is_thread_safe(), "it runs on worker threads")
	var box := _solid(_box(4.0))
	var sphere := _sphere(1.2)
	await _same("subtract", box, [BooleanOp.create(sphere, _at(2, 2, 2), BooleanOp.Operation.SUBTRACT)])
	await _same("union", box, [BooleanOp.create(sphere, _at(2, 0, 0), BooleanOp.Operation.UNION)])
	await _same("intersect", box, [BooleanOp.create(sphere, _at(1.5, 0, 0), BooleanOp.Operation.INTERSECT)])
	var many: Array[BooleanOp] = []
	for i in 6:
		many.append(BooleanOp.create(sphere, _at(-1.5 + i * 0.6, 2.0, 0.3 * i), BooleanOp.Operation.SUBTRACT))
	await _same("six digs in one batch", box, many)
	await _same("a union cut to bounds (walls on +x get tag 7)", Solid.new(),
			[BooleanOp.create(sphere, _at(0.5, 0, 0), BooleanOp.Operation.UNION)],
			AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), 7, BooleanBackend.side_bit(0, true))
	var turned := Transform3D(Basis.from_euler(Vector3(0.3, 0.7, -0.2)).scaled(Vector3(1.0, 0.5, 2.0)), Vector3(1, 1, 0))
	await _same("a turned, stretched box", box, [BooleanOp.create(_solid(_box(1.5)), turned, BooleanOp.Operation.SUBTRACT)])
	var with_uv := Solid.from_mesh(_box(4.0))
	var result: Solid = await ManifoldBooleanBackend.new().combine(with_uv, [BooleanOp.create(sphere, _at(2, 2, 2), BooleanOp.Operation.SUBTRACT)] as Array[BooleanOp], AABB(), 0)
	_check(result != null and result.uvs.size() == result.positions.size() and result.count_open_edges() == 0,
			"UVs come through (%d)" % (result.uvs.size() if result != null else -1))
	var open := _solid(_box(4.0))
	open.indices.resize(open.indices.size() - 3)
	open.tags.resize(open.tags.size() - 1)
	_check(await ManifoldBooleanBackend.new().combine(open, [BooleanOp.create(sphere, _at(2, 2, 2), BooleanOp.Operation.SUBTRACT)] as Array[BooleanOp], AABB(), 0) == null,
			"a target that isn't closed fails (null), as CSG does")
	_check((await ManifoldBooleanBackend.new().combine(Solid.new(), [BooleanOp.create(sphere, _at(0, 0, 0), BooleanOp.Operation.SUBTRACT)] as Array[BooleanOp], AABB(), 0)).is_empty(),
			"nothing to cut from: empty")
	await _timing(box, sphere)
	_kernel_parity()
	print("ALL PASSED" if _failures == 0 else "%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)


# Runs [param ops] on [param target] with both backends: the same triangles, volume and tags.
func _same(label: String, target: Solid, ops: Array, bounds := AABB(), tag := 0, walls := 63) -> void:
	var typed: Array[BooleanOp] = []
	typed.assign(ops)
	var csg: Solid = await CsgBooleanBackend.new().combine(target, typed, bounds, tag, walls)
	var native: Solid = await ManifoldBooleanBackend.new().combine(target, typed, bounds, tag, walls)
	var same := csg != null and native != null and csg.get_triangle_count() == native.get_triangle_count() \
			and absf(csg.get_volume() - native.get_volume()) < 1e-5 * maxf(absf(csg.get_volume()), 1.0) \
			and _tag_counts(csg) == _tag_counts(native) and native.count_open_edges() == 0
	_check(same, "%s: as CSG (%d triangles, volume %.4f, tags %s)" % [label,
			native.get_triangle_count() if native != null else -1, native.get_volume() if native != null else 0.0,
			_tag_counts(native) if native != null else {}])


func _timing(box: Solid, sphere: Solid) -> void:
	var dense := _sphere(2.0, 4)
	var ops: Array[BooleanOp] = [BooleanOp.create(sphere, _at(1, 1, 1), BooleanOp.Operation.SUBTRACT)]
	var rounds := 20
	var started := Time.get_ticks_usec()
	for i in rounds:
		await CsgBooleanBackend.new().combine(dense, ops, AABB(), 0)
	var csg := (Time.get_ticks_usec() - started) / float(rounds)
	started = Time.get_ticks_usec()
	for i in rounds:
		await ManifoldBooleanBackend.new().combine(dense, ops, AABB(), 0)
	var native := (Time.get_ticks_usec() - started) / float(rounds)
	print("  a dig in a %d-triangle sphere: CSG %.2f ms (main thread), Manifold %.2f ms (any thread)" % [
			dense.get_triangle_count(), csg / 1000.0, native / 1000.0])


func _tag_counts(solid: Solid) -> Dictionary:
	var out := {}
	for t in solid.tags:
		out[t] = out.get(t, 0) + 1
	return out


func _box(size: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	return mesh


func _solid(mesh: Mesh) -> Solid:
	var solid := Solid.from_mesh(mesh)
	solid.uvs = PackedVector2Array()
	solid.weld()
	return solid


func _sphere(radius: float, subdivisions: int = 2) -> Solid:
	var shape := SolidSphere.new()
	shape.radius = radius
	shape.subdivisions = subdivisions
	return shape.get_solid()


func _at(x: float, y: float, z: float) -> Transform3D:
	return Transform3D(Basis(), Vector3(x, y, z))


func _check(condition: bool, message: String) -> void:
	print(("  ok   " if condition else "  FAIL ") + message)
	if not condition:
		_failures += 1


# --- Native core: the same results as the GDScript, bit for bit --------------------------

# Digs into real pieces (the demos' terrain and castle) and runs every native operation and
# its GDScript on the results, comparing the arrays exactly.
func _kernel_parity() -> void:
	_check(NativeKernel.on(), "the native core loaded")
	if not NativeKernel.on():
		return
	var pieces: Array[Solid] = []
	var datas: Array[AdaptiveMeshData] = []
	for path in ["res://addons/adaptive_mesh/demo/models/low_poly_terrain.adaptive.res",
			"res://addons/adaptive_mesh/demo/models/castle.adaptive.res"]:
		var data: AdaptiveMeshData = load(path)
		datas.append(data)
		var keys := data.pieces.keys()
		for i in range(0, keys.size(), maxi(keys.size() / 12, 1)):
			pieces.append(data.pieces[keys[i]])
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var counts := {}
	var mismatches := {}
	for before in pieces:
		var box := before.get_aabb()
		var sphere := _sphere(box.get_longest_axis_size() * rng.randf_range(0.15, 0.4), rng.randi_range(1, 3))
		var at := box.position + box.size * Vector3(rng.randf(), rng.randf(), rng.randf())
		var ops: Array[BooleanOp] = [BooleanOp.create(sphere, Transform3D(Basis(), at), BooleanOp.Operation.SUBTRACT)]
		var after: Solid = ManifoldBooleanBackend.new().combine_native(before, ops, AABB(), 7)
		if after == null or after.is_empty():
			continue
		var cleanup := MeshCleanup.new()
		cleanup.min_edge_length = box.get_longest_axis_size() * 0.04
		cleanup.max_error = box.get_longest_axis_size() * 0.01
		cleanup.unlock_rings = rng.randi_range(0, 2)
		var bounds := box if rng.randf() < 0.5 else AABB()
		_compare(counts, mismatches, "clean", func() -> Variant:
			return _arrays(cleanup.clean(after, before, bounds)))
		_compare(counts, mismatches, "clean (no before)", func() -> Variant:
			return _arrays(cleanup.clean(after, null, AABB())))
		var extra := before.get_faces().slice(0, 300)
		_compare(counts, mismatches, "build_surfaces", func() -> Variant:
			return after.build_surfaces(30.0, PackedInt32Array([1000]), extra))
		var welded_source := Solid.from_mesh(_box_with_seams())
		_compare(counts, mismatches, "weld", func() -> Variant:
			var copy := welded_source.duplicate(true) as Solid
			copy.weld()
			return _arrays(copy))
		_compare(counts, mismatches, "islands", func() -> Variant:
			return after.get_islands().map(func(island: Solid) -> Array: return _arrays(island)))
		_compare(counts, mismatches, "part_infos", func() -> Variant:
			return MeshSeparation.part_infos(after, 7).map(func(info: Array) -> Array: return info.slice(1)))
		var cell := box.grow(-box.size.length() * 0.05)
		var cells := {Vector4i(1, 0, 0, 0): AABB(cell.position + Vector3(cell.size.x, 0, 0), cell.size),
				Vector4i(0, 0, 1, 0): AABB(cell.position + Vector3(0, 0, cell.size.z), cell.size)}
		var cut: Array[bool] = [true, false, true]
		_compare(counts, mismatches, "border_parts", func() -> Variant:
			return AdaptiveMesh._border_parts(after, cell, cut, 7, cells))
		_compare(counts, mismatches, "hull_points", func() -> Variant:
			return after.get_hull_points(0.95))
		_compare(counts, mismatches, "faces", func() -> Variant:
			return after.get_faces(PackedInt32Array([7])))
		_compare(counts, mismatches, "hull_sets", func() -> Variant:
			return ConvexCells.hull_sets(after, 4))
		_compare(counts, mismatches, "volume and centre", func() -> Variant:
			return [after.get_volume(), after.get_centre()])
		_compare(counts, mismatches, "aabb", func() -> Variant:
			return after.get_aabb())
		_compare(counts, mismatches, "encloses", func() -> Variant:
			return [after.encloses(box.get_center()), after.encloses(box.position - Vector3.ONE)])
		_compare(counts, mismatches, "merge_solids", func() -> Variant:
			var parts: Array[Solid] = [after, before]
			return _arrays(MeshSeparation.merge_solids(parts)))
		# Points on its edges (edge middles, nudged off a little) and some not.
		var points := PackedVector3Array()
		for k in range(0, mini(after.indices.size(), 60), 3):
			points.append(after.positions[after.indices[k]].lerp(after.positions[after.indices[k + 1]], 0.37))
		points.append(box.get_center())
		_compare(counts, mismatches, "split_edges_at", func() -> Variant:
			var copy := after.duplicate(true) as Solid
			var inserted := copy.split_edges_at(points, 1e-4)
			return [inserted, _arrays(copy)])
		# An open copy (a few triangles dropped, others split) to mend and snap.
		_compare(counts, mismatches, "fix_t_junctions", func() -> Variant:
			var copy := after.duplicate(true) as Solid
			copy.split_edges_at(points.slice(0, 4), 1e-4)
			var mended := copy.fix_t_junctions(1e-3)
			return [mended, _arrays(copy)])
		_compare(counts, mismatches, "count_open_edges", func() -> Variant:
			var copy := after.duplicate(true) as Solid
			copy.indices = copy.indices.slice(0, copy.indices.size() - 6)
			return [after.count_open_edges(), copy.count_open_edges()])
		_compare(counts, mismatches, "snap_seams", func() -> Variant:
			var copy := after.duplicate(true) as Solid
			copy.indices = copy.indices.slice(0, copy.indices.size() - 9)
			copy.tags = copy.tags.slice(0, copy.tags.size() - 3)
			AdaptiveMeshData._snap_seams(copy, 0.05)
			return copy.positions)
		# The fused edit against the same steps one call at a time (all native).
		var border := [true, cell, cut, 7, cells]
		var fused: Array = NativeKernel.edit_job(before, ops, AABB(), 7, 63, cleanup,
				[30.0, PackedInt32Array([7]), true, extra, false, 1], border).call()
		var stepwise: Array = AdaptivePiece._edit_job(AdaptivePiece._combine_job(ManifoldBooleanBackend.new(), before, ops,
				AABB(), 7, 63), before, cleanup, AABB(),
				AdaptivePiece._build_job(30.0, PackedInt32Array([7]), true, extra, false, 1), border).call()
		counts["edit_piece (fused vs step by step)"] = counts.get("edit_piece (fused vs step by step)", 0) + 1
		var fused_flat := [_arrays(fused[0]), fused[1], fused[2]]
		var stepwise_flat := [_arrays(stepwise[0]), stepwise[1], stepwise[2]]
		if not mismatches.has("edit_piece (fused vs step by step)") and not _equal(fused_flat, stepwise_flat):
			mismatches["edit_piece (fused vs step by step)"] = _first_difference(fused_flat, stepwise_flat, "")
	# Merging: whole meshes (the terrain and the rock join up closed, the castle doesn't), and
	# a piece with some neighbours (open: null both ways).
	for path in ["res://addons/adaptive_mesh/demo/models/low_poly_terrain.adaptive.res",
			"res://addons/adaptive_mesh/demo/models/castle.adaptive.res", "res://addons/adaptive_mesh/demo/models/rock.adaptive.res"]:
		var whole: AdaptiveMeshData = load(path)
		_compare(counts, mismatches, "merged", func() -> Variant:
			var joined := whole.merged()
			return _arrays(joined.pieces[Vector4i.ZERO]) if joined != null else null)
	for data in datas:
		var keys := data.pieces.keys()
		for i in range(0, keys.size(), maxi(keys.size() / 10, 1)):
			var part := AdaptiveMeshData.new()
			part.chunking = data.chunking
			part.extent = data.extent
			part.region = data.region
			for key: Vector4i in [keys[i]] + data.neighbour_keys(keys[i]).slice(0, 3):
				if data.pieces.has(key):
					part.pieces[key] = data.pieces[key]
			_compare(counts, mismatches, "merged", func() -> Variant:
				var joined := part.merged()
				return _arrays(joined.pieces[Vector4i.ZERO]) if joined != null else null)
	# Joining: the groups (as which parts go together) must match.
	var corner_sets := []
	for i in 60:
		var corners := PackedVector3Array()
		for k in 2:
			corners.append(Vector3(rng.randi_range(0, 14), rng.randi_range(0, 2), rng.randi_range(0, 14)) * 0.5)
		corner_sets.append(corners)
	var native_groups := _groups(ClassDB.class_call_static(NativeKernel.CLASS, &"join_parts", corner_sets, 1e-4))
	var script_groups := _groups(_join_in_script(corner_sets, 1e-4))
	_check(native_groups == script_groups, "join_parts: the same groups (%d)" % native_groups.size())
	for op: String in counts:
		_check(not mismatches.has(op), "%s: native and GDScript the same on %d dug pieces%s" % [op, counts[op],
				(", first difference: " + mismatches[op]) if mismatches.has(op) else ""])


# Runs [param make] with the native core and then without, and notes a difference.
func _compare(counts: Dictionary, mismatches: Dictionary, op: String, make: Callable) -> void:
	NativeKernel.enabled = true
	var native: Variant = make.call()
	NativeKernel.enabled = false
	var script: Variant = make.call()
	NativeKernel.enabled = true
	counts[op] = counts.get(op, 0) + 1
	if not mismatches.has(op) and not _equal(native, script):
		mismatches[op] = _first_difference(native, script, "")


func _arrays(solid: Solid) -> Array:
	return [solid.positions, solid.indices, solid.tags, solid.uvs]


# Exact equality, through Arrays and Dictionaries (Variant == on packed arrays compares
# their elements; floats bit for bit apart from -0 and 0).
func _equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _equal(a[i], b[i]):
				return false
		return true
	if a is Dictionary:
		if a.keys() != b.keys():
			return false
		for k in a:
			if not _equal(a[k], b[k]):
				return false
		return true
	return a == b


func _first_difference(a: Variant, b: Variant, where: String) -> String:
	if typeof(a) != typeof(b):
		return "%s: type %d vs %d" % [where, typeof(a), typeof(b)]
	if a is Array or a is PackedVector3Array or a is PackedInt32Array or a is PackedVector2Array or a is PackedFloat64Array:
		if a.size() != b.size():
			return "%s: size %d vs %d" % [where, a.size(), b.size()]
		for i in a.size():
			if not _equal(a[i], b[i]):
				return _first_difference(a[i], b[i], "%s[%d]" % [where, i])
	if a is Dictionary:
		if a.keys() != b.keys():
			return "%s: keys %s vs %s" % [where, a.keys(), b.keys()]
		for k in a:
			if not _equal(a[k], b[k]):
				return _first_difference(a[k], b[k], "%s[%s]" % [where, k])
	return "%s: %s vs %s" % [where, a, b]


# Sets of parts that go together, from a group number per part.
func _groups(group_of: PackedInt32Array) -> Array:
	var by := {}
	for i in group_of.size():
		if not by.has(group_of[i]):
			by[group_of[i]] = []
		(by[group_of[i]] as Array).append(i)
	var out := by.values()
	out.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	return out


# The GDScript joining (as in MeshSeparation.find_parts_job), for comparison.
func _join_in_script(corner_sets: Array, snap: float) -> PackedInt32Array:
	var parent := range(corner_sets.size())
	var root := func(i: int) -> int:
		while parent[i] != i:
			parent[i] = parent[parent[i]]
			i = parent[i]
		return i
	var grid := {}
	for i in corner_sets.size():
		for p: Vector3 in corner_sets[i]:
			var home := Vector3i((p / snap).round())
			for o in 27:
				var other: int = grid.get(home + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1), -1)
				if other >= 0:
					var a: int = root.call(i)
					var b: int = root.call(other)
					if a != b:
						parent[b] = a
			if not grid.has(home):
				grid[home] = i
	var out := PackedInt32Array()
	for i in corner_sets.size():
		out.append(root.call(i))
	return out


# A subdivided box: split at UV seams, so welding has work to do.
func _box_with_seams() -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.subdivide_width = 2
	mesh.subdivide_height = 2
	return mesh
