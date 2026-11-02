extends "test_suite.gd"
## AdaptiveMesh with GridChunking: cutting, closed seams before and after edits that cross them,
## edits only reaching the chunks they touch, building into empty cells, saving, per-edit
## cost staying flat as the mesh grows, crowded pieces splitting (also under random edits
## arriving mid-split), neighbours redrawing only when their seam changed, and collision
## snapshots.


func run() -> void:
	await _test_split()
	await _test_edit_across_seams()
	await _test_cleanup_keeps_seams()
	await _test_shading_across_seams()
	await _test_build_into_empty_cells()
	await _test_saved_data()
	await _test_cost_follows_the_edit()
	await _test_crowded_pieces_split()
	await _test_random_edits_during_splits()
	await _test_neighbours_redraw_only_when_needed()
	await _test_collision_snapshot()


func _test_split() -> void:
	print("split")
	var mesh := _chunked(Vector3(2, 0, 2))
	await _wait_idle(mesh)
	_check(mesh.get_pieces().size() == 4, "4 x 4 box in 2-wide columns: %d chunks" % mesh.get_pieces().size())
	var all_closed := true
	for chunk: AdaptivePiece in mesh.get_pieces().values():
		all_closed = all_closed and chunk.solid.count_open_edges() == 0
	_check(all_closed, "every chunk is closed on its own")
	var faces := mesh.get_faces()
	_check(_open_edges(faces) == 0 and _seam_errors(mesh) == 0, "visible surfaces of all chunks join with no gaps (caps hidden)")
	_check(is_equal_approx(_area(faces), 6.0 * 16.0), "visible area %.3f is the box's (96)" % _area(faces))
	mesh.queue_free()


# A dig right where four chunks meet.
func _test_edit_across_seams() -> void:
	print("edit across seams")
	var mesh := _chunked(Vector3(2, 0, 2))
	await _wait_idle(mesh)
	var edited := {}
	mesh.piece_edited.connect(func(key: Vector4i) -> void: edited[key] = true)
	var finished := [0]
	mesh.edited.connect(func() -> void: finished[0] += 1)
	mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(0, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	await process_frame
	_check(edited.size() == 4, "all 4 chunks around the corner cut (%d)" % edited.size())
	_check(finished[0] == 1, "edited fires once when they're all done (%d)" % finished[0])
	_check(_seam_errors(mesh) == 0, "seams still closed after the cut")
	mesh.edit(_sphere(0.6), Transform3D(Basis(), Vector3(1, 2, 1)), BooleanOp.Operation.SUBTRACT)
	edited.clear()
	await _wait_idle(mesh)
	_check(edited.size() == 1, "a dig inside one chunk only cuts that one (%d)" % edited.size())
	mesh.queue_free()


# Cleanup runs per chunk; it must leave the vertices on cell walls alone.
func _test_cleanup_keeps_seams() -> void:
	print("cleanup and seams")
	var mesh := _chunked(Vector3(2, 0, 2), false)
	mesh.cleanup = MeshCleanup.new()
	mesh.cleanup.min_edge_length = 0.15
	mesh.cleanup.unlock_rings = 1
	root.add_child(mesh)
	await _wait_idle(mesh)
	for x in [-0.4, 0.0, 0.4]:
		mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(x, 2, x * 0.5)), BooleanOp.Operation.SUBTRACT)
		await _wait_idle(mesh)
	_check(_seam_errors(mesh) == 0, "three cleaned digs across the corner: seams still match")
	mesh.queue_free()


