extends SceneTree
## Levels of detail by distance and depth (LOD 1 to 4): a big, deep pond with the focus at one corner of its surface, so every
## band of the detail distance is in it. Prints, as it settles, how many particles each level has, how still the water is and
## how long a step takes, and at the end the water's height in each band (from the matter in it, a coarse particle counting as
## the fine ones it stands for), which should be the same in every band.
##   godot --headless --path . -s res://addons/water_sim/tools/lod_check.gd
## LEVELS=n levels past the finest (default 3: LOD 1-4; 1 is LOD 1-2, 0 all fine), DETAIL=m the band width (default 12),
## SIZE=metres across (default 24), DEPTH=metres (default 12), STEPS (default 600), THREADS (default all), CELL=m (default 1/8),
## SUBS=n substeps (default 2), WAVE=1 drops a block of water by the focus at the start, DRIFT and SETTLING set the bounded pressure's, SLEEP_BY_MOTION=1 sets sleep_by_motion, BUDGET=n the particle budget (default none), APPROACH=1 jumps the focus to the middle of the pond half way and counts the spray.

const WATER := 0


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, fallback: float) -> float:
	return float(OS.get_environment(name)) if OS.get_environment(name) != "" else fallback


func _go() -> void:
	var cell := _env("CELL", 0.125)
	var substeps := int(_env("SUBS", 2.0))
	var size := _env("SIZE", 24.0)
	var depth := _env("DEPTH", 12.0)
	var detail := _env("DETAIL", 12.0)
	var levels := int(_env("LEVELS", 3.0))
	var n := int(size / cell)
	var s := WaterSimSolver.new()
	s.set_max_substeps(substeps)
	s.configure(Vector3i(n, int((depth + 10.0) / cell), n), cell)
	# (0: every core, as the node does.)
	s.set_threads(int(_env("THREADS", 0.0)))
	s.set_max_particles(40000000)
	s.set_substance(WATER, (load("res://addons/water_sim/substances/water.tres") as WaterSimSubstance).to_settings())
	var side := (n - 4) * cell
	var middle := n * cell * 0.5
	s.fill(0, Transform3D(Basis(), Vector3(middle, cell + depth * 0.5, middle)), Vector3(side * 0.5, depth * 0.5, side * 0.5), Vector3.ZERO, WATER)
	var focus := Vector3(middle - side * 0.5 + 6.0, cell + depth, middle - side * 0.5 + 6.0)
	if OS.get_environment("WAVE") == "1":
		s.fill(0, Transform3D(Basis(), focus + Vector3(4.0, 5.0, 4.0)), Vector3(3.0, 2.0, 3.0), Vector3.ZERO, WATER)
	var start := s.get_particle_count()
	if OS.get_environment("DRIFT") != "" or OS.get_environment("SETTLING") != "" or OS.get_environment("SWING") != "":
		s.set_bounded_pressure(3.5, _env("SETTLING", 48.0), 0.5, _env("DRIFT", 0.2), _env("SWING", 1.0))
	s.set_sleep_by_motion(OS.get_environment("SLEEP_BY_MOTION") == "1")
	s.set_adaptive(levels > 0, levels, detail, int(_env("BUDGET", 0.0)))
	s.set_focus(PackedVector3Array([focus]))
	print("LOD 1-%d, bands of %.1f m, %.0f m across, %.1f m deep, cells %.3f m: %d fine particles" % [levels + 1, detail, size, depth, cell, start])
	var steps := int(_env("STEPS", 600.0))
	var total_ms := 0.0
	var timed := 0
	var worst := 0.0
	var worst_rows := 0.0
	var worst_adapt := 0.0
	var worst_parts := ""
	# Over the second half: the mean of each part of the step.
	const PARTS := ["step_msec", "bin_msec", "p2g_msec", "grid_msec", "restrict_msec", "update_msec", "prolong_msec", "sleep_msec", "adapt_msec", "hier_msec"]
	var part_sums := {}
	for i in steps:
		s.step(1.0 / 60.0)
		var st := s.get_stats()
		if st["step_msec"] > worst:
			worst_parts = "bin %.1f p2g %.1f grid %.1f g2p %.1f adapt %.1f hier %.1f buffers %.1f" % [st["bin_msec"], st["p2g_msec"], st["grid_msec"], st["g2p_msec"], st["adapt_msec"], st["hier_msec"], st["buffers_msec"]]
		worst = maxf(worst, st["step_msec"])
		worst_rows = maxf(worst_rows, st["hier_msec"])
		worst_adapt = maxf(worst_adapt, st["adapt_msec"])
		if OS.get_environment("APPROACH") == "1":
			# The camera jumps to the middle of the pond half way: spray over the open surface is what comes of the water turning fine.
			if i == steps / 2:
				s.set_focus(PackedVector3Array([Vector3(middle, cell + depth, middle)]))
			if i >= steps / 2 and i % 20 == 0:
				var pos := s.get_positions()
				var vel := s.get_velocities()
				var rising := 0
				for k in pos.size():
					if vel[k].y > 2.0 and pos[k].y > cell + depth + 0.1:
						rising += 1
				print("  step %d after the focus jump: %d particles rising over 2 m/s above the surface, %d particles" % [i, rising, pos.size()])
		if i >= steps / 2:
			total_ms += st["step_msec"]
			timed += 1
			for key in PARTS:
				part_sums[key] = part_sums.get(key, 0.0) + float(st.get(key, 0.0))
		if i % 60 == 59:
			print("         slowest step this second %.1f ms (rows at most %.1f, adapt at most %.1f) [%s]" % [worst, worst_rows, worst_adapt, worst_parts])
			worst = 0.0
			worst_rows = 0.0
			worst_adapt = 0.0
			print("  t=%4.1f s: %8d particles (LOD %d / %d / %d / %d), mean speed %.3f, fastest %.2f m/s, %d substeps, step %.1f ms (adapt %.1f, rows %.1f, transfers %.1f, grid %.1f), %d of %d blocks asleep, budget bias %d" % [
					(i + 1) / 60.0, s.get_particle_count(), st["level_0"], st["level_1"], st["level_2"], st["level_3"], st["mean_speed"], st["max_speed"],
					st["substeps"], st["step_msec"], st["adapt_msec"], st["hier_msec"], st["p2g_msec"], st["grid_msec"], st["sleeping_blocks"], st["active_blocks"], st["budget_bias"]])
	# The height of the water by band: the matter in each 2 m column over the column's area, columns grouped by band.
	var points := s.get_positions()
	var lv := s.get_levels()
	var column := 2.0
	var cols := int(ceil(n * cell / column))
	var matter := PackedFloat64Array()
	matter.resize(cols * cols)
	var fine := 0
	for i in points.size():
		var w := 1 << (3 * lv[i])
		fine += w
		var cx := clampi(int(points[i].x / column), 0, cols - 1)
		var cz := clampi(int(points[i].z / column), 0, cols - 1)
		matter[cz * cols + cx] += w
	var particle_volume := pow(cell * 0.5, 3.0)
	var bands := {}
	for cz in cols:
		for cx in cols:
			var c := Vector3((cx + 0.5) * column, 0.0, (cz + 0.5) * column)
			# (Columns over the whole pond only, 4 m in from its sides.)
			if absf(c.x - middle) > side * 0.5 - 4.0 or absf(c.z - middle) > side * 0.5 - 4.0:
				continue
			var band := int(Vector2(c.x - focus.x, c.z - focus.z).length() / detail) if detail > 0.0 else 0
			if not bands.has(band):
				bands[band] = []
			bands[band].append(matter[cz * cols + cx] * particle_volume / (column * column))
	var line := "  water height by band (mean, lowest-highest column):"
	var keys := bands.keys()
	keys.sort()
	for band in keys:
		var list: Array = bands[band]
		var lo := 1e9
		var hi := -1e9
		var sum := 0.0
		for h in list:
			lo = minf(lo, h)
			hi = maxf(hi, h)
			sum += h
		line += "  %d: %.3f (%.2f-%.2f)" % [band, sum / list.size(), lo, hi]
	print(line)
	# Where the particles are: within 1 m of a side wall, of the floor, of the top (the rest of them is the inside), by level.
	var top := cell + depth
	var lo_wall := middle - side * 0.5
	var where := {"side wall": [0, 0, 0, 0], "floor": [0, 0, 0, 0], "top": [0, 0, 0, 0], "inside": [0, 0, 0, 0]}
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		var key := "side wall" if d_side < 1.0 else ("floor" if p.y < 1.0 else ("top" if top - p.y < 1.0 else "inside"))
		where[key][lv[i]] += 1
	# The inside's level 0 particles by distance to the focus (bands) and to the nearest side wall (metres).
	var by_band := {}
	var by_wall := {}
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		if lv[i] != 0 or d_side < 1.0 or p.y < 1.0 or top - p.y < 1.0:
			continue
		var band := int(Vector3(p.x - focus.x, 0.0, p.z - focus.z).length() / detail) if detail > 0.0 else 0
		by_band[band] = by_band.get(band, 0) + 1
		var wall_bin := int(minf(d_side, 5.9))
		by_wall[wall_bin] = by_wall.get(wall_bin, 0) + 1
	# Level 0 left in blocks that are mostly level 1: how many a block, and how far into the block they sit (cells from its nearest face).
	var block := cell * 4.0
	var per_block := {}
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		if d_side < 2.0 or p.y < 2.0 or top - p.y < 2.0:
			continue
		var key := Vector3i(int(p.x / block), int(p.y / block), int(p.z / block))
		if not per_block.has(key):
			per_block[key] = [0, 0]
		per_block[key][0 if lv[i] == 0 else 1] += 1
	var hist := {}
	var depth_hist := {}
	for key in per_block:
		var c: Array = per_block[key]
		if c[1] < 20:
			continue
		hist[mini(c[0] / 8 * 8, 64)] = hist.get(mini(c[0] / 8 * 8, 64), 0) + 1
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		if lv[i] != 0 or d_side < 2.0 or p.y < 2.0 or top - p.y < 2.0:
			continue
		var key := Vector3i(int(p.x / block), int(p.y / block), int(p.z / block))
		if per_block[key][1] < 20:
			continue
		var f := Vector3(p.x / block - floorf(p.x / block), p.y / block - floorf(p.y / block), p.z / block - floorf(p.z / block))
		var face := minf(minf(minf(f.x, 1.0 - f.x), minf(f.y, 1.0 - f.y)), minf(f.z, 1.0 - f.z)) * 4.0
		var bin := int(face * 2.0)
		depth_hist[bin] = depth_hist.get(bin, 0) + 1
	print("  level 0 a block in mostly-level-1 blocks (blocks by count, 8 wide): ", hist)
	print("  those level 0 by half-cells from the block's nearest face: ", depth_hist)
	var by_depth := {}
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		if d_side < 1.0 or p.y < 1.0 or top - p.y < 1.0:
			continue
		var key := "%d m under the top" % int(top - p.y)
		if not by_depth.has(key):
			by_depth[key] = [0, 0, 0]
		by_depth[key][mini(lv[i], 2)] += 1
	print("  inside particles by depth, [L0, L1, L2]: ", by_depth)
	var levels_by_band := {}
	var levels_by_depth := {}
	for i in points.size():
		var p := points[i]
		var d_side := minf(minf(p.x - lo_wall, lo_wall + side - p.x), minf(p.z - lo_wall, lo_wall + side - p.z))
		if d_side < 1.5 or p.y < 1.5 or top - p.y < 1.5:
			continue
		var band := int(Vector3(p.x - focus.x, 0.0, p.z - focus.z).length() / detail) if detail > 0.0 else 0
		if not levels_by_band.has(band):
			levels_by_band[band] = [0, 0, 0, 0]
		levels_by_band[band][lv[i]] += 1
		var dkey := "band %d, %d m down" % [band, int(top - p.y)]
		if not levels_by_depth.has(dkey):
			levels_by_depth[dkey] = [0, 0, 0, 0]
		levels_by_depth[dkey][lv[i]] += 1
	var dkeys := levels_by_depth.keys()
	dkeys.sort()
	for k in dkeys:
		print("    %s: %s" % [k, levels_by_depth[k]])
	print("  deep inside (1.5 m from every face) by band of the focus, [L0, L1, L2, L3]: ", levels_by_band)
	print("  inside level 0 by band of the focus: ", by_band, "  by metres from the side wall: ", by_wall)
	for key in where:
		var row: Array = where[key]
		print("  %-9s %9d particles (LOD %d / %d / %d / %d) = %d fine" % [key, row[0] + row[1] + row[2] + row[3], row[0], row[1], row[2], row[3], row[0] + 8 * row[1] + 64 * row[2] + 512 * row[3]])
	var st := s.get_stats()
	print("  awake particles by level: %d / %d / %d / %d of %d / %d / %d / %d;  blocks with matter by grid level (awake of all): %d of %d / %d of %d / %d of %d / %d of %d" % [
			st["awake_level_0"], st["awake_level_1"], st["awake_level_2"], st["awake_level_3"], st["level_0"], st["level_1"], st["level_2"], st["level_3"],
			st["awake_leaf_blocks_0"], st["leaf_blocks_0"], st["awake_leaf_blocks_1"], st["leaf_blocks_1"], st["awake_leaf_blocks_2"], st["leaf_blocks_2"], st["awake_leaf_blocks_3"], st["leaf_blocks_3"]])
	print("  matter kept: %d fine particles of %d; mean step over the second half %.1f ms" % [fine, start, total_ms / maxf(timed, 1.0)])
	var parts_line := "  second half means (ms):"
	for key in PARTS:
		parts_line += " %s %.3f" % [key.trim_suffix("_msec"), part_sums.get(key, 0.0) / maxf(timed, 1.0)]
	print(parts_line)
	quit()
