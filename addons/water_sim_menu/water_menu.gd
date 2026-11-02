class_name WaterSimMenu
extends Node
## The settings of a [WaterSim] in the menus add-on: one panel, Water, with a tab each for the simulation (Sim), the substances and
## colliders (Liquid), how the water is drawn (View), its spray (Spray), the pull tool (Tools) and settings still being tried
## (EXPERIMENTAL). Put it in a scene with a [MenuHost]
## ([code]menus.tscn[/code]) and say which sim it is for; it finds the box's fluid, spray and particle views, its substances and its
## colliders itself. Does nothing in a scene without a host.
##
## The keys of the old demo panel answer here too: Esc pauses, R resets, F, P, M and B change the views, S turns the spray on and
## off. The host's Save button
## writes the tab showing to its config file; the next start loads it.

## The simulation to control.
@export var sim: WaterSim
## A pull tool ([code]water_sim/demo/components/pull_tool.gd[/code]): the Tools tab sets its strength and range; none: no tab.
@export var pull: Node
## A tool belt ([code]WaterSimToolBelt[/code]): the Tools tab picks its tool and shows the selected tool's settings (what its
## [code]get_settings()[/code] lists); none: only the pull tool's, if any.
@export var tools: Node
## Takes the water back from the start when the cell size changes (the simulation is cleared when it does): fills again whatever
## fills on start. Off for a scene that fills the water itself (connect [signal cell_size_changed] to do it).
@export var refill_emitters := true
## Clears every particle and fills again whatever fills on start (a button too; 0: neither).
@export var reset_key := KEY_R

## The cell size was changed (the water has been cleared).
signal cell_size_changed(cell_size: float)

var _panel: MenuPanel
var _fluids: Array[Node] = []
var _particles: Array[Node] = []
var _sprays: Array[Node] = []
var _substances: Array[WaterSimSubstance] = []
var _substance: WaterSimSubstance
var _host: MenuHost


func _ready() -> void:
	_host = MenuHost.find(get_tree())
	if _host == null or sim == null:
		return
	_fluids = _views(&"WaterSimFluidView")
	_particles = _views(&"WaterSimParticleView")
	_sprays = _views(&"WaterSimSprayView")
	_panel = MenuPanel.new()
	_panel.title = "Water"
	_host.add_panel(_panel)
	_build_sim()
	_build_liquid()
	_build_view()
	_build_spray()
	_build_tools()
	_build_experimental()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if _panel == null or key == null or not key.pressed or key.echo:
		return
	var handled := false
	if key.keycode == KEY_ESCAPE:
		handled = _toggle("Pause (Esc)")
	elif reset_key != 0 and key.keycode == reset_key:
		reset()
		handled = true
	elif key.keycode == KEY_F:
		handled = _toggle("Show water (F)")
	elif key.keycode == KEY_P:
		handled = _toggle("Show particles (P)")
	elif key.keycode == KEY_M:
		handled = _cycle("Water look (M)")
	elif key.keycode == KEY_B:
		handled = _cycle("Particle shape (B)")
	elif key.keycode == KEY_S:
		handled = _toggle("Spray on (S)")
	if handled:
		get_viewport().set_input_as_handled()


## Clears every particle of the simulation and starts its emitters again: what fills on start fills, what pours a set amount pours
## it again (what pours without end just goes on).
func reset() -> void:
	if sim == null:
		return
	sim.clear()
	_refill()


func _toggle(text: String) -> bool:
	var button := _panel.get_control(text) as CheckButton
	if button == null:
		return false
	button.button_pressed = not button.button_pressed
	return true


# The next choice of a drop-down (the keys step through them).
func _cycle(text: String) -> bool:
	var pick := _panel.get_control(text) as OptionButton
	if pick == null or pick.item_count == 0:
		return false
	var next := (pick.selected + 1) % pick.item_count
	pick.select(next)
	pick.item_selected.emit(next)
	return true


func _views(type: StringName) -> Array[Node]:
	var found: Array[Node] = []
	for view in sim.find_children("*", type, true, false):
		found.append(view)
	return found


