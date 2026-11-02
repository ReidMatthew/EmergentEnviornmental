extends "test_suite.gd"
## Soak (opt-in): a long random run of digs, builds and cuts on a static chunked mesh, a
## moving one, and every part that comes away (parts of parts too), checking after each
## step that every piece is closed, that the total volume (meshes, parts and plain bodies)
## changed by exactly what the edit should have removed or added (so separating loses and
## duplicates nothing), that the adaptive parts stay within max_parts, and that nothing
## fell through the floor. Worst frames are printed. At the end everything is freed and
## the object and orphan node counts must come back. Then a static mesh that splits its
## pieces at the slightest crowding (150 triangles), dug and cut for 100 steps: every piece
## must stay closed through splits, seams and cuts.

const STEPS := 60
const SEEDS: Array[int] = [1, 2]
const FLOOR_Y := -2.0
const MAX_PARTS := 10
const SPLIT_STEPS := 100
const SPLIT_SEEDS: Array[int] = [6, 7]

var _plain: Array[RigidBody3D] = []  # plain bodies: small parts, and parts made plain
var _bodies: Array[RigidBody3D] = []  # every part's body
var _rng := RandomNumberGenerator.new()


func run() -> void:
	for run_seed in SEEDS:
		await _soak(run_seed)
	for run_seed in SPLIT_SEEDS:
		await _soak_splits(run_seed)


# Digs and cuts on a static mesh whose pieces split at 150 triangles (no physics, so a seed
# always plays out the same).
func _soak_splits(run_seed: int) -> void:
	print("soak, deep splits, seed %d, %d steps" % [run_seed, SPLIT_STEPS])
	_rng.seed = run_seed
	var box := BoxMesh.new()
	box.size = Vector3(6, 4, 6)
	var node := _adaptive(box, false)
	node.position = Vector3(0, 0, 40)
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	node.chunking.split_above = 150
	root.add_child(node)
	await _settle(node)
	var failed_at := -1
	var worst := 0.0
	for step in SPLIT_STEPS:
		var op := _pick_op(node)
		if op.kind == "dig" or op.kind == "build":
			node.edit(op.shape, op.xform, BooleanOp.Operation.SUBTRACT)
		else:
			node.cut(op.from, op.to, op.direction, op.depth, op.thickness)
		var frame_stats: Array = await _settle_all()
		worst = maxf(worst, frame_stats[0])
		if node.data.pieces.values().any(func(solid: Solid) -> bool: return solid.count_open_edges() > 0):
			failed_at = step
			break
	_check(failed_at < 0, "%d steps, %d pieces from %d split cells: every piece closed%s (worst frame %.0f ms)" % [
			SPLIT_STEPS, node.data.pieces.size(), node.data.split_keys.size(),
			"" if failed_at < 0 else " (open pieces at step %d)" % failed_at, worst])
	node.queue_free()
	await process_frame


