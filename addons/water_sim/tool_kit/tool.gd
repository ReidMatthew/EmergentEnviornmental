@icon("../icon.svg")
class_name WaterSimTool
extends Node3D
## A tool the player aims with the mouse: a spell, a hose, a magnet. It is built from its children: whatever components it holds
## (emitters, drains, converters, recyclers, force fields, streams, orbs, or any node with [code]set_active(on)[/code]) are switched
## on while it is used. So one script makes a pour, a blast, a tornado, a vacuum or a freeze, and a new tool is a new arrangement of
## components, with no code.
##
## A [WaterSimToolBelt] moves the selected tool to where the mouse points and tells it when the button goes down and up. The tool
## then:
## - scales its components' speeds, flows and rates by [member power] and their sizes (and their offsets from it) by
##   [member reach], from the values they were given;
## - is placed on the surface under the mouse ([member height] above it) or [member distance] along the ray ([member aim_mode]);
## - is turned by [member facing]: upright, along the view (its -Z away from the camera: a wind child blows away from you), along
##   the view kept level, or with its up along the surface;
## - acts while the button is held, is switched on and off by clicks, acts for [member pulse_time] after each click, or leaves a
##   copy of its components where it is clicked ([member use]).
##
## [method get_settings] lists what the player may change, for a menu to show (the [code]water_sim_menu[/code] add-on's Tools tab
## builds itself from it). Override it to add a tool's own.

## Emitted when a setting is changed by the tool itself or by the belt's keys (so a menu can show it).
signal settings_changed

enum Use {
	## Acts while the button is held.
	HOLD,
	## A click switches it on or off; holding drags it (it stays where it's left).
	TOGGLE,
	## Acts for [member pulse_time] after each click.
	PULSE,
	## A click leaves a working copy of its components there (until [method clear_placed]).
	PLACE,
}
enum Aim {
	## On whatever is under the mouse (ground, objects or water), [member height] above it.
	SURFACE,
	## [member distance] from the camera along the ray through the mouse.
	RAY,
}
enum Facing {
	## Upright.
	UP,
	## -Z along the ray from the camera.
	VIEW,
	## -Z along the ray, kept level.
	VIEW_LEVEL,
	## Up along the surface's normal.
	SURFACE,
}

## Name shown in the tool list.
@export var label := "Tool"
## One line on how to use it.
@export var hint := ""
@export var use := Use.HOLD
@export var aim_mode := Aim.SURFACE
@export var facing := Facing.UP
## Above the surface (m), aiming at a surface.
@export var height := 0.0:
	set(value):
		height = value
		settings_changed.emit()
## From the camera (m), aiming along the ray.
@export_range(0.5, 100.0, 0.1, "or_greater") var distance := 8.0:
	set(value):
		distance = maxf(value, 0.5)
		settings_changed.emit()
## Times the components' speeds, flows and rates.
@export_range(0.0, 4.0, 0.01, "or_greater") var power := 1.0:
	set(value):
		power = maxf(value, 0.0)
		_scale_components()
		settings_changed.emit()
## Times the components' sizes and offsets.
@export_range(0.1, 4.0, 0.01, "or_greater") var reach := 1.0:
	set(value):
		reach = maxf(value, 0.1)
		_scale_components()
		settings_changed.emit()
## Whether its force fields and orbs shed spray from the water they hold (see [member WaterSimForceField.spray]); it starts as
## they were given (on if any is).
var spray := false:
	set(value):
		spray = value
		for node in _components():
			if &"spray" in node and node.get(&"spray") is bool:
				node.set(&"spray", value)
		settings_changed.emit()
## Components elsewhere switched on and off with this tool, but not moved or scaled: a recycler at the floor of a pool feeding this
## tool's emitter (summoning water out of the pool rather than out of nothing).
@export var linked: Array[Node] = []
## How long a pulse lasts (s).
@export var pulse_time := 0.3
## Most copies left at once with [constant Use.PLACE]; the oldest goes first.
@export var max_placed := 6

## What the belt last saw: the ray through the mouse, and the surface's normal where it hit (up where it hit water or nothing).
var ray_origin := Vector3.ZERO
var ray_direction := Vector3.FORWARD
var surface_normal := Vector3.UP
## Whether the button is held on this tool.
var held := false
## Whether its components are on.
var active := false

# What each component was given, to scale from: node -> { property: value }.
var _base := {}
var _pulse_left := 0.0
var _placed: Array[Node3D] = []

# Speeds, flows and rates (scaled by power) and sizes (by reach), of every kind of component.
const POWER_PROPERTIES: Array[StringName] = [&"speed", &"swirl_speed", &"pull_speed", &"lift_speed", &"flow", &"rate",
		&"speed_start", &"speed_end", &"pull", &"swirl", &"velocity", &"strength"]
const REACH_PROPERTIES: Array[StringName] = [&"radius", &"size", &"height", &"position"]


func _ready() -> void:
	_remember()
	spray = _sprays().any(func(node: Node) -> bool: return node.get(&"spray"))
	_scale_components()
	_switch(false)


func _physics_process(delta: float) -> void:
	if _pulse_left > 0.0:
		_pulse_left -= delta
		if _pulse_left <= 0.0:
			_switch(false)


## Called every physics frame while selected, with the point the mouse is on (on the ground, an object or the water, whichever is
## nearest) and the collider hit, if any. [member ray_origin], [member ray_direction] and [member surface_normal] are set first.
func aim(point: Vector3, _hit: Object) -> void:
	# A toggled tool stays where it was left while on, unless it's being dragged.
	if use == Use.TOGGLE and active and not held:
		return
	var at := point + Vector3.UP * height if aim_mode == Aim.SURFACE else ray_origin + ray_direction * distance
	global_transform = Transform3D(_facing_basis(), at)