# A crater dug across a chunk corner: where the chunks meet, both sides must draw the same
# normals, or the lighting jumps at the seam.
func _test_shading_across_seams() -> void:
	print("shading across seams")
	var mesh := _chunked(Vector3(2, 0, 2))
	await _wait_idle(mesh)
	mesh.edit(_sphere(1.3, 3), Transform3D(Basis(), Vector3(0.2, 2.3, -0.1)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	await process_frame
	# Drawn normals by position, per chunk.
	var by_chunk := []
	for chunk: AdaptivePiece in mesh.get_pieces().values():
		var normals := {}
		var drawn := (chunk.get_child(0, true) as MeshInstance3D).mesh
		for s in drawn.get_surface_count():
			var arrays := drawn.surface_get_arrays(s)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var vertex_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in vertices.size():
				var key := Vector3i((vertices[i] * 1e5).round())
				if not normals.has(key):
					normals[key] = []
				(normals[key] as Array).append(vertex_normals[i])
		by_chunk.append(normals)
	var seam_vertices := 0
	var worst := 0.0
	for i in by_chunk.size():
		for j in by_chunk.size():
			if i == j:
				continue
			for key: Vector3i in by_chunk[i]:
				if not by_chunk[j].has(key):
					continue
				seam_vertices += 1
				# Every normal drawn here on one side must be drawn on the other side too.
				for n: Vector3 in by_chunk[i][key]:
					var best := PI
					for m: Vector3 in by_chunk[j][key]:
						best = minf(best, n.angle_to(m))
					worst = maxf(worst, best)
	_check(seam_vertices > 20 and worst < deg_to_rad(0.5),
			"%d seam vertex pairs, worst normal mismatch %.3f degrees" % [seam_vertices, rad_to_deg(worst)])
	mesh.queue_free()


# Building up out of the top of a box split vertically too: new chunks above, still closed.
func _test_build_into_empty_cells() -> void:
	print("build into empty cells")
	var mesh := _chunked(Vector3(2, 2, 2))
	(mesh.chunking as GridChunking).offset = Vector3(0, 0.5, 0)  # keep cell walls off the box's flat top (y = 2)
	mesh.max_bounds = AABB(Vector3(-2, -2, -2), Vector3(4, 6, 4))  # 2 units of room on top
	root.add_child(mesh)
	await _wait_idle(mesh)
	var before := mesh.get_pieces().size()
	mesh.edit(_sphere(1.2), Transform3D(Basis(), Vector3(0.5, 2.6, 0.5)), BooleanOp.Operation.UNION)
	await _wait_idle(mesh)
	var top := -INF
	var faces := mesh.get_faces()
	for p in faces:
		top = maxf(top, p.y)
	_check(mesh.get_pieces().size() > before, "chunks made for empty cells above (%d -> %d)" % [before, mesh.get_pieces().size()])
	_check(absf(top - 3.8) < 0.01 and _seam_errors(mesh) == 0, "the bump reaches y = %.2f across old and new chunks, closed" % top)
	mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(0, 7, 0)), BooleanOp.Operation.UNION)
	await _wait_idle(mesh)
	_check(_area(mesh.get_faces()) == _area(faces), "nothing is built outside max_bounds")
	# A bump cut off by the top of max_bounds: its flat top is an outer face, so it shows
	# (only faces between pieces are hidden).
	mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(-1.0, 3.6, -1.0)), BooleanOp.Operation.UNION)
	await _wait_idle(mesh)
	faces = mesh.get_faces()
	top = -INF
	for p in faces:
		top = maxf(top, p.y)
	var hidden_on_top := 0
	for piece: AdaptivePiece in mesh.get_pieces().values():
		var solid := piece.solid
		for t in solid.get_triangle_count():
			var on_top := true
			for c in 3:
				on_top = on_top and absf(solid.positions[solid.indices[t * 3 + c]].y - 4.0) < 1e-4
			if on_top and solid.tags[t] == mesh.data.get_cap_tag():
				hidden_on_top += 1
	_check(absf(top - 4.0) < 1e-3 and hidden_on_top == 0 and _seam_errors(mesh) == 0,
			"a bump cut off at max_bounds (y = %.2f) is closed on top by shown faces, not hidden caps" % top)
	mesh.queue_free()