func _soak(run_seed: int) -> void:
	print("soak, seed %d, %d steps" % [run_seed, STEPS])
	_rng.seed = run_seed
	_plain.clear()
	_bodies.clear()
	await _frames(5)
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var stage := Node3D.new()
	root.add_child(stage)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(200, 1, 200)
	floor_shape.shape = slab
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, FLOOR_Y - 0.5, 0)
	stage.add_child(floor_body)
	var still := _static_mesh()
	stage.add_child(still)
	var moving_body := _moving_mesh()
	stage.add_child(moving_body)
	var moving: AdaptiveMesh = moving_body.get_child(0).get_child(0)
	await _settle_all()
	moving.activate()
	await _settle_all()
	var failures_before := failures
	var worst := {}  # op -> worst frame (ms)
	var slow := 0
	var separations := 0
	var steps_failed := 0
	for step in STEPS:
		var meshes := _alive()
		if meshes.is_empty():
			break
		var mesh: AdaptiveMesh = meshes[_rng.randi_range(0, meshes.size() - 1)]
		var mesh_name := mesh.name  # (the mesh may be gone after the edit: dug away)
		var op := _pick_op(mesh)
		var before := _total_volume()
		var detail_before := _detail()
		var delta := await _expected_change(mesh, op)
		var count_before := _alive().size()
		match op.kind:
			"dig":
				mesh.edit(op.shape, op.xform, BooleanOp.Operation.SUBTRACT)
			"build":
				mesh.edit(op.shape, op.xform, BooleanOp.Operation.UNION)
			"cut":
				mesh.cut(op.from, op.to, op.direction, op.depth, op.thickness)
		var frame_stats: Array = await _settle_all()
		worst[op.kind] = maxf(worst.get(op.kind, 0.0), frame_stats[0])
		slow += frame_stats[1]
		separations += maxi(_alive().size() - count_before, 0)
		var problems := _check_state(before + delta, still.separation, moving.separation)
		if not problems.is_empty():
			steps_failed += 1
			if steps_failed <= 5:
				printerr("  step %d (%s on %s, expected change %.3f): %s" % [step, op.kind, mesh_name, delta, "; ".join(problems)])
				printerr("    before: %s" % detail_before)
				printerr("    after:  %s" % _detail())
	_check(_alive().size() >= 2 and steps_failed == 0, "%d steps: every piece closed, volume conserved, parts within %d, nothing fell through (%d failed)"
			% [STEPS, MAX_PARTS, steps_failed])
	print("  %d meshes alive, %d plain bodies, %d separations; worst frame per op %s, %d frames over 33 ms"
			% [_alive().size(), _plain.filter(func(b: Variant) -> bool: return is_instance_valid(b)).size(), separations,
			_rounded(worst), slow])
	# Free everything; nothing should be left behind (parts not tracked too, should a step
	# have gone wrong).
	for mesh in AdaptiveMesh.get_all(tree):
		if mesh.is_moving() and mesh._owns_body:
			mesh.get_body().queue_free()
	for body in _bodies + _plain:
		if is_instance_valid(body):
			body.queue_free()
	stage.queue_free()
	await _frames(30)
	var objects_after := Performance.get_monitor(Performance.OBJECT_COUNT)
	var orphans_after := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	if orphans_after > orphans_before:
		Node.print_orphan_nodes()
	_check(orphans_after <= orphans_before and objects_after - objects_before < 30,
			"freed: objects %d -> %d, orphan nodes %d -> %d" % [objects_before, objects_after, orphans_before, orphans_after])
	if failures > failures_before:
		print("  (seed %d)" % run_seed)


# A 6 x 4 x 6 box (y from -2 to 2, on the floor) in 2 x 2 columns, static, with no
# collision mask (as static things usually are).
func _static_mesh() -> AdaptiveMesh:
	var box := BoxMesh.new()
	box.size = Vector3(6, 4, 6)
	box.subdivide_width = 2
	box.subdivide_height = 2
	box.subdivide_depth = 2
	var node := _adaptive(box)
	node.name = "Static"
	node.position = Vector3(-6, 0, 0)
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	node.collision = PieceCollision.new()
	node.collision.mask = 0
	node.separation = _separation()
	_watch(node)
	return node


# A 3 x 3 x 3 rigid box (mass 27, so a unit of volume weighs one), with an adaptive mesh
# component, dropped onto the floor.
func _moving_mesh() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Moving"
	body.position = Vector3(6, 0, 0)
	body.mass = 27.0
	var view := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(3, 3, 3)
	view.mesh = box
	body.add_child(view)
	var shape := CollisionShape3D.new()
	var hull := BoxShape3D.new()
	hull.size = Vector3(3, 3, 3)
	shape.shape = hull
	body.add_child(shape)
	var adaptive := AdaptiveMesh.new()
	adaptive.name = "MovingMesh"
	adaptive.separation = _separation()
	adaptive.collision = PieceCollision.new()
	adaptive.collision.hulls_per_piece = 4  # its parts (and theirs) inherit it
	view.add_child(adaptive)
	_watch(adaptive)
	return body


