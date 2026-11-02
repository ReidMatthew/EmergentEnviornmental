extends SceneTree
## The waves on still water: a pond of SIZE x SIZE m (default 16) at CELL (default 0.25), 1 m deep, a push in the middle, then
## STEPS physics ticks (default 600). Prints the cost of a tick's waves and of drawing the surface, the highest wave as it runs,
## whether the mean level is kept, and when the waves have died out. DRAW=1 times only the surface's drawing (20 times).
##   godot --headless --path . -s res://addons/water_sim/tools/waves_check.gd


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, fallback: float) -> float:
	return float(OS.get_environment(name)) if OS.get_environment(name) != "" else fallback


func _go() -> void:
	var size := _env("SIZE", 16.0)
	var cell := _env("CELL", 0.25)
	var still := WaterSimStillWater.new()
	still.fill_on_start = false
	still.size = Vector2(size, size)
	still.cell_size = cell
	root.add_child(still)
	var n := still.get_grid_size()
	for k in n.y:
		for i in n.x:
			still.set_column(i, k, -1.0, 0.0)
	await process_frame
	var draw_ms := 0.0
	for i in 20:
		var t := Time.get_ticks_usec()
		still._rebuild_view()
		draw_ms += (Time.get_ticks_usec() - t) / 1000.0
	var build_ms := 0.0
	for i in 20:
		var t := Time.get_ticks_usec()
		still._waves.build_surface(Vector3.ZERO)
		build_ms += (Time.get_ticks_usec() - t) / 1000.0
	print("waves: %d x %d columns; drawing the surface %.2f ms (of which the triangles %.2f ms)" % [n.x, n.y, draw_ms / 20.0, build_ms / 20.0])
	if OS.get_environment("DRAW") == "1":
		quit()
		return
	still.disturb(Vector3.ZERO, 1.0, -2.0)
	var steps := int(_env("STEPS", 600.0))
	var tick_ms := 0.0
	var ticks := 0
	var died := -1
	for s in steps:
		var t := Time.get_ticks_usec()
		still._physics_process(1.0 / 60.0)
		if still._redraw:
			still._redraw = false
			still._rebuild_view()
		tick_ms += (Time.get_ticks_usec() - t) / 1000.0
		ticks += 1
		var heights := still._waves.get_heights()
		var most := 0.0
		var mean := 0.0
		for h in heights:
			most = maxf(most, absf(h))
			mean += h
		mean /= heights.size()
		if s % 60 == 0 or (died < 0 and not still._waves.is_active()):
			print("  t=%5.2f s: highest wave %.4f m, mean level %+.3f um, active %s" % [s / 60.0, most, mean * 1e6, still._waves.is_active()])
		if died < 0 and not still._waves.is_active():
			died = s
			break
	print("waves: a tick (waves and drawing) %.3f ms while active; died out after %s" % [tick_ms / maxi(ticks, 1), "%.1f s" % (died / 60.0) if died >= 0 else "more than %d ticks" % steps])
	quit()
