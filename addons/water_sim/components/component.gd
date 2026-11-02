@tool
class_name WaterSimComponent
extends Node3D
## Base for the nodes that act on a [WaterSim]. Each finds its simulation by itself: the
## one set in [member sim], else the nearest above it, else the one whose box it's in (found
## again whenever it moves out of that box). When it acts, it wakes that box, or with a
## [WaterSimWorld] in the scene and no box there, has one started (see [method _activity]).

## Leave empty to find it.
@export var sim: WaterSim:
	set(value):
		if _sim != null and is_inside_tree():
			_detach(_sim)
		sim = value
		_sim = null
		if is_inside_tree() and not Engine.is_editor_hint():
			get_sim()

var _sim: WaterSim
# Whether _sim is fixed (set, or above this node) rather than found by position.
var _fixed := false
# Time held back while the box's step was still running (see _tick_time).
var _held := 0.0


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		get_sim.call_deferred()


func _exit_tree() -> void:
	if _sim != null:
		_detach(_sim)
		_sim = null


## The simulation this acts on (null if there's none).
func get_sim() -> WaterSim:
	if _sim != null and is_instance_valid(_sim) and not _sim.is_queued_for_deletion():
		if _fixed or _sim.has_point(global_position):
			return _sim
	if not is_inside_tree():
		return null
	var found := sim if sim != null else WaterSim.find_for(self)
	if found != _sim:
		if _sim != null and is_instance_valid(_sim):
			_detach(_sim)
		_sim = found
		if _sim != null:
			_attach(_sim)
	_fixed = sim != null or (_sim != null and _sim.is_ancestor_of(self))
	return _sim


## The simulation, awake and ready to be acted on: [method get_sim] woken, or (when there's
## none here and the scene has a [WaterSimWorld]) a box started around this node. Null when
## there's neither.
## Whether its box is paused ([member WaterSim.simulating] off): what acts over time (pouring, draining, converting,
## recycling) waits with the water.
## The time to act for on this tick: delta and what was held back, or 0 while the box's
## background step still runs (a call into it would make the frame wait for the step), the
## time then held for the next tick.
func _tick_time(delta: float) -> float:
	var on := get_sim()
	if on != null and on.is_stepping():
		_held = minf(_held + delta, 0.25)
		return 0.0
	var time := delta + _held
	_held = 0.0
	return time


func _paused() -> bool:
	var on := get_sim()
	return on != null and not on.simulating


func _activity() -> WaterSim:
	var on := get_sim()
	if on == null or (not _fixed and not on.has_point(global_position)):
		var world := WaterSimWorld.find(get_tree())
		if world != null:
			var started := world.ensure_box(global_position)
			if started != null:
				on = get_sim()
	if on != null:
		on.wake()
	return on


## Called when this starts acting on a simulation.
func _attach(_on: WaterSim) -> void:
	pass


## Called when it stops.
func _detach(_from: WaterSim) -> void:
	pass
