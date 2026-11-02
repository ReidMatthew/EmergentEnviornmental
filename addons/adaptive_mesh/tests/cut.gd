extends "test_suite.gd"
## Cuts (thin slab subtractions: notches, and cuts right through that divide a mesh), their
## thickness limits, dismantling into cubes, and the frame budget shared by every mesh.


func run() -> void:
	await _test_shared_budget()
	await _test_cuts()
	await _test_cut_divides()
	await _test_cut_makes_no_debris()
	await _test_dismantle()
	await _test_dismantle_draws_each_part()


func _test_shared_budget() -> void:
	print("shared frame budget")
	await process_frame
	var first := FrameBudget.new()
	var second := FrameBudget.new()
	first.spend(5000)
	_check(FrameBudget.get_used_usec() >= 5000, "time one budget spends counts for all")
	var frame := Engine.get_process_frames()
	await second.wait_turn()
	_check(Engine.get_process_frames() > frame, "so another mesh's budget waits for the next frame")
	second.spend(5000)
	var unlimited := FrameBudget.new()
	unlimited.budget_ms = 0.0
	frame = Engine.get_process_frames()
	await unlimited.wait_turn()
	_check(Engine.get_process_frames() == frame, "a budget of 0 runs at once")
	# Jobs that wait go nearest first (lowest priority), whatever order they came in, and the
	# first of a frame always runs.
	await process_frame
	first.spend(5000)
	var order: Array[float] = []
	var job := func(priority: float) -> void:
		await second.wait_turn(priority)
		order.append(priority)
		second.spend(5000)
	for priority: float in [30.0, 10.0, 20.0]:
		job.call(priority)
	for i in 5:
		await process_frame
	_check(order == [10.0, 20.0, 30.0], "waiting jobs go nearest the camera first (%s)" % [order])


func _test_cuts() -> void:
	print("cuts")
	var node := _adaptive(_box_mesh(), false)
	node.position = Vector3(0, 0, -40)
	root.add_child(node)
	await _settle(node)
	_check(node.get_aabb().is_equal_approx(AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))), "get_aabb() is the box")
	_check(is_equal_approx(node.get_cut_thickness(), 4.0 / 1000.0) and is_equal_approx(node.get_min_cut_thickness(), 4.0 / 1000.0),
			"default and thinnest cut follow the size (%.4f, %.4f)" % [node.get_cut_thickness(), node.get_min_cut_thickness()])
	# Across the top, a unit deep: a notch.
	var t := node.get_cut_thickness()
	node.cut(node.position + Vector3(-3, 2, 0), node.position + Vector3(3, 2, 0), Vector3.DOWN, 1.0)
	await _settle(node)
	var solid := _only_solid(node)
	_check(solid.get_islands().size() == 1 and solid.count_open_edges() == 0
			and absf(solid.get_volume() - (64.0 - 4.0 * t)) < 1e-3,
			"a cut a unit deep is a notch: one closed part, %.4f of %.4f left" % [solid.get_volume(), 64.0 - 4.0 * t])
	# Down the same line, right through: two halves.
	node.cut(node.position + Vector3(-3, 2.5, 0), node.position + Vector3(3, 2.5, 0), Vector3.DOWN, 5.0)
	await _settle(node)
	solid = _only_solid(node)
	var halves := solid.get_islands()
	_check(halves.size() == 2 and solid.count_open_edges() == 0 and absf(solid.get_volume() - (64.0 - 16.0 * t)) < 1e-3,
			"a cut right through divides it: %d closed parts, %.4f left" % [halves.size(), solid.get_volume()])
	_check(halves.all(func(half: Solid) -> bool: return absf(half.get_volume() - (32.0 - 8.0 * t)) < 1e-3),
			"into equal halves")
	# Too thin is raised to the thinnest cut.
	var before := solid.get_volume()
	node.cut(node.position + Vector3(-3, 2.5, 1), node.position + Vector3(3, 2.5, 1), Vector3.DOWN, 5.0, 1e-7)
	await _settle(node)
	var removed := before - _only_solid(node).get_volume()
	_check(absf(removed - 16.0 * node.get_min_cut_thickness()) < 1e-3,
			"a cut thinner than the limit is made at the limit (%.4f removed)" % removed)
	# No plane to cut along.
	var count := _only_solid(node).get_triangle_count()
	node.cut(node.position, node.position + Vector3.DOWN, Vector3.DOWN, 3.0)
	await _settle(node)
	_check(_only_solid(node).get_triangle_count() == count, "a direction along the line cuts nothing")
	node.queue_free()
	await process_frame


func _test_cut_divides() -> void:
	print("a cut divides a chunked mesh")
	var node := _adaptive(_box_mesh(), false)
	node.position = Vector3(10, 0, -40)
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	node.separation = MeshSeparation.new()
	root.add_child(node)
	await _settle(node)
	await _frames(5)
	var fell: Array[AdaptiveMesh] = []
	node.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: fell.append_array(parts))
	# Level, from the side, at y = 1, right across all four columns.
	node.cut(node.position + Vector3(-3, 1, -3), node.position + Vector3(3, 1, -3), Vector3.BACK, 6.5)
	await _settle(node)
	for i in 300:
		if not fell.is_empty():
			break
		await process_frame
	_check(fell.size() == 1 and (fell[0].global_transform * fell[0].get_aabb()).get_center().y > 1.0,
			"the part above the cut separates (%d)" % fell.size())
	for part in fell:
		part.get_body().queue_free()
	node.queue_free()
	await process_frame


