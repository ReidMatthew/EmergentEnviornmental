@tool
class_name SceneSource
extends SolidSource
## An imported scene (a .glb, .gltf, .fbx or .tscn) as the source: every [MeshInstance3D]
## in it, placed where the scene puts it, combined into one solid with one tag per material.
##
## Models made only for rendering usually aren't solids. The repair options fix the usual
## problems, in this order:
## - [member merge_tolerance]: pieces whose borders don't quite meet (terrain exported one
##   piece per material).
## - [member fix_t_junctions]: borders where one side has a vertex the other doesn't.
## - [member close_to_floor]: an open sheet (a terrain's top surface only), closed with
##   walls down to a flat floor.
## Check the console: building the solid reports what it did, and warns if the result still
## isn't closed.

## The scene to read.
@export var scene: PackedScene:
	set(value):
		scene = value
		emit_changed()
## Only meshes under this node (a path from the scene's root). Empty reads the whole scene.
@export var root_path := NodePath():
	set(value):
		root_path = value
		emit_changed()
## Meshes whose names start with any of these are skipped. The defaults are the usual
## collision-mesh prefixes (UCX_ and friends), which duplicate the visible ones.
@export var skip_prefixes := PackedStringArray(["UCX_", "UBX_", "UCP_", "USP_"]):
	set(value):
		skip_prefixes = value
		emit_changed()
## Scales the whole model so it is this wide (along x). 0 keeps its size.
@export_range(0.0, 10000.0, 0.01, "or_greater") var width := 0.0:
	set(value):
		width = value
		emit_changed()
## Vertices closer than this (after scaling) are merged. 0 merges only exact matches.
@export_range(0.0, 1.0, 0.0001, "or_greater") var merge_tolerance := 0.0:
	set(value):
		merge_tolerance = value
		emit_changed()
## Splits open edges where another piece's vertex lies on them, within
## [member merge_tolerance].
@export var fix_t_junctions := false:
	set(value):
		fix_t_junctions = value
		emit_changed()
@export_group("Close to Floor")
## Closes an open, upward-facing sheet with walls straight down to a flat floor.
@export var close_to_floor := false:
	set(value):
		close_to_floor = value
		emit_changed()
## How far below the lowest point the floor goes: deeper than anything will dig.
@export_range(0.0, 1000.0, 0.01, "or_greater") var floor_depth := 10.0:
	set(value):
		floor_depth = value
		emit_changed()
## Material of the walls and floor (they get the tag after the scene's materials). Empty
## uses the scene's first material.
@export var floor_material: Material:
	set(value):
		floor_material = value
		emit_changed()


func _build() -> Solid:
	if scene == null:
		return Solid.new()
	var root := scene.instantiate()
	var from: Node = root.get_node_or_null(root_path) if not root_path.is_empty() else root
	if from == null:
		push_warning("SceneSource: no node at %s." % root_path)
		root.free()
		return Solid.new()
	var solid := _build_from(root, from, scene.resource_path.get_file())
	root.free()
	return solid


# Combines the meshes under [param from] (placed relative to [param root]), then scales and
# repairs the result. [param label] names it in the report.
func _build_from(root: Node, from: Node, label: String) -> Solid:
	var solid := Solid.new()
	var tag_of := {}  # Material (or null) -> tag
	var instances: Array[MeshInstance3D] = []
	_collect(from, instances)
	for instance in instances:
		var surface_tags := PackedInt32Array()
		for s in instance.mesh.get_surface_count():
			var material := instance.get_active_material(s)
			if not tag_of.has(material):
				tag_of[material] = _cached_materials.size()
				_cached_materials.append(material)
			surface_tags.append(tag_of[material])
		var piece := Solid.from_mesh(instance.mesh, 0, 0.0).transformed(_transform_to(root, instance))
		for t in piece.tags.size():
			piece.tags[t] = surface_tags[piece.tags[t]]
		_append(solid, piece)
	var box := solid.get_aabb()
	if width > 0.0 and box.size.x > 0.0:
		var factor := width / box.size.x
		for i in solid.positions.size():
			solid.positions[i] *= factor
	var report := PackedStringArray(["%d meshes, %d materials, %d triangles" % [instances.size(),
			_cached_materials.size(), solid.get_triangle_count()]])
	if merge_tolerance > 0.0:
		report.append("%d vertices merged" % solid.merge_close(merge_tolerance))
	else:
		solid.weld()
	if fix_t_junctions:
		report.append("%d T-junctions split" % solid.fix_t_junctions(maxf(merge_tolerance, 1e-6)))
	if close_to_floor:
		var floor_tag := _cached_materials.size()
		_cached_materials.append(floor_material if floor_material != null
				else (_cached_materials[0] if not _cached_materials.is_empty() else null))
		var closed := solid.close_to_floor(solid.get_aabb().position.y - floor_depth, floor_tag)
		report.append("closed to a floor" if closed else "couldn't close to a floor")
	var open := solid.count_open_edges()
	print("%s (%s): %s." % [get_script().get_global_name(), label, ", ".join(report)])
	if open > 0:
		push_warning("%s (%s): the result has %d open edges, so booleans will fail on it. Try a "
				% [get_script().get_global_name(), label, open] + "bigger merge_tolerance, fix_t_junctions or close_to_floor.")
	return solid


# The visible meshes under [param node], minus collision meshes ([member skip_prefixes]) and
# anything an [AdaptiveMesh] draws.
func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is AdaptiveMesh:
		return
	var instance := node as MeshInstance3D
	if instance != null and instance.mesh != null:
		var skip := false
		for prefix in skip_prefixes:
			if not prefix.is_empty() and String(instance.name).begins_with(prefix):
				skip = true
		if not skip:
			out.append(instance)
	for child in node.get_children():
		var skip_branch := false
		for prefix in skip_prefixes:
			if not prefix.is_empty() and String(child.name).begins_with(prefix):
				skip_branch = true
		if not skip_branch:
			_collect(child, out)


# [param node]'s transform relative to [param root].
static func _transform_to(root: Node, node: Node3D) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var n: Node = node
	while n != root and n != null:
		if n is Node3D:
			xform = (n as Node3D).transform * xform
		n = n.get_parent()
	return xform


static func _append(solid: Solid, other: Solid) -> void:
	var base := solid.positions.size()
	solid.positions.append_array(other.positions)
	for i in other.indices:
		solid.indices.append(base + i)
	solid.tags.append_array(other.tags)
