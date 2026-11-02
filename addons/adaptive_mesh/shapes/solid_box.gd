@tool
class_name SolidBox
extends SolidShape
## A box of 12 triangles.

@export var size := Vector3.ONE:
	set(value):
		size = value
		emit_changed()


static var _unit: Solid  # a 1 x 1 x 1 box, as Solid.from_mesh() makes it from a BoxMesh


func _build_solid() -> Solid:
	# The unit box scaled, corners at +-size / 2: a BoxMesh of this size made into a solid, to
	# within rounding, without making a mesh resource each time, which costs milliseconds on
	# the main thread.
	if _unit == null:
		_unit = Solid.from_mesh(BoxMesh.new())
	var solid := _unit.duplicate() as Solid
	var positions := _unit.positions.duplicate()  # (packed arrays are shared, not copied, by duplicate())
	for i in positions.size():
		positions[i] *= size
	solid.positions = positions
	return solid
