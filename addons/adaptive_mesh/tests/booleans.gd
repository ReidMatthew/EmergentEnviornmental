extends "test_suite.gd"
## CsgBooleanBackend: results stay closed, untouched triangles stay exactly as they were,
## tags survive, bounds clip unions.


func run() -> void:
	await _test_subtract_keeps_untouched_triangles()
	await _test_union_clipped_to_bounds()
	await _test_intersect_and_batches()
	await _test_chained_edits_stay_closed()
	await _test_nothing_to_cut()


func _test_subtract_keeps_untouched_triangles() -> void:
	print("subtract")
	var backend := CsgBooleanBackend.new()
	var box := Solid.from_mesh(_box_mesh())
	var center := Vector3(0.3, 2.0, -0.2)
	var ops: Array[BooleanOp] = [BooleanOp.create(_sphere(1.0).get_solid(), Transform3D(Basis(), center),
			BooleanOp.Operation.SUBTRACT)]
	var result: Solid = await backend.combine(box, ops, AABB(), 0)
	_check(result != null and result.count_open_edges() == 0, "result is closed")
	var cut := _count_tag(result, 1)
	_check(cut > 0, "%d triangles from the brush (tag 1), %d total (was %d)"
			% [cut, result.get_triangle_count(), box.get_triangle_count()])
	# Triangles whose bounds miss the brush's bounds must come through unchanged.
	var brush_box := AABB(center - Vector3.ONE * 1.01, Vector3.ONE * 2.02)
	var kept := _triangle_keys(result, 0)
	var expected := 0
	var missing := 0
	for t in box.get_triangle_count():
		var a := box.positions[box.indices[t * 3]]
		var b := box.positions[box.indices[t * 3 + 1]]
		var c := box.positions[box.indices[t * 3 + 2]]
		if AABB(a, Vector3.ZERO).expand(b).expand(c).grow(0.001).intersects(brush_box):
			continue
		expected += 1
		if not kept.has(_triangle_key(a, b, c)):
			missing += 1
	_check(expected > 150 and missing == 0, "all %d untouched triangles kept exactly (%d missing)" % [expected, missing])
	var lowest := 10.0
	for p in result.positions:
		if Vector2(p.x - center.x, p.z - center.z).length() < 0.3:
			lowest = minf(lowest, p.y)
	_check(absf(lowest - 1.0) < 0.05, "crater floor at the brush's bottom (y = %.3f)" % lowest)


func _test_union_clipped_to_bounds() -> void:
	print("union inside bounds")
	var backend := CsgBooleanBackend.new()
	var box := Solid.from_mesh(_box_mesh())
	var bounds := AABB(Vector3(-2, -2, -2), Vector3(4, 4.5, 4))  # top at y = 2.5
	var ops: Array[BooleanOp] = [BooleanOp.create(_sphere(1.0).get_solid(),
			Transform3D(Basis(), Vector3(1.5, 2.0, 0)), BooleanOp.Operation.UNION)]
	var result: Solid = await backend.combine(box, ops, bounds, 5)
	var top := -10.0
	var max_x := -10.0
	for p in result.positions:
		top = maxf(top, p.y)
		max_x = maxf(max_x, p.x)
	_check(result.count_open_edges() == 0, "result is closed")
	_check(absf(top - 2.5) < 1e-3 and max_x <= 2.0 + 1e-3,
			"nothing added outside the bounds (top %.3f, max x %.3f)" % [top, max_x])
	_check(_count_tag(result, 5) > 0 and _count_tag(result, 1) > 0,
			"cut faces get bounds_tag (%d), the rest the shape's tag (%d)" % [_count_tag(result, 5), _count_tag(result, 1)])
	var unbounded: Solid = await backend.combine(box, ops, AABB(), 5)
	var unbounded_top := -10.0
	for p in unbounded.positions:
		unbounded_top = maxf(unbounded_top, p.y)
	_check(absf(unbounded_top - 3.0) < 0.01, "without bounds the shape sticks out (top %.3f)" % unbounded_top)


func _test_intersect_and_batches() -> void:
	print("intersect and batches")
	var backend := CsgBooleanBackend.new()
	var box := Solid.from_mesh(_box_mesh())
	var ops: Array[BooleanOp] = [BooleanOp.create(_sphere(3.0).get_solid(), Transform3D(),
			BooleanOp.Operation.INTERSECT)]
	var result: Solid = await backend.combine(box, ops, AABB(), 0)
	_check(result.count_open_edges() == 0 and result.get_aabb().size.is_equal_approx(Vector3(4, 4, 4))
			and _count_tag(result, 1) > 0, "rounded box: closed, still 4 wide, corners from the sphere")
	var many: Array[BooleanOp] = []
	for i in 3:
		many.append(BooleanOp.create(_sphere(0.6).get_solid(), Transform3D(Basis(), Vector3(i - 1, 2, 0)),
				BooleanOp.Operation.SUBTRACT))
	many.append(BooleanOp.create(_sphere(0.5).get_solid(), Transform3D(Basis(), Vector3(0, -2, 1)),
			BooleanOp.Operation.UNION))
	result = await backend.combine(box, many, AABB(), 0)
	_check(result.count_open_edges() == 0 and result.get_aabb().position.y < -2.4, "four ops in one batch: closed, union applied")


func _test_chained_edits_stay_closed() -> void:
	print("chained edits")
	var backend := CsgBooleanBackend.new()
	var solid := Solid.from_mesh(_box_mesh())
	var sphere := _sphere(0.7, 1).get_solid()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var start := Time.get_ticks_usec()
	var open := 0
	var done := 0
	for i in 40:
		var op := BooleanOp.Operation.UNION if i % 4 == 3 else BooleanOp.Operation.SUBTRACT
		var at := Vector3(rng.randf_range(-2, 2), rng.randf_range(1.0, 2.2), rng.randf_range(-2, 2))
		var ops: Array[BooleanOp] = [BooleanOp.create(sphere, Transform3D(Basis(), at), op)]
		var next: Solid = await backend.combine(solid, ops, AABB(), 0)
		if next == null:
			break
		solid = next
		open += solid.count_open_edges()
		done += 1
	_check(done == 40 and open == 0, "%d random digs and adds, closed after every one" % done)
	print("         %d triangles after %d edits, %.1f ms per edit (including a frame)"
			% [solid.get_triangle_count(), done, (Time.get_ticks_usec() - start) / 1000.0 / maxi(done, 1)])


# Digging into nothing: an empty result, and no CSG node left behind.
func _test_nothing_to_cut() -> void:
	print("nothing to cut")
	await process_frame
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var ops: Array[BooleanOp] = [BooleanOp.create(_sphere(1.0).get_solid(), Transform3D.IDENTITY, BooleanOp.Operation.SUBTRACT)]
	var result: Solid = await CsgBooleanBackend.new().combine(Solid.new(), ops, AABB(), 1)
	await process_frame
	_check(result != null and result.is_empty() and Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == orphans,
			"a dig into an empty solid: empty, and no stray CSG node")
