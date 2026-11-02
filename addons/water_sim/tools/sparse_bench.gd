extends SceneTree
## Phase 2: a lake in the corner of a big domain. Prints what the domain costs when it is empty, and nanoseconds a particle a
## substep from one thread up, for a lake of LAKE particles (default 1,000,000) in a 512 x 512 x 128 cell domain.
##   LAKE=2000000 godot --headless --path . -s res://addons/water_sim/tools/sparse_bench.gd

const DT := 1.0 / 60.0


func _initialize() -> void:
	_go.call_deferred()


func _lake(solver: WaterSimSolver, particles: int) -> void:
	# A slab 40 m square from the floor up, thick enough for that many particles (512 a cubic metre), moving a little so that
	# it sloshes against the walls.
	var side := 40.0
	var depth := float(particles) / 512.0 / (side * side)
	var transform := Transform3D(Basis(), Vector3(1.0 + side * 0.5, 0.25 + depth * 0.5, 1.0 + side * 0.5))
	solver.fill(0, transform, Vector3(side * 0.5, depth * 0.5, side * 0.5), Vector3(2.0, 0, 1.0), 0)


func _go() -> void:
	var water := (load("res://addons/water_sim/substances/water.tres") as WaterSimSubstance).to_settings()
	var particles := int(OS.get_environment("LAKE")) if OS.get_environment("LAKE") != "" else 1000000
	for dims in [Vector3i(48, 24, 48), Vector3i(512, 512, 128)]:
		var solver := WaterSimSolver.new()
		solver.configure(dims, 0.25)
		solver.set_max_particles(2000000)
		solver.set_substance(0, water)
		solver.fill(0, Transform3D(Basis(), Vector3(3, 0.6, 3)), Vector3(2.5, 0.5, 2.5), Vector3(1, 0, 0), 0)
		var step := 0.0
		var substeps := 0
		for i in 40:
			solver.step(DT)
			step += solver.get_stats().step_msec
			substeps += solver.get_stats().substeps
		print("domain %s, %d particles: %.2f ms a step, %.1f ns a particle-substep" % [dims, solver.get_particle_count(), step / 40.0, step * 1.0e6 / (solver.get_particle_count() * substeps)])
	print("lake of about %d particles in 512 x 512 x 128 cells:" % particles)
	var one_thread := 0.0
	for threads in [1, 2, 4, 8, 16, 0]:
		var solver := WaterSimSolver.new()
		solver.set_threads(threads)
		solver.configure(Vector3i(512, 512, 128), 0.25)
		solver.set_max_particles(particles + 100000)
		solver.set_substance(0, water)
		_lake(solver, particles)
		for i in 5:
			solver.step(DT)
		var step := 0.0
		var substeps := 0
		var kernel := 0.0
		var bins := 0.0
		var grid := 0.0
		var frames := 20
		for i in frames:
			solver.step(DT)
			var s := solver.get_stats()
			step += s.step_msec
			substeps += s.substeps
			kernel += s.p2g_msec
			bins += s.bin_msec
			grid += s.grid_msec
		var ns := step * 1.0e6 / (solver.get_particle_count() * substeps)
		if threads == 1:
			one_thread = ns
		print("  %2s threads: %d particles, %.1f ms a step (%.1f substeps; transfers %.1f, moving particles between blocks %.1f, grid %.1f), %.1f ns a particle-substep, %.1fx one thread" % [
			str(solver.get_threads()), solver.get_particle_count(), step / frames, float(substeps) / frames, kernel / frames, bins / frames, grid / frames, ns, one_thread / ns])
	quit()