func _separation() -> MeshSeparation:
	var separation := MeshSeparation.new()
	# Dust under the default size (0.05 across, at most about 0.0001 of volume) is dropped:
	# well inside the volume check's tolerance. (Smaller bodies are below what physics
	# collides reliably.)
	separation.min_adaptive_size = 0.3
	separation.max_parts = MAX_PARTS
	return separation


# Keeps track of the parts [param mesh] (and its parts, and theirs) separate into.
func _watch(mesh: AdaptiveMesh) -> void:
	mesh.separated.connect(func(parts: Array[AdaptiveMesh], plain: Array[RigidBody3D]) -> void:
		for part in parts:
			_bodies.append(part.get_body())
			_watch(part)
		_plain.append_array(plain))


func _alive() -> Array[AdaptiveMesh]:
	var out: Array[AdaptiveMesh] = []
	for mesh in AdaptiveMesh.get_all(tree):
		# (Parts start dormant: not active until edited, but their data is theirs all the same.)
		if is_instance_valid(mesh) and not mesh.is_queued_for_deletion() and mesh.data != null \
				and not mesh.data.pieces.is_empty():
			out.append(mesh)
	return out


# A random edit for [param mesh], around its box: {kind, shape, xform} for digs and builds,
# {kind, from, to, direction, depth, thickness} for cuts (through or part way).
func _pick_op(mesh: AdaptiveMesh) -> Dictionary:
	var box := mesh.global_transform * mesh.get_aabb()
	var size := box.size.length()
	var point := box.position + box.size * Vector3(_rng.randf(), _rng.randf(), _rng.randf())
	var roll := _rng.randf()
	if roll < 0.5 or roll < 0.65:
		var sphere := SolidSphere.new()
		sphere.radius = clampf(size * _rng.randf_range(0.08, 0.25), 0.2, 1.2)
		return {kind = "dig" if roll < 0.5 else "build", shape = sphere, xform = Transform3D(Basis(), point)}
	# A cut: a line across the box through the point, cutting in a random direction square
	# to it, all the way through or part way.
	var along := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.3, 0.3), _rng.randf_range(-1, 1)).normalized()
	var direction := along.cross(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1))).normalized()
	if direction.is_zero_approx():
		direction = Vector3.DOWN
	var reach := size
	var start := point - direction * reach * 0.5
	var through := _rng.randf() < 0.6
	return {kind = "cut", from = start - along * reach, to = start + along * reach, direction = direction,
			depth = reach * (1.0 if through else _rng.randf_range(0.3, 0.5)), thickness = mesh.get_min_cut_thickness() * 3.0}


# How much the total volume should change: minus what of [param mesh] is inside a dig or a
# cut's slab, or what a build adds outside it.
func _expected_change(mesh: AdaptiveMesh, op: Dictionary) -> float:
	var shape: SolidShape
	var xform: Transform3D
	if op.kind == "cut":
		var slab := mesh.get_cut_slab(op.from, op.to, op.direction, op.depth, op.thickness)
		if slab.is_empty():
			return 0.0
		shape = slab[0]
		xform = slab[1]
	else:
		shape = op.shape
		xform = op.xform
	var solid := shape.get_solid()
	var local := mesh.global_transform.affine_inverse() * xform
	var inside := 0.0
	var backend := CsgBooleanBackend.new()
	for key: Vector4i in mesh.data.pieces:
		var piece: Solid = mesh.data.pieces[key]
		if piece.is_empty():
			continue
		var ops: Array[BooleanOp] = [BooleanOp.create(solid, local, BooleanOp.Operation.INTERSECT)]
		var overlap: Solid = await backend.combine(piece, ops, AABB(), 0, 0)
		if overlap != null:
			inside += overlap.get_volume()
	if op.kind == "build":
		return solid.get_volume() - inside
	return -inside


# Every adaptive mesh's volume, plus the plain bodies' (their mass: a unit of volume
# weighs one everywhere here).
func _total_volume() -> float:
	var total := 0.0
	for mesh in _alive():
		for key: Vector4i in mesh.data.pieces:
			total += (mesh.data.pieces[key] as Solid).get_volume()
	for body in _bodies + _plain:
		if is_instance_valid(body) and AdaptiveMesh.find(body) == null:
			total += body.mass  # plain: small, or made plain past max_parts
	return total


