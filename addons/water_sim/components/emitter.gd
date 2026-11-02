@tool
@icon("../icon.svg")
class_name WaterSimEmitter
extends WaterSimVolume
## Adds a substance to a [WaterSim]: fills its shape once (a lake, a rock that's there from
## the start) and/or keeps pouring while [member emitting] (a fountain, a spell).

signal filled(count: int)

@export var substance: WaterSimSubstance
## Fill the shape when the simulation starts.
@export var fill_on_start := false
## Fill with at most this many particles, from the bottom up (a pool of a set amount; make the shape deep enough). 0: the whole shape.
@export var fill_limit := 0
## Keep adding particles at [member flow].
@export var emitting := false
## Cubic metres a second while emitting.
@export var flow := 0.5
## Stop emitting once this many cubic metres have been added (0: no limit). Filling a pool by pouring.
@export var max_volume := 0.0
## Velocity new matter starts with, in this node's space (so turning the node aims it).
@export var velocity := Vector3.ZERO


var _owed := 0.0
var _started := false
var _poured := 0.0


func _attach(on: WaterSim) -> void:
	if fill_on_start and not _started:
		_started = true
		if on.is_node_ready():
			fill()
		else:
			on.ready.connect(fill, CONNECT_ONE_SHOT)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not emitting or _paused():
		return
	delta = _tick_time(delta)
	if delta <= 0.0:
		return
	var on := _activity()
	if on == null:
		return
	var volume := flow * delta
	if max_volume > 0.0:
		volume = minf(volume, max_volume - _poured)
		if volume <= 0.0:
			emitting = false
			return
	_poured += volume
	# Eight particles per cell.
	_owed += volume * 8.0 / pow(on.cell_size, 3)
	var amount := int(_owed)
	if amount > 0:
		_owed -= amount
		on.spray(shape, global_transform, get_extents(), amount, substance, _global_velocity())


## Fills the shape. Returns how many particles were added.
func fill() -> int:
	var on := _activity()
	if on == null:
		return 0
	var count := on.fill(shape, global_transform, get_extents(), substance, _global_velocity(), false,
			fill_limit if fill_limit > 0 else -1)
	filled.emit(count)
	return count


## Pours [member max_volume] again from the start (after the water was cleared).
func pour_again() -> void:
	_poured = 0.0
	_owed = 0.0
	emitting = true


func _global_velocity() -> Vector3:
	return global_transform.basis.orthonormalized() * velocity


func _get_shape_color() -> Color:
	return substance.color if substance != null else Color(0.4, 0.8, 1.0)
