extends SceneTree
## Test runner. From the project folder:
##   godot --headless -s res://addons/meshers/tests/run_tests.gd
## runs every group. Name groups after [code]--[/code] to run only those:
##   godot -s res://addons/meshers/tests/run_tests.gd -- marching_cubes
##
## Groups (tests/<group>.gd): marching_cubes, dual_contouring, bench.
## GPU tests need a RenderingDevice, so they are skipped with --headless; drop the flag (a
## window opens) to run them. Exits with code 1 if anything fails.

const GROUPS: Array[String] = ["marching_cubes", "dual_contouring", "bench"]
const OPT_IN: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var names: Array[String] = []
	for arg in OS.get_cmdline_user_args():
		if arg == "all":
			names.append_array(GROUPS + OPT_IN)
		elif arg in GROUPS or arg in OPT_IN:
			names.append(arg)
		else:
			printerr("unknown test group \"%s\"; groups: %s, opt-in: %s" % [arg, ", ".join(GROUPS), ", ".join(OPT_IN)])
			quit(2)
			return
	if names.is_empty():
		names = GROUPS.duplicate()
	var has_gpu := MarchingCubesGpuMesher.new().is_gpu_available()
	var failures := 0
	for group in names:
		print("\n== %s" % group)
		var script: GDScript = load(get_script().resource_path.get_base_dir().path_join("%s.gd" % group))
		if script == null or not script.can_instantiate():
			printerr("  FAIL tests/%s.gd does not load" % group)
			failures += 1
			continue
		var suite: RefCounted = script.new()
		suite.tree = self
		await suite.run(has_gpu)
		failures += suite.failures
	print("\n%s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)
