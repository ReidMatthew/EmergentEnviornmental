extends SceneTree
## Test runner. From the project folder:
##   godot --headless -s res://addons/adaptive_mesh/tests/run_tests.gd
## runs every group except the opt-in ones. Name groups after [code]--[/code] to run only
## those, or [code]all[/code] for everything:
##   godot -s res://addons/adaptive_mesh/tests/run_tests.gd -- booleans
##
## Groups (tests/<group>.gd): solid, booleans, node, stroke, cleanup, chunks, component, debris, cut, moving, separation, demos. Opt-in: latency (frames
## and worst frame per edit on the terrain, printed), quality (a dig stroke done
## several ways, triangle counts and quality printed), soak (a long random run of digs,
## builds and cuts on static and moving meshes and their parts, checking closedness, volume
## and limits after every step, and that everything frees).
## Runs fine with --headless (the demos' dig check needs a window and is skipped). Exits
## with code 1 if anything fails.

const GROUPS: Array[String] = ["solid", "booleans", "node", "stroke", "cleanup", "chunks", "component", "debris", "cut", "moving", "separation", "demos"]
const OPT_IN: Array[String] = ["quality", "latency", "soak"]


# Counts script errors, so a group that breaks (a parse error, an error part way through a
# test) fails instead of passing on the checks it got to.
class _ScriptErrors extends Logger:
	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SCRIPT:
			count += 1


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
	var failures := 0
	var errors := _ScriptErrors.new()
	OS.add_logger(errors)
	for group in names:
		var errors_before := errors.count
		print("\n== %s" % group)
		var script: GDScript = load(get_script().resource_path.get_base_dir().path_join("%s.gd" % group))
		if script == null or not script.can_instantiate():
			printerr("  FAIL tests/%s.gd does not load" % group)
			failures += 1
			continue
		var suite: RefCounted = script.new()
		suite.tree = self
		await suite.run()
		failures += suite.failures
		if errors.count > errors_before:
			printerr("  FAIL %d script errors in %s" % [errors.count - errors_before, group])
			failures += 1
	OS.remove_logger(errors)
	print("\n%s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)
