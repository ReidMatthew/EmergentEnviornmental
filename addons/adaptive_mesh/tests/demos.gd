extends "test_suite.gd"
## The demo scenes, all ordinary models made adaptive by a component: they start from
## their saved bakes (no baking), the bakes still match what the models make, the dig tool
## digs, and reset hands the models back. In the rocks demo, the rocks stay ordinary until
## one is dug. Digging needs a window for the mouse, so it's skipped with --headless.


func run() -> void:
	for file in ["hill_demo", "terrain_demo"]:
		await _test_demo(file)
	await _test_rocks()
	await _test_castle()


# The hill (dormant until dug) and the terrain (taking over at start): ordinary models made
# adaptive by a component.
func _test_demo(file: String) -> void:
	print(file)
	var start := Time.get_ticks_msec()
	var scene: Node = load(get_script().resource_path.get_base_dir().path_join("../demo/%s.tscn" % file)).instantiate()
	root.add_child(scene)
	var all := AdaptiveMesh.get_all(tree)
	var mesh: AdaptiveMesh = all[0] if all.size() == 1 else null
	if mesh == null:
		_check(false, "one adaptive mesh in the scene (%d)" % all.size())
		scene.queue_free()
		return
	var at_start := mesh.activation == AdaptiveMesh.Activation.AT_START
	var baked := _data_triangles(mesh.data)
	_check(mesh.is_component() and mesh.is_idle() and mesh.data.is_baked() and mesh.is_active() == at_start,
			"a component on the %s, ready from its saved bake in %d ms (%d pieces, %d triangles), %s" % [
			mesh.get_target().name, Time.get_ticks_msec() - start, mesh.data.pieces.size(), baked,
			"taken over at start" if at_start else "dormant until dug"])
	# The bake must still be what the model makes (re-bake after changing either).
	var fresh := AdaptiveMesh.new()
	fresh.target = mesh.get_target()
	fresh.source = mesh.source
	fresh.chunking = mesh.chunking
	fresh.max_bounds = mesh.max_bounds
	scene.add_child(fresh)
	fresh.bake()
	await fresh.baked
	await process_frame  # out of the signal before freeing it
	_check(fresh.data.pieces.size() == mesh.data.pieces.size() and _data_triangles(fresh.data) == baked
			and mesh.data.fingerprint == mesh.get_bake_fingerprint(),
			"the saved bake matches a fresh one (%d pieces, %d triangles) and its fingerprint" % [
			fresh.data.pieces.size(), _data_triangles(fresh.data)])
	fresh.queue_free()
	await process_frame
	if DisplayServer.get_name() == "headless":
		print("  skip digging (needs a window for the mouse)")
	else:
		for i in 5:
			await tree.physics_frame
		var centre := root.get_visible_rect().size / 2.0
		root.warp_mouse(centre)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = centre
		Input.parse_input_event(press)
		for i in 60:
			await process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = centre
		Input.parse_input_event(release)
		# The release reaches the tool a frame or two later, and ending the stroke may queue
		# one last edit: wait for both before checking (and before resetting).
		var dig_tool: Node = scene.get_node("DigTool")
		while dig_tool.stroke.is_active():
			await process_frame
		await process_frame
		while not mesh.is_idle():
			await process_frame
		_check(mesh.is_active() and mesh.get_triangle_count() != baked, "holding the mouse on it digs (%d -> %d triangles)"
				% [baked, mesh.get_triangle_count()])
	mesh.reset()
	await process_frame
	_check(mesh.is_idle() and mesh.is_active() == at_start and (not at_start or mesh.get_triangle_count() == baked),
			"reset hands the model back%s" % (" and takes over again from the saved bake" if at_start else ""))
	scene.queue_free()
	await process_frame


# Visible triangles in [param data] (caps between pieces left out).
func _data_triangles(data: AdaptiveMeshData) -> int:
	var count := 0
	for solid: Solid in data.pieces.values():
		for tag in solid.tags:
			if tag != data.get_cap_tag():
				count += 1
	return count


