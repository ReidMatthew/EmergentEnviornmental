@tool
class_name MeshSource
extends SolidSource
## A closed mesh (no holes, outward-facing) as the source. Surface [code]s[/code] gets tag
## [code]s[/code] and keeps its material.

@export var mesh: Mesh:
	set(value):
		if mesh != null and mesh.changed.is_connected(emit_changed):
			mesh.changed.disconnect(emit_changed)
		mesh = value
		if mesh != null:
			mesh.changed.connect(emit_changed)
		emit_changed()
## Corners closer than this are merged (see [method Solid.from_mesh]).
@export_range(0.0, 0.01, 0.000001, "or_greater") var merge_distance := 1e-5:
	set(value):
		merge_distance = value
		emit_changed()


func _build() -> Solid:
	if mesh == null:
		return Solid.new()
	for s in mesh.get_surface_count():
		_cached_materials.append(mesh.surface_get_material(s))
	return Solid.from_mesh(mesh, 0, merge_distance)
