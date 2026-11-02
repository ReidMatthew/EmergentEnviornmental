@tool
@icon("../icon.svg")
class_name WaterSimPush
extends WaterSimForceField
## Pushes matter straight out from this node (a blast), or pulls it in with a negative
## speed (a gathering spell). A pull gathers only into room: where the matter is already full
## it holds it still and up against gravity instead of squeezing it further.

## Speed away from the centre (m/s). Negative pulls in.
@export var speed := 6.0


func _get_settings() -> Dictionary:
	return { "type": 1, "speed": speed }
