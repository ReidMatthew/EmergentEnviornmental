@tool
@icon("../icon.svg")
class_name WaterSimDrain
extends WaterSimVolume
## Takes matter away inside its shape: a drain, a sponge, a fire boiling water off.

signal drained(count: int)

## What it takes. Empty: everything.
@export var from: Array[WaterSimSubstance] = []
## Keep draining.
@export var active := true
## While active: the fraction of what's inside taken each second (above about 10 it's
## immediate).
@export_range(0.0, 10.0, 0.01, "or_greater") var rate := 20.0


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not active or _paused():
		return
	delta = _tick_time(delta)
	if delta > 0.0:
		apply(1.0 - exp(-rate * delta))


## Removes what's inside, each particle with chance fraction. Returns how many went.
func apply(fraction := 1.0) -> int:
	var on := _activity()
	if on == null:
		return 0
	var count := on.remove(shape, global_transform, get_extents(), from, fraction)
	if count > 0:
		drained.emit(count)
	return count


func _get_shape_color() -> Color:
	return Color(0.9, 0.4, 0.3)