func _test_rocks() -> void:
	print("rocks_demo")
	var scene: Node = load(get_script().resource_path.get_base_dir().path_join("../demo/rocks_demo.tscn")).instantiate()
	root.add_child(scene)
	await process_frame
	var rocks: Array[AdaptiveMesh] = AdaptiveMesh.get_all(tree).filter(func(m: AdaptiveMesh) -> bool: return not m.is_moving())
	var rigid: Array[AdaptiveMesh] = AdaptiveMesh.get_all(tree).filter(func(m: AdaptiveMesh) -> bool: return m.is_moving())
	var dormant := AdaptiveMesh.get_all(tree).filter(func(m: AdaptiveMesh) -> bool: return not m.is_active() and m.get_pieces().is_empty())
	_check(rocks.size() == 6 and rigid.size() == 3 and dormant.size() == 9,
			"6 rocks and 3 rigid rocks, all ordinary meshes until dug (%d of %d dormant)" % [dormant.size(), rocks.size() + rigid.size()])
	var first: AdaptiveMesh = rocks[0]
	_check(first.data != null and first.data.fingerprint == first.get_bake_fingerprint()
			and first.target == first.get_parent(), "they share the rock prefab's bake, it's up to date, and its target is set")
	var ground: Node = scene.get_node("Ground/Collision")
	_check(AdaptiveMesh.find(ground) == null and AdaptiveMesh.find(scene.get_node("Rock2/Collision")) == rocks[1],
			"find() tells a rock's collision from the ground's")
	if DisplayServer.get_name() == "headless":
		print("  skip digging (needs a window for the mouse)")
	else:
		for i in 5:
			await tree.physics_frame
		var camera := root.get_camera_3d()
		var centre := camera.unproject_position(first.get_target().global_position + Vector3(0, 0.3, 0))
		root.warp_mouse(centre)
		var before: int = (first.get_target() as VisualInstance3D).layers
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = centre
		Input.parse_input_event(press)
		for i in 30:
			await process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = centre
		Input.parse_input_event(release)
		await process_frame
		while not first.is_idle():
			await process_frame
		var active := rocks.filter(func(m: AdaptiveMesh) -> bool: return m.is_active())
		_check(active == [first] and (first.get_target() as VisualInstance3D).layers == 0 and before != 0,
				"holding the mouse on a rock digs that rock only (%d taken over)" % active.size())
		# Cut mode: a line dragged across another rock, starting beside it, cuts it through,
		# and the smaller part falls. (Largest, not the prefab's Ground: the cut slopes away
		# from the camera, and a slope that passes under the rock leaves both parts on the
		# ground.)
		var second: AdaptiveMesh = rocks[1]
		second.separation = second.separation.duplicate()
		second.separation.anchor = MeshSeparation.Anchor.LARGEST
		var fell: Array[AdaptiveMesh] = []
		second.separated.connect(func(parts: Array[AdaptiveMesh], _plain: Array[RigidBody3D]) -> void: fell.append_array(parts))
		var tool: Node = scene.get_node("DigTool")
		tool.mode = tool.Mode.CUT
		var middle := camera.unproject_position(second.get_target().global_position + Vector3(0, 0.25, 0))
		var reach := absf(camera.unproject_position(second.get_target().global_position + Vector3(3.0, 0.25, 0)).x - middle.x)
		root.warp_mouse(middle - Vector2(reach, 0))
		press.position = middle - Vector2(reach, 0)
		Input.parse_input_event(press)
		for step in 11:
			root.warp_mouse(middle + Vector2(reach * (step / 5.0 - 1.0), 0))
			await process_frame
		release.position = middle + Vector2(reach, 0)
		Input.parse_input_event(release)
		for i in 300:
			if not fell.is_empty():
				break
			await process_frame
		_check(fell.size() == 1 and tool.target == second, "cut mode: a line dragged across a rock cuts it through and a part separates (%d)"
				% fell.size())
	# A rigid rock: dug in code, its own hull is swapped for the piece's (4, as the prefab
	# asks), on the same body.
	var falling: AdaptiveMesh = rigid[0]
	var body := falling.get_body()
	falling.edit(_sphere(0.3), falling.global_transform * Transform3D(Basis(), Vector3(0.3, 0.3, 0)), BooleanOp.Operation.SUBTRACT)
	await _settle(falling)
	var hulls := 0
	var own_on := 0
	for owner_id in body.get_shape_owners():
		if body.shape_owner_get_owner(owner_id) is AdaptivePiece:
			hulls += body.shape_owner_get_shape_count(owner_id)
		elif not body.is_shape_owner_disabled(owner_id):
			own_on += 1
	_check(falling.is_active() and hulls == 4 and own_on == 0 and AdaptiveMesh.find(body) == falling,
			"a rigid rock dug takes over its body: the piece's 4 hulls on (%d), its own off, find() knows the body" % hulls)
	scene.queue_free()
	await process_frame


