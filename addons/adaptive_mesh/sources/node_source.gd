@tool
class_name NodeSource
extends SceneSource
## The meshes of a node in the scene as the source: [member node] and every [MeshInstance3D]
## under it, placed relative to it, one tag per material (the meshes' active materials,
## overrides included). An [AdaptiveMesh] used as a component reads its target with one:
## give it one as its [member AdaptiveMesh.source] to set the repair options (they're
## [SceneSource]'s), and the component fills in [member node]. Sizes are the target's own:
## scale the target (or its import) rather than the source, so the pieces line up with it.

## The node to read. Not saved: set it from code.
var node: Node3D:
	set(value):
		node = value
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"scene", &"root_path", &"width"]:
		property.usage = PROPERTY_USAGE_NONE  # read from [member node], at its own size


func _build() -> Solid:
	if node == null:
		return Solid.new()
	if width != 0.0:
		width = 0.0  # the pieces must match the node they replace
	return _build_from(node, node, node.name)


## Changes when the meshes, their materials or where they sit under [member node] change,
## as well as the repair settings.
func get_fingerprint() -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	hash_object(hashing, self, 0)
	if node != null:
		var instances: Array[MeshInstance3D] = []
		_collect(node, instances)
		for instance in instances:
			hash_value(hashing, instance.mesh)
			SolidSource.hash_bytes(hashing, var_to_bytes(_transform_to(node, instance)))
			for s in instance.mesh.get_surface_count():
				var material := instance.get_active_material(s)
				SolidSource.hash_bytes(hashing, (material.resource_path if material != null else "").to_utf8_buffer())
	return hashing.finish().hex_encode()


## The meshes this source reads (for taking them over).
func get_mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node != null:
		_collect(node, out)
	return out
