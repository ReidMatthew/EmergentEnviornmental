@tool
class_name MesherSkirts
extends RefCounted
## Seam skirts: a short strip of extra triangles hanging from every mesh edge that lies on
## the boundary of the polygonised cell range, along the reversed surface normal. Chunks of
## the same resolution share their boundary vertices exactly, but each is drawn with its
## own transform, so rounding can let single pixels through the seam between them; the
## strips cover that. (Chunks of different resolutions are joined by transition cells, see
## [MesherTransition].)
##
## Skirts are double-sided (each quad is emitted with both windings) because which side
## faces the camera depends on the view, not on the surface orientation. Skirt vertices
## copy the normal and material of the edge they hang from, so they shade like the surface.

## Bit for each boundary face of the cell range: 1 << (axis * 2 + (0 low, 1 high)).
static func face_bit(axis: int, high: bool) -> int:
	return 1 << (axis * 2 + (1 if high else 0))


## Boundary faces the grid edge from sample [param p] along [param axis] lies on.
static func edge_face_mask(grid: MesherGrid, p: Vector3i, axis: int) -> int:
	var begin := grid.cell_begin
	var end := grid.get_cell_end()
	var mask := 0
	for f in 3:
		if f == axis:
			continue
		if p[f] == begin[f]:
			mask |= face_bit(f, false)
		elif p[f] == end[f]:
			mask |= face_bit(f, true)
	return mask


## Appends skirts [member MesherGrid.skirt_depth] deep to [param mesh] (built from
## [param grid]). [param masks] gives each vertex's boundary faces (see
## [method edge_face_mask]); when empty they're worked out from vertex positions.
static func add(mesh: MeshData, grid: MesherGrid, masks: PackedInt32Array = PackedInt32Array()) -> void:
	var depth := grid.skirt_depth
	if depth <= 0.0 or mesh.is_empty():
		return
	if masks.size() != mesh.vertices.size():
		masks = _masks_from_positions(mesh, grid)
	var vertices := mesh.vertices
	var normals := mesh.normals
	var colors := mesh.colors
	var indices := mesh.indices
	var has_colors := colors.size() == vertices.size()
	var triangle_end := indices.size()
	for t in range(0, triangle_end, 3):
		for e in 3:
			var a := indices[t + e]
			var b := indices[t + (e + 1) % 3]
			if masks[a] & masks[b] == 0:
				continue
			var a2 := vertices.size()
			var b2 := a2 + 1
			vertices.append(vertices[a] - normals[a] * depth)
			vertices.append(vertices[b] - normals[b] * depth)
			normals.append(normals[a])
			normals.append(normals[b])
			if has_colors:
				colors.append(colors[a])
				colors.append(colors[b])
			indices.append_array(PackedInt32Array([a, b, b2, a, b2, a2, a, b2, b, a, a2, b2]))
	mesh.vertices = vertices
	mesh.normals = normals
	mesh.colors = colors
	mesh.indices = indices


static func _masks_from_positions(mesh: MeshData, grid: MesherGrid) -> PackedInt32Array:
	var begin := Vector3(grid.cell_begin)
	var end := Vector3(grid.get_cell_end())
	var eps := 1e-3
	var masks := PackedInt32Array()
	masks.resize(mesh.vertices.size())
	for i in mesh.vertices.size():
		var s := (mesh.vertices[i] - grid.origin) / grid.spacing
		var mask := 0
		for f in 3:
			if absf(s[f] - begin[f]) < eps:
				mask |= face_bit(f, false)
			elif absf(s[f] - end[f]) < eps:
				mask |= face_bit(f, true)
		masks[i] = mask
	return masks
