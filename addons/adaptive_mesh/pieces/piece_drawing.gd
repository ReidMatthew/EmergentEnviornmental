@tool
class_name PieceDrawing
extends Resource
## How an [AdaptiveMesh]'s pieces are drawn. Empty on the mesh uses the defaults.

## Material per tag (index = tag), overriding the source's. Faces shapes make get the
## shape's tag (1 by default), so put the look of fresh cuts there.
@export var materials: Array[Material] = []
## Faces that bend less than this (degrees) are shaded smooth across their shared edges. 0
## shades every face flat (a low-poly look).
@export_range(0.0, 180.0, 0.1) var crease_angle := 40.0
@export var cast_shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
