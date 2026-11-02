extends "test_suite.gd"
## BrushStroke: spacing, advancing while held still (digging in, building out), drags not
## advancing unless asked, the advance limit.

const FPS := 60.0


func run() -> void:
	await _test_dig_in_place()
	await _test_build_in_place()
	await _test_drag_does_not_advance()
	_test_advance_rules()


# Holding still on top of the box for 1 s, advancing 2 units/s straight down: one bore
# 2 units deep, swept in a few edits.
func _test_dig_in_place() -> void:
	print("dig in place")
	var mesh := _mesh()
	var stroke := _stroke(BooleanOp.Operation.SUBTRACT, Vector3.DOWN)
	var top := Vector3(0, 2, 0)
	stroke.begin(mesh, top)
	var edits := 1
	for f in roundi(FPS):
		if stroke.update(top, 1.0 / FPS):
			edits += 1
		await _wait_idle(mesh)
	stroke.end()
	await _wait_idle(mesh)
	var floor_y := _lowest_near_axis(_only_solid(mesh))
	_check(absf(stroke.get_advanced() - 2.0) < 0.05, "advanced %.2f units in 1 s" % stroke.get_advanced())
	_check(absf(floor_y - (2.0 - 2.0 - 1.0)) < 0.1, "bore floor at y = %.2f (start 2, advanced 2, radius 1)" % floor_y)
	_check(edits >= 3 and edits <= 6 and _only_solid(mesh).count_open_edges() == 0,
			"%d edits for 2 units at spacing 0.5 (swept, so no gaps); closed" % edits)
	mesh.queue_free()


func _test_build_in_place() -> void:
	print("build in place")
	var mesh := _mesh()
	var stroke := _stroke(BooleanOp.Operation.UNION, Vector3.UP)
	var top := Vector3(0, 2, 0)
	stroke.begin(mesh, top)
	for f in roundi(FPS * 0.75):
		stroke.update(top, 1.0 / FPS)
		await _wait_idle(mesh)
	stroke.end()
	await _wait_idle(mesh)
	var peak := _only_solid(mesh).get_aabb().end.y
	_check(absf(peak - (2.0 + 1.5 + 1.0)) < 0.1, "pillar top at y = %.2f (start 2, advanced 1.5, radius 1)" % peak)
	_check(_only_solid(mesh).count_open_edges() == 0, "closed")
	mesh.queue_free()


# Dragging across faster than the advance speed digs a level trench.
func _test_drag_does_not_advance() -> void:
	print("drag")
	var mesh := _mesh()
	var stroke := _stroke(BooleanOp.Operation.SUBTRACT, Vector3.DOWN)
	stroke.begin(mesh, Vector3(-1.5, 2, 0))
	for f in range(1, 31):
		stroke.update(Vector3(-1.5 + f * 0.1, 2, 0), 1.0 / FPS)  # 6 units/s, faster than 2
		await _wait_idle(mesh)
	stroke.end()
	await _wait_idle(mesh)
	_check(stroke.get_advanced() == 0.0, "no advance while moving faster than advance_speed")
	_check(absf(_lowest_near_axis(_only_solid(mesh)) - 1.0) < 0.1, "trench floor level at y = 1 (top 2, radius 1)")
	mesh.queue_free()


func _test_advance_rules() -> void:
	print("advance rules")
	var stroke := _stroke(BooleanOp.Operation.SUBTRACT, Vector3(0, -2, 0))
	stroke.max_advance = 0.5
	var fake := AdaptiveMesh.new()  # never in the tree: idle, so update only advances and edits nothing real
	stroke._mesh = fake
	stroke.spacing = 100.0
	for i in 60:
		stroke.update(Vector3.ZERO, 1.0 / FPS)
	_check(is_equal_approx(stroke.get_advanced(), 0.5), "max_advance caps it (%.2f)" % stroke.get_advanced())
	_check(stroke.get_brush_position().is_equal_approx(Vector3(0, -0.5, 0)), "direction normalised: brush at %s" % stroke.get_brush_position())
	stroke.max_advance = 0.0
	stroke.advance_while_moving = true
	stroke._advanced = 0.0
	for i in 30:
		stroke.update(Vector3(i * 0.5, 0, 0), 1.0 / FPS)
	_check(is_equal_approx(stroke.get_advanced(), 1.0), "advance_while_moving: advances during a fast drag (%.2f)" % stroke.get_advanced())
	fake.free()


func _mesh() -> AdaptiveMesh:
	var mesh := _adaptive(_box_mesh(), false)
	root.add_child(mesh)
	return mesh


func _stroke(operation: BooleanOp.Operation, direction: Vector3) -> BrushStroke:
	var stroke := BrushStroke.new()
	stroke.shape = _sphere(1.0)
	stroke.operation = operation
	stroke.spacing = 0.5
	stroke.advance_direction = direction
	stroke.advance_speed = 2.0
	return stroke


# Lowest point of the cut faces (tag 1) near the vertical line through the origin.
func _lowest_near_axis(solid: Solid) -> float:
	var lowest := INF
	for t in solid.get_triangle_count():
		if solid.tags[t] != 1:
			continue
		for c in 3:
			var p := solid.positions[solid.indices[t * 3 + c]]
			if absf(p.z) < 0.3 and absf(p.x) < 0.3:
				lowest = minf(lowest, p.y)
	return lowest


func _wait_idle(mesh: AdaptiveMesh) -> void:
	while not mesh.is_idle():
		await process_frame
