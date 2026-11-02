@tool
@abstract
class_name SolidShape
extends Resource
## A shape to cut out of or add to an [AdaptiveMesh]: builds a [Solid] centred on its
## origin. Subclass this for new shapes.

## Tag given to the faces this shape makes (see [Solid]). The default 1 tells them apart
## from the authored surface (tag 0).
@export var tag := 1:
	set(value):
		tag = value
		emit_changed()

var _solid: Solid


func _init() -> void:
	# A method, not a lambda: a lambda using self would keep this resource alive for good
	# (it holds the resource, and the resource holds it through its own signal).
	changed.connect(_forget)


func _forget() -> void:
	_solid = null


## The shape as a solid, built once and reused until a property changes. Don't modify it.
func get_solid() -> Solid:
	if _solid == null:
		_solid = _build_solid()
		_solid.tags.fill(tag)
	return _solid


## Builds the solid. Tags are overwritten with [member tag] afterwards.
@abstract func _build_solid() -> Solid
