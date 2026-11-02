extends SceneTree
## Does a step slower than a frame make the game stutter? The game scale demo made heavy (all fine, THREADS default 1,
## SUBSTEPS default 4: a step of about 20 ms, longer than a 60 Hz tick), filled, then 600 frames timed: the frame times, how
## many steps a second the water got, and how often a frame ended with the solver idle and a step owed.
##   godot --headless --path . -s res://addons/water_sim/tools/stall_check.gd
## WAIT=1 sets WaterSim.wait_for_step (the frame waits for the step, as before 2026-10-28).

var _steps := 0


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	Engine.max_fps = 0
	var demo: Node = (load("res://addons/water_sim/demo/scenes/game_scale_demo.tscn") as PackedScene).instantiate()
	var sim: WaterSim = demo.get_node("WaterSim")
	sim.threads = int(OS.get_environment("THREADS")) if OS.get_environment("THREADS") != "" else 1
	sim.max_substeps = int(OS.get_environment("SUBSTEPS")) if OS.get_environment("SUBSTEPS") != "" else 4
	sim.detail_levels = 1
	sim.wait_for_step = OS.get_environment("WAIT") == "1"
	root.add_child(demo)
	sim.stepped.connect(func() -> void: _steps += 1)
	for i in 10:
		await process_frame
	(sim.get_node("Fill") as WaterSimEmitter).fill()
	for i in 120:
		await process_frame
	var times: Array[float] = []
	var idle := 0
	_steps = 0
	var start := Time.get_ticks_usec()
	var last := start
	for i in 600:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
		if not sim.get_solver().is_stepping():
			idle += 1
	var seconds := (last - start) / 1e6
	times.sort()
	print("stall: %d particles, step %.1f ms; frames p50 %.2f p99 %.2f max %.2f ms (%.0f fps); %.1f steps a second (%.2f s of water a second); solver idle at %d of 600 frame ends" % [
			sim.get_particle_count(), sim.get_stats().get("step_msec", 0.0), times[300], times[594], times[599], 600 / seconds,
			_steps / seconds, _steps / seconds * sim.fixed_step, idle])
	quit()
