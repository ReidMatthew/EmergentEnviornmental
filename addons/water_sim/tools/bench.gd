extends SceneTree
## A fixed run of a demo that writes one small results file (frame, GPU, render CPU, sim step, memory)
## and prints one line, so a change is judged by comparing two files rather than by logs or screenshots.
##   godot --path . -s res://addons/water_sim/tools/bench.gd                       (window: GPU numbers)
##   godot --headless --path . -s res://addons/water_sim/tools/bench.gd            (sim only, no GPU)
##   COMPARE=res://.bench/before.json,res://.bench/after.json godot --headless --path . -s res://addons/water_sim/tools/bench.gd
## DEMO=res://... picks the scene (default the waterfall), LABEL names the file (default "latest"),
## WARMUP and SECONDS set the run in seconds (default 2 and 5; seconds, so runs at different frame rates cover the same game time), THREADS the sim's threads (default: the demo's), BUDGET=ms its step_budget_ms (default 0, every thread; the results' sim.threads_used says how many it used), VIEW=x,y,z,distance,yaw,pitch aims the camera,
## CELL (m) and SUBSTEPS override the node's cell size and substeps; LEVELS sets detail_levels, BY_VIEW=0 or 1 sets detail_by_view, SLEEP_BY_MOTION=0 or 1 sets sleep_by_motion, DROWSY=0 or 1 and DROWSY_SPEED the drowsy blocks, FILL_SIZE=x,y,z the fill emitter's size. SHAPE=0, 1 or 2 draws the particles as spheres, cubes or discs.
## SMALL=px sets the fluid view's small_pixels (particles under that many pixels across go to the compute rasterizer). STAGES=1 adds the fluid effect's GPU time by pass (windowed). FILL=WaterSim/Fill fills that emitter's shape at the start (the game scale demo starts empty).
## THIN=n sets the fluid views' thin_interior (0: off); the results file's drawn_points is the particles sent to the fluid passes. WAVES=m sets surface_wave_height.
## SCALE=f sets the viewport's 3D resolution scale (what the fluid passes draw at), SMOOTH_PASSES=n the fluid views' smoothing_passes.
## FUSE_RESOLVE=0 or 1 the fluid views' fuse_resolve.
## SPRAY=0 or 1 turns the spray views off or on. WATER=0 hides the fluid and particle views (the demo's F and P), to see what
## drawing the water costs against the step.
## CAP=fps caps the frame rate as a game's refresh would (default none): the step's threads and the card then idle between frames, so the step and the GPU's ms read as they do in play.
## Files go to res://.bench/<LABEL>.json; Godot and git skip the folder.

const DIR := "res://.bench"


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, default: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else default


# The sim's settings from the environment. (Applied again after the first frame: a demo's menu loads its saved settings then.)
func _apply_overrides(sim: WaterSim) -> void:
	if OS.get_environment("THREADS") != "":
		sim.threads = int(OS.get_environment("THREADS"))
	# (Off unless asked for: THREADS is then the threads measured.)
	sim.step_budget_ms = float(_env("BUDGET", "0"))
	if OS.get_environment("SUBSTEPS") != "":
		sim.max_substeps = int(OS.get_environment("SUBSTEPS"))
	if OS.get_environment("LEVELS") != "":
		sim.detail_levels = int(OS.get_environment("LEVELS"))
	if OS.get_environment("SLEEP_BY_MOTION") != "":
		sim.sleep_by_motion = OS.get_environment("SLEEP_BY_MOTION") == "1"
	if OS.get_environment("DROWSY") != "":
		sim.drowsy_blocks = OS.get_environment("DROWSY") == "1"
	if OS.get_environment("DROWSY_SPEED") != "":
		sim.drowsy_speed = float(OS.get_environment("DROWSY_SPEED"))
	if OS.get_environment("WAVES") != "":
		sim.surface_wave_height = float(OS.get_environment("WAVES"))
	if OS.get_environment("BY_VIEW") != "":
		sim.detail_by_view = OS.get_environment("BY_VIEW") == "1"