func _test_saved_data() -> void:
	print("saved data")
	var mesh := _chunked(Vector3(2, 0, 2))
	await _wait_idle(mesh)
	mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(0.5, 2, 0.5)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	var path := "user://adaptive_mesh_data_test.res"
	_check(ResourceSaver.save(mesh.data, path) == OK, "data saves")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as AdaptiveMeshData
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var copy := AdaptiveMesh.new()
	copy.data = loaded
	copy.collision = mesh.collision
	root.add_child(copy)
	_check(copy.is_idle() and copy.get_pieces().size() == mesh.get_pieces().size(), "loaded data: ready at once, no baking")
	_check(copy.get_triangle_count() == mesh.get_triangle_count(), "same triangles as the edited original (%d)" % copy.get_triangle_count())
	var built_meshes := 0
	for piece: AdaptivePiece in copy.get_pieces().values():
		if loaded.meshes.values().has(piece.get_mesh()):
			built_meshes += 1
	_check(built_meshes == copy.get_pieces().size(), "pieces show the saved meshes (nothing rebuilt)")
	# Two nodes sharing data: an edit on one doesn't reach the other.
	var twin := AdaptiveMesh.new()
	twin.data = loaded
	twin.collision = mesh.collision
	root.add_child(twin)
	var before := twin.get_triangle_count()
	copy.edit(_sphere(1.0), Transform3D(Basis(), Vector3(-1, 2, -1)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(copy)
	_check(copy.data != loaded and twin.data == loaded and twin.get_triangle_count() == before
			and copy.get_triangle_count() != before, "editing one of two nodes sharing data gives it its own copy")
	mesh.queue_free()
	copy.queue_free()
	twin.queue_free()


# The same dig on a box 4 times as wide: one big piece gets slower, chunks don't.
func _test_cost_follows_the_edit() -> void:
	print("cost")
	# Booleans cost about as much as the pieces they work on, so the check counts the
	# triangles each edit's booleans processed (the pieces it reached, before the edit).
	# Milliseconds are printed too, but they depend on frames (vsync, rendering), so they
	# aren't checked.
	var work := []
	for setup: Array in [[8.0, Vector3.ZERO], [16.0, Vector3.ZERO], [8.0, Vector3(4, 0, 4)], [16.0, Vector3(4, 0, 4)]]:
		var box := BoxMesh.new()
		box.size = Vector3(setup[0], 4, setup[0])
		box.subdivide_width = int(setup[0]) * 2
		box.subdivide_depth = int(setup[0]) * 2
		var mesh := AdaptiveMesh.new()
		mesh.source = MeshSource.new()
		(mesh.source as MeshSource).mesh = box
		var grid := GridChunking.new()
		grid.cell_size = setup[1]
		grid.offset = Vector3(0.37, 0, 0.37)  # cell walls off the box's grid lines
		mesh.chunking = grid
		mesh.collision = _no_collision()
		root.add_child(mesh)
		await _wait_idle(mesh)
		var processed := [0]
		var sizes := {}  # piece triangles before the edit
		var each := []
		for i in 5:
			sizes.clear()
			for key: Vector4i in mesh.get_pieces():
				sizes[key] = (mesh.get_pieces()[key] as AdaptivePiece).solid.get_triangle_count()
			var reached := mesh.piece_edited.connect(func(key: Vector4i) -> void: processed[0] += sizes.get(key, 0))
			var start := Time.get_ticks_usec()
			mesh.edit(_sphere(0.8), Transform3D(Basis(), Vector3(i * 0.5 - 1.0, 2, 1.0)), BooleanOp.Operation.SUBTRACT)
			await _wait_idle(mesh)
			each.append((Time.get_ticks_usec() - start) / 1000.0)
			for connection in mesh.piece_edited.get_connections():
				mesh.piece_edited.disconnect(connection.callable)
		each.sort()
		work.append(processed[0] / 5.0)
		_check(_seam_errors(mesh) == 0, "%s wide, chunks %s: closed, %d triangles through the booleans and %.1f ms per edit (%d chunks)"
				% [setup[0], setup[1], work[-1], each[2], mesh.get_pieces().size()])
		mesh.queue_free()
	_check(work[3] < work[1] * 0.3 and work[3] < work[2] * 1.5,
			"16-wide box: chunked edits process %d triangles, not the %d of one piece, and about as many as on an 8-wide box (%d)"
			% [work[3], work[1], work[2]])


# A chunked 4 x 4 x 4 box. Added to the tree unless [param add] is false (callers that
# change settings first add it themselves).
func _chunked(size: Vector3, add: bool = true) -> AdaptiveMesh:
	var mesh := AdaptiveMesh.new()
	mesh.source = MeshSource.new()
	(mesh.source as MeshSource).mesh = _box_mesh()
	var grid := GridChunking.new()
	grid.cell_size = size
	mesh.chunking = grid
	mesh.collision = _no_collision()
	if add and size.y == 0.0:
		root.add_child(mesh)
	return mesh


func _no_collision() -> PieceCollision:
	var off := PieceCollision.new()
	off.enabled = false
	return off


func _wait_idle(mesh: AdaptiveMesh) -> void:
	await process_frame
	var frames := 0
	while not mesh.is_idle():
		await process_frame
		frames += 1
		if frames == 2000:
			_check(false, "the mesh settles (still busy after 2000 frames)")
			return


# Seams that don't line up, plus chunks that aren't closed. Each chunk must be closed on
# its own (caps included), and every visible edge that borders a cap (the chunk's edge of
# the visible surface, on a cell wall) must meet the same edge, the other way round, in a
# neighbouring chunk. Positions are compared to 1e-5.
func _seam_errors(mesh: AdaptiveMesh) -> int:
	var errors := 0
	var seam := {}
	for chunk: AdaptivePiece in mesh.get_pieces().values():
		var solid := chunk.solid
		errors += solid.count_open_edges()
		var owner := {}  # directed edge (by position) -> visible?
		for t in solid.get_triangle_count():
			for e in 3:
				var k := [solid.positions[solid.indices[t * 3 + e]], solid.positions[solid.indices[t * 3 + (e + 1) % 3]]]
				owner[k] = solid.tags[t] != mesh.data.get_cap_tag()
		for k: Array in owner:
			if owner[k] and owner.has([k[1], k[0]]) and not owner[[k[1], k[0]]]:
				var key := [Vector3i((k[0] * 1e5).round()), Vector3i((k[1] * 1e5).round())]
				seam[key] = seam.get(key, 0) + 1
	for key: Array in seam:
		if seam.get([key[1], key[0]], 0) != seam[key]:
			errors += 1
	return errors


# Edges (by position, snapped to 1e-4) not shared by exactly two triangles running
# opposite ways, in a triangle soup. Nearly-degenerate triangles (two corners closer than
# the snap) count as open, so use it on clean meshes only.
func _open_edges(faces: PackedVector3Array) -> int:
	var directed := {}
	for t in range(0, faces.size(), 3):
		for e in 3:
			var k := [Vector3i((faces[t + e] * 1e4).round()), Vector3i((faces[t + (e + 1) % 3] * 1e4).round())]
			if k[0] == k[1]:
				continue
			directed[k] = directed.get(k, 0) + 1
	var bad := 0
	for k: Array in directed:
		if directed[k] != 1 or directed.get([k[1], k[0]], 0) != 1:
			bad += 1
	return bad


func _area(faces: PackedVector3Array) -> float:
	var total := 0.0
	for t in range(0, faces.size(), 3):
		total += (faces[t + 1] - faces[t]).cross(faces[t + 2] - faces[t]).length() * 0.5
	return total


# The demo hill in 8-wide columns (16 pieces, walls on the hill's grid lines).
func _hill(split_above: int) -> AdaptiveMesh:
	var mesh := AdaptiveMesh.new()
	mesh.source = MeshSource.new()
	(mesh.source as MeshSource).mesh = load(get_script().resource_path.get_base_dir().path_join("../demo/models/hill.res"))
	var grid := GridChunking.new()
	grid.cell_size = Vector3(8, 0, 8)
	grid.split_above = split_above
	grid.max_split_depth = 2
	mesh.chunking = grid
	mesh.collision = _no_collision()
	root.add_child(mesh)
	return mesh


# Where a sphere sits on the hill's surface at ([param x], [param z]).
func _on_hill(mesh: AdaptiveMesh, x: float, z: float) -> Transform3D:
	var top := -INF
	for p in mesh.get_faces():
		if absf(p.x - x) < 1.1 and absf(p.z - z) < 1.1:
			top = maxf(top, p.y)
	return Transform3D(Basis(), Vector3(x, top, z))


func _test_crowded_pieces_split() -> void:
	print("crowded pieces split")
	var mesh := await _hill_ready(150)
	var whole := await _hill_ready(0)  # the same edits, never split
	var digs := [Vector2(2.5, 2.5), Vector2(5.5, 2.5), Vector2(2.5, 5.5), Vector2(5.5, 5.5), Vector2(4, 4)]
	for at: Vector2 in digs:
		for target: AdaptiveMesh in [mesh, whole]:
			target.edit(_sphere(1.2), _on_hill(whole, at.x, at.y), BooleanOp.Operation.SUBTRACT)
		await _wait_idle(mesh)
		await _wait_idle(whole)
	await _settle_frames(mesh)
	var parent := Vector4i(0, 0, 0, 0)
	var children := 0
	for key: Vector4i in mesh.get_pieces():
		if AdaptiveMeshData.is_inside(key, parent):
			children += 1
	_check(mesh.data.split_keys.has(parent) and children > 1 and not mesh.get_pieces().has(parent),
			"the piece dug into 5 times split (%d pieces in its place)" % children)
	var most := 0
	for piece: AdaptivePiece in mesh.get_pieces().values():
		most = maxi(most, piece.solid.get_triangle_count())
	_check(most <= 150 or mesh.data.split_keys.size() > 1, "pieces stay near the limit (largest %d triangles)" % most)
	var area := _area(mesh.get_faces())
	var whole_area := _area(whole.get_faces())
	_check(absf(area - whole_area) < 1e-3 * whole_area, "same surface as without splitting (area %.3f vs %.3f)" % [area, whole_area])
	_check(_seam_errors(mesh) == 0, "split pieces join their siblings and neighbours with no gaps")
	var hidden := 0
	for piece: AdaptivePiece in mesh.get_pieces().values():
		if not piece.visible:
			hidden += 1
	_check(hidden == 0, "the split pieces are shown once drawn (%d hidden)" % hidden)
	# Edits across the new walls and the old ones.
	for target: AdaptiveMesh in [mesh, whole]:
		target.edit(_sphere(1.0), _on_hill(whole, 4, 4), BooleanOp.Operation.SUBTRACT)
		target.edit(_sphere(1.0), _on_hill(whole, 8, 4), BooleanOp.Operation.UNION)
	await _wait_idle(mesh)
	await _wait_idle(whole)
	await _settle_frames(mesh)
	area = _area(mesh.get_faces())
	whole_area = _area(whole.get_faces())
	_check(_seam_errors(mesh) == 0 and absf(area - whole_area) < 1e-3 * whole_area,
			"later edits across new and old walls: closed, same surface (%.3f vs %.3f)" % [area, whole_area])
	# Saved and loaded, split cells and all.
	var copy := AdaptiveMesh.new()
	copy.data = mesh.data.copy()
	copy.collision = _no_collision()
	root.add_child(copy)
	_check(copy.is_idle() and copy.get_pieces().size() == mesh.get_pieces().size()
			and copy.get_triangle_count() == mesh.get_triangle_count(), "loaded data shows the split pieces")
	mesh.queue_free()
	whole.queue_free()
	copy.queue_free()


func _hill_ready(split_above: int) -> AdaptiveMesh:
	var mesh := _hill(split_above)
	await mesh.baked
	await _wait_idle(mesh)
	return mesh


# Waits a few frames for split pieces to swap in.
func _settle_frames(mesh: AdaptiveMesh) -> void:
	for i in 4:
		await process_frame
	await _wait_idle(mesh)


# Neighbours redraw their seam shading only when the faces they share with the edited piece
# changed: never for a dig in the middle of a piece, only the one across the wall for a dig
# next to a wall.
func _test_neighbours_redraw_only_when_needed() -> void:
	print("neighbours redraw only when needed")
	var mesh := await _hill_ready(0)
	var drawn := {}
	for key: Vector4i in mesh.get_pieces():
		(mesh.get_pieces()[key] as AdaptivePiece).drawn.connect(func() -> void: drawn[key] = drawn.get(key, 0) + 1)
	var middle := Vector4i(0, 0, 0, 0)  # cell x 0..8, z 0..8
	mesh.edit(_sphere(0.8), _on_hill(mesh, 4, 4), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	await process_frame
	var others := drawn.keys().filter(func(k: Vector4i) -> bool: return k != middle)
	_check(drawn.has(middle) and others.is_empty(), "a dig in the middle of a piece: no neighbour redraws (%s)" % [others])
	drawn.clear()
	mesh.edit(_sphere(0.8), _on_hill(mesh, 7.2, 4), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	await process_frame
	others = drawn.keys().filter(func(k: Vector4i) -> bool: return k != middle)
	_check(others == [Vector4i(1, 0, 0, 0)], "a dig next to the +x wall: only the piece across it redraws (%s)" % [others])
	_check(_seam_errors(mesh) == 0, "seams closed")
	mesh.queue_free()


# Collision shapes kept from before an edit still describe the surface as it was.
func _test_collision_snapshot() -> void:
	print("collision snapshot")
	var mesh := _chunked(Vector3(2, 0, 2), false)
	mesh.collision = PieceCollision.new()
	root.add_child(mesh)
	await _wait_idle(mesh)
	var shapes := mesh.get_collision_shapes()
	_check(shapes.size() == mesh.get_pieces().size(), "one shape per piece (%d)" % shapes.size())
	var before := []
	for shape in shapes:
		before.append((shape as ConcavePolygonShape3D).get_faces())
	mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(0, 2, 0)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(mesh)
	var unchanged := true
	for i in shapes.size():
		unchanged = unchanged and (shapes[i] as ConcavePolygonShape3D).get_faces() == before[i]
	var now := mesh.get_collision_shapes()
	var replaced := 0
	for shape in now:
		if not shapes.has(shape):
			replaced += 1
	_check(unchanged and replaced == 4, "the old shapes are untouched; the 4 edited pieces have new ones (%d)" % replaced)
	# A redraw (new seam shading, say) of a piece whose solid didn't change keeps its
	# collision shape: only the mesh is new.
	var piece: AdaptivePiece = mesh.get_pieces().values()[0]
	var shape := piece.get_collision_shape()
	var drawn := piece.get_mesh()
	piece.request_redraw()
	await _wait_idle(mesh)
	_check(piece.get_mesh() != drawn and piece.get_collision_shape() == shape,
			"a redraw makes a new mesh and keeps the collision shape")
	mesh.queue_free()



# Random digs and builds a few frames apart, with a tiny frame budget so splits take many
# frames and edits keep arriving mid-split, against a mesh that never splits. The hill's
# flat sides lie on the halfway lines of its edge cells (x and z = +-12): those pieces must
# stay whole rather than lose the side (cutting along a flat face drops it).
func _test_random_edits_during_splits() -> void:
	print("random edits during splits")
	var rng := RandomNumberGenerator.new()
	for trial in 3:
		rng.seed = trial
		var mesh := _hill(120)
		mesh.main_thread_budget_ms = 0.3
		var whole := _hill(0)
		# Both bake at once, and either may finish first: count both signals, rather than
		# await one and then the other (which may have fired meanwhile, and never fires again).
		var baked := [0]
		mesh.baked.connect(func() -> void: baked[0] += 1, CONNECT_ONE_SHOT)
		whole.baked.connect(func() -> void: baked[0] += 1, CONNECT_ONE_SHOT)
		while baked[0] < 2:
			await process_frame
		for step in 10:
			var at := Vector2(rng.randf_range(0.5, 9.5), rng.randf_range(0.5, 7.5))
			var operation := BooleanOp.Operation.UNION if rng.randf() < 0.3 else BooleanOp.Operation.SUBTRACT
			var xform := _on_hill(whole, at.x, at.y)
			for target: AdaptiveMesh in [mesh, whole]:
				target.edit(_sphere(1.0), xform, operation)
			for frame in rng.randi_range(0, 3):
				await process_frame
		await _wait_idle(whole)
		await _settle_frames(mesh)
		var area := _area(mesh.get_faces())
		var whole_area := _area(whole.get_faces())
		_check(absf(area - whole_area) < 1e-3 * whole_area and _seam_errors(mesh) == 0,
				"trial %d: %d cells split, same surface (%.3f vs %.3f), seams closed" % [trial,
				mesh.data.split_keys.size(), area, whole_area])
		mesh.queue_free()
		whole.queue_free()
		await process_frame
