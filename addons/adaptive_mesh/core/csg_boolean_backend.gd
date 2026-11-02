@tool
class_name CsgBooleanBackend
extends BooleanBackend
## Booleans through Godot's CSG nodes (the Manifold library since Godot 4.4). Needs no
## native code, but CSG nodes only work on the main thread, inside the scene tree. Its cost
## grows with the whole target (a few milliseconds for a few hundred triangles), so keep
## solids small (chunk them) or use a native backend for big ones.
##
## The CSG update is forced right away, so [method combine] finishes in the frame it was
## called in. (It calls CSGShape3D's [code]_update_shape()[/code]; on a Godot without it,
## it waits a frame for the deferred update instead.) Pieces call it in two parts:
## [method combine_main] does the CSG on the main thread and [method combine_finish] turns
## the result into a solid (welding) on a worker.
##
## Tags travel through CSG as materials: each tag gets a placeholder material, and faces
## come back grouped by it.

# Placeholder material per tag, and back. Shared by every instance.
static var _tag_materials := {}
static var _material_tags := {}
static var _lock := Mutex.new()


func is_thread_safe() -> bool:
	return false


func combine(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Solid:
	return combine_finish(await combine_main(target, ops, bounds, bounds_tag, bounds_walls))


## Runs the CSG and returns its surfaces as [code][vertices, uvs, indices, tag][/code]
## arrays, an empty solid when there's nothing to do, or null on failure.
func combine_main(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	if target.is_empty() and not ops.any(func(op: BooleanOp) -> bool: return op.operation == BooleanOp.Operation.UNION):
		return Solid.new()  # nothing to cut from, nothing added
	var root := CSGCombiner3D.new()
	root.visible = false
	if not target.is_empty():
		root.add_child(_shape_node(target, CSGShape3D.OPERATION_UNION))
	# An empty target only matters to unions: each union adds its (cut) shape.
	for op in ops:
		var node: CSGShape3D
		if op.operation == BooleanOp.Operation.UNION and bounds.has_volume():
			# Cut the shape to the bounds first, so the union stays inside them.
			node = CSGCombiner3D.new()
			node.add_child(_shape_node(op.shape, CSGShape3D.OPERATION_UNION))
			var shape_tag := op.shape.tags[0] if not op.shape.tags.is_empty() else bounds_tag
			var box := _shape_node(_bounds_box(bounds.size, bounds_walls, bounds_tag, shape_tag),
					CSGShape3D.OPERATION_INTERSECTION)
			# The box is placed in the solid's space, so undo the shape's transform.
			box.transform = op.transform.affine_inverse() * Transform3D(Basis(), bounds.get_center())
			node.add_child(box)
		else:
			node = _shape_node(op.shape, CSGShape3D.OPERATION_UNION)
		node.operation = _csg_operation(op.operation)
		node.transform = op.transform
		root.add_child(node)
	tree.root.add_child(root)
	if root.has_method(&"_update_shape"):
		root.call(&"_update_shape")
	else:
		await tree.process_frame  # CSG nodes update deferred, at the end of the frame
	var baked := root.bake_static_mesh()
	root.queue_free()
	if baked == null:
		return null
	var surfaces := []
	for s in baked.get_surface_count():
		var arrays := baked.surface_get_arrays(s)
		surfaces.append([arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_TEX_UV], arrays[Mesh.ARRAY_INDEX],
				_tag_of(baked.surface_get_material(s))])
	return surfaces


## Builds the solid from [method combine_main]'s surfaces and welds it. Thread-safe.
func combine_finish(main_result: Variant) -> Solid:
	if main_result == null or main_result is Solid:
		return main_result
	var surfaces: Array = main_result
	var solid := Solid.new()
	var has_uv := surfaces.any(func(entry: Array) -> bool: return entry[1] != null)
	for entry: Array in surfaces:
		var vertices: PackedVector3Array = entry[0]
		var surface_indices := PackedInt32Array()
		if entry[2] != null:
			surface_indices = entry[2]
		if surface_indices.is_empty():
			surface_indices.resize(vertices.size())
			for i in vertices.size():
				surface_indices[i] = i
		var base := solid.positions.size()
		solid.positions.append_array(vertices)
		if has_uv:
			var surface_uvs := PackedVector2Array()
			if entry[1] != null:
				surface_uvs = entry[1]
			surface_uvs.resize(vertices.size())
			solid.uvs.append_array(surface_uvs)
		for i in surface_indices:
			solid.indices.append(base + i)
		var tag: int = entry[3]
		for t in surface_indices.size() / 3:
			solid.tags.append(tag)
	solid.weld()
	return solid


# A box of [param size] centred on the origin: faces on sides in [param walls] get
# [param wall_tag], the others [param open_tag].
static func _bounds_box(size: Vector3, walls: int, wall_tag: int, open_tag: int) -> Solid:
	var box := BoxMesh.new()
	box.size = size
	var solid := Solid.from_mesh(box)
	solid.uvs = PackedVector2Array()
	solid.weld()
	for t in solid.get_triangle_count():
		var a := solid.positions[solid.indices[t * 3]]
		var n := (solid.positions[solid.indices[t * 3 + 2]] - a).cross(solid.positions[solid.indices[t * 3 + 1]] - a)
		var axis := n.abs().max_axis_index()
		var bit := BooleanBackend.side_bit(axis, n[axis] > 0.0)
		solid.tags[t] = wall_tag if walls & bit else open_tag
	return solid


static func _csg_operation(operation: BooleanOp.Operation) -> CSGShape3D.Operation:
	match operation:
		BooleanOp.Operation.SUBTRACT:
			return CSGShape3D.OPERATION_SUBTRACTION
		BooleanOp.Operation.INTERSECT:
			return CSGShape3D.OPERATION_INTERSECTION
	return CSGShape3D.OPERATION_UNION


static func _shape_node(solid: Solid, operation: CSGShape3D.Operation) -> CSGMesh3D:
	var node := CSGMesh3D.new()
	node.mesh = _to_mesh(solid)
	node.operation = operation
	return node


# One surface per tag, each with that tag's placeholder material.
static func _to_mesh(solid: Solid) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var by_tag := {}
	for t in solid.tags.size():
		var tag := solid.tags[t]
		if not by_tag.has(tag):
			by_tag[tag] = []
		(by_tag[tag] as Array).append(t)
	var has_uv := solid.uvs.size() == solid.positions.size()
	for tag: int in by_tag:
		var tag_indices := PackedInt32Array()
		for t: int in by_tag[tag]:
			tag_indices.append_array([solid.indices[t * 3], solid.indices[t * 3 + 1], solid.indices[t * 3 + 2]])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = solid.positions
		if has_uv:
			arrays[Mesh.ARRAY_TEX_UV] = solid.uvs
		arrays[Mesh.ARRAY_INDEX] = tag_indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material_for(tag))
	return mesh


static func _material_for(tag: int) -> Material:
	_lock.lock()
	var material: Material = _tag_materials.get(tag)
	if material == null:
		material = StandardMaterial3D.new()
		material.resource_name = "tag_%d" % tag
		_tag_materials[tag] = material
		_material_tags[material] = tag
	_lock.unlock()
	return material


static func _tag_of(material: Material) -> int:
	_lock.lock()
	var tag: int = _material_tags.get(material, 0)
	_lock.unlock()
	return tag
