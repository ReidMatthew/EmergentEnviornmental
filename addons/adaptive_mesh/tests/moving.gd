extends "test_suite.gd"
## Moving mode: an AdaptiveMesh under a RigidBody3D puts its pieces' hulls on the body,
## keeps the body's mass and centre of mass with the shape, places edits in its own space,
## hands the body back as it was, and the body falls and lands on its hulls.


func run() -> void:
	await _test_takeover()
	await _test_rotated_dig()
	await _test_chunked()
	await _test_falls()
	await _test_emptied()
	await _test_hull_detail()


# A frozen RigidBody3D (mass 2) at [param at] with a 4 x 4 x 4 box mesh at [param offset]
# in it, its own box collision, and an AdaptiveMesh component on the mesh:
# [body, mesh instance, adaptive mesh, the body's own collision shape].
func _rigid_box(at: Vector3, offset: Vector3 = Vector3.ZERO, chunked: bool = false) -> Array:
	var body := RigidBody3D.new()
	body.position = at
	body.mass = 2.0
	body.freeze = true
	var view := MeshInstance3D.new()
	view.mesh = _box_mesh()
	view.position = offset
	body.add_child(view)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	shape.shape = box
	shape.position = offset
	body.add_child(shape)
	var adaptive := AdaptiveMesh.new()
	if chunked:
		adaptive.chunking = GridChunking.new()
		(adaptive.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	view.add_child(adaptive)
	root.add_child(body)
	return [body, view, adaptive, shape]


# The hull shapes pieces put on [param body]: [owner id, shape] per piece.
func _piece_hulls(body: RigidBody3D) -> Array:
	var out := []
	for owner_id in body.get_shape_owners():
		if body.shape_owner_get_owner(owner_id) is AdaptivePiece:
			for i in body.shape_owner_get_shape_count(owner_id):
				out.append([owner_id, body.shape_owner_get_shape(owner_id, i)])
	return out


func _test_takeover() -> void:
	print("moving: taking over a rigid body")
	var made := _rigid_box(Vector3(0, 0, 80), Vector3(1, 0, 0))
	var body: RigidBody3D = made[0]
	var adaptive: AdaptiveMesh = made[2]
	var own: CollisionShape3D = made[3]
	_check(adaptive.is_moving() and adaptive.get_body() == body and AdaptiveMesh.find(body) == adaptive,
			"it knows its body, and find() takes the body for the mesh")
	adaptive.activate()
	await _settle(adaptive)
	var hulls := _piece_hulls(body)
	_check(own.disabled and hulls.size() == 1 and hulls[0][1] is ConvexPolygonShape3D,
			"taking over: the body's own shape is off, the piece's hull is on the body")
	_check(body.shape_owner_get_transform(hulls[0][0]).origin.is_equal_approx(Vector3(1, 0, 0)),
			"placed where the mesh is in the body")
	_check(is_equal_approx(body.mass, 2.0) and body.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
			and body.center_of_mass.distance_to(Vector3(1, 0, 0)) < 1e-3,
			"mass as it was (%.3f), centre of mass in the middle of the mesh %s" % [body.mass, body.center_of_mass])
	_check(adaptive.get_collision_shapes() == [hulls[0][1]], "get_collision_shapes() gives the hulls")
	# A big bite out of the +x +y corner.
	adaptive.edit(_sphere(2.0), adaptive.global_transform * Transform3D(Basis(), Vector3(2, 2, 2)), BooleanOp.Operation.SUBTRACT)
	await _settle(adaptive)
	await process_frame
	var volume := _only_solid(adaptive).get_volume()
	hulls = _piece_hulls(body)
	_check(absf(body.mass - 2.0 * volume / 64.0) < 1e-3, "the mass follows the volume (%.3f for %.2f of 64)" % [body.mass, volume])
	var shift := body.center_of_mass - Vector3(1, 0, 0)
	_check(shift.x < -0.01 and shift.y < -0.01 and shift.z < -0.01, "the centre of mass moves away from the bite %s" % shift)
	_check(hulls.size() == 1 and (hulls[0][1] as ConvexPolygonShape3D).points.size() >= 4, "the hull is rebuilt (a new shape)")
	adaptive.reset()
	await process_frame
	_check(not own.disabled and _piece_hulls(body).is_empty() and is_equal_approx(body.mass, 2.0)
			and body.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_AUTO,
			"reset hands the body back: its own shape, no hulls, its mass and centre of mass as set")
	body.queue_free()
	await process_frame


func _test_rotated_dig() -> void:
	print("moving: digs land in the mesh's own space")
	var made := _rigid_box(Vector3(10, 0, 80))
	var body: RigidBody3D = made[0]
	var adaptive: AdaptiveMesh = made[2]
	body.rotation = Vector3(0.3, 1.2, -0.4)
	adaptive.activate()
	await _settle(adaptive)
	var local := Vector3(2, 2, 0)
	adaptive.edit(_sphere(1.0), adaptive.global_transform * Transform3D(Basis(), local), BooleanOp.Operation.SUBTRACT)
	# The body moves before the edit is applied: it still lands where it was aimed.
	body.position += Vector3(5, 0, 0)
	await _settle(adaptive)
	var solid := _only_solid(adaptive)
	var worst := 0.0
	var cut := 0
	for t in solid.get_triangle_count():
		if solid.tags[t] != 1:
			continue
		cut += 1
		for c in 3:
			worst = maxf(worst, absf(solid.positions[solid.indices[t * 3 + c]].distance_to(local) - 1.0))
	_check(cut > 0 and worst < 0.05, "a dig on a turned, moved body cuts round the point it was aimed at (off by %.3f)" % worst)
	body.queue_free()
	await process_frame


func _test_chunked() -> void:
	print("moving: chunked")
	var made := _rigid_box(Vector3(20, 0, 80), Vector3.ZERO, true)
	var body: RigidBody3D = made[0]
	var adaptive: AdaptiveMesh = made[2]
	adaptive.activate()
	await _settle(adaptive)
	_check(_piece_hulls(body).size() == 4 and adaptive.get_pieces().size() == 4, "one hull per piece (%d)" % _piece_hulls(body).size())
	_check(is_equal_approx(body.mass, 2.0) and body.center_of_mass.length() < 1e-3, "mass and centre from all the pieces")
	body.queue_free()
	await process_frame


func _test_falls() -> void:
	print("moving: falls and lands")
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var plane := BoxShape3D.new()
	plane.size = Vector3(40, 1, 40)
	floor_shape.shape = plane
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(30, -0.5, 80)
	root.add_child(floor_body)
	var made := _rigid_box(Vector3(30, 6, 80))
	var body: RigidBody3D = made[0]
	var adaptive: AdaptiveMesh = made[2]
	adaptive.activate()
	await _settle(adaptive)
	# Dig a notch out of the bottom, so it stands on what's left.
	adaptive.edit(_sphere(1.0), adaptive.global_transform * Transform3D(Basis(), Vector3(0, -2, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(adaptive)
	body.freeze = false
	for i in 240:
		await tree.physics_frame
	_check(body.position.y > 1.6 and body.position.y < 2.4 and body.linear_velocity.length() < 0.5,
			"it falls onto the floor and rests on its hull (centre at y = %.2f)" % body.position.y)
	body.queue_free()
	floor_body.queue_free()
	await process_frame


# Everything dug away: a body of the user's is frozen (it would fall with nothing to
# collide with), a separated part's body is freed.
func _test_emptied() -> void:
	print("moving: emptied")
	var made := _rigid_box(Vector3(40, 0, 80))
	var body: RigidBody3D = made[0]
	var adaptive: AdaptiveMesh = made[2]
	body.freeze = false
	body.gravity_scale = 0.0
	adaptive.separation = MeshSeparation.new()
	adaptive.activate()
	await _settle(adaptive)
	# Cut the top quarter off: it comes away as a part on a body of its own.
	var parts: Array[AdaptiveMesh] = []
	adaptive.separated.connect(func(new_parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: parts.append_array(new_parts))
	var slab := SolidBox.new()
	slab.size = Vector3(10, 0.4, 10)
	adaptive.edit(slab, adaptive.global_transform * Transform3D(Basis(), Vector3(0, 1.0, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(adaptive)
	for i in 300:
		if not parts.is_empty():
			break
		await process_frame
	if parts.size() != 1:
		_check(false, "a part comes away to dig away (%d)" % parts.size())
		body.queue_free()
		return
	var part := parts[0]
	var part_body := part.get_body()
	part_body.gravity_scale = 0.0
	await _settle(part)
	var emptied := [0, 0]
	adaptive.emptied.connect(func() -> void: emptied[0] += 1)
	part.emptied.connect(func() -> void: emptied[1] += 1)
	var huge := _sphere(6.0)
	part.edit(huge, part.global_transform, BooleanOp.Operation.SUBTRACT)
	adaptive.edit(huge, adaptive.global_transform, BooleanOp.Operation.SUBTRACT)
	for i in 120:
		await process_frame
	_check(emptied == [1, 1], "both report they're empty (%s)" % [emptied])
	_check(not is_instance_valid(part_body), "the part's body is freed")
	_check(is_instance_valid(body) and body.freeze, "the user's body is frozen, not freed")
	body.queue_free()
	await process_frame


# A slot cut down through a rigid box: one hull fills it in; more hulls leave it open.
func _test_hull_detail() -> void:
	print("moving: hulls per piece")
	var results := {}
	for hulls in [1, 8]:
		var made := _rigid_box(Vector3(50 + hulls * 10, 0, 80))
		var body: RigidBody3D = made[0]
		var adaptive: AdaptiveMesh = made[2]
		adaptive.collision = PieceCollision.new()
		adaptive.collision.hulls_per_piece = hulls
		adaptive.activate()
		await _settle(adaptive)
		var slot := SolidBox.new()
		slot.size = Vector3(1.6, 3.0, 6.0)
		adaptive.edit(slot, adaptive.global_transform * Transform3D(Basis(), Vector3(0, 1.0, 0)), BooleanOp.Operation.SUBTRACT)
		await _settle(adaptive)
		await tree.physics_frame
		await tree.physics_frame
		var space := body.get_world_3d().direct_space_state
		var in_slot := PhysicsPointQueryParameters3D.new()
		in_slot.position = adaptive.global_transform * Vector3(0, 1.0, 0)
		var in_wall := PhysicsPointQueryParameters3D.new()
		in_wall.position = adaptive.global_transform * Vector3(1.5, 1.0, 0)
		results[hulls] = [_piece_hulls(body).size(), not space.intersect_point(in_slot).is_empty(),
				not space.intersect_point(in_wall).is_empty()]
		body.queue_free()
		await process_frame
	_check(results[1] == [1, true, true], "one hull: the slot is filled in (%s)" % [results[1]])
	_check(results[8][0] > 1 and results[8][1] == false and results[8][2] == true,
			"%d hulls: the slot is open, the walls still collide (%s)" % [results[8][0], results[8]])