func _build_sim() -> void:
	var p := _panel
	p.tab("Sim")
	p.section("Simulation")
	p.check("Pause (Esc)", not sim.simulating, func(on: bool) -> void: sim.simulating = not on)
	if reset_key != 0:
		p.button("Reset (%s)" % OS.get_keycode_string(reset_key), reset)
	p.check("Adaptive detail", sim.adaptive, func(on: bool) -> void: sim.adaptive = on)
	p.slider("Detail distance", 0.0, 60.0, 0.5, sim.detail_distance, func(v: float) -> void: sim.detail_distance = v,
			func(v: float) -> String: return "off" if v <= 0.0 else "%.1f m" % v)
	p.slider("Detail levels", 1, 4, 1, sim.detail_levels, func(v: float) -> void: sim.detail_levels = int(v),
			func(v: float) -> String: return "LOD 1" if int(v) == 1 else "LOD 1-%d" % int(v))
	var cores := maxi(OS.get_processor_count(), 1)
	p.slider("Threads", 1, cores, 1, cores if sim.threads == 0 else sim.threads, func(v: float) -> void: sim.threads = int(v),
			func(v: float) -> String: return "%d of %d" % [int(v), cores])
	# (As few of those threads as keep a step under this.)
	p.slider("Step budget", 0.0, 16.0, 0.5, sim.step_budget_ms, func(v: float) -> void: sim.step_budget_ms = v,
			func(v: float) -> String: return "all threads" if v <= 0.0 else "%.1f ms" % v)
	p.slider("Cell size", 0.1, 1.5, 0.001, sim.cell_size, Callable(), func(v: float) -> String: return "%s m" % str(snappedf(v, 0.01)),
			_apply_cell_size)
	# (The pressure's gain: how stiff the water is; deeper water needs more.)
	p.slider("Pressure gain", 0.5, 8.0, 0.1, sim.bounded_gain, func(v: float) -> void: sim.bounded_gain = v,
			func(v: float) -> String: return "%.1f" % v)
	p.slider("Substeps", 1, 24, 1, sim.max_substeps, func(v: float) -> void: sim.max_substeps = int(v),
			func(v: float) -> String: return str(int(v)))
	# (The strength only: the direction stays what the node was given. More than earth's makes the water feel quicker.)
	var down := sim.gravity.normalized() if sim.gravity.length() > 0.0 else Vector3.DOWN
	p.slider("Gravity", 1.0, 40.0, 0.1, sim.gravity.length(), func(v: float) -> void: sim.gravity = down * v,
			func(v: float) -> String: return "%.1f m/s^2" % v)


func _build_liquid() -> void:
	_substances = _find_substances()
	var colliders := _find_colliders()
	if _substances.is_empty() and colliders.is_empty():
		return
	var p := _panel
	p.tab("Liquid")
	if not _substances.is_empty():
		_substance = _substances[0]
		p.section("Substance")
		if _substances.size() > 1:
			p.options("Substance", _substances.map(_substance_name), 0, func(index: int) -> void:
					_substance = _substances[index]
					p.show_value("Density", _substance.density)
					p.show_value("Viscosity", _substance.viscosity)
					p.show_value("Surface friction", _substance.friction))
		p.slider("Density", 100.0, 3000.0, 10.0, _substance.density, func(v: float) -> void: _substance.density = v,
				func(v: float) -> String: return "%d kg/m^3" % int(v))
		p.slider("Viscosity", 0.0, 300.0, 0.5, _substance.viscosity, func(v: float) -> void: _substance.viscosity = v,
				func(v: float) -> String: return "%.1f Pa s" % v)
		p.slider("Surface friction", 0.0, 2.0, 0.01, _substance.friction, func(v: float) -> void: _substance.friction = v,
				func(v: float) -> String: return "%.2f" % v)
	if not colliders.is_empty():
		p.section("Colliders")
		# (Every collider of the box takes the same: the first one's is where it starts.)
		p.slider("Collider roughness", 0.0, 4.0, 0.05, colliders[0].friction, func(v: float) -> void: _set_all(colliders, &"friction", v),
				func(v: float) -> String: return "%.2f x" % v)


