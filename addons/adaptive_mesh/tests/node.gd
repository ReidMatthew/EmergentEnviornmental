extends "test_suite.gd"
## AdaptiveMesh as one piece: baking, drawing, queued edits, collision, materials, bounds,
## reset.


func run() -> void:
	await _test_node()
	await _test_bounds_and_settings()


func _test_node() -> void:
	print("adaptive mesh node")
	var node := _adaptive(_box_mesh())
	node.position = Vector3(10, 0, 0)
	var baked := [false]
	node.baked.connect(func() -> void: baked[0] = true)
	root.add_child(node)
	await _settle(node)
	_check(baked[0] and node.get_pieces().size() == 1 and node.data.is_baked(), "bakes on its own: one piece, data filled")
	var piece: AdaptivePiece = node.get_pieces()[Vector4i.ZERO]
	_check(piece.get_mesh().get_surface_count() == 1, "draws the source mesh")
	var finished := [0]
	var batches := [0]
	node.edited.connect(func() -> void: finished[0] += 1)
	node.piece_edited.connect(func(_key: Vector4i) -> void: batches[0] += 1)
	var sphere := _sphere(1.0)
	for x in [-1.0, 0.0, 1.0]:
		node.edit(sphere, Transform3D(Basis(), Vector3(10 + x, 2, 0)), BooleanOp.Operation.SUBTRACT)
	_check(not node.is_idle(), "busy after queueing edits")
	await _settle(node)
	await process_frame
	_check(batches[0] == 1 and finished[0] == 1, "three edits in one frame: %d batch(es) (all of a frame's edits go in one job), edited %d time(s)"
			% [batches[0], finished[0]])
	_check(piece.get_mesh().get_surface_count() == 2 and piece.solid.count_open_edges() == 0,
			"tags 0 and 1 drawn as two surfaces; closed")
	_check(node.data.pieces[Vector4i.ZERO] == piece.solid and node.data.meshes[Vector4i.ZERO] == piece.get_mesh(),
			"edits are in the data (shape and mesh)")
	# Collision follows the edit: a ray down the middle of the trench lands on its floor.
	await tree.physics_frame
	await tree.physics_frame
	var space := node.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(10, 10, 0), Vector3(10, -10, 0)))
	_check(not hit.is_empty() and hit.position.y < 1.2,
			"collision updated (ray hits at y = %.2f)" % (hit.position.y if not hit.is_empty() else NAN))
	node.reset()
	await _settle(node)
	_check(_only_solid(node).get_triangle_count() == 192, "reset bakes again from the source")
	node.queue_free()


func _test_bounds_and_settings() -> void:
	print("bounds, materials, collision off")
	var cut := StandardMaterial3D.new()
	var node := _adaptive(_box_mesh(), false)
	node.drawing = PieceDrawing.new()
	node.drawing.materials = [null, cut]
	node.max_bounds = AABB(Vector3(-2, -2, -2), Vector3(4, 4.5, 4))  # top at y = 2.5
	root.add_child(node)
	await _settle(node)
	node.edit(_sphere(1.0), Transform3D(Basis(), Vector3(0, 2.2, 0)), BooleanOp.Operation.UNION)
	await _settle(node)
	var solid := _only_solid(node)
	var top := solid.get_aabb().end.y
	var top_tags := {}
	for t in solid.get_triangle_count():
		var on_top := true
		for c in 3:
			on_top = on_top and absf(solid.positions[solid.indices[t * 3 + c]].y - 2.5) < 1e-4
		if on_top:
			top_tags[solid.tags[t]] = true
	_check(absf(top - 2.5) < 1e-4 and solid.count_open_edges() == 0 and top_tags.keys() == [1],
			"a bump cut off at max_bounds is closed by a face with the shape's tag (shown), top y = %.2f" % top)
	var piece: AdaptivePiece = node.get_pieces()[Vector4i.ZERO]
	var instance := piece.get_child(0, true) as MeshInstance3D
	var cut_surface := -1
	for s in piece.get_mesh().get_surface_count():
		if piece.get_mesh().surface_get_name(s) == "tag_1":
			cut_surface = s
	_check(cut_surface >= 0 and instance.get_surface_override_material(cut_surface) == cut, "drawing.materials sets tag 1's material")
	var bodies := piece.find_children("*", "StaticBody3D", true, false)
	_check(bodies.is_empty(), "collision off: no body")
	node.queue_free()
