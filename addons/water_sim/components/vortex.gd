@tool
@icon("../icon.svg")
class_name WaterSimVortex
extends WaterSimForceField
## A tornado or whirlpool: swirls matter about this node's up axis, pulls it in and lifts it.
## Shaped like a cylinder by default, centred on the node.

## Speed around the axis (m/s) outside the core (the inner quarter turns like a solid).
## Negative turns the other way.
@export var swirl_speed := 8.0
## Speed towards the axis.
@export var pull_speed := 2.0
## Speed up the axis. Up to 4 m/s, this also cancels that fraction of gravity inside.
@export var lift_speed := 5.0


func _init() -> void:
	if shape == WaterSim.Shape.SPHERE and radius == 0.5:
		shape = WaterSim.Shape.CYLINDER
		radius = 2.0
		height = 6.0


func _get_settings() -> Dictionary:
	return { "type": 0, "speed": swirl_speed, "pull": pull_speed, "lift": lift_speed }
