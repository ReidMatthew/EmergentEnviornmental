@tool
class_name MesherTransition
extends RefCounted
## Full-resolution samples for one face of a [MesherGrid]'s cell range, where the
## neighbouring chunk has twice the grid's resolution. Meshers fill that face with
## Transvoxel transition cells (see [TransvoxelTables]) so the surface meets the
## neighbour's exactly, and shrink the grid's last layer of cells next to the face by
## [member MesherGrid.transition_width] to make room.
##
## The samples cover the face at half the grid spacing, plus one sample of padding around
## it, in three layers: just below the face, on it, and just above it along the face's
## axis (the outer layers are only read for normals). In face coordinates, i runs along
## [method axes] u and j along v, both from -1 to 2 x cells + 1; sample (i, j) of the face
## layer sits at [code]cell_begin + (i / 2, j / 2)[/code] on the face.

## Which face, as [code]axis * 2 + (1 if high else 0)[/code]: the bit index of
## [method MesherSkirts.face_bit].
var face := 0
## Samples, (2 x cells along u + 3) x (2 x cells along v + 3) x 3, i fastest, then j, then
## the layer (below, on, above the face along its axis). Bytes decode with the grid's
## [member MesherGrid.byte_center] and [member MesherGrid.byte_scale].
var bytes := PackedByteArray()
## Material id per sample of the face layer, (2 x cells along u + 3) x (2 x cells along v
## + 3), indexed by [method face_index_of]. Empty for material 0 everywhere.
var materials := PackedByteArray()


## Axes of [param face] as (w, u, v): w is the face's own axis, u and v run along it. u, v
## and the direction into the cell range are right-handed for every face.
static func axes(face_index: int) -> Vector3i:
	var w := face_index >> 1
	var u := (w + 1) % 3
	var v := (w + 2) % 3
	if face_index & 1:
		return Vector3i(w, v, u)
	return Vector3i(w, u, v)


## Samples per row and column of a face of [param grid] (padding included).
static func dimensions(grid: MesherGrid, face_index: int) -> Vector2i:
	var a := axes(face_index)
	var end := grid.get_cell_end()
	return Vector2i(2 * (end[a.y] - grid.cell_begin[a.y]) + 3, 2 * (end[a.z] - grid.cell_begin[a.z]) + 3)


## Index into [member materials] of face sample (i, j) (each from -1).
static func face_index_of(dims: Vector2i, i: int, j: int) -> int:
	return (i + 1) + dims.x * (j + 1)


## Index into [member bytes] of face sample (i, j) (each from -1) in [param layer] (-1 below
## the face, 0 on it, 1 above).
static func index_of(dims: Vector2i, i: int, j: int, layer: int) -> int:
	return (i + 1) + dims.x * ((j + 1) + dims.y * (layer + 1))


## [param grid]'s transitions packed for the GPU shaders (transition.glslinc): a header of
## four uints per face (present, first word of its samples, first word of its material ids,
## row and column sizes as two 16-bit halves), then the faces' bytes, each padded to whole
## uints.
static func gpu_data(grid: MesherGrid) -> PackedByteArray:
	var header := PackedInt32Array()
	header.resize(24)
	var body := PackedByteArray()
	for t in grid.transitions:
		var dims := dimensions(grid, t.face)
		var samples := t.bytes.duplicate()
		samples.resize(ceili(samples.size() / 4.0) * 4)
		var ids := t.materials.duplicate()
		ids.resize(ceili(dims.x * dims.y / 4.0) * 4)  # zeros when there are none
		header[t.face * 4] = 1
		header[t.face * 4 + 1] = 24 + body.size() / 4
		body.append_array(samples)
		header[t.face * 4 + 2] = 24 + body.size() / 4
		body.append_array(ids)
		header[t.face * 4 + 3] = dims.x | (dims.y << 16)
	return header.to_byte_array() + body


## Bytes [method gpu_data] needs at most for grids up to [param side] samples along each axis.
static func gpu_data_capacity(side: int) -> int:
	var dims := 2 * side + 3
	return 96 + 6 * (ceili(dims * dims * 3 / 4.0) * 4 + ceili(dims * dims / 4.0) * 4)
