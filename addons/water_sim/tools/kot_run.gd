extends SceneTree
## Runs the big-world demo (256 x 256 x 128 cells of 0.25 m, about four million particles) for a while, printing what it costs (needs a window):
##   godot --path . -s res://addons/water_sim/tools/kot_run.gd
## KOT_FRAMES sets how many frames, KOT_SHOTS a folder for pictures, KOT_THREADS the threads (0: all), KOT_DETAIL the detail distance (0: none), KOT_SUBSTEPS the most substeps a frame, KOT_CELL=x (cell size in m), KOT_DROP=0 (no block dropped: a calm lake), KOT_LAKE=m (the lake's side in metres; default 7/8 of the world), KOT_SLEEP=0/1 (sleeping blocks), KOT_SINGLE=0/1 and KOT_CULL=0/1 choose the drawing, KOT_VSYNC=0 (vsync off, to see the real frame time), KOT_FLUID=0 hides the water
## drawing (the simulation alone), KOT_VIEW=x,y,z,distance,yaw,pitch aims the camera.


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var packed := load("res://addons/water_sim/demo/scenes/kot_demo.tscn") as PackedScene
	var demo: Node = packed.instantiate()
	if OS.get_environment("KOT_CELL") != "":
		demo.cell_size = float(OS.get_environment("KOT_CELL"))
	if OS.get_environment("KOT_DETAIL") != "":
		demo.detail_distance = float(OS.get_environment("KOT_DETAIL"))
	if OS.get_environment("KOT_DROP") == "0":
		demo.drop_block = false
	if OS.get_environment("KOT_LAKE") != "":
		demo.lake_size = float(OS.get_environment("KOT_LAKE"))
	if OS.get_environment("KOT_THREADS") != "":
		demo.threads = int(OS.get_environment("KOT_THREADS"))
	root.add_child(demo)
	if OS.get_environment("KOT_ISLANDS") == "0":
		for child in demo.get_children():
			if child.name.begins_with("Island"):
				child.free()
	var sim: WaterSim = demo.get_node("WaterSim")
	if OS.get_environment("KOT_VSYNC") == "0":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	# (Before the first frame is drawn the passes can still be chosen.)
	# KOT_OPAQUE=0 the translucent style; KOT_SMALL=px the opaque style's compute-rasterizer threshold.
	if OS.get_environment("KOT_OPAQUE") != "":
		sim.get_node("Fluid")._effect.opaque = OS.get_environment("KOT_OPAQUE") == "1"
	if OS.get_environment("KOT_SMALL") != "":
		sim.get_node("Fluid").small_pixels = float(OS.get_environment("KOT_SMALL"))
	if OS.get_environment("KOT_SINGLE") != "":
		sim.get_node("Fluid")._effect.single_pass = OS.get_environment("KOT_SINGLE") == "1"
	if OS.get_environment("KOT_SLEEP") != "":
		sim.sleeping_blocks = OS.get_environment("KOT_SLEEP") == "1"
	if OS.get_environment("KOT_CULL") != "":
		sim.get_node("Fluid").cull_to_camera = OS.get_environment("KOT_CULL") == "1"
	if OS.get_environment("KOT_PROFILE") == "1":
		sim.get_node("Fluid")._effect.profile = true
	if OS.get_environment("KOT_RADIUS") != "":
		sim.get_node("Fluid").particle_radius = float(OS.get_environment("KOT_RADIUS"))
	if OS.get_environment("KOT_EQUI") == "1":
		sim.get_node("Fluid")._effect.equilateral = true
	if OS.get_environment("KOT_SHRINK") != "":
		sim.get_node("Fluid")._effect.thickness_shrink = int(OS.get_environment("KOT_SHRINK"))
	if OS.get_environment("KOT_VERTEX_ONLY") == "1":
		sim.get_node("Fluid")._effect.vertex_only = true
	if OS.get_environment("KOT_FLUID") == "0":
		sim.get_node("Fluid").visible = false
	if OS.get_environment("KOT_SUBSTEPS") != "":
		sim.max_substeps = int(OS.get_environment("KOT_SUBSTEPS"))
	if OS.get_environment("KOT_VIEW") != "":
		var v := OS.get_environment("KOT_VIEW").split(",")
		var camera: Camera3D = demo.get_node("Camera")
		camera.target = Vector3(float(v[0]), float(v[1]), float(v[2]))
		camera.distance = float(v[3])
		camera.yaw = float(v[4])
		camera.pitch = float(v[5])
		camera._place()
	var frames := int(OS.get_environment("KOT_FRAMES")) if OS.get_environment("KOT_FRAMES") != "" else 400
	var shots := OS.get_environment("KOT_SHOTS")
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var gpu := 0.0
	var main := 0.0
	var render_cpu := 0.0
	var started := Time.get_ticks_msec()
	var window_start := started
	# KOT_PAUSE_AT=n stops the simulation at frame n: what is left is the frame without it (drawing the last points).
	var pause_at := int(OS.get_environment("KOT_PAUSE_AT")) if OS.get_environment("KOT_PAUSE_AT") != "" else -1
	for i in frames:
		if i == pause_at:
			sim.simulating = false
			print("paused")
		await process_frame
		main += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		if i % 50 == 49:
			var now := Time.get_ticks_msec()
			var st := sim.get_stats()
			print("drawn points: ", sim.get_node("Fluid")._effect._count, " window ", root.get_window().size, " stages ", sim.get_node("Fluid")._effect.timings)
			print("  render CPU %.2f ms" % (render_cpu / 50.0))
			render_cpu = 0.0
			print("frame %d: %d particles (%d fine), step %.1f ms (%d substeps, %d blocks, %d asleep, %d woke), buffers %.1f ms; %.1f fps over the last 50 frames; max speed %.1f, GPU %.1f ms, main thread %.1f ms; transfers %.1f, grid %.1f, bins %.1f, fine %d" % [i + 1, st.particles, sim.get_fine_particle_count(),
					st.step_msec, st.substeps, st.active_blocks, st.sleeping_blocks, st.get("woken_blocks", 0), st.buffers_msec, 50000.0 / (now - window_start), st.max_speed, gpu / 50.0, main / 50.0, st.p2g_msec, st.grid_msec, st.bin_msec, sim.get_fine_particle_count()])
			gpu = 0.0
			main = 0.0
			window_start = now
		if shots != "" and (i == 10 or i == frames / 2 or i == frames - 1):
			root.get_viewport().get_texture().get_image().save_png("%s/kot_%d.png" % [shots, i])
	if OS.get_environment("KOT_STRIP") != "":
		var vv := sim.get_solver().get_velocities()
		var pp := sim.get_solver().get_positions()
		var edges := [0.1, 0.3, 1.0, 3.0]
		var hist := [0, 0, 0, 0, 0]
		var worst := []
		for i in vv.size():
			var l := vv[i].length()
			var k := 0
			while k < 4 and l > edges[k]:
				k += 1
			hist[k] += 1
			if l > 3.0 and worst.size() < 8:
				worst.append("(%.1f %.2f %.1f) %.1f m/s" % [pp[i].x, pp[i].y, pp[i].z, l])
		var cellc := {}
		var cellf := {}
		for i in vv.size():
			var key := Vector2i(int(pp[i].x / 4.0), int(pp[i].z / 4.0))
			cellc[key] = cellc.get(key, 0) + 1
			if vv[i].length() > 0.3:
				cellf[key] = cellf.get(key, 0) + 1
		for zc in range(15, -1, -1):
			var row := ""
			for xc in 16:
				var key := Vector2i(xc, zc)
				var fr: float = 100.0 * cellf.get(key, 0) / maxf(cellc.get(key, 1), 1)
				row += "%3d" % int(fr)
			print("map z%2d:%s" % [zc * 4, row])
		var above := [0, 0, 0, 0, 0, 0]
		for i in pp.size():
			var h := pp[i].y
			above[0 if h < 2.3 else 1 if h < 2.6 else 2 if h < 3.5 else 3 if h < 6.0 else 4 if h < 12.0 else 5] += 1
		print("heights: <2.3 %d, <2.6 %d, <3.5 %d, <6 %d, <12 %d, more %d" % above)
		print("particle speeds: <0.1 %d, <0.3 %d, <1 %d, <3 %d, more %d; fast: %s" % [hist[0], hist[1], hist[2], hist[3], hist[4], str(worst)])
	if OS.get_environment("KOT_STRIP") != "":
		# Surface height and mean speed along x in a strip of z (KOT_STRIP=z0,z1), by 2 m.
		var z := OS.get_environment("KOT_STRIP").split(",")
		var ps := sim.get_solver().get_positions()
		var vs := sim.get_solver().get_velocities()
		var tops := {}
		var spd := {}
		var cnt := {}
		for i in ps.size():
			if ps[i].z < float(z[0]) or ps[i].z > float(z[1]):
				continue
			var b := int(floor((ps[i].x + 32.0) / 2.0))
			tops[b] = maxf(tops.get(b, 0.0), ps[i].y)
			spd[b] = spd.get(b, 0.0) + vs[i].length()
			cnt[b] = cnt.get(b, 0) + 1
		var keys := tops.keys()
		keys.sort()
		for b in keys:
			print("x %3d: top %.3f, mean speed %.3f, %d particles" % [b * 2 - 32, tops[b], spd[b] / cnt[b], cnt[b]])
	var highest := 0.0
	for p in sim.get_solver().get_positions():
		highest = maxf(highest, p.y)
	print("highest particle %.2f m" % highest)
	print("%.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit()
