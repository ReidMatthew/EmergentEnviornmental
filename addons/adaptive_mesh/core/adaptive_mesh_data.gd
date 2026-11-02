@tool
class_name AdaptiveMeshData
extends Resource
## What an [AdaptiveMesh] is made of: its pieces' shapes and ready-to-draw meshes, and
## how they were cut. Made by baking (see [method AdaptiveMesh.bake]); edits update it,
## so saving it (as a [code].res[/code]) keeps them. Loading it skips baking.
##
## Nodes using the same data share it until one of them is edited: that node then works on
## its own copy (see [method copy]).

## Each piece's shape by key: [code](x, y, z, depth)[/code]. Depth 0 is a cell of the
## chunking ([code](0, 0, 0, 0)[/code] when there's none); a cell split because its piece
## grew too big (see [member Chunking.split_above]) has children one depth down, halving
## it along every axis the chunking cuts, at [code](x * 2 + 0 or 1, ..., depth + 1)[/code].
@export var pieces: Dictionary[Vector4i, Solid] = {}
## Each piece's drawn mesh, one surface per drawn tag (named [code]tag_<n>[/code]), so a
## piece shows without building anything. Missing entries are built when needed.
@export var meshes: Dictionary[Vector4i, ArrayMesh] = {}
## Cells that have been split: their pieces live in their children.
@export var split_keys: Dictionary[Vector4i, bool] = {}
## The chunking the pieces were cut with (a copy), or null for one piece.
@export var chunking: Chunking
## Where pieces may exist and unions may build, in the mesh's space. Empty: anywhere.
@export var region := AABB()
## How far pieces reach along axes the chunking doesn't split (and the whole piece when
## there's no chunking): the source's bounds, grown.
@export var extent := AABB()
## Materials by tag, from the source. [member PieceDrawing.materials] overrides them.
@export var materials: Array[Material] = []
## What it was baked from (source, chunking and bounds), so the editor can tell when it's
## out of date. Empty: unknown.
@export var fingerprint := ""


## True once baked (even if the source was empty).
func is_baked() -> bool:
	return not pieces.is_empty() or extent.has_volume()


## A copy whose piece lists can be changed without touching this one (the shapes and
## meshes themselves are shared until replaced, which edits do).
func copy() -> AdaptiveMeshData:
	var out := AdaptiveMeshData.new()
	out.pieces = pieces.duplicate()
	out.meshes = meshes.duplicate()
	out.split_keys = split_keys.duplicate()
	out.chunking = chunking
	out.region = region
	out.extent = extent
	out.materials = materials.duplicate()
	out.fingerprint = fingerprint
	return out


## This data as one piece without chunking: the pieces joined, the walls between them (the
## faces tagged [method get_cap_tag]) gone and the seams welded. For an object smaller
## than a chunk that straddles cell corners, which is then one piece instead of several.
## Null if the pieces don't join up closed. Meshes aren't kept (the piece draws itself).
##
## Each side of a wall was cut separately, so corners on the seam can differ by float
## noise: corners within [param tolerance] (0: a millionth of [member extent]'s size) are
## made one.
func merged(tolerance: float = 0.0) -> AdaptiveMeshData:
	if tolerance <= 0.0:
		tolerance = maxf(extent.get_longest_axis_size(), 1.0) * 2e-6
	var cap := get_cap_tag()
	if NativeKernel.on():
		var arrays := []
		for solid: Solid in pieces.values():
			arrays.append([solid.positions, solid.indices, solid.tags, solid.uvs])
		var native: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"merged_solid", arrays, cap, tolerance)
		return _merged_data(NativeKernel.to_solid(native)) if not native.is_empty() else null
	var joined := Solid.new()
	var has_uv := pieces.values().all(func(solid: Solid) -> bool: return solid.uvs.size() == solid.positions.size())
	for key: Vector4i in pieces:
		var solid: Solid = pieces[key]
		var base := joined.positions.size()
		joined.positions.append_array(solid.positions)
		if has_uv:
			joined.uvs.append_array(solid.uvs)
		for t in solid.tags.size():
			if solid.tags[t] == cap:
				continue
			joined.indices.append_array([base + solid.indices[t * 3], base + solid.indices[t * 3 + 1],
					base + solid.indices[t * 3 + 2]])
			joined.tags.append(solid.tags[t])
	joined.remove_unused()
	_snap_seams(joined, tolerance)
	joined.weld()
	if joined.count_open_edges() > 0:
		joined.fix_t_junctions(tolerance * 10.0)
		joined.weld()
	if joined.is_empty() or joined.count_open_edges() > 0:
		return null
	return _merged_data(joined)


func _merged_data(joined: Solid) -> AdaptiveMeshData:
	var out := AdaptiveMeshData.new()
	out.pieces[Vector4i.ZERO] = joined
	out.region = region
	out.extent = extent
	out.materials = materials.duplicate()
	return out


