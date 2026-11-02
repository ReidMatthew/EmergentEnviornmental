extends SceneTree
## Does the game scale pond still behave? Fills the demo's pond (the spout and pump freed, so the water is a closed amount), runs
## it a fixed number of steps and checks: nothing is NaN or outside the box, the particle count holds, the surface does not sink
## or climb, the water stays in the pool, goes to sleep and stops moving, and a body put into the sleeping pond wakes it and pushes
## the water aside. One line a check; exit code 1 if any failed.
## Run it before and after each solver change.
##   godot --headless --fixed-fps 60 --path . -s res://addons/water_sim/tools/regression_check.gd
## --fixed-fps 60 makes every frame one step, so the run does not depend on the machine's speed.
## By default the limits are the baseline below (what the code did on 2026-10-28) with room for thread timing, so it fails when
## the pond gets worse. STRICT=1 uses the limits of a pond that is right (it fails today, see BASELINE), TRACE=1 prints each
## second, FRAMES (default 900), THREADS, SUBSTEPS and CELL override the node's, DROWSY=0 or 1 and DROWSY_SPEED the drowsy blocks.

const DEMO := "res://addons/water_sim/demo/scenes/game_scale_demo.tscn"
const SETTLE_FRAME := 240  ## The pond has spread by here: the reference for what must then hold.
## The pool's inside in the solver's space (the 16 m box, banks 2 m thick), and how far into a wall a particle may be and still count as inside.
const POOL_MIN := 2.0
const POOL_MAX := 14.0
const WALL_SLACK := 0.2

## Limits for a pond that is right.
## (Rest is judged by the particles: the grid's mean speed stat has each substep's gravity in it, so it never reads as rest.)
const STRICT := {"count_drift": 0.03, "surface_drift": 0.05, "in_walls": 0.001, "asleep": 0.8, "speed": 0.05, "max_speed": 2.0, "displaced": 0.05}
## Limits that hold the code of 2026-10-28 after the wall fixes and 1d (1 substep, 4 threads: 141k particles, 0.2% of the water
## inside the walls, the particles' mean speed and the share asleep as printed by the check, 2% of the particles faster than 0.5 m/s)
## with room for a change that is meant to alter the water a little. Tighten them as the pond improves, until they are STRICT.
const BASELINE := {"count_drift": 0.05, "surface_drift": 0.03, "in_walls": 0.01, "asleep": 0.4, "speed": 0.15, "max_speed": 8.0, "displaced": 0.15}

var _failed := 0


func _initialize() -> void:
	_go.call_deferred()


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _apply_overrides(sim: WaterSim) -> void:
	if OS.get_environment("THREADS") != "":
		sim.threads = int(OS.get_environment("THREADS"))
	if OS.get_environment("SUBSTEPS") != "":
		sim.max_substeps = int(OS.get_environment("SUBSTEPS"))
	if OS.get_environment("DROWSY") != "":
		sim.drowsy_blocks = OS.get_environment("DROWSY") == "1"
	if OS.get_environment("DROWSY_SPEED") != "":
		sim.drowsy_speed = float(OS.get_environment("DROWSY_SPEED"))


