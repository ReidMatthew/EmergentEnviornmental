extends SceneTree
## Compares two settings of the water drawing in one run (the machine's load drifts, so runs one after another prove nothing):
## the demo runs, and every WINDOW frames a property of the fluid view's effect is switched between two values; the GPU time and the
## frame rate are averaged for each. Needs a window.
##   AB=smooth_fast:true:false godot --path . -s res://addons/water_sim/tools/fluid_ab.gd
## AB=name:a:b (the values: true, false or a number). DETAIL=d, COARSE=1, LAKE=size:depth (m), WINDOW=n (default 60), ROUNDS=n (default 6).

func _initialize() -> void:
	_go.call_deferred()


func _value(text: String) -> Variant:
	if text == "true":
		return true
	if text == "false":
		return false
	return float(text)


func _go() -> void:
	var demo: Node = (load("res://addons/water_sim/demo/scenes/kot_demo.tscn") as PackedScene).instantiate()
	demo.detail_distance = float(OS.get_environment("DETAIL")) if OS.get_environment("DETAIL") != "" else 0.0
	demo.coarse_far = OS.get_environment("COARSE") == "1"
	demo.drop_block = false
	if OS.get_environment("LAKE") != "":
		demo.lake_size = float(OS.get_environment("LAKE").get_slice(":", 0))
		demo.lake_depth = float(OS.get_environment("LAKE").get_slice(":", 1))
	root.add_child(demo)
	var sim: WaterSim = demo.get_node("WaterSim")
	sim.max_substeps = 3
	var fluid: Node = sim.get_node("Fluid")
	var parts := OS.get_environment("AB").split(":")
	var name := parts[0]
	var values := [_value(parts[1]), _value(parts[2])]
	var window := int(OS.get_environment("WINDOW")) if OS.get_environment("WINDOW") != "" else 60
	var rounds := int(OS.get_environment("ROUNDS")) if OS.get_environment("ROUNDS") != "" else 6
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 120:
		await process_frame
	var sums := [0.0, 0.0]
	var times := [0.0, 0.0]
	var counts := [0, 0]
	for r in rounds:
		for which in 2:
			if name in ["smooth_fast", "single_pass", "skip_upload", "skip_smooth", "skip_shade", "skip_copy"]:
				fluid._effect.set(name, values[which])
			else:
				fluid.set(name, values[which])
			for i in 10:
				await process_frame
			var gpu := 0.0
			var started := Time.get_ticks_usec()
			for i in window:
				await process_frame
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			counts[which] = sim.get_solver().get_buffer_point_count(fluid.get_instance_id() & 0x3fffffff)
			sums[which] += gpu / window
			times[which] += float(Time.get_ticks_usec() - started) / window / 1000.0
	for which in 2:
		print("%s = %s: GPU %.2f ms, frame %.1f ms, %d points (mean of %d windows)" % [name, str(values[which]), sums[which] / rounds, times[which] / rounds, counts[which], rounds])
	quit()
