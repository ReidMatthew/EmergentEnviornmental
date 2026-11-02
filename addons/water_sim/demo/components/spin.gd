extends Node3D
## Spins this node about its up axis, and shows it only while the force field it's under is
## enabled (the tornado's funnel).

@export var speed := 4.0


func _process(delta: float) -> void:
	var field := get_parent() as WaterSimForceField
	visible = field == null or field.enabled
	if visible:
		rotate_object_local(Vector3.UP, speed * delta)
