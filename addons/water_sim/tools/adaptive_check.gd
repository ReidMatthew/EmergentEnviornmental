extends SceneTree
## Phase 5: a deep pond with and without adaptive detail: how many particles, how the surface sits, how long a step takes.
##   godot --headless --path . -s res://addons/water_sim/tools/adaptive_check.gd
## SLEEP=0 turns sleeping blocks off. LEVELS=n (default 2), SIZE=cells across (default 48), DEPTH=metres (default 4), THREADS=n,
## CELL=m and SUBS=n (default 1/8 m and 2 substeps).

const WATER := 0


func _initialize() -> void:
	_go.call_deferred()


func _make(adaptive: bool) -> WaterSimSolver:
	var n := int(OS.get_environment("SIZE")) if OS.get_environment("SIZE") != "" else 48
	var s := WaterSimSolver.new()
	var depth := float(OS.get_environment("DEPTH")) if OS.get_environment("DEPTH") != "" else 4.0
	var cell := float(OS.get_environment("CELL")) if OS.get_environment("CELL") != "" else 0.125
	s.set_max_substeps(int(OS.get_environment("SUBS")) if OS.get_environment("SUBS") != "" else 2)
	s.configure(Vector3i(n, int(depth / cell) + 16, n), cell)
	s.set_threads(int(OS.get_environment("THREADS")) if OS.get_environment("THREADS") != "" else 8)
	s.set_max_particles(20000000)
	s.set_substance(WATER, (load("res://addons/water_sim/substances/water.tres") as WaterSimSubstance).to_settings())
	var side := (n - 3) * cell
	s.fill(0, Transform3D(Basis(), Vector3(n * cell * 0.5, cell + depth * 0.5, n * cell * 0.5)), Vector3(side * 0.5, depth * 0.5, side * 0.5), Vector3.ZERO, WATER)
	s.set_sleeping(OS.get_environment("SLEEP") != "0")
	s.set_adaptive(adaptive, int(OS.get_environment("LEVELS")) if OS.get_environment("LEVELS") != "" else 2, 0.0)
	return s


# The height below which 98% of the matter lies (a coarse particle counts as the fine ones it stands for).
func _top(s: WaterSimSolver) -> float:
	var points := s.get_positions()
	var levels := s.get_levels()
	var pairs: Array = []
	var total := 0.0
	for i in points.size():
		var w := float(1 << (3 * levels[i]))
		pairs.append(Vector2(points[i].y, w))
		total += w
	pairs.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var sum := 0.0
	for p in pairs:
		sum += p.y
		if sum >= total * 0.98:
			return p.x
	return 0.0


func _go() -> void:
	for adaptive in [false, true]:
		var s := _make(adaptive)
		var start := s.get_particle_count()
		var t := 0.0
		for i in int(OS.get_environment("STEPS")) if OS.get_environment("STEPS") != "" else 240:
			s.step(1.0 / 60.0)
			if adaptive and i % 30 == 0:
				var q := s.get_stats()
				print("  step %d: %d particles, levels %d/%d/%d" % [i, s.get_particle_count(), q["level_0"], q["level_1"], q["level_2"]])
			if i >= 100:
				t += s.get_stats()["step_msec"]
		var st := s.get_stats()
		var hist := PackedInt32Array()
		hist.resize(16)
		var levels := s.get_levels()
		var points := s.get_positions()
		for i in points.size():
			hist[clampi(int(points[i].y), 0, 15)] += 1 << (3 * levels[i])
		print("  fine-equivalent particles per metre of height: ", hist)
		var highest := 0.0
		for v in s.get_positions():
			highest = maxf(highest, v.y)
		print("  highest particle %.2f m" % highest)
		print("%s: %d -> %d particles, 98th percentile height %.3f, mean speed %.3f, step %.2f ms (adapt %.2f ms), levels %d/%d/%d/%d, %d blocks asleep of %d; substeps %d, transfers %.1f grid %.1f bin %.1f ms" % [
				"adaptive" if adaptive else "uniform ", start, s.get_particle_count(), _top(s), s.mean_speed(1), t / 120.0, st["adapt_msec"], st["level_0"], st["level_1"], st["level_2"], st["level_3"], st["sleeping_blocks"], st["active_blocks"], st["substeps"], st["p2g_msec"], st["grid_msec"], st["bin_msec"]])
	quit()
