extends SceneTree
## Where the time goes, stage by stage, on the adaptive_mesh demos. From the project folder:
##   godot --headless -s res://addons/adaptive_mesh_native/tests/benchmark.gd
##   godot --headless -s res://addons/adaptive_mesh_native/tests/benchmark.gd -- manifold castle
## (or without --headless, to include drawing). Arguments after [code]--[/code] filter:
## backend names (csg, manifold) and words in scenario names; [code]script[/code] runs the
## GDScript geometry instead of the native core.
##
## Each scenario loads its demo scene fresh, sets the meshes' backend, makes the same edits,
## and waits until everything is idle. Per scenario and backend it prints (medians of a few
## rounds) how long until settled (pieces idle and separated parts out), frames taken, the
## main thread's worst frame and frames over 16.7 ms; then the time per stage (see [StageProfile]), added up over all threads,
## with calls. Stages starting "main:" run on the main thread.

const DEMO := "res://addons/adaptive_mesh/demo/"
const ROUNDS := 3


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var filters := OS.get_cmdline_user_args()
	var backends := ["csg", "manifold"].filter(func(b: String) -> bool: return b in filters)
	if backends.is_empty():
		backends = ["csg", "manifold"]
	# "script": the GDScript geometry instead of the native core (to compare the two).
	NativeKernel.enabled = not "script" in filters
	print("geometry: %s" % ("native" if NativeKernel.on() else "GDScript"))
	var words := Array(filters).filter(func(w: String) -> bool: return not w in ["csg", "manifold", "script"])
	if "manifold" in backends and not ManifoldBooleanBackend.is_available():
		print("The Manifold library didn't load.")
		quit(1)
		return
	StageProfile.enabled = true
	if ManifoldBooleanBackend.is_available():
		ClassDB.class_call_static(&"ManifoldBoolean", &"set_timing", true)
	for scenario: Array in _scenarios():
		if not words.is_empty() and not words.any(func(w: String) -> bool: return w in scenario[0]):
			continue
		print("\n%s" % scenario[0])
		for backend_name: String in backends:
			var results := []
			for round in ROUNDS:
				results.append(await _measure(scenario, backend_name))
			_print_result(backend_name, results)
	quit()


func _scenarios() -> Array:
	return [
		["terrain: one dig", "terrain_demo", "Terrain", _one_dig.bind(Vector3(10, 0, 10), 6.0)],
		["terrain: 12-dig stroke", "terrain_demo", "Terrain", _stroke.bind(Vector3(-30, 0, 10), Vector3(30, 0, 10), 12, 6.0)],
		["terrain: blast (8 digs at once)", "terrain_demo", "Terrain", _blast.bind(Vector3(0, 0, 0), 25.0, 8, 7.0)],
		["castle: one dig in a wall", "castle_demo", "Castle", _one_dig_at.bind(Vector3(-12, 6, 38.5), 2.0)],
		["castle: 12-dig stroke on a wall", "castle_demo", "Castle", _stroke_at.bind(Vector3(-14, 6, 38.5), Vector3(8, 6, 38.5), 12, 2.0)],
		["castle: cut through the keep", "castle_demo", "Castle", _cut.bind()],
		["castle: dismantle (cubes of 5)", "castle_demo", "Castle", _dismantle.bind(5.0)],
		["rigid rock: one dig", "rocks_demo", "", _rigid_dig.bind()],
	]


# Loads the scenario's scene with every mesh on [param backend_name], runs the edits and
# measures until everything is idle again. Returns [settled ms, frames, worst frame ms,
# frames over 16.7 ms, stage totals].
func _measure(scenario: Array, backend_name: String) -> Array:
	var scene: Node = load(DEMO + scenario[1] + ".tscn").instantiate()
	# The backend goes on before the meshes enter the tree: they hand it to their pieces
	# when they make them.
	var backend: BooleanBackend = CsgBooleanBackend.new() if backend_name == "csg" else ManifoldBooleanBackend.new()
	for node in scene.find_children("*", "", true, false):
		if node is AdaptiveMesh:
			(node as AdaptiveMesh).backend = backend
	root.add_child(scene)
	current_scene = scene  # (separated parts go into it, and are freed with it)
	for i in 30:
		await process_frame
	var mesh: AdaptiveMesh
	for m: AdaptiveMesh in AdaptiveMesh.get_all(self):
		if scenario[2] == "" and m.is_moving():
			mesh = m
		elif scenario[2] != "" and m.get_target() != null and m.get_target().name == scenario[2]:
			mesh = m
	if mesh.get_body() != null:
		mesh.get_body().freeze = true  # (so it stays where the edits are aimed)
	mesh.activate()
	for i in 10:
		await process_frame
	# The edits are worked out (where each dig meets the surface) before timing starts.
	var edits: Callable = scenario[3]
	var queue: Array = edits.call(mesh)  # a Callable per frame
	StageProfile.reset()
	if ManifoldBooleanBackend.is_available():
		ClassDB.class_call_static(&"ManifoldBoolean", &"reset_timings")
	var start := Time.get_ticks_usec()
	var last := start
	var worst := 0
	var slow := 0
	var frames := [0]  # (in an array: the lambda below sees changes)
	var idle_since := -1  # when the current run of idle frames began
	var idle_frame := 0
	var idle_frames := 0
	# When the last separated parts were out (separation runs after the pieces are idle).
	var parts_out := [-1, 0]  # [usec, frame]
	for m: AdaptiveMesh in AdaptiveMesh.get_all(self):
		m.separated.connect(func(_made: Array, _plain: Array) -> void:
			parts_out[0] = Time.get_ticks_usec()
			parts_out[1] = frames[0])
	while true:
		if not queue.is_empty():
			var asked := StageProfile.begin()
			(queue.pop_front() as Callable).call()
			StageProfile.end(&"main: the edit calls", asked)
		await process_frame
		frames[0] += 1
		var now := Time.get_ticks_usec()
		worst = maxi(worst, now - last)
		if now - last > 16700:
			slow += 1
		last = now
		# Settled: idle for 10 frames in a row (separation checks start a frame or two after
		# the pieces go idle), timed to the first of them.
		if queue.is_empty() and frames[0] > 2 and AdaptiveMesh.get_all(self).all(func(m: AdaptiveMesh) -> bool: return m.is_idle()):
			if idle_frames == 0:
				idle_since = now
				idle_frame = frames[0]
			idle_frames += 1
			# (and 60 more, for parts a separation check may still free)
			if idle_frames >= 60 and frames[0] - parts_out[1] >= 10:
				break
		else:
			idle_frames = 0
		if frames[0] > 5000:
			break
	var stages := StageProfile.get_totals()
	if backend_name == "manifold":
		# Inside the native calls: their own phases (boolean, weld, clean-up...).
		var phases: Dictionary = ClassDB.class_call_static(&"ManifoldBoolean", &"get_timings")
		for phase: String in phases:
			if phases[phase] > 0:
				stages[StringName("  native: " + phase)] = [phases[phase], 0]
	scene.queue_free()
	for i in 30:
		await process_frame
	var done := maxi(idle_since, parts_out[0])
	return [(done - start) / 1000.0, maxi(idle_frame, parts_out[1]), worst / 1000.0, slow, stages]


