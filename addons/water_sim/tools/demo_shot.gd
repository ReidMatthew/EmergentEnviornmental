extends SceneTree
## A picture of a demo scene after a while (needs a window):
##   DEMO=res://addons/water_sim/demo/scenes/waterfall_demo.tscn SHOT=path.png godot --path . -s res://addons/water_sim/tools/demo_shot.gd
## TOOL=Blast POINT=x,y,z uses a tool of the demo (held for TOOLFRAMES frames, from frame TOOLAT, 20 by default) at a point.
## PUSH=speed makes the Blast stronger. VIEW=x,y,z,distance,yaw,pitch aims the camera, FRAMES how long to wait,
## FLUID=name=value,... sets properties of the fluid view.


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var demo: Node = (load(OS.get_environment("DEMO")) as PackedScene).instantiate()
	# DEMO_SET=lake_size=32,lake_depth=8 sets properties of the demo before it starts.
	if OS.get_environment("DEMO_SET") != "":
		for pair in OS.get_environment("DEMO_SET").split(","):
			demo.set(pair.get_slice("=", 0), float(pair.get_slice("=", 1)))
	root.add_child(demo)
	if OS.get_environment("VIEW") != "":
		var v := OS.get_environment("VIEW").split(",")
		var camera: Camera3D = demo.get_node("Camera")
		camera.target = Vector3(float(v[0]), float(v[1]), float(v[2]))
		camera.distance = float(v[3])
		camera.yaw = float(v[4])
		camera.pitch = float(v[5])
		camera._place()
	if OS.get_environment("PUSH") != "":
		var push = demo.get_node("Tools/Blast/Push")
		push.speed = float(OS.get_environment("PUSH"))
		push.strength = 4.0 * push.speed
	if OS.get_environment("FLUID") != "":
		# FLUID=refraction=0,smoothing=0.3 sets those properties of the fluid view.
		for pair in OS.get_environment("FLUID").split(","):
			var kv := pair.split("=")
			# (Whole numbers as ints: an enum such as style takes nothing else.)
			demo.get_node("WaterSim/Fluid").set(kv[0], int(kv[1]) if kv[1].is_valid_int() else float(kv[1]))
	# FILL=WaterSim/Fill fills that emitter's shape at the start.
	if OS.get_environment("FILL") != "":
		(demo.get_node(OS.get_environment("FILL")) as WaterSimEmitter).fill.call_deferred()
	var tool_name := OS.get_environment("TOOL")
	var tool_node: Node = demo.get_node("Tools/" + tool_name) if tool_name != "" else null
	if tool_node != null:
		demo.get_node("Tools").set_physics_process(false)
	var tool_at := int(OS.get_environment("TOOLAT")) if OS.get_environment("TOOLAT") != "" else 20
	var frames := int(OS.get_environment("FRAMES")) if OS.get_environment("FRAMES") != "" else 150
	for i in frames:
		await process_frame
		if tool_node != null and i == tool_at:
			var q := OS.get_environment("POINT").split(",")
			tool_node.aim(Vector3(float(q[0]), float(q[1]), float(q[2])), null)
			tool_node.press(null)
		if tool_node != null and i == tool_at + int(OS.get_environment("TOOLFRAMES")) and OS.get_environment("TOOLFRAMES") != "":
			tool_node.release()
	var sim: WaterSim = demo.get_node("WaterSim")
	print("%d particles; step %.1f ms; buffers %.1f ms" % [sim.get_particle_count(), sim.get_stats().get("step_msec", 0.0), sim.get_stats().get("buffers_msec", 0.0)])
	root.get_viewport().get_texture().get_image().save_png(OS.get_environment("SHOT"))
	quit()