func _build_view() -> void:
	if _fluids.is_empty() and _particles.is_empty():
		return
	var p := _panel
	p.tab("View")
	if not _fluids.is_empty():
		var first := _fluids[0]
		p.section("Water")
		p.check("Show water (F)", first.visible, func(on: bool) -> void: _set_all(_fluids, &"visible", on))
		p.options("Water look (M)", _names(WaterSimFluidView.Style), int(first.style), func(i: int) -> void: _set_all(_fluids, &"style", i))
		p.options("Particle shape (B)", _names(WaterSimFluidView.Shape), int(first.shape), func(i: int) -> void: _set_all(_fluids, &"shape", i))
		p.check("Discs face camera", first.discs_face_camera, func(on: bool) -> void: _set_all(_fluids, &"discs_face_camera", on))
		p.check("Smoothing", first.smooth, func(on: bool) -> void: _set_all(_fluids, &"smooth", on))
		p.options("Location", _names(WaterSimFluidView.Location), int(first.location), func(i: int) -> void: _set_all(_fluids, &"location", i))
	if not _particles.is_empty():
		p.section("Particles")
		p.check("Show particles (P)", _particles[0].visible, func(on: bool) -> void: _set_all(_particles, &"visible", on))


# Settings still being tried: they may cost accuracy, and may go.
func _build_experimental() -> void:
	var p := _panel
	p.tab("EXPERIMENTAL")
	p.section("Drowsy blocks")
	# (Slow water moves every other step, twice as far: cheaper, its neighbours feel its pressure a step late.)
	p.check("Drowsy blocks", sim.drowsy_blocks, func(on: bool) -> void: sim.drowsy_blocks = on)
	p.slider("Drowsy below", 0.0, 4.0, 0.05, sim.drowsy_speed, func(v: float) -> void: sim.drowsy_speed = v,
			func(v: float) -> String: return "%.2f m/s" % v)
	if not _fluids.is_empty():
		p.section("Drawing")
		# (The depth resolved inside the smoothing, one pass fewer.)
		p.check("Fused resolve", _fluids[0].fuse_resolve, func(on: bool) -> void: _set_all(_fluids, &"fuse_resolve", on))


# Every spray view of the box takes the same: the first one's is where each starts.
func _build_spray() -> void:
	if _sprays.is_empty():
		return
	var p := _panel
	var first := _sprays[0]
	p.tab("Spray")
	p.section("Spray")
	p.check("Spray on (S)", first.enabled, func(on: bool) -> void: _set_all(_sprays, &"enabled", on))
	p.section("Shed from")
	p.check("Fast water", first.from_fast, func(on: bool) -> void: _set_all(_sprays, &"from_fast", on))
	p.check("Free-flying water", first.from_free, func(on: bool) -> void: _set_all(_sprays, &"from_free", on))
	p.check("Impacts", first.from_impacts, func(on: bool) -> void: _set_all(_sprays, &"from_impacts", on))
	p.check("Fields and orbs that spray", first.from_fields, func(on: bool) -> void: _set_all(_sprays, &"from_fields", on))
	p.slider("Spray per particle", 1, 16, 1, first.per_particle, func(v: float) -> void: _set_all(_sprays, &"per_particle", int(v)),
			func(v: float) -> String: return str(int(v)))
	p.section("Look")
	p.slider("Spray size", 0.005, 0.2, 0.005, first.size, func(v: float) -> void: _set_all(_sprays, &"size", v),
			func(v: float) -> String: return "%d mm" % roundi(v * 1000.0))
	p.slider("Spray opacity", 0.0, 1.0, 0.01, first.opacity, func(v: float) -> void: _set_all(_sprays, &"opacity", v),
			func(v: float) -> String: return "%.2f" % v)
	p.slider("Spray lifetime", 0.1, 5.0, 0.05, first.lifetime, func(v: float) -> void: _set_all(_sprays, &"lifetime", v),
			func(v: float) -> String: return "%.2f s" % v)
	p.slider("Spray stretch", 0.0, 0.2, 0.001, first.stretch, func(v: float) -> void: _set_all(_sprays, &"stretch", v),
			func(v: float) -> String: return "round" if v <= 0.0 else "%.3f s" % v)


func _build_tools() -> void:
	if pull == null and (tools == null or not tools.has_method(&"get_tools")):
		return
	var p := _panel
	p.tab("Tools")
	if tools != null and tools.has_method(&"get_tools"):
		_build_belt(tools)
	if pull == null:
		return
	p.section("Pull")
	p.label("Left click: pull water in at the mouse.")
	p.slider("Pull strength", 0.0, 30.0, 0.1, pull.strength, func(v: float) -> void: pull.strength = v,
			func(v: float) -> String: return "%.1f m/s" % v)
	p.slider("Pull range", 0.5, 40.0, 0.1, pull.distance, func(v: float) -> void: pull.distance = v,
			func(v: float) -> String: return "%.1f m from camera" % v)


