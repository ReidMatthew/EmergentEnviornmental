extends "test_suite.gd"
## AdaptiveMesh as a component on an existing mesh: dormant until the first edit (or the
## start), then taking over the target's look and physics; find(); reset handing back; a
## target set by path; bake fingerprints; editor warnings; freeing a mesh mid-edit.


func run() -> void:
	await _test_dormant_until_first_edit()
	await _test_baked_data_takes_over_at_once()
	await _test_activation_at_start()
	await _test_target_by_path()
	await _test_fingerprints_and_warnings()
	await _test_auto_bake_saving()
	await _test_free_mid_edit()


# A box mesh with simplified collision (a box shape) on physics layer 4, and a component.
func _rock(add: bool = true) -> MeshInstance3D:
	var rock := MeshInstance3D.new()
	rock.mesh = _box_mesh()
	rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rock.layers = 3
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = 4
	body.collision_mask = 2
	rock.add_child(body)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(4, 4, 4)
	body.add_child(shape)
	var adaptive := AdaptiveMesh.new()
	adaptive.name = "Adaptive"
	rock.add_child(adaptive)
	if add:
		root.add_child(rock)
	return rock


func _adaptive_of(rock: Node) -> AdaptiveMesh:
	return rock.get_node("Adaptive")


func _shape_of(rock: Node) -> CollisionShape3D:
	return rock.get_node("Collision").get_child(0)


