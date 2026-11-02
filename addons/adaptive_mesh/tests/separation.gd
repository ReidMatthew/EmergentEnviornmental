extends "test_suite.gd"
## Separation: parts that digs and cuts divide off become adaptive meshes of their own on
## RigidBody3Ds, inheriting their pieces; anchors; parts separate from the start; off
## checks nothing; a moving mesh's parts keep its velocity; parts divide again; small parts
## across cell walls merged into one piece; limits (plain small parts, the most adaptive
## parts at once), and nothing running per frame for a part at rest.


func run() -> void:
	await _test_separates()
	await _test_no_mask()
	await _test_off()
	await _test_anchors()
	await _test_separate_from_the_start()
	await _test_moving_parent()
	await _test_merge()
	await _test_small_part_merged()
	await _test_plain_small_part()
	await _test_max_parts(MeshSeparation.OverLimit.MAKE_PLAIN)
	await _test_max_parts(MeshSeparation.OverLimit.FREE)


# A 4 x 4 x 4 box (y from -2 to 2) in 2 x 2 columns with separation on (or off).
func _chunked_box(at: Vector3, anchor: MeshSeparation.Anchor = MeshSeparation.Anchor.AUTO, on: bool = true) -> AdaptiveMesh:
	var node := _adaptive(_box_mesh())
	node.position = at
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	if on:
		node.separation = MeshSeparation.new()
		node.separation.anchor = anchor
	root.add_child(node)
	return node


# Cuts [param node] (at its position) right through with a level slab [param thickness]
# thick at height [param y], or only part of the way across.
func _slab(node: AdaptiveMesh, y: float, across: float = 10.0, thickness: float = 0.5) -> void:
	var slab := SolidBox.new()
	slab.size = Vector3(across, thickness, 10.0)
	node.edit(slab, node.global_transform * Transform3D(Basis(), Vector3((across - 10.0) * 0.5, y, 0)),
			BooleanOp.Operation.SUBTRACT)


func _volume(node: AdaptiveMesh) -> float:
	var volume := 0.0
	for key: Vector4i in node.data.pieces:
		volume += (node.data.pieces[key] as Solid).get_volume()
	return volume


func _closed(node: AdaptiveMesh) -> bool:
	return node.data.pieces.values().all(func(solid: Solid) -> bool: return solid.count_open_edges() == 0)


func _middle(node: AdaptiveMesh) -> Vector3:
	return (node.global_transform * node.get_aabb()).get_center()


