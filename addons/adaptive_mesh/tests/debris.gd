extends "test_suite.gd"
## Debris: Solid volume and islands, Voronoi cells, breaking up what a dig removed, and the
## fragments an AdaptiveMesh drops (on, off, limits, reset).


func run() -> void:
	_test_solid_helpers()
	_test_cells()
	await _test_clip()
	await _test_break_up()
	await _test_mesh_debris()
	await _test_off_and_limits()


func _test_solid_helpers() -> void:
	print("volume and islands")
	var box := Solid.from_mesh(_box_mesh())
	_check(absf(box.get_volume() - 64.0) < 1e-3, "a 4 x 4 x 4 box holds 64 (%.3f)" % box.get_volume())
	_check(box.get_islands().size() == 1 and box.get_islands()[0] == box, "one part: itself")
	var two := Solid.from_mesh(_box_mesh())
	var moved := box.transformed(Transform3D(Basis(), Vector3(10, 0, 0)))
	var base := two.positions.size()
	two.positions.append_array(moved.positions)
	two.uvs.append_array(moved.uvs)
	for i in moved.indices:
		two.indices.append(base + i)
	two.tags.append_array(moved.tags)
	var parts := two.get_islands()
	_check(parts.size() == 2 and parts.all(func(part: Solid) -> bool:
			return part.count_open_edges() == 0 and absf(part.get_volume() - 64.0) < 1e-3),
			"two boxes apart: two closed parts of 64 each")
	_check(MeshDebris.get_centre(moved).distance_to(Vector3(10, 0, 0)) < 1e-3, "centre of a moved box")


func _test_cells() -> void:
	print("voronoi cells")
	var box := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var seeds := PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 6:
		seeds.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)))
	var cells := MeshDebris.voronoi_cells(box, seeds, 3)
	var total := 0.0
	var closed := true
	for cell in cells:
		total += cell.get_volume()
		closed = closed and cell.count_open_edges() == 0 and cell.get_volume() > 0.0 and Array(cell.tags).all(
				func(tag: int) -> bool: return tag == 3)
	_check(cells.size() == 6 and closed, "six seeds: six closed, outward cells with the given tag")
	_check(absf(total - 8.0) < 1e-3, "together they fill the box (%.4f of 8)" % total)


func _test_clip() -> void:
	print("clipping")
	var box := Solid.from_mesh(_box_mesh())
	var half := MeshDebris.clip(box, Plane(Vector3(1, 1, 0).normalized(), 0.0), 5)
	_check(half != null and half.count_open_edges() == 0 and absf(half.get_volume() - 32.0) < 1e-3
			and _count_tag(half, 5) > 0, "a box cut diagonally through the middle: closed, half the volume, the cut tagged")
	_check(MeshDebris.clip(box, Plane(Vector3.UP, 5.0), 5) == box and MeshDebris.clip(box, Plane(Vector3.UP, -5.0), 5).is_empty(),
			"all inside: itself; all outside: empty")
	var sphere := _sphere(1.0).get_solid()
	var cap := MeshDebris.clip(sphere, Plane(Vector3(0.3, 1, 0.2).normalized(), 0.4), 5)
	var rest := MeshDebris.clip(sphere, Plane(-Vector3(0.3, 1, 0.2).normalized(), -0.4), 5)
	_check(cap.count_open_edges() == 0 and rest.count_open_edges() == 0
			and absf(cap.get_volume() + rest.get_volume() - sphere.get_volume()) < 1e-4,
			"a sphere cut in two: both closed, together the whole")
	# A box with a square hole through it: cut across the hole, the outline is a ring.
	var ring: Solid = await CsgBooleanBackend.new().combine(box, [BooleanOp.create(Solid.from_mesh(_tall_box()),
			Transform3D.IDENTITY, BooleanOp.Operation.SUBTRACT)] as Array[BooleanOp], AABB(), 1, 0)
	_check(MeshDebris.clip(ring, Plane(Vector3.UP, 0.3), 5) == null, "a cut with a hole: null (left to a boolean)")
	var settings := MeshDebris.new()
	settings.rng.seed = 2
	settings.fragment_size = 1.5
	settings.min_size = 0.0
	var fragments: Array[Solid] = await settings.break_up(ring, 1, CsgBooleanBackend.new())
	var total := 0.0
	for fragment in fragments:
		total += fragment.get_volume()
	_check(fragments.size() > 1 and absf(total - ring.get_volume()) < 1e-3,
			"breaking up the ring still adds up (%d fragments, %.3f of %.3f)" % [fragments.size(), total, ring.get_volume()])


func _tall_box() -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 6, 2)
	return mesh