func _test_dormant_until_first_edit() -> void:
	print("dormant until the first edit")
	var rock := _rock()
	var adaptive := _adaptive_of(rock)
	await process_frame
	var body: StaticBody3D = rock.get_node("Collision")
	_check(adaptive.is_component() and adaptive.get_target() == rock and not adaptive.is_active()
			and adaptive.get_pieces().is_empty(), "under a MeshInstance3D with no source: a dormant component, no pieces")
	_check(rock.layers == 3 and not _shape_of(rock).disabled, "the mesh draws and collides as authored")
	_check(AdaptiveMesh.find(body) == adaptive and AdaptiveMesh.find(rock) == adaptive
			and AdaptiveMesh.get_all(tree).has(adaptive), "find() knows it from the mesh's own collision; it's in the group")
	_check(adaptive.get_reads_description() == "%s (1 mesh), default settings" % rock.name
			and adaptive.get_collision_description() == "copies Collision (layer 4, mask 2)",
			"the inspector says what the empty slots resolve to: %s; %s" % [adaptive.get_reads_description(),
			adaptive.get_collision_description()])
	_check(AdaptiveMesh.find(root) == null, "find() on anything else is null")
	adaptive.edit(_sphere(1.0), Transform3D(Basis(), Vector3(2, 2, 2)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(adaptive)
	var piece: AdaptivePiece = adaptive.get_pieces().values()[0] if not adaptive.get_pieces().is_empty() else null
	_check(adaptive.is_active() and piece != null and adaptive.data != null and adaptive.data.is_baked(),
			"the first edit baked it (no saved data) and took over")
	_check(rock.layers == 0 and _shape_of(rock).disabled, "the mesh is hidden (render layers 0) and its collision off")
	_check(adaptive.get_triangle_count() > 12, "the dig shows in the pieces (%d triangles)" % adaptive.get_triangle_count())
	var piece_body: StaticBody3D = null
	var mesh_instance: MeshInstance3D = null
	if piece != null:
		for child in piece.get_children(true):
			if child is StaticBody3D:
				piece_body = child
			elif child is MeshInstance3D:
				mesh_instance = child
	_check(piece_body != null and piece_body.collision_layer == 4 and piece_body.collision_mask == 2
			and AdaptiveMesh.find(piece_body) == adaptive, "pieces collide on the mesh's physics layers, and find() knows them")
	_check(mesh_instance != null and mesh_instance.layers == 3
			and mesh_instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "pieces draw like the mesh (layers, shadows)")
	adaptive.reset()
	await process_frame
	_check(not adaptive.is_active() and adaptive.get_pieces().is_empty() and rock.layers == 3
			and not _shape_of(rock).disabled, "reset hands the mesh back as authored")
	rock.queue_free()


func _test_baked_data_takes_over_at_once() -> void:
	print("baked data takes over at once")
	var source := _rock()
	var adaptive := _adaptive_of(source)
	adaptive.bake()
	await adaptive.baked
	_check(not adaptive.is_active() and adaptive.data.is_baked(), "baking a component doesn't take over")
	var rock := _rock(false)
	_adaptive_of(rock).data = adaptive.data
	root.add_child(rock)
	await process_frame
	_adaptive_of(rock).edit(_sphere(1.0), Transform3D(Basis(), Vector3(-2, 2, 2)), BooleanOp.Operation.SUBTRACT)
	_check(_adaptive_of(rock).is_active() and not _adaptive_of(rock).get_pieces().is_empty() and rock.layers == 0,
			"with saved data the edit takes over in the same frame")
	await _wait_idle(_adaptive_of(rock))
	_check(_adaptive_of(rock).data != adaptive.data, "and works on its own copy of the shared data")
	source.queue_free()
	rock.queue_free()


func _test_activation_at_start() -> void:
	print("activation at start")
	var rock := _rock(false)
	_adaptive_of(rock).activation = AdaptiveMesh.Activation.AT_START
	root.add_child(rock)
	await _wait_idle(_adaptive_of(rock))
	_check(_adaptive_of(rock).is_active() and rock.layers == 0 and _shape_of(rock).disabled
			and not _adaptive_of(rock).get_pieces().is_empty(), "takes over without an edit")
	rock.queue_free()


# The component next to the mesh instead of under it, pointing at it.
func _test_target_by_path() -> void:
	print("target set by path")
	var holder := Node3D.new()
	root.add_child(holder)
	var rock := MeshInstance3D.new()
	rock.mesh = _box_mesh()
	rock.position = Vector3(10, 0, 0)
	holder.add_child(rock)
	var adaptive := AdaptiveMesh.new()
	adaptive.target = rock
	holder.add_child(adaptive)
	await process_frame
	_check(adaptive.is_component() and adaptive.global_position.is_equal_approx(rock.global_position),
			"moves onto its target when the game starts")
	adaptive.edit(_sphere(1.0), Transform3D(Basis(), Vector3(12, 2, 2)), BooleanOp.Operation.SUBTRACT)
	await _wait_idle(adaptive)
	var corner_dug := true
	for p in adaptive.get_faces():
		if p.is_equal_approx(Vector3(2, 2, 2)):
			corner_dug = false
	_check(adaptive.is_active() and rock.layers == 0 and corner_dug, "edits land on the mesh where it is (its corner dug away)")
	holder.queue_free()


func _test_fingerprints_and_warnings() -> void:
	print("fingerprints and warnings")
	var rock := _rock()
	var adaptive := _adaptive_of(rock)
	_check(adaptive._get_configuration_warnings().is_empty(),
			"no warnings for an unbaked component with auto-bake on (it's on its way)")
	_check("simpler" in adaptive.get_collision_note(), "the simplified collision is a note for the inspector, not a warning")
	adaptive.activation = AdaptiveMesh.Activation.AT_START
	_check(adaptive.get_collision_note().is_empty(), "no note when taking over at start")
	adaptive.activation = AdaptiveMesh.Activation.ON_FIRST_EDIT
	adaptive.auto_bake = false
	_check("No baked data" in "".join(adaptive._get_configuration_warnings()), "with auto-bake off, a missing bake is a warning")
	adaptive.bake()
	await adaptive.baked
	_check(not adaptive.data.fingerprint.is_empty() and adaptive.data.fingerprint == adaptive.get_bake_fingerprint()
			and adaptive._get_configuration_warnings().is_empty(), "a fresh bake matches its fingerprint")
	(rock.mesh as BoxMesh).size = Vector3(4, 5, 4)
	_check(adaptive.data.fingerprint != adaptive.get_bake_fingerprint()
			and "out of date" in "".join(adaptive._get_configuration_warnings()), "changing the mesh makes the bake out of date")
	(rock.mesh as BoxMesh).size = Vector3(4, 4, 4)
	_check(adaptive.data.fingerprint == adaptive.get_bake_fingerprint(), "and changing it back matches again")
	rock.queue_free()


# What the editor's auto-bake does once a change has settled: bake, save next to the mesh
# and point at the file; share a matching file; never overwrite another mesh's file.
func _test_auto_bake_saving() -> void:
	print("auto-bake saving")
	var dir := "user://adaptive_mesh_auto_bake_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var mesh_path := dir.path_join("crate.res")
	ResourceSaver.save(_box_mesh(), mesh_path)
	var crate_mesh: Mesh = ResourceLoader.load(mesh_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var first := _crate(crate_mesh)
	_check(first.get_data_path() == dir.path_join("crate.adaptive.res"), "saves next to the mesh: %s" % first.get_data_path().get_file())
	await first._auto_bake()
	_check(first.data != null and first.data.resource_path == dir.path_join("crate.adaptive.res")
			and FileAccess.file_exists(first.data.resource_path) and first.data.fingerprint == first.get_bake_fingerprint(),
			"bakes, saves and points data at the file")
	var copy := _crate(crate_mesh)
	await copy._auto_bake()
	_check(copy.data != null and copy.data.resource_path == first.data.resource_path, "another copy of the same mesh shares that file")
	var other := _crate(crate_mesh)
	var grid := GridChunking.new()
	grid.cell_size = Vector3(2, 0, 2)
	other.chunking = grid
	_check(other.get_data_path() == dir.path_join("crate_2.adaptive.res"),
			"different settings don't overwrite it: %s" % other.get_data_path().get_file())
	for node in [first, copy, other]:
		node.get_parent().queue_free()
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
	await process_frame


func _crate(mesh: Mesh) -> AdaptiveMesh:
	var crate := MeshInstance3D.new()
	crate.mesh = mesh
	var adaptive := AdaptiveMesh.new()
	crate.add_child(adaptive)
	root.add_child(crate)
	return adaptive


# Freeing a mesh while its edits run on worker threads must wait for them, not crash.
func _test_free_mid_edit() -> void:
	print("freeing a mesh mid-edit")
	for frames in [0, 1, 2]:
		var mesh := _adaptive(_box_mesh(), false)
		root.add_child(mesh)
		await _settle(mesh)
		mesh.edit(_sphere(1.0), Transform3D(Basis(), Vector3(2, 2, 2)), BooleanOp.Operation.SUBTRACT)
		for i in frames:
			await process_frame
		var busy := not mesh.is_idle()
		mesh.free()
		await process_frame
		_check(true, "freed %d frames after an edit (busy: %s): no crash" % [frames, busy])


func _wait_idle(mesh: AdaptiveMesh) -> void:
	await process_frame
	var frames := 0
	while not mesh.is_idle():
		await process_frame
		frames += 1
		if frames == 2000:
			_check(false, "the mesh settles (still busy after 2000 frames)")
			return