# The castle demo: the field and the castle take over at start from their saved bakes
# (which are up to date), the rocks stay ordinary until dug, and a dig into the castle
# wall lands.
func _test_castle() -> void:
	print("castle_demo")
	var start := Time.get_ticks_msec()
	var scene: Node = load(get_script().resource_path.get_base_dir().path_join("../demo/castle_demo.tscn")).instantiate()
	root.add_child(scene)
	await process_frame
	# (Parts an earlier test cut off may still be about: only this scene's meshes count.)
	var all := AdaptiveMesh.get_all(tree).filter(func(m: AdaptiveMesh) -> bool: return scene.is_ancestor_of(m))
	var active := all.filter(func(m: AdaptiveMesh) -> bool: return m.is_active())
	var names := active.map(func(m: AdaptiveMesh) -> String: return m.get_target().name)
	names.sort()
	_check(all.size() == 42 and names == ["Castle", "Field"],
			"the field and the castle take over at start, 40 rocks wait (%d meshes, active: %s)" % [all.size(), names])
	var fresh := true
	for m: AdaptiveMesh in active:
		fresh = fresh and m.is_idle() and m.data.is_baked() and m.data.fingerprint == m.get_bake_fingerprint()
	_check(fresh, "both ready from saved bakes that match their models, in %d ms" % (Time.get_ticks_msec() - start))
	var castle: AdaptiveMesh = active[0] if active[0].get_target().name == "Castle" else active[1]
	var pieces := castle.get_pieces().size()
	var hole := SolidSphere.new()
	hole.radius = 2.0
	hole.tag = 10
	# Into the curtain wall's outer face, beside the gatehouse.
	castle.edit(hole, Transform3D(Basis(), castle.global_transform * Vector3(-12.0, 6.0, 38.5)), BooleanOp.Operation.SUBTRACT)
	while not castle.is_idle():
		await process_frame
	var dug := 0
	var open := 0
	for piece: AdaptivePiece in castle.get_pieces().values():
		open += piece.solid.count_open_edges()
		for t in piece.solid.get_triangle_count():
			if piece.solid.tags[t] == 10:
				dug += 1
	_check(dug > 0 and open == 0 and castle.get_pieces().size() >= pieces,
			"a dig into the wall leaves cut stone (%d triangles), every piece closed (%d open edges)" % [dug, open])
	# The overlay showing a part (wireframe on) that is then freed: it used to keep its
	# wireframe under the part, freed with it, and break (a script error stops the game).
	var separated := []
	castle.separated.connect(func(made: Array, _plain: Array) -> void: separated.append_array(made))
	castle.dismantle(20.0)
	var waited := 0
	while separated.is_empty() and waited < 600:
		await process_frame
		waited += 1
	var overlay: Node = scene.get_node("DebugOverlay")
	overlay._wireframe.visible = true
	for part: AdaptiveMesh in separated.slice(0, 2):
		scene.get_node("DigTool").target = part
		await process_frame
		part.get_body().queue_free()
		for i in 3:
			await process_frame
	_check(not separated.is_empty() and overlay._current == null and is_instance_valid(overlay._wireframe),
			"the overlay lets go of a part freed while shown (%d parts)" % separated.size())
	scene.queue_free()
	await process_frame
