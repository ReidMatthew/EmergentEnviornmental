extends SceneTree
## Phase 4: what the fluid look costs on the GPU (needs a window). Runs a demo and reports the GPU time of a frame with the fluid
## on, with the plain particle spheres, and with neither.
##   DEMO=res://addons/water_sim/demo/scenes/waterfall_demo.tscn godot --path . -s res://addons/water_sim/tools/fluid_perf.gd
## VIEW=x,y,z,distance,yaw,pitch aims the camera.

var _demo: Node
var _sim: WaterSim


func _initialize() -> void:
	_go.call_deferred()


func _measure(frames: int) -> Vector2:
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var gpu := 0.0
	var cpu := 0.0
	for i in frames:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	return Vector2(gpu / frames, cpu / frames)


func _go() -> void:
	_demo = (load(OS.get_environment("DEMO") if OS.get_environment("DEMO") != "" else "res://addons/water_sim/demo/scenes/waterfall_demo.tscn") as PackedScene).instantiate()
	root.add_child(_demo)
	_sim = _demo.get_node("WaterSim")
	if OS.get_environment("VIEW") != "":
		var v := OS.get_environment("VIEW").split(",")
		var camera: Camera3D = _demo.get_node("Camera")
		camera.target = Vector3(float(v[0]), float(v[1]), float(v[2]))
		camera.distance = float(v[3])
		camera.yaw = float(v[4])
		camera.pitch = float(v[5])
		camera._place()
	var fluid: Node3D = _sim.get_node("Fluid")
	var particles: Node3D = _sim.get_node("Particles")
	for i in 150:
		await process_frame
	print("%d particles, window %s" % [_sim.get_particle_count(), root.size])
	for config in [["fluid", true, false], ["particle spheres", false, true], ["neither", false, false]]:
		fluid.visible = config[1]
		particles.visible = config[2]
		for i in 20:
			await process_frame
		var t := await _measure(60)
		print("  %-18s GPU %.2f ms, render CPU %.2f ms" % [config[0], t.x, t.y])
	quit()