## The button went down.
func press(_hit: Object) -> void:
	held = true
	match use:
		Use.HOLD:
			_switch(true)
		Use.TOGGLE:
			_switch(not active)
		Use.PULSE:
			_pulse_left = pulse_time
			_switch(true)
		Use.PLACE:
			_place()


## The button went up (or the tool was put away).
func release() -> void:
	held = false
	if use == Use.HOLD:
		_switch(false)


## Removes what [constant Use.PLACE] left, and switches a toggled tool off.
func clear_placed() -> void:
	for node in _placed:
		if is_instance_valid(node):
			node.queue_free()
	_placed.clear()
	if use == Use.TOGGLE:
		_switch(false)


## Shows or hides where its components act (the belt shows the selected tool's).
func show_shapes(on: bool) -> void:
	for node in _components():
		if &"show_shape" in node:
			node.show_shape = on


## What the player may change, for a menu: an array of dictionaries, each with [code]name[/code], [code]property[/code] (of this
## node) and either [code]min[/code], [code]max[/code], [code]step[/code] and [code]format[/code] (a slider; the format is a
## [code]%[/code] format for the value), [code]items[/code] (a drop-down of those names) or [code]check[/code] (a switch).
func get_settings() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	# (A menu may ask before this tool is ready.)
	if _base.is_empty():
		_remember()
	if _has_any(POWER_PROPERTIES):
		list.append({ "name": "Power", "property": "power", "min": 0.0, "max": 4.0, "step": 0.05, "format": "%.2f x" })
	if _has_any(REACH_PROPERTIES):
		list.append({ "name": "Reach", "property": "reach", "min": 0.25, "max": 4.0, "step": 0.05, "format": "%.2f x" })
	if aim_mode == Aim.SURFACE:
		list.append({ "name": "Height", "property": "height", "min": -2.0, "max": 12.0, "step": 0.1, "format": "%.1f m" })
	else:
		list.append({ "name": "Distance", "property": "distance", "min": 1.0, "max": 60.0, "step": 0.5, "format": "%.1f m" })
	if not _sprays().is_empty():
		list.append({ "name": "Spray", "property": "spray", "check": true })
	list.append({ "name": "Use", "property": "use", "items": Use.keys().map(func(k: String) -> String: return k.capitalize()) })
	list.append({ "name": "Facing", "property": "facing", "items": Facing.keys().map(func(k: String) -> String: return k.capitalize()) })
	return list


## Its components: every descendant that is a water sim component (or has [code]set_active[/code]), not inside another.
func _components() -> Array[Node]:
	var found: Array[Node] = []
	_collect(self, found)
	return found


## Its components that can shed spray (force fields, orbs).
func _sprays() -> Array[Node]:
	var found: Array[Node] = []
	for node in _components():
		if &"spray" in node and node.get(&"spray") is bool:
			found.append(node)
	return found


func _collect(node: Node, found: Array[Node]) -> void:
	for child in node.get_children():
		if child is WaterSimComponent or child.has_method(&"set_active"):
			found.append(child)
		else:
			_collect(child, found)


func _remember() -> void:
	_base.clear()
	for node in _components():
		var values := {}
		for property in POWER_PROPERTIES + REACH_PROPERTIES:
			if property in node:
				values[property] = node.get(property)
		_base[node] = values


func _has_any(properties: Array[StringName]) -> bool:
	for values: Dictionary in _base.values():
		for property in properties:
			if values.has(property) and property != &"position":
				return true
	return false


func _scale_components() -> void:
	if not is_node_ready():
		return
	for node: Node in _base:
		if not is_instance_valid(node):
			continue
		var values: Dictionary = _base[node]
		for property: StringName in values:
			var scale := power if property in POWER_PROPERTIES else reach
			node.set(property, values[property] * scale)


func _switch(on: bool) -> void:
	active = on
	for node in _components():
		_switch_node(node, on)
	for node in linked:
		if is_instance_valid(node):
			_switch_node(node, on)


static func _switch_node(node: Node, on: bool) -> void:
	if node is WaterSimEmitter:
		node.emitting = on
	elif &"enabled" in node:
		node.enabled = on
	elif &"active" in node:
		node.active = on
	elif node.has_method(&"set_active"):
		node.set_active(on)


# A working copy of the components where the tool is, kept until cleared.
func _place() -> void:
	var holder := Node3D.new()
	holder.name = "%sPlaced" % label.to_pascal_case()
	for node in _components():
		var copy := node.duplicate()
		holder.add_child(copy)
		copy.transform = (node as Node3D).transform if node is Node3D else Transform3D()
		_switch_node(copy, true)
		if &"show_shape" in copy:
			copy.show_shape = false
	# (Beside the tool, under the belt: the belt stays put, the tool follows the mouse.)
	get_parent().add_child(holder)
	holder.global_transform = global_transform
	_placed.append(holder)
	while _placed.size() > max_placed:
		var oldest: Node3D = _placed.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


func _facing_basis() -> Basis:
	match facing:
		Facing.VIEW:
			return Basis.looking_at(ray_direction, Vector3.UP if absf(ray_direction.y) < 0.99 else Vector3.FORWARD)
		Facing.VIEW_LEVEL:
			var level := Vector3(ray_direction.x, 0.0, ray_direction.z)
			return Basis.looking_at(level.normalized()) if level.length() > 1e-4 else Basis()
		Facing.SURFACE:
			var up := surface_normal.normalized()
			var side := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
			return Basis(side, up, side.cross(up))
	return Basis()