func _print_result(backend_name: String, results: Array) -> void:
	var medians := []
	for c in 4:
		var values := results.map(func(r: Array) -> float: return r[c])
		values.sort()
		medians.append(values[values.size() / 2])
	print("  %-9s settled %5.0f ms  frames %4d  worst frame %5.1f ms  over 16.7 ms: %d" % [backend_name,
			medians[0], medians[1], medians[2], medians[3]])
	# Stage times: the mean over the rounds, biggest first.
	var totals := {}
	for r: Array in results:
		var stages: Dictionary = r[4]
		for stage: StringName in stages:
			var entry: Array = totals.get(stage, [0.0, 0.0])
			entry[0] += stages[stage][0] / 1000.0 / results.size()
			entry[1] += stages[stage][1] / float(results.size())
			totals[stage] = entry
	var names := totals.keys()
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return totals[a][0] > totals[b][0])
	for stage: StringName in names:
		print("      %-34s %8.1f ms  %6.0f calls" % [stage, totals[stage][0], totals[stage][1]])


# --- Scenarios: each returns the edits, a Callable per frame -------------------------

func _sphere(radius: float) -> SolidSphere:
	var sphere := SolidSphere.new()
	sphere.radius = radius
	sphere.tag = 10
	return sphere


# The highest point of the mesh near x, z (its own space).
func _surface(mesh: AdaptiveMesh, x: float, z: float) -> Vector3:
	var best := -INF
	for p in mesh.get_faces():
		if absf(p.x - x) < 3.0 and absf(p.z - z) < 3.0:
			best = maxf(best, p.y)
	return Vector3(x, best, z)


func _dig_at(mesh: AdaptiveMesh, local: Vector3, radius: float) -> Callable:
	var sphere := _sphere(radius)
	var at := mesh.global_transform * Transform3D(Basis(), local)
	return func() -> void: mesh.edit(sphere, at, BooleanOp.Operation.SUBTRACT)


func _one_dig(mesh: AdaptiveMesh, at: Vector3, radius: float) -> Array:
	return [_dig_at(mesh, _surface(mesh, at.x, at.z), radius)]


func _stroke(mesh: AdaptiveMesh, from: Vector3, to: Vector3, count: int, radius: float) -> Array:
	var out := []
	for i in count:
		var p := from.lerp(to, i / float(count - 1))
		out.append(_dig_at(mesh, _surface(mesh, p.x, p.z), radius))
	return out


# [param count] digs in a ring of [param spread] round [param centre], all in one frame.
func _blast(mesh: AdaptiveMesh, centre: Vector3, spread: float, count: int, radius: float) -> Array:
	var digs := []
	for i in count:
		var a := TAU * i / count
		var p := centre + Vector3(cos(a), 0, sin(a)) * spread
		digs.append(_dig_at(mesh, _surface(mesh, p.x, p.z), radius))
	return [func() -> void:
		for dig: Callable in digs:
			dig.call()]


func _one_dig_at(mesh: AdaptiveMesh, local: Vector3, radius: float) -> Array:
	return [_dig_at(mesh, local, radius)]


func _stroke_at(mesh: AdaptiveMesh, from: Vector3, to: Vector3, count: int, radius: float) -> Array:
	var out := []
	for i in count:
		out.append(_dig_at(mesh, from.lerp(to, i / float(count - 1)), radius))
	return out


func _cut(mesh: AdaptiveMesh) -> Array:
	var g := mesh.global_transform
	return [func() -> void: mesh.cut(g * Vector3(-30, 30, 20), g * Vector3(30, 30, 20), g.basis * Vector3(0, 0, -1), 60.0)]


func _dismantle(mesh: AdaptiveMesh, size: float) -> Array:
	return [func() -> void: mesh.dismantle(size)]


# A dig into the top of a rigid rock (a moving mesh).
func _rigid_dig(mesh: AdaptiveMesh) -> Array:
	var top := mesh.get_aabb()
	return [_dig_at(mesh, Vector3(top.get_center().x, top.end.y, top.get_center().z), 0.25)]
