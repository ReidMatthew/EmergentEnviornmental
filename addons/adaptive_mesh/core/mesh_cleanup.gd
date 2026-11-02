@tool
class_name MeshCleanup
extends Resource
## Tidies the triangles an edit made: collapses short edges and needle-shaped slivers, and
## flips edges to fatten cap-shaped slivers, without changing the shape by more than
## [member max_error]. Give it to [member AdaptiveMesh.cleanup]; it runs on a worker
## thread after every batch of booleans.
##
## Only triangles the edit created can change (plus [member unlock_rings] rings of old
## triangles around them), so untouched parts keep their exact triangles. Sharp creases and
## lines where tags meet are kept: vertices on them only slide along them. Vertices on the
## mesh's [member AdaptiveMesh.bounds] never move, so pieces that meet there stay joined.
## Removed vertices are always merged into a neighbour, so no new positions appear.
##
## Override [method clean] for a different cleanup (for example a native simplifier).

## Edges shorter than this (in the solid's units) are collapsed when the shape allows.
@export_range(0.0, 10.0, 0.001, "or_greater") var min_edge_length := 0.1
## Triangles with an angle under this (degrees) count as slivers: their shortest edge is
## collapsed or their longest edge flipped when the shape allows.
@export_range(0.0, 60.0, 0.1) var sliver_angle := 15.0
## How far (in the solid's units) a removed vertex may lie from the surface that replaces
## it. Bigger cleans more but flattens curved cuts.
@export_range(0.0, 1.0, 0.0001, "or_greater") var max_error := 0.02
## Edges bending more than this (degrees), and edges where tags meet, are features: they
## are never flipped, and vertices on them only slide along them.
@export_range(0.0, 180.0, 0.1) var feature_angle := 35.0
## Faces around a collapse may turn by at most this much (degrees).
@export_range(0.0, 90.0, 0.1) var max_normal_change := 30.0
## Rings of untouched triangles around the edit that may change too. 0 keeps every
## triangle the edit didn't make exactly as it was; 1-2 lets the cleanup also fix the long
## thin triangles where a cut meets the old surface.
@export_range(0, 4) var unlock_rings := 0
## Rounds of collapsing and flipping. Each round only runs if the last one changed
## something.
@export_range(1, 10) var passes := 3


## Returns a tidied copy of [param solid]. [param before] is the solid before the edit
## (null treats every triangle as new); [param bounds] (if it has a size) marks vertices
## that must not move. Safe to call from a worker thread.
func clean(solid: Solid, before: Solid, bounds: AABB) -> Solid:
	var started := StageProfile.begin()
	var out := _clean_work(solid, before, bounds)
	StageProfile.end(&"cleanup", started)
	return out


func _clean_work(solid: Solid, before: Solid, bounds: AABB) -> Solid:
	if NativeKernel.on():
		var has_before := before != null
		return NativeKernel.to_solid(ClassDB.class_call_static(NativeKernel.CLASS, &"clean", solid.positions,
				solid.indices, solid.tags, solid.uvs, has_before,
				before.positions if has_before else PackedVector3Array(),
				before.indices if has_before else PackedInt32Array(), bounds,
				PackedFloat64Array([min_edge_length, sliver_angle, max_error, feature_angle, max_normal_change,
				unlock_rings, passes])))
	var work := _Work.new(solid, self)
	work.mark_modifiable(before, unlock_rings)
	work.lock_bounds(bounds)
	for i in passes:
		var changed := work.collapse_pass()
		changed += work.flip_pass()
		if changed == 0:
			break
	return work.result()


