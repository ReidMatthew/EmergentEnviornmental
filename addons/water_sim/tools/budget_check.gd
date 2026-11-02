extends SceneTree
## Does WaterSim.step_budget_ms hold? The game scale demo filled at a game's frame rate, with a blast into the pond partway through:
## twice a second the threads the step used and how long it took, then how often a step went over the budget and over its tick, how many
## threads it used on average and how many steps the water got.
##   godot --path . -s res://addons/water_sim/tools/budget_check.gd
## THREADS (default 4) and BUDGET (ms, default 8) set the sim, SECONDS the run (default 30), BLAST_AT and BLAST_FOR the blast (seconds,
## default 12 and 2; BLAST_AT=0: none), BLAST=x,y,z where it goes (in the box, default the pond's middle), BLAST_SIZE its radius (m, default 3),
## CALM=1 frees the spout and the pump, so the pond goes quiet. A force field wakes every block while it is there, so this is the worst case.

const DEMO := "res://addons/water_sim/demo/scenes/game_scale_demo.tscn"

var _steps := 0


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback


func _go() -> void:
	Engine.max_fps = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var demo: Node = (load(DEMO) as PackedScene).instantiate()
	root.add_child(demo)
	var sim: WaterSim = demo.get_node("WaterSim")
	if _env("CALM", "0") == "1":
		sim.get_node("Spout").free()
		sim.get_node("Pump").free()
	var threads := int(_env("THREADS", "4"))
	var budget := float(_env("BUDGET", "8"))
	sim.stepped.connect(func() -> void: _steps += 1)
	await process_frame
	# (After the first frame: the demo's menu loads its saved settings then.)
	sim.threads = threads
	sim.step_budget_ms = budget
	(sim.get_node("Fill") as WaterSimEmitter).fill()
	var blast_at := float(_env("BLAST_AT", "12"))
	var blast_for := float(_env("BLAST_FOR", "2"))
	var place := _env("BLAST", "0,1,0").split(",")
	var blast := WaterSimPush.new()
	blast.speed = 6.0
	blast.strength = 24.0
	blast.position = Vector3(float(place[0]), float(place[1]), float(place[2]))
	blast.radius = float(_env("BLAST_SIZE", "3"))
	var seconds := float(_env("SECONDS", "30"))
	var start := Time.get_ticks_usec()
	var next_line := 0.0
	var blasting := false
	var blasted := false
	# Of the steps taken after the first second (the fill's merging comes before): over the budget, over the tick, and their sums.
	var seen := 0
	var over_budget := 0
	var over_tick := 0
	var threads_sum := 0.0
	var step_sum := 0.0
	var longest := 0.0
	var steps_at_start := 0
	var last_time := -1.0
	while true:
		await process_frame
		var now := (Time.get_ticks_usec() - start) / 1e6
		if now >= seconds:
			break
		if blast_at > 0.0 and not blasted and now >= blast_at:
			blasted = true
			blasting = true
			sim.add_child(blast)
			print("%5.1f s  blast" % now)
		if blasting and now >= blast_at + blast_for:
			blasting = false
			sim.remove_child(blast)
		var stats := sim.get_stats()
		var step := float(stats.get("step_msec", 0.0)) + float(stats.get("buffers_msec", 0.0))
		var used := int(stats.get("threads_used", 1))
		if now >= 1.0:
			if steps_at_start == 0:
				steps_at_start = _steps
			# (A new step's stats: the same time twice is the same step.)
			if step != last_time:
				last_time = step
				seen += 1
				over_budget += 1 if step > budget else 0
				over_tick += 1 if step > sim.fixed_step * 1000.0 else 0
				threads_sum += used
				step_sum += step
				longest = maxf(longest, step)
		if now >= next_line:
			next_line += 0.5
			print("%5.1f s  %d threads  step %5.2f ms  %d particles" % [now, used, step, sim.get_particle_count()])
	print("budget %.1f ms, %d threads at most: %d steps (%.1f a second), mean %.2f threads, mean step %.2f ms, longest %.2f ms; over the budget %d (%.1f%%), over the tick %d" % [
			budget, threads, seen, (_steps - steps_at_start) / (seconds - 1.0), threads_sum / maxi(seen, 1), step_sum / maxi(seen, 1), longest,
			over_budget, 100.0 * over_budget / maxi(seen, 1), over_tick])
	blast.free()
	quit()