func _test_break_up() -> void:
	print("breaking up")
	var settings := MeshDebris.new()
	settings.rng.seed = 3
	settings.fragment_size = 0.8
	settings.min_size = 0.0
	var removed := _sphere(1.5).get_solid().duplicate() as Solid
	var volume := removed.get_volume()
	var fragments: Array[Solid] = await settings.break_up(removed, 1, CsgBooleanBackend.new())
	var total := 0.0
	var closed := true
	for fragment in fragments:
		total += fragment.get_volume()
		closed = closed and fragment.count_open_edges() == 0
	_check(fragments.size() >= 4 and fragments.size() <= settings.max_fragments + 4 and closed,
			"a 1.5 sphere breaks into %d closed fragments" % fragments.size())
	_check(absf(total - volume) < 1e-3, "that add up to it (%.4f of %.4f)" % [total, volume])
	settings.fragment_size = 10.0
	fragments = await settings.break_up(removed, 1, CsgBooleanBackend.new())
	_check(fragments.size() == 1 and fragments[0] == removed, "smaller than one fragment: kept whole")
	settings.min_size = 3.0
	fragments = await settings.break_up(removed, 1, CsgBooleanBackend.new())
	_check(fragments.is_empty(), "smaller than min_size: dropped")


func _test_mesh_debris() -> void:
	print("mesh drops debris")
	var node := _adaptive(_box_mesh())
	node.position = Vector3(30, 0, 0)
	node.debris = MeshDebris.new()
	node.debris.rng.seed = 5
	node.debris.fragment_size = 0.5
	root.add_child(node)
	await _settle(node)
	var spawned: Array[RigidBody3D] = []
	node.debris_spawned.connect(func(bodies: Array[RigidBody3D]) -> void: spawned.append_array(bodies))
	var finished := [0]
	node.edited.connect(func() -> void: finished[0] += 1)
	var before := _only_solid(node).get_volume()
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(32, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle_debris(node, spawned)
	await _frames(3)
	_check(finished[0] == 1, "edited fires once the dig and its debris work are done (%d)" % finished[0])
	var after := _only_solid(node).get_volume()
	var total := 0.0
	var inside := true
	for body in spawned:
		var view := body.get_child(0) as MeshInstance3D
		total += Solid.from_mesh(view.mesh, 0, 0.0).get_volume()
		inside = inside and body.get_parent() == root and body.global_position.distance_to(Vector3(32, 2, 0)) < 1.1 \
				and body.find_children("*", "CollisionShape3D", false, false).size() == 1
	_check(spawned.size() >= 2 and inside, "%d fragments, rigid bodies with a hull, in the dig, in the scene" % spawned.size())
	_check(absf(total - (before - after)) < (before - after) * 0.005,
			"they hold what the dig removed (%.3f of %.3f)" % [total, before - after])
	_check(node.get_debris() == spawned, "get_debris() lists them")
	var others := spawned.size()
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(28, 2, 0)), BooleanOp.Operation.UNION)
	await _settle(node)
	await _frames(5)
	_check(spawned.size() == others, "building drops nothing")
	node.reset()
	await _settle(node)
	await process_frame
	_check(node.get_debris().is_empty() and spawned.all(func(body: Variant) -> bool: return not is_instance_valid(body)),
			"reset clears the debris")
	node.queue_free()
	await process_frame


func _test_off_and_limits() -> void:
	print("debris off, limits, lifetime")
	var node := _adaptive(_box_mesh())
	node.position = Vector3(-30, 0, 0)
	root.add_child(node)
	await _settle(node)
	var spawned: Array[RigidBody3D] = []
	node.debris_spawned.connect(func(bodies: Array[RigidBody3D]) -> void: spawned.append_array(bodies))
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(-32, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(node)
	await _frames(5)
	_check(spawned.is_empty(), "no debris setting: nothing")
	node.debris = MeshDebris.new()
	node.debris.enabled = false
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(-30, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(node)
	await _frames(5)
	_check(spawned.is_empty(), "enabled off: nothing")
	node.debris.enabled = true
	node.debris.max_bodies = 3
	node.debris.fragment_size = 0.4
	node.debris.lifetime = 0.3
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(-28, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle_debris(node, spawned)
	_check(spawned.size() > 3 and node.get_debris().size() == 3, "max_bodies keeps the newest 3 of %d" % spawned.size())
	var frames := 0
	while not node.get_debris().is_empty() and frames < 300:
		await process_frame
		frames += 1
	_check(node.get_debris().is_empty(), "lifetime frees them (after %d frames)" % frames)
	node.queue_free()
	await process_frame


# Waits for [param node]'s edits, then for its debris to land in [param spawned].
func _settle_debris(node: AdaptiveMesh, spawned: Array[RigidBody3D]) -> void:
	await _settle(node)
	var frames := 0
	while spawned.is_empty() and frames < 300:
		await process_frame
		frames += 1


func _frames(count: int) -> void:
	for i in count:
		await process_frame
