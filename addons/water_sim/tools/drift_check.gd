extends SceneTree
## Does a pond with a slope still level, and does a dam break still run, with a given settling and drift? A 12 m long, 3 m wide channel
## with water 2 m deep in the left half, let go: the front's place at 0.5, 1 and 1.5 s, then the height at each end and the step time.
##   godot --headless --path . -s res://addons/water_sim/tools/drift_check.gd
## SWING the drift of a block moving back against the way it set off (default 1; 0 is off), SUBS=n substeps (default 1), DRIFT and SETTLING (the node's defaults), SLEEP_BY_MOTION=1, STEPS (default 480), THREADS (default 4).

const WATER := 0


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, fallback: float) -> float:
	return float(OS.get_environment(name)) if OS.get_environment(name) != "" else fallback


func _go() -> void:
	var cell := 0.125
	var s := WaterSimSolver.new()
	s.set_max_substeps(int(_env("SUBS", 1.0)))
	s.configure(Vector3i(96, 40, 24), cell)
	s.set_threads(int(_env("THREADS", 4.0)))
	s.set_max_particles(2000000)
	s.set_substance(WATER, (load("res://addons/water_sim/substances/water.tres") as WaterSimSubstance).to_settings())
	s.set_bounded_pressure(3.5, _env("SETTLING", 48.0), 0.5, _env("DRIFT", 0.2), _env("SWING", 1.0))
	s.set_sleep_by_motion(OS.get_environment("SLEEP_BY_MOTION") == "1")
	s.fill(0, Transform3D(Basis(), Vector3(3.0, cell + 1.0, 1.5)), Vector3(3.0 - 0.2, 1.0, 1.5 - 0.2), Vector3.ZERO, WATER)
	var steps := int(_env("STEPS", 480.0))
	var total_ms := 0.0
	# The right end's height range over seconds 2-5 and 5-8: how much the water is still ringing.
	var ring := {false: Vector2(1e9, -1e9), true: Vector2(1e9, -1e9)}
	for i in steps:
		s.step(1.0 / 60.0)
		total_ms += float(s.get_stats()["step_msec"])
		if i >= 120 and i % 15 == 0:
			var h := _height(s, 10.0, 11.5)
			var late := i >= 300
			ring[late] = Vector2(minf(ring[late].x, h), maxf(ring[late].y, h))
		if i == 29 or i == 59 or i == 89:
			print("  t=%.1f s: front at %.2f m" % [(i + 1) / 60.0, _front(s)])
	print("  the right end's height ranged %.3f-%.3f m over 2-5 s, %.3f-%.3f m over 5-8 s" % [ring[false].x, ring[false].y, ring[true].x, ring[true].y])
	var left := _height(s, 0.5, 2.0)
	var right := _height(s, 10.0, 11.5)
	var st := s.get_stats()
	print("  after %.0f s: height at the left end %.3f m, at the right end %.3f m (left - right %.3f), mean speed %.3f m/s, %d of %d blocks asleep, step %.2f ms" % [
			steps / 60.0, left, right, left - right, st["mean_speed"], st["sleeping_blocks"], st["active_blocks"], total_ms / steps])
	quit()


# The farthest place along the channel with water low down (the front of the surge, not the spray).
func _front(s: WaterSimSolver) -> float:
	var front := 0.0
	for p in s.get_positions():
		if p.y < 0.5:
			front = maxf(front, p.x)
	return front


# The depth of the water over a stretch of the channel: its matter over the stretch's area.
func _height(s: WaterSimSolver, x0: float, x1: float) -> float:
	var points := s.get_positions()
	var levels := s.get_levels()
	var matter := 0.0
	for i in points.size():
		if points[i].x >= x0 and points[i].x < x1:
			matter += float(1 << (3 * levels[i]))
	return matter * pow(0.125 * 0.5, 3.0) / ((x1 - x0) * 3.0)