class _Work:
	var settings: MeshCleanup
	var positions: PackedVector3Array
	var uvs: PackedVector2Array
	var indices: PackedInt32Array
	var tags: PackedInt32Array
	var alive := PackedByteArray()
	var modifiable := PackedByteArray()  # per triangle
	var locked := PackedByteArray()  # per vertex
	# Triangles around each vertex: built for every vertex at once into flat arrays (start
	# offsets, then the list), and copied into an editable Array per vertex only when a
	# vertex near the edit is looked at, so untouched parts of the mesh cost almost nothing.
	var _around_start := PackedInt32Array()
	var _around := PackedInt32Array()
	var _vertex_triangles: Array = []  # vertex -> Array of triangles, or null until used
	var _unit := PackedVector3Array()  # triangle unit normals, valid where _unit_ok is set
	# Per vertex, cached until a collapse or flip changes the triangles around it: its
	# neighbours (Dictionary), and how many of its edges are features plus the neighbours
	# across them ([count, PackedInt32Array]).
	var _neighbour_cache: Array = []
	var _feature_cache: Array = []
	var _unit_ok := PackedByteArray()
	var cos_normal_change: float
	var cos_feature: float

	func _init(solid: Solid, from: MeshCleanup) -> void:
		settings = from
		positions = solid.positions.duplicate()
		uvs = solid.uvs.duplicate()
		indices = solid.indices.duplicate()
		tags = solid.tags.duplicate()
		var count := indices.size() / 3
		var vertex_count := positions.size()
		alive.resize(count)
		alive.fill(1)
		modifiable.resize(count)
		_unit.resize(count)
		_unit_ok.resize(count)
		locked.resize(vertex_count)
		_vertex_triangles.resize(vertex_count)
		_neighbour_cache.resize(vertex_count)
		_feature_cache.resize(vertex_count)
		_around_start.resize(vertex_count + 1)
		for v in indices:
			_around_start[v + 1] += 1
		for v in vertex_count:
			_around_start[v + 1] += _around_start[v]
		_around.resize(indices.size())
		var fill := _around_start.duplicate()
		for i in indices.size():
			var v := indices[i]
			_around[fill[v]] = i / 3
			fill[v] += 1
		cos_normal_change = cos(deg_to_rad(from.max_normal_change))
		cos_feature = cos(deg_to_rad(from.feature_angle))

	# The triangles around [param v], in triangle order; editable.
	func _tris(v: int) -> Array:
		var list: Variant = _vertex_triangles[v]
		if list == null:
			var made := []
			for k in range(_around_start[v], _around_start[v + 1]):
				made.append(_around[k])
			_vertex_triangles[v] = made
			return made
		return list

	# Triangles not in [param before] (exact positions) can change, plus [param rings]
	# rings of neighbours. Then locks what mustn't move among the vertices that could.
	func mark_modifiable(before: Solid, rings: int) -> void:
		var count := indices.size() / 3
		if before == null:
			modifiable.fill(1)
		else:
			# Positions to ids (the first vertex at each position, so UV seams don't
			# count), then triangles as one int each: their three ids, rotated to start at
			# the smallest so the winding counts.
			var ids := {}
			for p in before.positions:
				if not ids.has(p):
					ids[p] = ids.size()
			var old := {}
			for t in before.indices.size() / 3:
				old[_key(ids[before.positions[before.indices[t * 3]]], ids[before.positions[before.indices[t * 3 + 1]]],
						ids[before.positions[before.indices[t * 3 + 2]]])] = true
			var old_id := PackedInt32Array()
			old_id.resize(positions.size())
			for v in positions.size():
				old_id[v] = ids.get(positions[v], -1)
			for t in count:
				var a := old_id[indices[t * 3]]
				var b := old_id[indices[t * 3 + 1]]
				var c := old_id[indices[t * 3 + 2]]
				modifiable[t] = 0 if a >= 0 and b >= 0 and c >= 0 and old.has(_key(a, b, c)) else 1
			for r in rings:
				var grow := PackedInt32Array()
				for t in count:
					if not modifiable[t]:
						continue
					for c in 3:
						for other: int in _tris(indices[t * 3 + c]):
							if not modifiable[other]:
								grow.append(other)
				for t in grow:
					modifiable[t] = 1
		# Vertices on an edge that isn't shared by exactly two triangles (UV seams, holes)
		# are left alone: the mesh isn't a simple closed surface there. Only vertices of
		# triangles that can change are ever moved, so only they are checked.
		var checked := PackedByteArray()
		checked.resize(positions.size())
		var seen := {}
		for t in count:
			if not modifiable[t]:
				continue
			for c in 3:
				var v := indices[t * 3 + c]
				if checked[v]:
					continue
				checked[v] = 1
				seen.clear()
				for other: int in _tris(v):
					for k in 3:
						var n := indices[other * 3 + k]
						if n != v:
							seen[n] = seen.get(n, 0) + 1
				for n: int in seen:
					if seen[n] != 2:
						locked[v] = 1
						break

	func lock_bounds(bounds: AABB) -> void:
		if not bounds.has_volume():
			return
		for v in positions.size():
			var p := positions[v]
			for axis in 3:
				if absf(p[axis] - bounds.position[axis]) < 1e-4 or absf(p[axis] - bounds.end[axis]) < 1e-4:
					locked[v] = 1

	# Collapses short edges and the shortest edge of slivers, shortest first (ties by
	# vertex, so the order doesn't depend on how the sort treats equal keys).
	func collapse_pass() -> int:
		var candidates := []
		var min_length := settings.min_edge_length
		var sliver := deg_to_rad(settings.sliver_angle)
		var lengths := PackedFloat64Array([0.0, 0.0, 0.0])
		for t in alive.size():
			if not alive[t] or not modifiable[t]:
				continue
			var i := t * 3
			var shortest := 0
			for c in 3:
				lengths[c] = positions[indices[i + c]].distance_to(positions[indices[i + (c + 1) % 3]])
				if lengths[c] < lengths[shortest]:
					shortest = c
			# The angle test is only needed when the shortest edge isn't short anyway.
			var is_sliver := lengths[shortest] >= min_length and _smallest_angle(t) < sliver
			for c in 3:
				if lengths[c] < min_length or (c == shortest and is_sliver):
					candidates.append([lengths[c], indices[i + c], indices[i + (c + 1) % 3]])
		candidates.sort()
		var done := 0
		# Each edge usually comes twice (once from each triangle), next to each other after
		# sorting: if nothing collapsed since the first was turned down, so is the second.
		var rejected := Vector2i(-1, -1)
		var rejected_at := -1
		for candidate: Array in candidates:
			var a: int = candidate[1]
			var b: int = candidate[2]
			var edge := Vector2i(mini(a, b), maxi(a, b))
			if edge == rejected and rejected_at == done:
				continue
			if _edge_triangles(a, b).size() != 2:
				continue  # already collapsed away
			var error_ab := _collapse_error(a, b)
			var error_ba := _collapse_error(b, a)
			if error_ab < 0.0 and error_ba < 0.0:
				rejected = edge
				rejected_at = done
				continue
			if error_ba >= 0.0 and (error_ab < 0.0 or error_ba < error_ab):
				_collapse(b, a)
			else:
				_collapse(a, b)
			done += 1
		return done

	# Flips the longest edge of slivers when that makes both triangles fatter.
	func flip_pass() -> int:
		var done := 0
		var sliver := deg_to_rad(settings.sliver_angle)
		for t in alive.size():
			if not alive[t] or not modifiable[t] or _smallest_angle(t) >= sliver:
				continue
			var longest := 0
			var longest_length := -1.0
			for c in 3:
				var length := positions[indices[t * 3 + c]].distance_to(positions[indices[t * 3 + (c + 1) % 3]])
				if length > longest_length:
					longest_length = length
					longest = c
			if _flip(indices[t * 3 + longest], indices[t * 3 + (longest + 1) % 3]):
				done += 1
		return done

	# How far [param a] lies from the surface left by moving it onto [param b], or -1 if
	# that collapse isn't allowed. Cheap checks first: most candidates fail the geometry.
	func _collapse_error(a: int, b: int) -> float:
		if locked[a]:
			return -1.0
		var around_a := _tris(a)
		for t: int in around_a:
			if not modifiable[t]:
				return -1.0
		var shared := _edge_triangles(a, b)
		if shared.size() != 2:
			return -1.0
		var max_error := settings.max_error
		var error := 0.0
		var pa := positions[a]
		var pb := positions[b]
		for t: int in around_a:
			if t == shared[0] or t == shared[1]:
				continue
			var i := t * 3
			var p0 := positions[indices[i]]
			var p1 := positions[indices[i + 1]]
			var p2 := positions[indices[i + 2]]
			var old_normal := _normal(p0, p1, p2)
			if indices[i] == a:
				p0 = pb
			elif indices[i + 1] == a:
				p1 = pb
			else:
				p2 = pb
			var new_normal := _normal(p0, p1, p2)
			if new_normal.length_squared() < 1e-12:
				return -1.0
			new_normal = new_normal.normalized()
			if old_normal.length_squared() > 0.0 and new_normal.dot(old_normal.normalized()) < cos_normal_change:
				return -1.0
			error = maxf(error, absf(new_normal.dot(pa - p0)))
			if error > max_error:
				return -1.0
		# Link condition: a and b may only share the two vertices across the edge, or the
		# collapse pinches the surface.
		var across_0 := _opposite(shared[0], a, b)
		var across_1 := _opposite(shared[1], a, b)
		var neighbours_a := _neighbours(a)
		for n: int in _neighbours(b):
			if n != a and neighbours_a.has(n) and n != across_0 and n != across_1:
				return -1.0
		# A vertex on a feature may only slide along it, onto the next feature vertex.
		var features := _features(a)
		var count: int = features[0]
		if count == 1 or count > 2 or (count == 2 and not (features[1] as PackedInt32Array).has(b)):
			return -1.0
		return error

	# [count, neighbours] of [param v]'s feature edges (creases, tag changes, and edges not
	# shared by exactly two triangles).
	func _features(v: int) -> Array:
		var cached: Variant = _feature_cache[v]
		if cached != null:
			return cached
		var across := PackedInt32Array()
		for n: int in _neighbours(v):
			var around_edge := _edge_triangles(v, n)
			if around_edge.size() != 2 or _is_feature(around_edge[0], around_edge[1]):
				across.append(n)
		var made := [across.size(), across]
		_feature_cache[v] = made
		return made

	# Forgets what's cached for the corners of triangle [param t].
	func _forget(t: int) -> void:
		for c in 3:
			var v := indices[t * 3 + c]
			_neighbour_cache[v] = null
			_feature_cache[v] = null

	func _collapse(a: int, b: int) -> void:
		for t: int in _tris(a):
			_forget(t)
		for t in _edge_triangles(a, b):
			alive[t] = 0
			for c in 3:
				_tris(indices[t * 3 + c]).erase(t)
		for t: int in _tris(a):
			for c in 3:
				if indices[t * 3 + c] == a:
					indices[t * 3 + c] = b
			_unit_ok[t] = 0
			_tris(b).append(t)
		_vertex_triangles[a] = []

	func _flip(a: int, b: int) -> bool:
		var shared := _edge_triangles(a, b)
		if shared.size() != 2:
			return false
		# t1 runs a -> b, t2 runs b -> a.
		var t1: int = shared[0]
		var t2: int = shared[1]
		if not _runs(t1, a, b):
			var swap := t1
			t1 = t2
			t2 = swap
		if not modifiable[t1] or not modifiable[t2] or tags[t1] != tags[t2] or _is_feature(t1, t2):
			return false
		var c := _opposite(t1, a, b)
		var d := _opposite(t2, a, b)
		if c == d or _neighbours(c).has(d):
			return false
		var n1 := _normal(positions[c], positions[a], positions[d])
		var n2 := _normal(positions[d], positions[b], positions[c])
		var old1 := _normal(positions[a], positions[b], positions[c]).normalized()
		var old2 := _normal(positions[b], positions[a], positions[d]).normalized()
		if n1.length_squared() < 1e-12 or n2.length_squared() < 1e-12:
			return false
		for n in [n1.normalized(), n2.normalized()]:
			if n.dot(old1) < cos_normal_change or n.dot(old2) < cos_normal_change:
				return false
		# How far the quad is from flat: the most the surface moves by flipping it.
		var tent := maxf(absf(old1.dot(positions[d] - positions[a])), absf(old2.dot(positions[c] - positions[a])))
		if tent > settings.max_error:
			return false
		var before := minf(_smallest_angle(t1), _smallest_angle(t2))
		var after := minf(_angle_of(positions[c], positions[a], positions[d]), _angle_of(positions[d], positions[b], positions[c]))
		if after <= before + 1e-3:
			return false
		# t1 becomes (c, a, d), t2 becomes (d, b, c).
		for t in [t1, t2]:
			for k in 3:
				_tris(indices[t * 3 + k]).erase(t)
		_unit_ok[t1] = 0
		_unit_ok[t2] = 0
		_forget(t1)
		_forget(t2)
		indices[t1 * 3] = c
		indices[t1 * 3 + 1] = a
		indices[t1 * 3 + 2] = d
		indices[t2 * 3] = d
		indices[t2 * 3 + 1] = b
		indices[t2 * 3 + 2] = c
		for t in [t1, t2]:
			for k in 3:
				_tris(indices[t * 3 + k]).append(t)
		return true

	func result() -> Solid:
		var out := Solid.new()
		out.positions = positions
		out.uvs = uvs
		var kept_indices := PackedInt32Array()
		var kept_tags := PackedInt32Array()
		kept_indices.resize(indices.size())
		kept_tags.resize(alive.size())
		var n := 0
		for t in alive.size():
			if alive[t]:
				kept_indices[n * 3] = indices[t * 3]
				kept_indices[n * 3 + 1] = indices[t * 3 + 1]
				kept_indices[n * 3 + 2] = indices[t * 3 + 2]
				kept_tags[n] = tags[t]
				n += 1
		kept_indices.resize(n * 3)
		kept_tags.resize(n)
		out.indices = kept_indices
		out.tags = kept_tags
		out.remove_unused()
		return out

	func _edge_triangles(a: int, b: int) -> Array:
		var out := []
		for t: int in _tris(a):
			if indices[t * 3] == b or indices[t * 3 + 1] == b or indices[t * 3 + 2] == b:
				out.append(t)
		return out

	# Vertices sharing a triangle with [param v]. Cached: don't modify.
	func _neighbours(v: int) -> Dictionary:
		var cached: Variant = _neighbour_cache[v]
		if cached != null:
			return cached
		var out := {}
		for t: int in _tris(v):
			for c in 3:
				var n := indices[t * 3 + c]
				if n != v:
					out[n] = true
		_neighbour_cache[v] = out
		return out

	func _is_feature(t1: int, t2: int) -> bool:
		if tags[t1] != tags[t2]:
			return true
		var n1 := _unit_normal(t1)
		var n2 := _unit_normal(t2)
		if n1 == Vector3.ZERO or n2 == Vector3.ZERO:
			return false
		return n1.dot(n2) < cos_feature

	# Unit normal of [param t] (zero if degenerate), cached until the triangle changes.
	func _unit_normal(t: int) -> Vector3:
		if _unit_ok[t]:
			return _unit[t]
		var n := _triangle_normal(t)
		n = n.normalized() if n.length_squared() != 0.0 else Vector3.ZERO
		_unit[t] = n
		_unit_ok[t] = 1
		return n

	func _runs(t: int, a: int, b: int) -> bool:
		for c in 3:
			if indices[t * 3 + c] == a and indices[t * 3 + (c + 1) % 3] == b:
				return true
		return false

	func _opposite(t: int, a: int, b: int) -> int:
		for c in 3:
			var v := indices[t * 3 + c]
			if v != a and v != b:
				return v
		return -1

	func _triangle_normal(t: int) -> Vector3:
		return _normal(positions[indices[t * 3]], positions[indices[t * 3 + 1]], positions[indices[t * 3 + 2]])

	func _smallest_angle(t: int) -> float:
		return _angle_of(positions[indices[t * 3]], positions[indices[t * 3 + 1]], positions[indices[t * 3 + 2]])

	static func _normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
		return (c - a).cross(b - a)

	static func _angle_of(a: Vector3, b: Vector3, c: Vector3) -> float:
		var ab := b - a
		var ac := c - a
		var bc := c - b
		if ab.length_squared() == 0.0 or ac.length_squared() == 0.0 or bc.length_squared() == 0.0:
			return 0.0
		return minf(ab.angle_to(ac), minf((-ab).angle_to(bc), (-ac).angle_to(-bc)))

	# One int for a triangle of position ids a, b, c (each under 2^21), rotated to start at
	# the smallest so the same triangle gives the same key whichever corner comes first.
	static func _key(a: int, b: int, c: int) -> int:
		if b < a and b < c:
			return b | (c << 21) | (a << 42)
		if c < a and c < b:
			return c | (a << 21) | (b << 42)
		return a | (b << 21) | (c << 42)
