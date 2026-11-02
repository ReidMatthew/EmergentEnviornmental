class_name AdaptiveMeshMenu
extends Node
## The settings of the scene's [AdaptiveMesh] nodes in the menus add-on: one panel, Mesh, with a tab for the frame budget and the
## numbers (Mesh), and one each for the cleanup, separation and debris settings a mesh has (Cleanup, Separation, Debris; a tab shows
## only when some mesh has that resource). A setting goes to every mesh in the scene (resources they share are set once). Put it in a
## scene with a [MenuHost] ([code]menus.tscn[/code]), after the meshes; it does nothing without a host or a mesh.
##
## The host's Save button writes the tab showing to its config file, and the next start loads it. Only what a mesh reads when it
## edits is here: how a mesh is drawn or collided is baked into its pieces, so it is not.

var _meshes: Array[AdaptiveMesh] = []
var _panel: MenuPanel
var _host: MenuHost
var _stats: Label
var _shown := 0.0


func _ready() -> void:
	_host = MenuHost.find(get_tree())
	_meshes = AdaptiveMesh.get_all(get_tree())
	if _host == null or _meshes.is_empty():
		return
	_panel = MenuPanel.new()
	_panel.title = "Mesh"
	_panel.order = 3
	_host.add_panel(_panel)
	_build_mesh()
	_build_cleanup()
	_build_separation()
	_build_debris()


func _process(delta: float) -> void:
	_shown -= delta
	if _shown > 0.0 or _stats == null or not _host.is_open():
		return
	_shown = 0.5
	_stats.text = _stats_text()


func _build_mesh() -> void:
	var p := _panel
	p.tab("Mesh")
	p.section("Edits")
	p.slider("Main thread budget", 0.0, 33.0, 0.1, _meshes[0].main_thread_budget_ms, func(v: float) -> void:
			for mesh in _meshes:
				if is_instance_valid(mesh):
					mesh.main_thread_budget_ms = v,
			func(v: float) -> String: return "no limit" if v <= 0.0 else "%.1f ms" % v)
	p.section("Meshes")
	_stats = p.label(_stats_text())


func _build_cleanup() -> void:
	var targets := _resources(&"cleanup")
	if targets.is_empty():
		return
	_panel.tab("Cleanup")
	_panel.section("Triangles an edit made")
	_slider(targets, "Min edge length", &"min_edge_length", 0.0, 2.0, 0.001)
	_slider(targets, "Sliver angle", &"sliver_angle", 0.0, 60.0, 0.1)
	_slider(targets, "Max error", &"max_error", 0.0, 0.5, 0.0001)
	_slider(targets, "Feature angle", &"feature_angle", 0.0, 180.0, 0.1)
	_slider(targets, "Max normal change", &"max_normal_change", 0.0, 90.0, 0.1)
	_slider(targets, "Unlock rings", &"unlock_rings", 0, 4, 1)
	_slider(targets, "Passes", &"passes", 1, 10, 1)


func _build_separation() -> void:
	var targets := _resources(&"separation")
	if targets.is_empty():
		return
	_panel.tab("Separation")
	_panel.section("Parts that come away")
	_check(targets, "Separate", &"enabled")
	_slider(targets, "Part min size", &"min_size", 0.0, 2.0, 0.001)
	_slider(targets, "Anchor margin", &"anchor_margin", 0.0, 2.0, 0.001)
	_slider(targets, "Part density", &"density", 0.001, 20.0, 0.001)
	_slider(targets, "Part friction", &"friction", 0.0, 1.0, 0.01)
	_panel.section("Limits")
	_slider(targets, "Min adaptive size", &"min_adaptive_size", 0.0, 5.0, 0.001)
	_slider(targets, "Max parts", &"max_parts", 0, 200, 1)
	_slider(targets, "Plain lifetime", &"plain_lifetime", 0.0, 60.0, 0.1)


func _build_debris() -> void:
	var targets := _resources(&"debris")
	if targets.is_empty():
		return
	_panel.tab("Debris")
	_panel.section("Dig fragments")
	_check(targets, "Debris", &"enabled")
	_check(targets, "Fragments", &"fragments")
	_slider(targets, "Fragment size", &"fragment_size", 0.01, 5.0, 0.01)
	_slider(targets, "Max fragments", &"max_fragments", 1, 64, 1)
	_slider(targets, "Scatter speed", &"scatter_speed", 0.0, 20.0, 0.1)
	_slider(targets, "Fragment lifetime", &"lifetime", 0.0, 60.0, 0.1)
	_panel.section("Bodies")
	_slider(targets, "Fragment min size", &"min_size", 0.0, 2.0, 0.001)
	_slider(targets, "Fragment density", &"density", 0.001, 20.0, 0.001)
	_slider(targets, "Fragment friction", &"friction", 0.0, 1.0, 0.01)
	_slider(targets, "Max bodies", &"max_bodies", 1, 300, 1)


# The distinct resources the meshes have in a slot (meshes may share one).
func _resources(slot: StringName) -> Array:
	var found: Array = []
	for mesh in _meshes:
		var resource: Object = mesh.get(slot)
		if resource != null and not found.has(resource):
			found.append(resource)
	return found


func _slider(targets: Array, text: String, property: StringName, low: float, high: float, step: float) -> void:
	_panel.slider(text, low, high, step, targets[0].get(property), func(v: float) -> void:
			for target in targets:
				target.set(property, int(v) if targets[0].get(property) is int else v))


func _check(targets: Array, text: String, property: StringName) -> void:
	_panel.check(text, targets[0].get(property), func(on: bool) -> void:
			for target in targets:
				target.set(property, on))


func _stats_text() -> String:
	var triangles := 0
	var busy := 0
	var count := 0
	for mesh in _meshes:
		if not is_instance_valid(mesh):
			continue
		count += 1
		triangles += mesh.get_triangle_count()
		if not mesh.is_idle():
			busy += 1
	return "%d meshes, %d triangles%s" % [count, triangles, ", %d working" % busy if busy > 0 else ""]
