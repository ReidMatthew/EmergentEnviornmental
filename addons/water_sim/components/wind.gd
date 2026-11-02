@tool
@icon("../icon.svg")
class_name WaterSimWind
extends WaterSimForceField
## Blows matter along this node's forward axis (-Z), like a current or a gust.

@export var speed := 6.0


func _init() -> void:
	if shape == WaterSim.Shape.SPHERE and radius == 0.5:
		shape = WaterSim.Shape.BOX
		size = Vector3(4, 2, 4)


func _get_settings() -> Dictionary:
	return { "type": 2, "speed": speed }