func _mesh_volume(mesh: AdaptiveMesh) -> float:
	var volume := 0.0
	for key: Vector4i in mesh.data.pieces:
		volume += (mesh.data.pieces[key] as Solid).get_volume()
	return volume


# Each mesh's volume and pieces, and the plain bodies' masses, for failure reports.
func _detail() -> String:
	var parts := PackedStringArray()
	for mesh in _alive():
		var volume := 0.0
		for key: Vector4i in mesh.data.pieces:
			volume += (mesh.data.pieces[key] as Solid).get_volume()
		parts.append("%s#%d %.3f (%d pieces)" % [mesh.name, mesh.get_instance_id() % 10000, volume, mesh.data.pieces.size()])
	for body in _bodies + _plain:
		if is_instance_valid(body) and AdaptiveMesh.find(body) == null:
			parts.append("plain %.3f" % body.mass)
	return ", ".join(parts)


# What's wrong now, given [param expected] total volume.
func _check_state(expected: float, still: MeshSeparation, moving: MeshSeparation) -> PackedStringArray:
	var problems := PackedStringArray()
	var open := 0
	for mesh in _alive():
		for key: Vector4i in mesh.data.pieces:
			if (mesh.data.pieces[key] as Solid).count_open_edges() > 0:
				open += 1
	if open > 0:
		var which := PackedStringArray()
		for mesh in _alive():
			for key: Vector4i in mesh.data.pieces:
				var solid: Solid = mesh.data.pieces[key]
				if solid.count_open_edges() > 0:
					which.append("%s %s (%d triangles, %d open edges)" % [mesh.name, key, solid.get_triangle_count(),
							solid.count_open_edges()])
		problems.append("%d open pieces: %s" % [open, ", ".join(which.slice(0, 8))])
	var total := _total_volume()
	if absf(total - expected) > 0.02 + absf(expected) * 0.002:
		problems.append("volume %.3f, expected %.3f" % [total, expected])
	for separation in [still, moving]:
		if separation.get_parts().size() > MAX_PARTS:
			problems.append("%d adaptive parts (max %d)" % [separation.get_parts().size(), MAX_PARTS])
	var fallen := PackedStringArray()
	for body in _bodies + _plain:
		if is_instance_valid(body) and body.global_position.y < FLOOR_Y - 3.0:
			var shapes := 0
			for owner_id in body.get_shape_owners():
				if not body.is_shape_owner_disabled(owner_id):
					shapes += body.shape_owner_get_shape_count(owner_id)
			var mesh := AdaptiveMesh.find(body)
			fallen.append("%s (%s, mass %.4f, %d shapes, speed %.1f%s)" % [body.name, "adaptive" if mesh != null else "plain",
					body.mass, shapes, body.linear_velocity.length(),
					", volume %.5f" % _mesh_volume(mesh) if mesh != null else ""])
	if not fallen.is_empty():
		problems.append("fell through the floor: %s" % ", ".join(fallen))
	return problems


# Waits until every mesh is idle, no separation is in flight and nothing new appears for
# a while: [worst frame (ms), frames over 33 ms].
func _settle_all() -> Array:
	var worst := 0.0
	var slow := 0
	var quiet := 0
	var last_count := -1
	var last := Time.get_ticks_usec()
	for frame in 900:
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		worst = maxf(worst, ms)
		if ms > 33.0:
			slow += 1
		var meshes := AdaptiveMesh.get_all(tree)
		var busy := meshes.any(func(m: AdaptiveMesh) -> bool: return not m.is_idle() or m._sep_checking)
		var count := meshes.size() + _plain.size()
		quiet = quiet + 1 if not busy and count == last_count else 0
		last_count = count
		if quiet >= 15:
			break
	return [worst, slow]


func _rounded(worst: Dictionary) -> String:
	var parts := PackedStringArray()
	for kind: String in worst:
		parts.append("%s %.0f ms" % [kind, worst[kind]])
	return ", ".join(parts)


func _frames(count: int) -> void:
	for i in count:
		await process_frame