# The views' settings from the environment (applied again after the first frame, like the sim's).
func _apply_view_overrides(demo: Node) -> void:
	var fluid_views := demo.find_children("*", "WaterSimFluidView", true, false)
	for view in fluid_views:
		if OS.get_environment("SHAPE") != "":
			view.shape = int(OS.get_environment("SHAPE")) as WaterSimFluidView.Shape
		if OS.get_environment("SMALL") != "":
			view.small_pixels = float(OS.get_environment("SMALL"))
		if OS.get_environment("THIN") != "":
			view.thin_interior = int(OS.get_environment("THIN"))
		if OS.get_environment("SMOOTH_PASSES") != "":
			view.smoothing_passes = int(OS.get_environment("SMOOTH_PASSES"))
		if OS.get_environment("FUSE_RESOLVE") != "":
			view.fuse_resolve = OS.get_environment("FUSE_RESOLVE") == "1"
	if OS.get_environment("SPRAY") != "":
		for view in demo.find_children("*", "WaterSimSprayView", true, false):
			view.enabled = OS.get_environment("SPRAY") == "1"
	# WATER=0: the fluid and particle views hidden.
	if OS.get_environment("WATER") == "0":
		for view in fluid_views + demo.find_children("*", "WaterSimParticleView", true, false):
			view.visible = false


func _go() -> void:
	if OS.get_environment("COMPARE") != "":
		var paths := OS.get_environment("COMPARE").split(",")
		_compare(_load(paths[0]), _load(paths[1]))
		quit()
		return
	seed(1)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = int(_env("CAP", "0"))
	var demo_path := _env("DEMO", "res://addons/water_sim/demo/scenes/waterfall_demo.tscn")
	var demo: Node = (load(demo_path) as PackedScene).instantiate()
	root.add_child(demo)
	var sim: WaterSim = demo.get_node("WaterSim")
	if OS.get_environment("CELL") != "":
		sim.cell_size = float(OS.get_environment("CELL"))
	_apply_overrides(sim)
	if OS.get_environment("FILL_SIZE") != "":
		var fs := OS.get_environment("FILL_SIZE").split(",")
		(demo.get_node(OS.get_environment("FILL")) as WaterSimEmitter).size = Vector3(float(fs[0]), float(fs[1]), float(fs[2]))
	if OS.get_environment("FILL") != "":
		(demo.get_node(OS.get_environment("FILL")) as WaterSimEmitter).fill.call_deferred()
	var fluid_views := demo.find_children("*", "WaterSimFluidView", true, false)
	if OS.get_environment("SCALE") != "":
		root.scaling_3d_scale = float(OS.get_environment("SCALE"))
	_apply_view_overrides(demo)
	if OS.get_environment("STAGES") == "1":
		for view in fluid_views:
			view._effect.profile = true
			view._effect.vertex_only = OS.get_environment("VERTEX_ONLY") == "1"
	if OS.get_environment("VIEW") != "":
		var v := OS.get_environment("VIEW").split(",")
		var camera: Camera3D = demo.get_node("Camera")
		camera.target = Vector3(float(v[0]), float(v[1]), float(v[2]))
		camera.distance = float(v[3])
		camera.yaw = float(v[4])
		camera.pitch = float(v[5])
		camera._place()
	var gpu_on := DisplayServer.get_name() != "headless"
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, gpu_on)
	# Seconds, not frames: a run drawing nothing goes many times faster, and a count of frames would measure it before the
	# water has settled (levels of detail, sleep).
	var warmup_end := Time.get_ticks_usec() + int(float(_env("WARMUP", "2")) * 1e6)
	await process_frame
	_apply_overrides(sim)
	_apply_view_overrides(demo)
	while Time.get_ticks_usec() < warmup_end:
		await process_frame

	var frame_ms: Array[float] = []
	var gpu_ms: Array[float] = []
	var render_cpu_ms: Array[float] = []
	var stats_sum := {}
	var stats_samples := 0
	var memory_start := OS.get_static_memory_usage()
	var last := Time.get_ticks_usec()
	var run_end := last + int(float(_env("SECONDS", "5")) * 1e6)
	var next_sample := last
	while last < run_end:
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append((now - last) / 1000.0)
		last = now
		if gpu_on:
			gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
			render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
		# get_stats waits for the step in flight, so reading it every frame would serialise the frame with the step
		# and hide the overlap being measured; a sample every sixth of a second (every tenth frame at 60 fps) is enough
		# for the averages.
		if now >= next_sample:
			next_sample = now + 166667
			var stats := sim.get_stats()
			stats_samples += 1
			for key in stats:
				if stats[key] is float or stats[key] is int:
					stats_sum[key] = stats_sum.get(key, 0.0) + float(stats[key])

	var sim_stats := {}
	for key in stats_sum:
		sim_stats[key] = snappedf(stats_sum[key] / maxi(stats_samples, 1), 0.001)
	var result := {
		"label": _env("LABEL", "latest"),
		"demo": demo_path,
		"time": Time.get_datetime_string_from_system(),
		"window": "%dx%d" % [root.size.x, root.size.y] if gpu_on else "headless",
		"threads": sim.threads,
		"frames": frame_ms.size(),
		"particles": sim.get_particle_count(),
		"fps": snappedf(frame_ms.size() * 1000.0 / _sum(frame_ms), 0.1),
		"frame_ms": _summary(frame_ms),
		"gpu_ms": _summary(gpu_ms) if gpu_on else null,
		"render_cpu_ms": _summary(render_cpu_ms) if gpu_on else null,
		"sim": sim_stats,
		"memory_mb": {
			"static": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1),
			"static_peak": snappedf(OS.get_static_memory_peak_usage() / 1048576.0, 0.1),
			"static_growth": snappedf((OS.get_static_memory_usage() - memory_start) / 1048576.0, 0.1),
			"video": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		},
		"drawn_points": fluid_views[0]._effect._count if not fluid_views.is_empty() else 0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	}
	# STAGES=1: the fluid effect's GPU time by pass (ms, a running mean; timestamps cost a little, so the frame times are not for comparing).
	if OS.get_environment("STAGES") == "1" and not fluid_views.is_empty():
		var stages := {}
		for stage: String in fluid_views[0]._effect.timings:
			stages[stage.trim_prefix("ws_")] = snappedf(fluid_views[0]._effect.timings[stage], 0.001)
		result["stages_ms"] = stages
		print("stages ", stages)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if not FileAccess.file_exists(DIR + "/.gdignore"):
		FileAccess.open(DIR + "/.gdignore", FileAccess.WRITE)
		FileAccess.open(DIR + "/.gitignore", FileAccess.WRITE).store_string("*\n")
	var path := "%s/%s.json" % [DIR, result.label]
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("bench %s: %.1f fps, frame p50 %.2f p99 %.2f ms, GPU %s, sim step %s ms, %d particles, mem %.1f MB (video %.1f) -> %s" % [
			result.label, result.fps, result.frame_ms.p50, result.frame_ms.p99,
			"%.2f ms" % result.gpu_ms.avg if gpu_on else "n/a", sim_stats.get("step_msec", "?"),
			result.particles, result.memory_mb.static, result.memory_mb.video, path])
	quit()