func _frames(count: int) -> void:
	for i in count:
		await process_frame


# What a cut removes is discarded: no dig fragments from its slab, even with debris on.
func _test_cut_makes_no_debris() -> void:
	print("cuts make no debris")
	var node := _adaptive(_box_mesh(), false)
	node.position = Vector3(20, 0, -40)
	node.debris = MeshDebris.new()
	root.add_child(node)
	await _settle(node)
	var bodies: Array[RigidBody3D] = []
	node.debris_spawned.connect(func(made: Array[RigidBody3D]) -> void: bodies.append_array(made))
	node.cut(node.position + Vector3(-3, 2.5, 0), node.position + Vector3(3, 2.5, 0), Vector3.DOWN, 2.0, 0.3)
	await _settle(node)
	await _frames(20)
	_check(bodies.is_empty(), "a cut (even a thick one) drops nothing")
	node.edit(_sphere(1.0), node.global_transform * Transform3D(Basis(), Vector3(2, 2, 2)), BooleanOp.Operation.SUBTRACT)
	await _settle(node)
	for i in 120:
		if not bodies.is_empty():
			break
		await process_frame
	_check(not bodies.is_empty(), "while a dig still does (%d fragments)" % bodies.size())
	node.queue_free()
	await process_frame


# A 4 x 4 x 4 box dismantled into 1-unit cubes: 3 cuts per axis taking out a visible gap,
# the bottom layer stays (the Ground anchor), the 48 cubes above come away, each a cube.
func _test_dismantle() -> void:
	print("dismantle")
	var node := _adaptive(_box_mesh(), false)
	node.position = Vector3(30, 0, -40)
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 0, 2)
	node.separation = MeshSeparation.new()
	root.add_child(node)
	await _settle(node)
	await _frames(5)
	var parts: Array[AdaptiveMesh] = []
	node.separated.connect(func(made: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: parts.append_array(made))
	_check(node.dismantle(5.0) == 0, "cubes bigger than the mesh: nothing to cut")
	var started := Time.get_ticks_msec()
	var cuts := node.dismantle(1.0)
	await _settle(node)
	for i in 600:
		if parts.size() >= 48:
			break
		await process_frame
	var took := Time.get_ticks_msec() - started
	for part in parts:
		part.get_body().freeze = true
	var cubes := 0
	var open := 0
	for part in parts:
		var box := part.get_aabb()
		var volume := 0.0
		for key in part.data.pieces:
			var solid: Solid = part.data.pieces[key]
			volume += solid.get_volume()
			open += solid.count_open_edges()
		# Each a cube 0.95 across: the gaps (5% of the cube size) are taken out, half from
		# each side, except on the box's outside faces.
		if box.size.x > 0.9 and box.size.x < 0.98 and box.size.y > 0.9 and box.size.y < 0.98 and volume > 0.75 and volume < 0.95:
			cubes += 1
	var left := 0
	for key in node.data.pieces:
		left += (node.data.pieces[key] as Solid).get_islands().size()
	_check(cuts == 9, "3 cuts along each axis (%d)" % cuts)
	_check(parts.size() == 48 and cubes == 48 and open == 0,
			"48 parts come away, each a closed cube with the gaps taken out (%d parts, %d cubes, %d open edges), in %d ms" % [parts.size(), cubes, open, took])
	_check(left == 16, "the bottom layer of 16 stays (%d)" % left)
	for part in parts:
		part.get_body().queue_free()
	node.queue_free()
	await process_frame


# Chunks of 2 x 2 x 2 dismantled into cubes of 1: the upper chunks leave entirely, each as
# several cubes. Each cube must draw its own mesh, not the whole chunk it came from.
func _test_dismantle_draws_each_part() -> void:
	print("dismantle: each part draws itself")
	var node := _adaptive(_box_mesh(), false)
	node.position = Vector3(40, 0, -40)
	node.chunking = GridChunking.new()
	(node.chunking as GridChunking).cell_size = Vector3(2, 2, 2)
	node.separation = MeshSeparation.new()
	root.add_child(node)
	await _settle(node)
	await _frames(5)
	var parts: Array[AdaptiveMesh] = []
	node.separated.connect(func(made: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: parts.append_array(made))
	node.dismantle(1.0, 0.0, 3)
	await _settle(node)
	for i in 600:
		if parts.size() >= 48:
			break
		await process_frame
	var wrong := 0
	var cut_tagged := 0
	for part in parts:
		part.get_body().freeze = true
		var drawn := AABB()
		var views := part.get_target().find_children("*", "MeshInstance3D", true, false)
		if part.get_target() is MeshInstance3D:
			views.append(part.get_target())  # (a part shows as one mesh: its target)
		for view in views:
			var mesh := (view as MeshInstance3D).mesh
			if mesh != null:
				drawn = mesh.get_aabb() if drawn.size == Vector3.ZERO else drawn.merge(mesh.get_aabb())
		if not drawn.grow(0.01).encloses(part.get_aabb()) or drawn.size.length() > part.get_aabb().size.length() + 0.01:
			wrong += 1
		for solid: Solid in part.data.pieces.values():
			cut_tagged += (solid.tags as Array).count(3)
	_check(parts.size() == 48 and wrong == 0,
			"48 cubes, each drawn as itself (%d parts, %d drawing something else)" % [parts.size(), wrong])
	_check(cut_tagged > 0, "the cuts' faces have the tag given (%d triangles)" % cut_tagged)
	for part in parts:
		part.get_body().queue_free()
	node.queue_free()
	await process_frame