func _wait_for(made: Array, frames: int = 300) -> void:
	for i in frames:
		if not made.is_empty():
			return
		await process_frame


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _test_separates() -> void:
	print("separation: a part cut off becomes a mesh of its own")
	var node := _chunked_box(Vector3(0, 0, 120))
	await _settle(node)
	var made: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	_slab(node, 0.5, 6.0)  # x from -5 to 1: the last unit still holds the top on
	await _settle(node)
	await _frames(20)
	_check(made.is_empty(), "a cut that doesn't go all the way round: nothing separates")
	_slab(node, 0.5)  # now all the way through
	await _settle(node)
	await _wait_for(made)
	_check(made.size() == 1, "cut all the way round: one part (%d)" % made.size())
	if made.size() != 1:
		node.queue_free()
		return
	var part := made[0]
	var body := part.get_body()
	_check(part.is_moving() and body != null and body.get_parent() == root and AdaptiveMesh.find(body) == part,
			"it's an adaptive mesh on a rigid body in the scene, and find() knows it")
	_check(body.physics_material_override != null and is_equal_approx(body.physics_material_override.friction, node.separation.friction),
			"its body has the separation's friction (%.2f)" % node.separation.friction)
	_check(part.data.pieces.size() == 4 and part.data.pieces.keys().all(func(key: Vector4i) -> bool: return node.data.pieces.has(key))
			and part.data.chunking == node.data.chunking,
			"it inherits the pieces it was made of: the same keys and chunk grid (%d pieces)" % part.data.pieces.size())
	await _settle(part)
	_check(_closed(part) and absf(_volume(part) - 4.0 * 4.0 * 1.25) < 0.05 and _middle(part).y > 0.75,
			"closed, the top's volume (%.2f of 20), above the cut" % _volume(part))
	_check(_closed(node) and absf(_volume(node) - 4.0 * 4.0 * 2.25) < 0.05, "the mesh keeps the bottom (%.2f of 36)" % _volume(node))
	_check(absf(body.mass - _volume(part)) < 0.05, "its mass comes from its volume and the density (%.2f)" % body.mass)
	_check(body.collision_layer == 1 and body.collision_mask & 1, "on the mesh's layer, and colliding with it")
	var start := body.global_position.y
	await _frames(30)
	_check(not body.freeze and body.global_position.y < start - 0.05, "it's let go once its hulls are on, and falls")
	# It's adaptive: dig it, then cut it in two (it moves now: the bigger part stays on it).
	var again: Array[AdaptiveMesh] = []
	part.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: again.append_array(parts))
	body.freeze = true
	var before := _volume(part)
	part.edit(_sphere(0.6), part.global_transform * Transform3D(Basis(), Vector3(-1.0, 2.0, -1.0)), BooleanOp.Operation.SUBTRACT)
	await _settle(part)
	_check(_volume(part) < before - 0.1, "it can be dug (%.2f -> %.2f)" % [before, _volume(part)])
	var cut := SolidBox.new()
	cut.size = Vector3(0.3, 10.0, 10.0)
	part.edit(cut, part.global_transform * Transform3D(Basis(), Vector3(1.0, 0, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(part)
	await _wait_for(again)
	_check(again.size() == 1 and _middle(again[0]).x > _middle(part).x, "and divided again: the smaller side leaves it (%d)" % again.size())
	for each in again + [part]:
		each.get_body().queue_free()
	node.queue_free()
	await process_frame


# A static mesh whose own body has no mask (usual for static things): its parts still
# collide with the world it came from.
func _test_no_mask() -> void:
	print("separation: parts of a static mesh with no mask")
	var node := _chunked_box(Vector3(90, 0, 120))
	node.collision = PieceCollision.new()
	node.collision.layer = 2
	node.collision.mask = 0
	await _settle(node)
	var made: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	_slab(node, 1.0)
	await _settle(node)
	await _wait_for(made)
	_check(made.size() == 1 and made[0].get_body().collision_layer == 2 and made[0].get_body().collision_mask == 2,
			"the part is on the mesh's layer and collides with it (mask %d)" % (made[0].get_body().collision_mask if made.size() == 1 else -1))
	for part in made:
		part.get_body().queue_free()
	node.queue_free()
	await process_frame


func _test_off() -> void:
	print("separation: off")
	var off := _chunked_box(Vector3(0, 0, 130), MeshSeparation.Anchor.AUTO, false)
	await _settle(off)
	_slab(off, 0.5)
	await _settle(off)
	await _frames(20)
	_check(off._sep_cache.is_empty() and off._sep_dirty.is_empty() and _volume(off) > 50.0,
			"no setting: nothing is looked at, the mesh stays whole")
	off.queue_free()
	await process_frame


func _test_anchors() -> void:
	print("separation: anchors")
	var largest := _chunked_box(Vector3(10, 0, 120), MeshSeparation.Anchor.LARGEST)
	var nothing := _chunked_box(Vector3(20, 0, 120), MeshSeparation.Anchor.NOTHING)
	await _settle(largest)
	await _settle(nothing)
	var from_largest: Array[AdaptiveMesh] = []
	var from_nothing: Array[AdaptiveMesh] = []
	largest.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: from_largest.append_array(parts))
	nothing.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: from_nothing.append_array(parts))
	# Cut through the middle of the columns' height... at y = -1: bottom 0.75 thick, top 2.75.
	_slab(largest, -1.0)
	_slab(nothing, 1.0)  # top 0.75, bottom 2.75
	await _settle(largest)
	await _settle(nothing)
	await _wait_for(from_largest)
	await _wait_for(from_nothing)
	await _frames(10)
	_check(from_largest.size() == 1 and _middle(from_largest[0]).y < -1.0,
			"largest: the smaller bottom separates, the top stays (%d)" % from_largest.size())
	await _settle(nothing)
	_check(from_nothing.size() == 2 and nothing.get_pieces().is_empty() and nothing.data.pieces.is_empty(),
			"nothing: both parts separate, and the mesh is left with no pieces (%d)" % from_nothing.size())
	# Until edited, a part shows as one mesh (its target), its pieces' surfaces joined; taking
	# over, each piece gets its own mesh at once (from surfaces kept for it), nothing built.
	var one_mesh := from_nothing.all(func(part: AdaptiveMesh) -> bool:
		var view := part.get_target() as MeshInstance3D
		return view != null and view.mesh != null and view.mesh.get_aabb().grow(0.01).encloses(part.get_aabb()))
	for part in from_nothing:
		part.activate()
	var drawn := from_nothing.all(func(part: AdaptiveMesh) -> bool:
		return part.data.meshes.size() == part.data.pieces.size() and part.get_pieces().values().all(
				func(piece: AdaptivePiece) -> bool: return piece.get_mesh() != null))
	_check(one_mesh and drawn, "a part shows as one mesh until edited, then each piece has its own at once (%d parts)"
			% from_nothing.size())
	for part in from_largest + from_nothing:
		part.get_body().queue_free()
	largest.queue_free()
	nothing.queue_free()
	await process_frame


# A mesh made of two boxes from the start, one floating: digging the other leaves it be.
func _test_separate_from_the_start() -> void:
	print("separation: parts separate from the start")
	var two := ArrayMesh.new()
	var box := _box_mesh()
	var floating := box.get_mesh_arrays()
	var moved := PackedVector3Array()
	for p: Vector3 in floating[Mesh.ARRAY_VERTEX]:
		moved.append(p + Vector3(0, 6, 0))
	floating[Mesh.ARRAY_VERTEX] = moved
	two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, floating)
	var node := _adaptive(two)
	node.position = Vector3(30, 0, 120)
	node.separation = MeshSeparation.new()
	root.add_child(node)
	await _settle(node)
	await _frames(10)
	var made: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	node.edit(_sphere(1.0), Transform3D(Basis(), node.position + Vector3(2, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(node)
	await _frames(20)
	_check(made.is_empty(), "a dig in the same piece: the floating box stays")
	_slab(node, 0.5)
	await _settle(node)
	await _wait_for(made)
	await _frames(5)
	_check(made.size() == 1 and _middle(made[0]).y < 3.0, "cutting the standing box: only its top separates (%d)" % made.size())
	for part in made:
		part.get_body().queue_free()
	node.queue_free()
	await process_frame


# A rigid box drifting sideways in no gravity, cut through: the part leaves with its speed.
func _test_moving_parent() -> void:
	print("separation: a moving mesh's parts keep its velocity")
	var body := RigidBody3D.new()
	body.position = Vector3(40, 0, 120)
	body.gravity_scale = 0.0
	body.mass = 4.0
	var view := MeshInstance3D.new()
	view.mesh = _box_mesh()
	body.add_child(view)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	shape.shape = box
	body.add_child(shape)
	var adaptive := AdaptiveMesh.new()
	adaptive.separation = MeshSeparation.new()
	view.add_child(adaptive)
	root.add_child(body)
	adaptive.activate()
	await _settle(adaptive)
	body.linear_velocity = Vector3(3, 0, 0)
	var made: Array[AdaptiveMesh] = []
	adaptive.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	_slab(adaptive, 1.0)  # the top 0.75 comes off; the body keeps the bigger bottom
	await _settle(adaptive)
	await _wait_for(made)
	await _frames(20)
	_check(made.size() == 1 and made[0].get_body() != body and _middle(made[0]).y > _middle(adaptive).y,
			"the smaller part leaves; the moving body keeps the bigger one (%d)" % made.size())
	if made.size() == 1:
		var speed := made[0].get_body().linear_velocity
		_check(speed.distance_to(Vector3(3, 0, 0)) < 0.3, "and it carries on at the body's speed %s" % speed)
		_check(absf(body.mass - 4.0 * _volume(adaptive) / 64.0) < 0.05 and absf(made[0].get_body().mass - 4.0 * _volume(made[0]) / 64.0) < 0.05,
				"both weigh what their share of the mass is (%.2f, %.2f)" % [body.mass, made[0].get_body().mass])
		made[0].get_body().queue_free()
	body.queue_free()
	await process_frame


# Meshes smaller than a cell but across its corner: their pieces join into one.
func _test_merge() -> void:
	print("separation: merging pieces")
	var box := BoxMesh.new()
	box.size = Vector3(1.5, 1.5, 1.5)
	box.subdivide_width = 2
	box.subdivide_depth = 2
	# An icosphere (Godot's SphereMesh isn't closed at its seam).
	var ball := _sphere(0.7, 3).get_solid()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = ball.positions
	arrays[Mesh.ARRAY_INDEX] = ball.indices
	var sphere := ArrayMesh.new()
	sphere.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	for mesh: Mesh in [box, sphere]:
		var node := _adaptive(mesh, false)
		node.position = Vector3(50, 0, 120)
		node.chunking = GridChunking.new()
		(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
		root.add_child(node)
		await _settle(node)
		var before := _volume(node)
		var joined := node.data.merged()
		var name := "a box" if mesh == box else "a sphere"
		_check(node.data.pieces.size() == 4 and joined != null and joined.pieces.size() == 1 and joined.chunking == null,
				"%s across a cell corner: 4 pieces become 1, without chunking" % name)
		if joined != null:
			var solid: Solid = joined.pieces.values()[0]
			_check(solid.count_open_edges() == 0 and absf(solid.get_volume() - before) < 1e-4 and _count_tag(solid, node.data.get_cap_tag()) == 0,
					"%s merged: closed, the same volume (%.4f of %.4f), no walls left" % [name, solid.get_volume(), before])
		node.queue_free()
		await process_frame


# A small block on a chunked base, cut off at its foot: it comes away as one piece.
func _test_small_part_merged() -> void:
	print("separation: a small part comes away as one piece")
	var node := _chunked_box(Vector3(60, 0, 120))
	await _settle(node)
	var block := SolidBox.new()
	block.size = Vector3(1.5, 1.5, 1.5)
	node.edit(block, node.global_transform * Transform3D(Basis(), Vector3(0, 2.6, 0)), BooleanOp.Operation.UNION)
	await _settle(node)
	await _frames(5)
	var made: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	_slab(node, 2.1, 10.0, 0.2)  # just above the base's top, under the block
	await _settle(node)
	await _wait_for(made)
	_check(made.size() == 1, "the block comes away (%d)" % made.size())
	if made.size() == 1:
		var part := made[0]
		_check(not part.is_active() and part.get_pieces().is_empty(), "it comes away dormant (a plain body until edited)")
		part.activate()
		await _settle(part)
		var solid := _only_solid(part)
		_check(part.data.pieces.size() == 1 and part.data.chunking == null and part.get_pieces().size() == 1
				and solid.count_open_edges() == 0 and absf(solid.get_volume() - 1.5 * 1.5 * 1.15) < 0.02,
				"as one closed piece without chunking (%d pieces, %.3f of %.3f)" % [part.data.pieces.size(),
				solid.get_volume(), 1.5 * 1.5 * 1.15])
		part.get_body().queue_free()
	node.queue_free()
	await process_frame


# A small block on a chunked base, cut off, with min_adaptive_size above its size: it comes
# away as a plain rigid body.
func _test_plain_small_part() -> void:
	print("separation: small parts come away plain")
	var node := _chunked_box(Vector3(70, 0, 120))
	node.separation.min_adaptive_size = 2.0
	await _settle(node)
	var block := SolidBox.new()
	block.size = Vector3(1.5, 1.5, 1.5)
	node.edit(block, node.global_transform * Transform3D(Basis(), Vector3(0, 2.6, 0)), BooleanOp.Operation.UNION)
	await _settle(node)
	await _frames(5)
	var made: Array[AdaptiveMesh] = []
	var plain: Array[RigidBody3D] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], bodies: Array[RigidBody3D]) -> void:
		made.append_array(parts)
		plain.append_array(bodies))
	_slab(node, 2.1, 10.0, 0.2)
	await _settle(node)
	await _wait_for(plain)
	_check(made.is_empty() and plain.size() == 1, "the block comes away as a plain body (%d plain, %d adaptive)" % [plain.size(), made.size()])
	if plain.size() == 1:
		var body := plain[0]
		var views := body.find_children("*", "MeshInstance3D", false, false)
		var shapes := body.find_children("*", "CollisionShape3D", false, false)
		_check(views.size() == 1 and shapes.size() == 1 and shapes[0].shape is ConvexPolygonShape3D
				and AdaptiveMesh.find(body) == null and not body.freeze,
				"drawn, colliding as one hull, not adaptive, moving")
		_check(absf(body.mass - 1.5 * 1.5 * 1.15) < 0.05, "mass from its volume (%.3f)" % body.mass)
		body.queue_free()
	node.queue_free()
	await process_frame


# max_parts 1: cutting off a second part deals with the first as [param how] says.
func _test_max_parts(how: MeshSeparation.OverLimit) -> void:
	print("separation: max_parts (%s)" % ("make plain" if how == MeshSeparation.OverLimit.MAKE_PLAIN else "free"))
	var node := _chunked_box(Vector3(80, 0, 120))
	node.separation.max_parts = 1
	node.separation.over_limit = how
	await _settle(node)
	var made: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: made.append_array(parts))
	_slab(node, 1.0)
	await _settle(node)
	await _wait_for(made)
	if made.size() != 1:
		_check(false, "the first part comes away (%d)" % made.size())
		node.queue_free()
		return
	var first := made[0]
	var first_body := first.get_body()
	await _settle(first)
	await _frames(5)
	_check(not first.is_processing() and not first.is_physics_processing()
			and first.get_pieces().values().all(func(piece: AdaptivePiece) -> bool: return not piece.is_processing() and not piece.is_physics_processing()),
			"a part at rest has nothing running per frame")
	first_body.freeze = true  # keep it where it is
	_slab(node, -0.5)
	await _settle(node)
	for i in 300:
		if made.size() > 1:
			break
		await process_frame
	await _frames(3)
	_check(made.size() == 2 and node.separation.get_parts() == [made[1]], "the second part comes away; only it counts now")
	if how == MeshSeparation.OverLimit.MAKE_PLAIN:
		_check(not is_instance_valid(first) and is_instance_valid(first_body)
				and first_body.find_children("*", "MeshInstance3D", true, false).size() == 1
				and first_body.find_children("*", "CollisionShape3D", true, false).size() == 4,
				"the first is made plain: its node gone, its body keeps its mesh (its 4 pieces as one) and 4 hulls")
	else:
		_check(not is_instance_valid(first_body), "the first is freed, body and all")
	for each in made:
		if is_instance_valid(each):
			each.get_body().queue_free()
	if is_instance_valid(first_body):
		first_body.queue_free()
	node.queue_free()
	await process_frame