# The belt's tools: a drop-down to pick one, and each tool's settings in a group shown while it is the one picked. The controls are
# named "<tool> <setting>" so every tool's are its own (and saved with the tab).
func _build_belt(belt: Node) -> void:
	var p := _panel
	var list: Array = belt.get_tools()
	if list.is_empty():
		return
	p.section("Tool")
	p.options("Tool", list.map(func(tool: Node) -> String: return tool.label), belt.get_selected(), func(i: int) -> void: belt.select(i))
	if belt.has_method(&"clear"):
		p.button("Clear placed (C)", belt.clear)
	var groups: Array[Control] = []
	for tool: Node in list:
		var group := p.begin_group()
		groups.append(group)
		p.section(tool.label)
		if tool.hint != "":
			p.label(tool.hint)
		var names := []
		if tool.has_method(&"get_settings"):
			for setting: Dictionary in tool.get_settings():
				names.append(_tool_setting(tool, setting))
		if tool.has_signal(&"settings_changed"):
			# Shows what the belt's keys changed.
			tool.settings_changed.connect(func() -> void:
				var settings: Array = tool.get_settings()
				for i in mini(names.size(), settings.size()):
					p.show_value(names[i], tool.get(settings[i].property)))
		p.end_group()
	var show := func(index: int) -> void:
		for i in groups.size():
			groups[i].visible = i == index
		p.show_value("Tool", index)
	belt.selected.connect(show)
	show.call(belt.get_selected())


# One control for a tool's setting (see WaterSimTool.get_settings); returns its name.
func _tool_setting(tool: Node, setting: Dictionary) -> String:
	var p := _panel
	var text := "%s %s" % [tool.label, String(setting.name).to_lower()]
	var property: String = setting.property
	if setting.has("items"):
		# (A drop-down shows only its choice: say what it is.)
		p.label(String(setting.name))
		p.options(text, setting.items, int(tool.get(property)), func(i: int) -> void: tool.set(property, i))
	elif setting.has("check"):
		p.check(text, bool(tool.get(property)), func(on: bool) -> void: tool.set(property, on))
	else:
		var format: String = setting.get("format", "")
		p.slider(text, setting.min, setting.max, setting.get("step", 0.01), float(tool.get(property)),
				func(v: float) -> void: tool.set(property, v),
				func(v: float) -> String: return format % v if format != "" else str(snappedf(v, setting.get("step", 0.01))))
	return text


func _names(type: Dictionary) -> Array:
	return type.keys().map(func(key: String) -> String: return key.capitalize())


func _apply_cell_size(value: float) -> void:
	sim.cell_size = value
	_cell_size_changed()


# The new grid is in place at the next physics frame, and clears the water: fill it again.
func _cell_size_changed() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if refill_emitters:
		_refill()
	cell_size_changed.emit(sim.cell_size)


func _refill() -> void:
	for emitter in get_tree().root.find_children("*", "WaterSimEmitter", true, false):
		if emitter.get_sim() != sim:
			continue
		if emitter.fill_on_start:
			emitter.fill()
		elif emitter.max_volume > 0.0:
			emitter.pour_again()


# The substances in the box: registered ones, the box's list and what its components put in (emitters, converters, transmuters).
func _find_substances() -> Array[WaterSimSubstance]:
	var found: Array[WaterSimSubstance] = []
	var candidates: Array = sim.get_substances() + sim.substances
	for component in get_tree().root.find_children("*", "WaterSimComponent", true, false):
		if component.get_sim() != sim:
			continue
		for property in [&"substance", &"to"]:
			candidates.append(component.get(property))
	for substance in candidates:
		if substance is WaterSimSubstance and not found.has(substance):
			found.append(substance)
	return found


func _find_colliders() -> Array[Node]:
	var found: Array[Node] = []
	for collider in get_tree().root.find_children("*", "WaterSimCollider", true, false):
		if collider.get_sim() == sim:
			found.append(collider)
	return found


func _substance_name(substance: WaterSimSubstance) -> String:
	if substance.resource_name != "":
		return substance.resource_name
	if substance.resource_path != "":
		return substance.resource_path.get_file().get_basename().capitalize()
	return "Substance %d" % (_substances.find(substance) + 1)


func _set_all(targets: Array, property: StringName, value: Variant) -> void:
	for node in targets:
		if is_instance_valid(node):
			node.set(property, value)