func _sum(values: Array[float]) -> float:
	var total := 0.0
	for v in values:
		total += v
	return total


func _summary(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	var at := func(q: float) -> float: return snappedf(sorted[mini(int(q * sorted.size()), sorted.size() - 1)], 0.01)
	return {"avg": snappedf(_sum(values) / values.size(), 0.01), "p50": at.call(0.5), "p95": at.call(0.95), "p99": at.call(0.99), "max": snappedf(sorted[-1], 0.01)}


func _load(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path.strip_edges()))


## Every number that differs between the two files, flattened, with the change from the first to the second.
func _compare(a: Dictionary, b: Dictionary) -> void:
	var flat_a := {}
	var flat_b := {}
	_flatten(a, "", flat_a)
	_flatten(b, "", flat_b)
	print("%-28s %12s %12s %9s" % ["%s -> %s" % [a.get("label"), b.get("label")], "before", "after", "change"])
	for key in flat_a:
		if not flat_b.has(key):
			continue
		var x: float = flat_a[key]
		var y: float = flat_b[key]
		if x == y:
			continue
		var change := ("%+.1f%%" % ((y - x) / absf(x) * 100.0) if x != 0.0 else "new")
		print("%-28s %12.2f %12.2f %9s" % [key, x, y, change])


func _flatten(value: Variant, prefix: String, out: Dictionary) -> void:
	if value is Dictionary:
		for key in value:
			_flatten(value[key], (prefix + "." if prefix != "" else "") + str(key), out)
	elif value is float or value is int:
		out[prefix] = float(value)
