@tool
@icon("../icon.svg")
class_name WaterSimConverter
extends WaterSimVolume
## Turns matter inside its shape into another substance: water into slime. Either all at once with [method apply],
## or bit by bit while [member active].

signal converted(count: int)

## What it changes. Empty: everything.
@export var from: Array[WaterSimSubstance] = []
## What it becomes.
@export var to: WaterSimSubstance
## Keep converting.
@export var active := false
## While active: the fraction of what's inside that changes each second (above about 10
## it's immediate).
@export_range(0.0, 10.0, 0.01, "or_greater") var rate := 2.0



func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not active or _paused():
		return
	delta = _tick_time(delta)
	if delta > 0.0:
		apply(1.0 - exp(-rate * delta))


## Converts what's inside, each particle with chance fraction. Returns how many changed.
func apply(fraction := 1.0) -> int:
	if to == null:
		return 0
	var on := _activity()
	if on == null:
		return 0
	var count := on.convert(shape, global_transform, get_extents(), from, to, fraction)
	if count > 0:
		converted.emit(count)
	return count


func _get_shape_color() -> Color:
	return to.color if to != null else Color(0.8, 0.8, 0.8)
