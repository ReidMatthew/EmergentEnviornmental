extends SceneTree
## What each style of the fluid view costs on the GPU, one after another in the same run (needs a window): the frame's GPU time
## and the effect's own stages, and a picture of each if SHOT=prefix is given (prefix_opaque.png, ...).
##   DEMO=res://addons/water_sim/demo/scenes/game_scale_demo.tscn godot --path . -s res://addons/water_sim/tools/style_perf.gd
## FLUID=path picks the view (default WaterSim/Fluid), ROUNDS how many times the styles are taken in turn (default 2), PAUSE=1
## stops the sim after the warm-up (the same water for every style).

const NAMES := ["opaque", "translucent", "clear"]


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var demo: Node = (load(OS.get_environment("DEMO")) as PackedScene).instantiate()
	root.add_child(demo)
	var fluid_path := OS.get_environment("FLUID") if OS.get_environment("FLUID") != "" else "WaterSim/Fluid"
	var fluid: WaterSimFluidView = demo.get_node(fluid_path)
	var sim: WaterSim = demo.get_node("WaterSim")
	for i in 150:
		await process_frame
	if OS.get_environment("PAUSE") == "1":
		sim.process_mode = Node.PROCESS_MODE_DISABLED
	fluid._effect.profile = true
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	print("%d particles, %d drawn, window %s" % [sim.get_particle_count(), fluid._effect._count, root.size])
	var rounds := int(OS.get_environment("ROUNDS")) if OS.get_environment("ROUNDS") != "" else 2
	for r in rounds:
		for style in NAMES.size():
			fluid.style = style
			for i in 40:
				await process_frame
			# (Frames still in flight from the last style left their stages in.)
			fluid._effect.timings.clear()
			var gpu := 0.0
			for i in 120:
				await process_frame
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			var stages := ""
			for stage: String in fluid._effect.timings:
				stages += " %s %.2f" % [stage.trim_prefix("ws_"), fluid._effect.timings[stage]]
			var total := 0.0
			for t: float in fluid._effect.timings.values():
				total += t
			print("  %-12s frame GPU %.2f ms, effect %.2f ms:%s" % [NAMES[style], gpu / 120.0, total, stages])
			if r == 0 and OS.get_environment("SHOT") != "":
				root.get_viewport().get_texture().get_image().save_png("%s_%s.png" % [OS.get_environment("SHOT"), NAMES[style]])
	quit()