func _go() -> void:
	seed(1)
	var limits: Dictionary = STRICT if _env("STRICT", "0") == "1" else BASELINE
	var demo: Node = (load(DEMO) as PackedScene).instantiate()
	root.add_child(demo)
	var sim: WaterSim = demo.get_node("WaterSim")
	sim.get_node("Spout").free()
	sim.get_node("Pump").free()
	# (Every frame one step, as the checks count them: the frame waits for a slow step rather than skipping it.)
	sim.wait_for_step = true
	if OS.get_environment("CELL") != "":
		sim.cell_size = float(OS.get_environment("CELL"))
	_apply_overrides(sim)
	# The colliders are handed to the solver in the first steps; fill after that.
	for i in 10:
		await process_frame
	# (Again: the demo's menu loads its saved settings in the first frame.)
	_apply_overrides(sim)
	(sim.get_node("Fill") as WaterSimEmitter).fill()
	var frames := int(_env("FRAMES", "900"))
	var trace := OS.get_environment("TRACE") == "1"
	var start_count := 0
	var settled_count := 0
	var settled_surface := 0.0
	var step_ms := 0.0
	var steps := 0
	for i in frames:
		await process_frame
		if i == 5:
			start_count = sim.get_particle_count()
		if i == SETTLE_FRAME:
			settled_count = sim.get_particle_count()
			settled_surface = _surface(sim)
		if trace and i % 60 == 0:
			var s := sim.get_stats()
			print("  t=%2d s: %d particles, %.1f%% in the walls, surface %.3f m, %d of %d blocks asleep, mean speed %.4f max %.3f m/s" % [
					i / 60, sim.get_particle_count(), _in_walls(sim) * 100.0, _surface(sim), s["sleeping_blocks"], s["active_blocks"],
					s["mean_speed"], s["max_speed"]])
		if i % 10 == 0:
			step_ms += float(sim.get_stats().get("step_msec", 0.0))
			steps += 1
	var stats := sim.get_stats()
	var count := sim.get_particle_count()
	var surface := _surface(sim)
	var walls := _in_walls(sim)
	var asleep := _asleep_share(sim)
	var speed := _mean_particle_speed(sim)
	print("regression: %d particles (%d at the start, %d settled), %.1f%% in the walls, surface %.3f m (%.3f settled), %.0f%% of the particles asleep (%d of %d blocks), mean speed %.4f m/s (grid %.3f), max %.3f m/s, step %.2f ms" % [
			count, start_count, settled_count, walls * 100.0, surface, settled_surface, asleep * 100.0, stats["sleeping_blocks"], stats["active_blocks"],
			speed, stats["mean_speed"], stats["max_speed"], step_ms / maxi(steps, 1)])
	var max_speed := float(stats["max_speed"])
	# A body walked into the sleeping pond: the water in its way must be pushed out, so the blocks round it have to wake.
	var body := demo.get_node("ChoralInTheWater") as Node3D
	body.global_position = Vector3(2.0, 0.05, -1.0)
	var in_the_way := _inside_capsule(sim, body)
	for i in 120:
		await process_frame
	var left := _inside_capsule(sim, body)
	var asleep_after := _asleep_share(sim)
	_check(start_count > 0, "the fill made particles (%d)" % start_count)
	_check(_finite_and_inside(sim), "every particle is finite and inside the box")
	_check(absf(count - settled_count) <= limits.count_drift * settled_count, "the particle count holds after settling (%d to %d, within %.0f%%)" % [settled_count, count, limits.count_drift * 100.0])
	_check(absf(surface - settled_surface) <= limits.surface_drift, "the surface stays put (%.3f to %.3f m, within %.2f m)" % [settled_surface, surface, limits.surface_drift])
	_check(walls <= limits.in_walls, "the water stays in the pool (%.1f%% inside the walls, at most %.1f%%)" % [walls * 100.0, limits.in_walls * 100.0])
	_check(asleep >= limits.asleep, "the pond sleeps (%.0f%% of the particles, at least %.0f%%)" % [asleep * 100.0, limits.asleep * 100.0])
	_check(speed <= limits.speed, "the water settles (mean particle speed %.4f m/s, at most %.2f)" % [speed, limits.speed])
	_check(max_speed <= limits.max_speed, "nothing is flung about (max %.3f m/s, at most %.1f)" % [max_speed, limits.max_speed])
	_check(in_the_way > 50, "there was water where the body was put (%d particles)" % in_the_way)
	_check(left <= limits.displaced * in_the_way, "the body pushes the water out of its way (%d of %d particles still inside it after 2 s; %.0f%% asleep before, %.0f%% after)" % [left, in_the_way, asleep * 100.0, asleep_after * 100.0])
	print("regression: %s (%s limits)" % ["all passed" if _failed == 0 else "%d FAILED" % _failed, "strict" if limits == STRICT else "baseline"])
	quit(1 if _failed > 0 else 0)


## The 95th percentile height of the particles: the water's surface, without the odd spray drop.
func _surface(sim: WaterSim) -> float:
	var ys := PackedFloat32Array()
	for p in sim.get_solver().get_positions():
		ys.append(p.y)
	if ys.is_empty():
		return 0.0
	ys.sort()
	return ys[int(ys.size() * 0.95)]


## The share of the particles inside the banks, the cliff or the glass: past the pool's inside on x or z.
func _in_walls(sim: WaterSim) -> float:
	var points := sim.get_solver().get_positions()
	var inside := 0
	for p in points:
		if p.x < POOL_MIN - WALL_SLACK or p.x > POOL_MAX + WALL_SLACK or p.z < POOL_MIN - WALL_SLACK or p.z > POOL_MAX + WALL_SLACK:
			inside += 1
	return float(inside) / maxf(float(points.size()), 1.0)


## The share of the particles in sleeping blocks.
func _asleep_share(sim: WaterSim) -> float:
	return float(sim.get_solver().get_asleep_levels().size()) / maxf(float(sim.get_particle_count()), 1.0)


func _mean_particle_speed(sim: WaterSim) -> float:
	var velocities := sim.get_solver().get_velocities()
	var sum := 0.0
	for v in velocities:
		sum += v.length()
	return sum / maxf(float(velocities.size()), 1.0)


## How many particles are inside the body's capsule (the demo's: radius 0.25, 1.6 m tall, standing on its origin).
func _inside_capsule(sim: WaterSim, body: Node3D) -> int:
	var to_world := sim.get_solver_transform()
	var bottom := body.global_position + Vector3(0.0, 0.25, 0.0)
	var top := body.global_position + Vector3(0.0, 1.35, 0.0)
	var inside := 0
	for p in sim.get_solver().get_positions():
		var w := to_world * p
		var on_axis := Vector3(bottom.x, clampf(w.y, bottom.y, top.y), bottom.z)
		if w.distance_to(on_axis) < 0.23:
			inside += 1
	return inside


func _finite_and_inside(sim: WaterSim) -> bool:
	var size := Vector3(sim.get_dims()) * sim.cell_size
	var slack := Vector3.ONE * sim.cell_size
	for p in sim.get_solver().get_positions():
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return false
		if p.x < -slack.x or p.y < -slack.y or p.z < -slack.z or p.x > size.x + slack.x or p.y > size.y + slack.y or p.z > size.z + slack.z:
			return false
	return true
