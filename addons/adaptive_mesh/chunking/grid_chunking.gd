@tool
class_name GridChunking
extends Chunking
## Cuts the mesh into a regular grid of cells, [member cell_size] apart. For terrain,
## (16, 0, 16) gives columns.
##
## Where you can, put cell walls along edges the source already has (for a mesh authored on
## a grid: a cell size that is a multiple of its spacing, [member offset] onto a grid line):
## the cut then adds no triangles, where a wall through the middle of triangles adds a row
## of them along it. Keep walls off large flat faces of the source (a flat floor exactly on
## a wall is ambiguous to cut).

## Size of a cell. 0 on an axis doesn't cut along it: cells span the whole mesh that way.
## All zero is one piece.
@export var cell_size := Vector3(16, 0, 16):
	set(value):
		cell_size = value
		_steps = _neighbour_steps()
## Moves the grid.
@export var offset := Vector3.ZERO

var _steps: Array[Vector3i] = _neighbour_steps()


func get_cell(key: Vector3i, extent: AABB) -> AABB:
	var cell := AABB()
	for axis in 3:
		if cell_size[axis] > 0.0:
			cell.position[axis] = offset[axis] + key[axis] * cell_size[axis]
			cell.size[axis] = cell_size[axis]
		else:
			cell.position[axis] = extent.position[axis]
			cell.size[axis] = extent.size[axis]
	return cell


func keys_overlapping(box: AABB) -> Array[Vector3i]:
	var from := Vector3i.ZERO
	var to := Vector3i.ZERO
	for axis in 3:
		if cell_size[axis] > 0.0:
			from[axis] = floori((box.position[axis] - offset[axis]) / cell_size[axis])
			to[axis] = floori((box.end[axis] - offset[axis]) / cell_size[axis])
	var keys: Array[Vector3i] = []
	for z in range(from.z, to.z + 1):
		for y in range(from.y, to.y + 1):
			for x in range(from.x, to.x + 1):
				keys.append(Vector3i(x, y, z))
	return keys


func neighbour_keys(key: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for step in _steps:
		out.append(key + step)
	return out


# The steps to the neighbouring cells (along the cut axes only), worked out when
# [member cell_size] is set: neighbour_keys is called for every piece of every part.
func _neighbour_steps() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var step := Vector3i(x, y, z)
				if step == Vector3i.ZERO:
					continue
				var along_cut_axes := true
				for axis in 3:
					if step[axis] != 0 and not cuts_axis(axis):
						along_cut_axes = false
				if along_cut_axes:
					out.append(step)
	return out


func cuts_axis(axis: int) -> bool:
	return cell_size[axis] > 0.0


# Cuts the source in half along its longest run of cells, then each half the same way,
# until every piece is one cell. Each cut only works on the piece it halves, so the whole
# split costs about the source's size times the number of halvings, instead of times the
# number of cells; with the CSG backend, every cut at one depth happens in the same frame.
func split(source: Solid, extent: AABB, backend: BooleanBackend) -> Dictionary:
	var results := {}
	var keys := keys_overlapping(source.get_aabb())
	var remaining := [1]  # unfinished pieces
	_split_range(source, source.get_aabb(), extent, keys[0], keys[-1], backend, results, remaining)
	var tree := Engine.get_main_loop() as SceneTree
	while remaining[0] > 0:
		await tree.process_frame
	return results


# Not awaited by the caller: both halves run at once.
func _split_range(piece: Solid, source_box: AABB, extent: AABB, from: Vector3i, to: Vector3i,
		backend: BooleanBackend, results: Dictionary, remaining: Array) -> void:
	var counts := to - from + Vector3i.ONE
	if counts == Vector3i.ONE:
		if not piece.is_empty():
			results[from] = piece
		remaining[0] -= 1
		return
	var axis := 0
	for a in 3:
		if counts[a] > counts[axis]:
			axis = a
	var middle := from[axis] + counts[axis] / 2
	var first_to := to
	first_to[axis] = middle - 1
	var second_from := from
	second_from[axis] = middle
	remaining[0] += 1  # two pieces replace this one
	for half: Array in [[from, first_to], [second_from, to]]:
		_cut_half(piece, source_box, extent, half[0], half[1], backend, results, remaining)


func _cut_half(piece: Solid, source_box: AABB, extent: AABB, from: Vector3i, to: Vector3i,
		backend: BooleanBackend, results: Dictionary, remaining: Array) -> void:
	var cut := get_cell(from, extent).merge(get_cell(to, extent))
	# Where the box meets the outside of the source, push it out, so it never lies exactly
	# on one of the source's outer faces. (Walls between cells may lie on the piece's
	# earlier caps; those have the same tag, so it doesn't matter which one survives.)
	for axis in 3:
		var start := cut.position[axis]
		var end := cut.end[axis]
		var margin := 1.0 + cut.size[axis] * 0.01
		if start <= source_box.position[axis]:
			start = source_box.position[axis] - margin
		if end >= source_box.end[axis]:
			end = source_box.end[axis] + margin
		cut.position[axis] = start
		cut.size[axis] = end - start
	var box := BoxMesh.new()
	box.size = cut.size
	var box_solid := Solid.from_mesh(box)
	box_solid.uvs = PackedVector2Array()
	box_solid.weld()
	box_solid.tags.fill(cap_tag)
	var ops: Array[BooleanOp] = [BooleanOp.create(box_solid, Transform3D(Basis(), cut.get_center()),
			BooleanOp.Operation.INTERSECT)]
	var half: Solid = await backend.combine(piece, ops, AABB(), cap_tag)
	if half == null or half.is_empty():
		remaining[0] -= 1
		return
	_split_range(half, source_box, extent, from, to, backend, results, remaining)
