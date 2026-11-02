extends "test_suite.gd"
## MeshCleanup: fewer small and thin triangles, still closed, shape kept, untouched
## triangles and bounds left alone, no new positions.


func run() -> void:
	var box := Solid.from_mesh(_box_mesh())
	var messy: Solid = await _messy(box)
	_test_cleans(box, messy)
	_test_unlock_rings(box, messy)
	await _test_bounds_stay()
	await _test_in_node()


func _test_cleans(box: Solid, messy: Solid) -> void:
	print("cleanup after overlapping digs")
	var cleanup := _cleanup()
	var start := Time.get_ticks_usec()
	var clean := cleanup.clean(messy, box, AABB())
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	var before := _stats(messy)
	var after := _stats(clean)
	print("         before: %d triangles, %d tiny, %d slivers; after: %d, %d, %d (%.1f ms)"
			% [before[0], before[1], before[2], after[0], after[1], after[2], ms])
	_check(clean.count_open_edges() == 0, "still closed")
	_check(after[0] < before[0] and after[1] < before[1] and after[2] < before[2], "fewer triangles, tiny ones and slivers")
	var volume_change := absf(_volume(clean) - _volume(messy)) / _volume(messy)
	_check(volume_change < 0.002, "shape kept (volume changed %.3f%%)" % (volume_change * 100.0))
	# Every old triangle the digs left alone is still there, exactly.
	var old := _triangle_keys(box)
	var kept_messy := 0
	var kept_clean := 0
	var clean_keys := _triangle_keys(clean)
	for key in _triangle_keys(messy):
		if old.has(key):
			kept_messy += 1
			if clean_keys.has(key):
				kept_clean += 1
	_check(kept_clean == kept_messy, "untouched triangles kept exactly (%d of %d)" % [kept_clean, kept_messy])
	var positions := {}
	for p in messy.positions:
		positions[p] = true
	var new_positions := 0
	for p in clean.positions:
		if not positions.has(p):
			new_positions += 1
	_check(new_positions == 0, "no new vertex positions (%d)" % new_positions)
	_check(_count_tag(clean, 1) > 0 and _count_tag(clean, 0) > 0, "both tags still there")


func _test_unlock_rings(box: Solid, messy: Solid) -> void:
	print("unlock rings")
	var results := []
	for rings in [0, 1, 2]:
		var cleanup := _cleanup()
		cleanup.unlock_rings = rings
		var clean := cleanup.clean(messy, box, AABB())
		results.append(_stats(clean))
		_check(clean.count_open_edges() == 0, "rings %d: closed, %d triangles, %d tiny, %d slivers"
				% [rings, results[-1][0], results[-1][1], results[-1][2]])
	_check(results[1][2] <= results[0][2], "unlocking a ring leaves no more slivers than keeping it")


func _test_bounds_stay() -> void:
	print("bounds")
	var backend := CsgBooleanBackend.new()
	var box := Solid.from_mesh(_box_mesh())
	var bounds := AABB(Vector3(-2, -2, -2), Vector3(4, 4.5, 4))
	var ops: Array[BooleanOp] = []
	for i in 3:
		ops.append(BooleanOp.create(_sphere(0.9).get_solid(), Transform3D(Basis(), Vector3(1.6 - i * 0.4, 2.0, i * 0.3)),
				BooleanOp.Operation.UNION))
	var grown: Solid = await backend.combine(box, ops, bounds, 5)
	var clean := _cleanup().clean(grown, box, bounds)
	var on_bounds := 0
	var still := 0
	var clean_positions := {}
	for p in clean.positions:
		clean_positions[p] = true
	for p in grown.positions:
		if absf(p.x - 2.0) < 1e-4 or absf(p.y - 2.5) < 1e-4:
			on_bounds += 1
			if clean_positions.has(p):
				still += 1
	_check(on_bounds > 0 and still == on_bounds and clean.count_open_edges() == 0,
			"all %d vertices on the bounds kept; closed" % on_bounds)


func _test_in_node() -> void:
	print("in AdaptiveMesh")
	var mesh := _adaptive(_box_mesh(), false)
	mesh.cleanup = _cleanup()
	root.add_child(mesh)
	for x in [-0.6, 0.0, 0.6]:
		mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(x, 2, 0)), BooleanOp.Operation.SUBTRACT)
		while not mesh.is_idle():
			await process_frame
	var stats := _stats(_only_solid(mesh))
	_check(_only_solid(mesh).count_open_edges() == 0, "cleaned after every batch: %d triangles, %d tiny, %d slivers"
			% [stats[0], stats[1], stats[2]])
	mesh.queue_free()


# Three overlapping digs into the box, one at a time.
func _messy(box: Solid) -> Solid:
	var backend := CsgBooleanBackend.new()
	var solid := box
	for x in [-0.6, 0.0, 0.6]:
		var ops: Array[BooleanOp] = [BooleanOp.create(_sphere(1.0).get_solid(), Transform3D(Basis(), Vector3(x, 2, 0)),
				BooleanOp.Operation.SUBTRACT)]
		solid = await backend.combine(solid, ops, AABB(), 0)
	return solid


func _cleanup() -> MeshCleanup:
	var cleanup := MeshCleanup.new()
	cleanup.min_edge_length = 0.1
	cleanup.max_error = 0.02
	return cleanup


# [triangles, tiny (area < 0.005), slivers (angle < 10 degrees)]
func _stats(solid: Solid) -> Array:
	var tiny := 0
	var slivers := 0
	for t in solid.get_triangle_count():
		var a := solid.positions[solid.indices[t * 3]]
		var b := solid.positions[solid.indices[t * 3 + 1]]
		var c := solid.positions[solid.indices[t * 3 + 2]]
		if (b - a).cross(c - a).length() * 0.5 < 0.005:
			tiny += 1
		var smallest := minf((b - a).angle_to(c - a), minf((a - b).angle_to(c - b), (a - c).angle_to(b - c)))
		if smallest < deg_to_rad(10.0):
			slivers += 1
	return [solid.get_triangle_count(), tiny, slivers]


func _volume(solid: Solid) -> float:
	var v := 0.0
	for t in solid.get_triangle_count():
		var a := solid.positions[solid.indices[t * 3]]
		v += a.dot(solid.positions[solid.indices[t * 3 + 2]].cross(solid.positions[solid.indices[t * 3 + 1]])) / 6.0
	return v
