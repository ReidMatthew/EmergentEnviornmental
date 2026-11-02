@tool
class_name SolidMesh
extends SolidShape
## Any closed mesh as a shape: rocks, buildings, a crater with a hand-made rim. Every
## surface gets [member tag]. The mesh must be closed (no holes) and outward-facing.

@export var mesh: Mesh:
	set(value):
		if mesh != null and mesh.changed.is_connected(emit_changed):
			mesh.changed.disconnect(emit_changed)
		mesh = value
		if mesh != null:
			mesh.changed.connect(emit_changed)
		emit_changed()


func _build_solid() -> Solid:
	if mesh == null:
		return Solid.new()
	return Solid.from_mesh(mesh)