# Moves the corners of [param solid]'s open edges (matched by position) that are within
# [param tolerance] of each other onto one position.
static func _snap_seams(solid: Solid, tolerance: float) -> void:
	if NativeKernel.on():
		solid.positions = ClassDB.class_call_static(NativeKernel.CLASS, &"snap_seams", solid.positions, solid.indices,
				tolerance)
		return
	var directed := {}
	for t in solid.indices.size() / 3:
		for k in 3:
			directed[[solid.positions[solid.indices[t * 3 + k]], solid.positions[solid.indices[t * 3 + (k + 1) % 3]]]] = true
	var on_seam := {}  # position -> true
	for edge: Array in directed:
		if not directed.has([edge[1], edge[0]]):
			on_seam[edge[0]] = true
			on_seam[edge[1]] = true
	var grid := {}  # Vector3i -> positions kept there
	var moved := {}  # position -> the position it becomes
	for p: Vector3 in on_seam:
		var home := Vector3i((p / tolerance).round())
		var found := p
		for o in 27:
			for q: Vector3 in grid.get(home + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1), []):
				if q.distance_to(p) <= tolerance:
					found = q
					break
			if found != p:
				break
		if found == p:
			if not grid.has(home):
				grid[home] = []
			(grid[home] as Array).append(p)
		else:
			moved[p] = found
	for v in solid.positions.size():
		if moved.has(solid.positions[v]):
			solid.positions[v] = moved[solid.positions[v]]


## The key of chunking cell [param cell] (depth 0).
static func cell_key(cell: Vector3i) -> Vector4i:
	return Vector4i(cell.x, cell.y, cell.z, 0)


## The box of [param key]. The whole [member extent] without chunking.
func get_cell(key: Vector4i) -> AABB:
	if chunking == null:
		return extent
	var depth := key.w
	var base := chunking.get_cell(Vector3i(key.x >> depth, key.y >> depth, key.z >> depth), extent)
	if depth == 0:
		return base
	var parts := 1 << depth
	var box := base
	for axis in 3:
		if chunking.cuts_axis(axis):
			var size := base.size[axis] / parts
			box.position[axis] = base.position[axis] + (key[axis] - ((key[axis] >> depth) << depth)) * size
			box.size[axis] = size
	return box


## The keys one depth down from [param key], halving it along every axis the chunking cuts.
func get_children(key: Vector4i) -> Array[Vector4i]:
	var out: Array[Vector4i] = [Vector4i(key.x * 2, key.y * 2, key.z * 2, key.w + 1)]
	for axis in 3:
		if chunking == null or not chunking.cuts_axis(axis):
			continue
		for k in out.size():
			var other := out[k]
			other[axis] += 1
			out.append(other)
	return out


## True if [param key] lies inside [param ancestor] (a split cell above it).
static func is_inside(key: Vector4i, ancestor: Vector4i) -> bool:
	var up := key.w - ancestor.w
	return up > 0 and Vector3i(key.x >> up, key.y >> up, key.z >> up) == Vector3i(ancestor.x, ancestor.y, ancestor.z)


## Pieces' cells overlapping [param box], one key per place: a piece, or a cell where a
## union may create one. Split cells are replaced by their children.
func keys_overlapping(box: AABB) -> Array[Vector4i]:
	var out: Array[Vector4i] = []
	if chunking == null:
		out.append(Vector4i.ZERO)
		return out
	for cell in chunking.keys_overlapping(box):
		_leaves(cell_key(cell), box, out)
	return out


## Pieces' cells touching [param key]'s (sharing a side, edge or corner), resolved through
## splits like [method keys_overlapping]. None without chunking.
func neighbour_keys(key: Vector4i) -> Array[Vector4i]:
	var out: Array[Vector4i] = []
	if chunking == null:
		return out
	var box := get_cell(key).grow(1e-4)
	var base := Vector3i(key.x >> key.w, key.y >> key.w, key.z >> key.w)
	var cells: Array[Vector3i] = [base]
	cells.append_array(chunking.neighbour_keys(base))
	for cell in cells:
		var top := Vector4i(cell.x, cell.y, cell.z, 0)
		if split_keys.has(top):
			_leaves(top, box, out)
		else:
			out.append(top)  # (as _leaves would: the usual case, made quick)
	out.erase(key)
	return out


## Tag of the faces that close pieces off where they meet; -1 without chunking.
func get_cap_tag() -> int:
	return chunking.cap_tag if chunking != null else -1


# Adds [param key] to [param out], or, if it was split, its children overlapping
# [param box], recursively. (Whether [param key] itself overlaps is the caller's call.)
func _leaves(key: Vector4i, box: AABB, out: Array[Vector4i]) -> void:
	if not split_keys.has(key):
		out.append(key)
		return
	for child in get_children(key):
		if get_cell(child).intersects(box):
			_leaves(child, box, out)
