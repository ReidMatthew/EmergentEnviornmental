extends "test_suite.gd"
## How quickly edits show up and how much they stall a frame, on the terrain demo's data
## (printed, not checked). The same radius 3 sphere digs:
##
## - one piece: the middle of the busiest piece
## - four pieces: the corner where four pieces meet
## - a stroke: ten digs a frame apart along a line crossing pieces
##
## At 60 fps (Engine.max_fps), like a game: "shows" counts frames from the edit call until
## the first piece draws it, "settled" until [signal AdaptiveMesh.edited] (neighbours
## have redrawn their seam shading too). Uncapped, where a frame lasts exactly as long as
## its main-thread work: "worst frame" is the longest, which is what shows as a hitch.

const RADIUS := 3.0


func run() -> void:
	var source := SceneSource.new()
	source.scene = load(get_script().resource_path.get_base_dir().path_join("../demo/models/low_poly_terrain.glb"))
	source.width = 200.0
	source.merge_tolerance = 0.02
	source.close_to_floor = true
	source.floor_depth = 40.0
	var sphere := _sphere(RADIUS, 2)
	sphere.tag = 10
	var fps := Engine.max_fps
	print("  %-14s %7s %9s %13s %10s" % ["edit", "shows", "settled", "worst frame", "triangles"])
	for case in ["one piece", "four pieces", "a stroke"]:
		Engine.max_fps = 60
		var timing: Array = await _measure(source, sphere, case)
		Engine.max_fps = 0
		var hitch: Array = await _measure(source, sphere, case)
		print("  %-14s %7d %9d %10.1f ms %+10d" % [case, timing[0], timing[1], hitch[2] / 1000.0, timing[3]])
	Engine.max_fps = fps


# [frames until it shows, frames until settled, longest frame (usec), triangles added]
func _measure(source: SceneSource, sphere: SolidShape, case: String) -> Array:
	var node := await _terrain(source)
	var cell := node.data.get_cell(_busiest(node))
	var at := cell.get_center() if case == "one piece" else cell.position
	# Warm up: one edit far away, so first-call costs don't count.
	node.edit(sphere, Transform3D(Basis(), _surface(node, at + Vector3(-40, 0, -40))), BooleanOp.Operation.SUBTRACT)
	await node.edited
	var before := node.get_triangle_count()
	# Where the digs go, found before timing starts.
	var spots: Array[Vector3] = []
	for i in (10 if case == "a stroke" else 1):
		spots.append(_surface(node, at + Vector3(i * 2.0, 0, i * 1.0)))
	await process_frame
	var state := {frames = 0, shown = -1, worst = 0, last = Time.get_ticks_usec()}
	var count := func() -> void:
		var now := Time.get_ticks_usec()
		state.worst = maxi(state.worst, now - state.last)
		state.last = now
		state.frames += 1
	var shown := func(_key: Vector4i) -> void:
		if state.shown < 0:
			state.shown = state.frames
	process_frame.connect(count)
	node.piece_edited.connect(shown)
	state.last = Time.get_ticks_usec()
	if case == "a stroke":
		for spot in spots:
			node.edit(sphere, Transform3D(Basis(), spot), BooleanOp.Operation.SUBTRACT)
			await process_frame
	else:
		node.edit(sphere, Transform3D(Basis(), spots[0]), BooleanOp.Operation.SUBTRACT)
	if not node.is_idle():
		await node.edited
	var settled: int = state.frames
	await process_frame  # the last frame's time
	process_frame.disconnect(count)
	var added := node.get_triangle_count() - before
	node.queue_free()
	await process_frame
	return [state.shown, settled, state.worst, added]


func _terrain(source: SceneSource) -> AdaptiveMesh:
	var node := AdaptiveMesh.new()
	var grid := GridChunking.new()
	grid.cell_size = Vector3(25, 0, 25)
	node.chunking = grid
	var box := source.get_solid().get_aabb()
	node.max_bounds = AABB(box.position, box.size + Vector3(0, 20, 0))
	node.source = source
	root.add_child(node)
	await node.baked
	return node


func _busiest(node: AdaptiveMesh) -> Vector4i:
	var best := Vector4i.ZERO
	var most := -1
	for key: Vector4i in node.get_pieces():
		var n: int = node.get_pieces()[key].solid.get_triangle_count()
		if n > most:
			most = n
			best = key
	return best


# The highest surface point near [param at] (x and z).
func _surface(node: AdaptiveMesh, at: Vector3) -> Vector3:
	var top := Vector3(at.x, -INF, at.z)
	for piece: AdaptivePiece in node.get_pieces().values():
		for p in piece.solid.positions:
			if absf(p.x - at.x) < 3.0 and absf(p.z - at.z) < 3.0 and p.y > top.y:
				top.y = p.y
	return top
