extends SceneTree
## How much the picture changes from one frame to the next (needs a window): the mean and the largest change of the pixels (0-255, on
## a 400 pixel wide copy) between consecutive frames, and how many pixels change by more than 48 in one frame (pops: a particle thinned
## or un-thinned, a hole in the surface). Run it with two builds and compare; the demo's own motion is the same in both.
##   DEMO=res://addons/water_sim/demo/scenes/game_scale_demo.tscn FILL=WaterSim/Fill VIEW=0,1,0,6,0.6,-0.3 godot --path . -s res://addons/water_sim/tools/flicker_check.gd
## WARMUP and FRAMES set the run (default 300 and 200).


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	seed(1)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var demo: Node = (load(OS.get_environment("DEMO")) as PackedScene).instantiate()
	root.add_child(demo)
	if OS.get_environment("FILL") != "":
		(demo.get_node(OS.get_environment("FILL")) as WaterSimEmitter).fill.call_deferred()
	if OS.get_environment("VIEW") != "":
		var v := OS.get_environment("VIEW").split(",")
		var camera: Camera3D = demo.get_node("Camera")
		camera.target = Vector3(float(v[0]), float(v[1]), float(v[2]))
		camera.distance = float(v[3])
		camera.yaw = float(v[4])
		camera.pitch = float(v[5])
		camera._place()
	for i in int(OS.get_environment("WARMUP") if OS.get_environment("WARMUP") != "" else "300"):
		await process_frame
	var frames := int(OS.get_environment("FRAMES") if OS.get_environment("FRAMES") != "" else "200")
	var last: Image
	var means: Array[float] = []
	var pops: Array[float] = []
	var worst := 0.0
	for i in frames:
		await process_frame
		var image := root.get_viewport().get_texture().get_image()
		image.convert(Image.FORMAT_L8)
		image.resize(400, int(400.0 * image.get_height() / image.get_width()), Image.INTERPOLATE_BILINEAR)
		if last != null:
			var a := last.get_data()
			var b := image.get_data()
			var sum := 0
			var big := 0
			var top := 0
			for k in a.size():
				var d := absi(int(a[k]) - int(b[k]))
				sum += d
				big += 1 if d > 48 else 0
				top = maxi(top, d)
			means.append(float(sum) / a.size())
			pops.append(100.0 * big / a.size())
			worst = maxf(worst, top)
		last = image
	var mean := 0.0
	var pop := 0.0
	for m in means:
		mean += m
	for p in pops:
		pop += p
	print("flicker: mean change %.3f, pixels over 48: %.4f%%, largest change %d, over %d frame pairs" % [mean / means.size(), pop / pops.size(), int(worst), means.size()])
	quit()
