@tool
class_name ConvexCells
extends RefCounted
## Cutting solids into convex cells without booleans: clipping a closed solid by planes
## (closing each cut), Voronoi cells, and the corners of a solid's convex parts for
## collision ([method hull_sets]). Static functions only, safe on worker threads.


## Point sets for colliding with [param solid] as up to [param count] convex hulls. The
## solid is halved again and again (the biggest part each time, across its longest side,
## at its middle), and each half split into the parts that don't touch, so the arms of a U
## become hulls of their own; then each part is a hull. More hulls follow hollows and
## hooks more closely. One hull (the solid's) for [param count] 1 or a small solid; a part
## that can't be halved cleanly stays whole.
static func hull_sets(solid: Solid, count: int) -> Array[PackedVector3Array]:
	var started := StageProfile.begin()
	var out := _hull_sets_work(solid, count)
	StageProfile.end(&"hulls", started)
	return out


static func _hull_sets_work(solid: Solid, count: int) -> Array[PackedVector3Array]:
	if NativeKernel.on():
		var sets: Array[PackedVector3Array] = []
		sets.assign(ClassDB.class_call_static(NativeKernel.CLASS, &"hull_sets", solid.positions, solid.indices,
				solid.tags, solid.uvs, count))
		return sets
	var whole: Array[PackedVector3Array] = [solid.get_hull_points()]
	if count <= 1 or solid.positions.size() < 8 or solid.is_empty():
		return whole
	var tiny := solid.get_aabb().get_longest_axis_size() * 1e-3
	var parts: Array[Solid] = []
	parts.append_array(solid.get_islands())
	var stuck := {}  # parts that couldn't be halved
	while parts.size() < count:
		# The biggest part not yet stuck.
		var biggest := -1
		var biggest_size := 0.0
		for i in parts.size():
			var size := parts[i].get_aabb().get_longest_axis_size()
			if not stuck.has(parts[i]) and size > biggest_size:
				biggest = i
				biggest_size = size
		if biggest < 0 or biggest_size <= tiny * 4.0:
			break
		var part := parts[biggest]
		var box := part.get_aabb()
		var axis := box.size.max_axis_index()
		var normal := Vector3.ZERO
		normal[axis] = 1.0
		var middle := box.get_center()[axis]
		var lower := clip(part, Plane(normal, middle), -1)
		var upper := clip(part, Plane(-normal, -middle), -1)
		if lower == null or upper == null or lower.is_empty() or upper.is_empty():
			stuck[part] = true
			continue
		parts.remove_at(biggest)
		parts.append_array(lower.get_islands())
		parts.append_array(upper.get_islands())
	var out: Array[PackedVector3Array] = []
	for part in parts:
		var points := part.get_hull_points()
		if points.size() >= 4:
			out.append(points)
	return out if not out.is_empty() else whole


## The Voronoi cells of [param seeds] inside [param box], as closed convex solids with
## every face tagged [param tag]. Together they fill the box.
static func voronoi_cells(box: AABB, seeds: PackedVector3Array, tag: int) -> Array[Solid]:
	var cells: Array[Solid] = []
	for i in seeds.size():
		var cell := voronoi_cell(box, seeds, i, tag)
		if not cell.is_empty():
			cells.append(cell)
	return cells


## The Voronoi cell of seed [param index] (see [method voronoi_cells]).
static func voronoi_cell(box: AABB, seeds: PackedVector3Array, index: int, tag: int) -> Solid:
	var planes: Array[Plane] = [
		Plane(Vector3.RIGHT, box.end.x), Plane(Vector3.LEFT, -box.position.x),
		Plane(Vector3.UP, box.end.y), Plane(Vector3.DOWN, -box.position.y),
		Plane(Vector3.BACK, box.end.z), Plane(Vector3.FORWARD, -box.position.z),
	]
	planes.append_array(_bisectors(seeds, index))
	return convex_solid(planes, tag, box.get_longest_axis_size() * 1e-5)


## [param solid] (closed) cut down to what's inside [param plane] (its normal points out),
## the cut closed with faces tagged [param tag]: what a knife along the plane leaves.
## Returns [param solid] itself if it's all inside, an empty solid if none of it is, and
## null if the cut can't be closed simply (its outline on the plane has a hole, or it
## didn't come out closed). Corners
## within [param tolerance] of the plane count as on it, and cut points that close together
## are one (at least a millionth of the solid's size: positions are 32-bit floats).
static func clip(solid: Solid, plane: Plane, tag: int, tolerance: float = 1e-6) -> Solid:
	var n := solid.positions.size()
	tolerance = maxf(tolerance, solid.get_aabb().get_longest_axis_size() * 1e-6)
	var side := PackedFloat64Array()
	side.resize(n)
	var any_out := false
	var any_in := false
	for v in n:
		var d := plane.distance_to(solid.positions[v])
		if absf(d) <= tolerance:
			d = 0.0
		side[v] = d
		any_out = any_out or d > 0.0
		any_in = any_in or d < 0.0
	if not any_out:
		return solid
	if not any_in:
		return Solid.new()
	var out := Solid.new()
	out.positions = solid.positions.duplicate()
	var has_uv := solid.uvs.size() == n
	if has_uv:
		out.uvs = solid.uvs.duplicate()
	var crossings := {}  # Vector2i(lower, higher vertex) -> the vertex where that edge crosses
	# Cut points (and corners on the plane) by grid cell, so edges crossing at the same point
	# (the sides of a sliver triangle, or next to a corner) share one vertex.
	var near := {}
	for v in n:
		if side[v] == 0.0:
			var home := Vector3i((solid.positions[v] / tolerance).floor())
			if not near.has(home):
				near[home] = []
			(near[home] as Array).append(v)
	for t in solid.indices.size() / 3:
		var a := solid.indices[t * 3]
		var b := solid.indices[t * 3 + 1]
		var c := solid.indices[t * 3 + 2]
		if side[a] <= 0.0 and side[b] <= 0.0 and side[c] <= 0.0:
			out.indices.append_array([a, b, c])
			out.tags.append(solid.tags[t])
			continue
		if side[a] >= 0.0 and side[b] >= 0.0 and side[c] >= 0.0:
			continue
		# Crossing: the inside part, in the same winding, as a fan.
		var corners := [a, b, c]
		var polygon := PackedInt32Array()
		for k in 3:
			var from: int = corners[k]
			var to: int = corners[(k + 1) % 3]
			if side[from] <= 0.0:
				polygon.append(from)
			if side[from] * side[to] < 0.0:
				var cut := _crossing(out, crossings, near, mini(from, to), maxi(from, to), side, has_uv, tolerance)
				if polygon.is_empty() or (polygon[polygon.size() - 1] != cut and polygon[0] != cut):
					polygon.append(cut)
		for k in range(1, polygon.size() - 1):
			var p0 := out.positions[polygon[0]]
			var p1 := out.positions[polygon[k]]
			var p2 := out.positions[polygon[k + 1]]
			if p0.distance_to(p1) <= tolerance or p1.distance_to(p2) <= tolerance or p2.distance_to(p0) <= tolerance:
				continue  # collapsed (cut points that met, with different UVs)
			out.indices.append_array([polygon[0], polygon[k], polygon[k + 1]])
			out.tags.append(solid.tags[t])
	# The cut's outline: edges between corners on the plane with no twin running the other
	# way. Only those can be open (every other edge was paired before and is kept whole), so
	# only they're looked at, keyed by an id per position.
	var on_plane := PackedByteArray()
	on_plane.resize(out.positions.size())
	for v in out.positions.size():
		on_plane[v] = 1 if v >= n or side[v] == 0.0 else 0
	var ids := {}  # position -> id
	var directed := _plane_edges(out, on_plane, ids)
	var next := {}  # start id -> [end id, start vertex]
	for edge: Vector2i in directed:
		if not directed.has(Vector2i(edge.y, edge.x)):
			if next.has(edge.x):
				return null  # the outline touches itself
			next[edge.x] = [edge.y, directed[edge]]
	if next.is_empty():
		return out
	# Chain it into loops, flattened onto the plane.
	var u := plane.normal.cross(Vector3.UP if absf(plane.normal.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := plane.normal.cross(u)
	var loops: Array[PackedInt32Array] = []
	var flat: Array[PackedVector2Array] = []
	while not next.is_empty():
		var start: int = next.keys()[0]
		var loop := PackedInt32Array()
		var points := PackedVector2Array()
		var at := start
		while true:
			var step: Array = next.get(at, [])
			if step.is_empty():
				return null  # the outline doesn't close
			next.erase(at)
			loop.append(step[1])
			var corner := out.positions[step[1]]
			points.append(Vector2(corner.dot(u), corner.dot(w)))
			at = step[0]
			if at == start:
				break
		loops.append(loop)
		flat.append(points)
	for i in loops.size():
		for j in loops.size():
			if i != j and Geometry2D.is_point_in_polygon(flat[i][0], flat[j]):
				return null  # a loop inside another: a cut with a hole
	for i in loops.size():
		var made := triangulate(flat[i])
		var triangles: PackedInt32Array = made[0]
		if triangles.is_empty():
			return null
		var loop := loops[i]
		for p: Vector2 in made[1]:
			loop.append(out.positions.size())
			out.positions.append(u * p.x + w * p.y + plane.normal * plane.d)
			on_plane.append(1)
			if has_uv:
				out.uvs.append(Vector2.ZERO)
		for k in range(0, triangles.size(), 3):
			# Counter-clockwise seen from outside the plane's inside (u, w, normal is
			# right-handed); solids wind clockwise seen from outside, so swap two corners. (A
			# sliver's 3D normal is too noisy to go by.)
			out.indices.append_array([loop[triangles[k]], loop[triangles[k + 2]], loop[triangles[k + 1]]])
			out.tags.append(tag)
	# Not closed after all (a corner case the clipping doesn't handle): leave it to a boolean.
	# (Every edge clipping or capping made has a corner on the plane; the rest were kept.)
	var counts := {}
	_plane_edges(out, on_plane, ids, counts, false)
	for edge: Vector2i in counts:
		if counts[edge] != 1 or counts.get(Vector2i(edge.y, edge.x), 0) != 1:
			return null
	out.remove_unused()
	return out


# The edges of [param out] between corners on the plane ([param on_plane]; with
# [param both] off, with at least one corner on it), as Vector2i(id from, id to) -> start
# vertex, with an id per position kept in [param ids] and how often each edge runs that
# way in [param counts].
static func _plane_edges(out: Solid, on_plane: PackedByteArray, ids: Dictionary, counts: Dictionary = {},
		both: bool = true) -> Dictionary:
	var directed := {}
	for t in out.indices.size() / 3:
		for k in 3:
			var a := out.indices[t * 3 + k]
			var b := out.indices[t * 3 + (k + 1) % 3]
			if both and not (on_plane[a] and on_plane[b]):
				continue
			if not both and not (on_plane[a] or on_plane[b]):
				continue
			var id_a: int = ids.get(out.positions[a], -1)
			if id_a < 0:
				id_a = ids.size()
				ids[out.positions[a]] = id_a
			var id_b: int = ids.get(out.positions[b], -1)
			if id_b < 0:
				id_b = ids.size()
				ids[out.positions[b]] = id_b
			var edge := Vector2i(id_a, id_b)
			directed[edge] = a
			counts[edge] = counts.get(edge, 0) + 1
	return directed


## The convex solid inside every one of [param planes] (normals pointing out), with every
## face tagged [param tag]. Empty if they enclose nothing. Corners closer than
## [param tolerance] count as one.
static func convex_solid(planes: Array[Plane], tag: int, tolerance: float = 1e-5) -> Solid:
	var solid := Solid.new()
	for p in Geometry3D.compute_convex_mesh_points(planes):
		var seen := false
		for q in solid.positions:
			if q.distance_to(p) <= tolerance:
				seen = true
				break
		if not seen:
			solid.positions.append(p)
	if solid.positions.size() < 4:
		return Solid.new()
	var on_plane := maxf(tolerance * 10.0, 1e-6)
	for plane in planes:
		var corners := PackedInt32Array()
		var middle := Vector3.ZERO
		for i in solid.positions.size():
			if absf(plane.distance_to(solid.positions[i])) <= on_plane:
				corners.append(i)
				middle += solid.positions[i]
		if corners.size() < 3:
			continue
		middle /= corners.size()
		# Around the face's middle in order, then a fan from the first corner.
		var u := (solid.positions[corners[0]] - middle).normalized()
		var v := plane.normal.cross(u)
		var around := []
		for i in corners:
			var offset := solid.positions[i] - middle
			around.append([atan2(offset.dot(v), offset.dot(u)), i])
		around.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		for k in range(1, around.size() - 1):
			var a: int = around[0][1]
			var b: int = around[k][1]
			var c: int = around[k + 1][1]
			var normal := (solid.positions[c] - solid.positions[a]).cross(solid.positions[b] - solid.positions[a])
			if normal.dot(plane.normal) < 0.0:
				var swap := b
				b = c
				c = swap
			solid.indices.append_array([a, b, c])
			solid.tags.append(tag)
	solid.remove_unused()
	return solid


## Counter-clockwise triangles covering the simple polygon [param points] (either way
## round) with every point on its outline: [code][indices, extra points][/code], three
## indices per triangle. Indices past the end of [param points] are extra points inside
## the polygon, added where points in a straight line would otherwise make flat triangles.
## Keeping every point means the triangles meet whatever shares the outline without
## T-junctions (Geometry2D's triangulation drops points in a line). Empty indices if it
## can't be done.
static func triangulate(points: PackedVector2Array) -> Array:
	var n := points.size()
	var order := PackedInt32Array()
	var area := 0.0
	var size := 0.0
	for i in n:
		order.append(i)
		area += points[i].cross(points[(i + 1) % n])
		size = maxf(size, maxf(absf(points[i].x), absf(points[i].y)))
	if area < 0.0:
		order.reverse()  # counter-clockwise
	var tolerance := maxf(size, 1e-6) * 1e-6
	# The corners, without points on the line between their neighbours (put back below).
	var kept := PackedInt32Array()
	for i in order:
		while kept.size() >= 2 and _on_segment(points, kept[kept.size() - 2], kept[kept.size() - 1], i, tolerance):
			kept.remove_at(kept.size() - 1)
		kept.append(i)
	while kept.size() >= 3 and _on_segment(points, kept[kept.size() - 2], kept[kept.size() - 1], kept[0], tolerance):
		kept.remove_at(kept.size() - 1)
	while kept.size() >= 3 and _on_segment(points, kept[kept.size() - 1], kept[0], kept[1], tolerance):
		kept.remove_at(0)
	if kept.size() < 3:
		return [PackedInt32Array(), PackedVector2Array()]
	# The points dropped between each pair of corners (start corner -> points, in order).
	var between := {}
	var start := order.find(kept[0])
	var corner := kept[0]
	for k in range(1, n + 1):
		var i := order[(start + k) % n]
		if kept.has(i):
			corner = i
		else:
			if not between.has(corner):
				between[corner] = PackedInt32Array()
			between[corner].append(i)
	var next := {}
	for k in kept.size():
		next[kept[k]] = kept[(k + 1) % kept.size()]
	# Ear clipping on the corners.
	var ears := PackedInt32Array()
	var left := kept.duplicate()
	var epsilon := maxf(size, 1e-6) * maxf(size, 1e-6) * 1e-12
	var stuck := 0
	var i := 0
	while left.size() > 3:
		if stuck > left.size():
			return [PackedInt32Array(), PackedVector2Array()]  # no ear left
		var m := left.size()
		var a := left[(i + m - 1) % m]
		var b := left[i % m]
		var c := left[(i + 1) % m]
		if _is_ear(points, left, a, b, c, epsilon):
			ears.append_array([a, b, c])
			left.remove_at(i % m)
			stuck = 0
			i = maxi(i - 1, 0)
		else:
			i = (i + 1) % m
			stuck += 1
	ears.append_array([left[0], left[1], left[2]])
	# Put the dropped points back: a triangle with some on its outline edges becomes a fan
	# around its middle.
	var out := PackedInt32Array()
	var extra := PackedVector2Array()
	for k in range(0, ears.size(), 3):
		var ring := PackedInt32Array()
		for e in 3:
			var from := ears[k + e]
			var to := ears[k + (e + 1) % 3]
			ring.append(from)
			if next[from] == to and between.has(from):
				ring.append_array(between[from])
		if ring.size() == 3:
			out.append_array(ring)
			continue
		var middle := n + extra.size()
		extra.append((points[ears[k]] + points[ears[k + 1]] + points[ears[k + 2]]) / 3.0)
		for r in ring.size():
			out.append_array([middle, ring[r], ring[(r + 1) % ring.size()]])
	return [out, extra]


# True if point [param middle] lies on the segment from [param from] to [param to].
static func _on_segment(points: PackedVector2Array, from: int, middle: int, to: int, tolerance: float) -> bool:
	var p := points[middle]
	return Geometry2D.get_closest_point_to_segment(p, points[from], points[to]).distance_to(p) <= tolerance


# True if corner [param b] (between [param a] and [param c]) of the counter-clockwise
# polygon [param left] can be cut off: it turns left, and no other corner is inside or on
# the triangle (one on its new edge would leave a T-junction).
static func _is_ear(points: PackedVector2Array, left: PackedInt32Array, a: int, b: int, c: int, epsilon: float) -> bool:
	var pa := points[a]
	var pb := points[b]
	var pc := points[c]
	if (pb - pa).cross(pc - pa) <= epsilon:
		return false
	for k in left:
		if k == a or k == b or k == c:
			continue
		var p := points[k]
		if p == pa or p == pb or p == pc:
			continue
		if (pb - pa).cross(p - pa) >= -epsilon and (pc - pb).cross(p - pb) >= -epsilon \
				and (pa - pc).cross(p - pc) >= -epsilon:
			return false
	return true


# The planes between seed [param index] and every other seed, facing away from it.
static func _bisectors(seeds: PackedVector3Array, index: int) -> Array[Plane]:
	var planes: Array[Plane] = []
	for j in seeds.size():
		if j != index and not seeds[index].is_equal_approx(seeds[j]):
			planes.append(Plane((seeds[j] - seeds[index]).normalized(), (seeds[index] + seeds[j]) * 0.5))
	return planes


# The vertex where edge [param lower]-[param higher] crosses the plane, made once per edge.
# It's worked out from the end with the smaller position, so an edge whose twin uses other
# vertices at the same places (a UV seam) crosses at exactly the same point; and a cut
# point within [param tolerance] of an earlier one (with the same UV) is that one.
static func _crossing(out: Solid, crossings: Dictionary, near: Dictionary, lower: int, higher: int,
		side: PackedFloat64Array, has_uv: bool, tolerance: float) -> int:
	var key := Vector2i(lower, higher)
	if crossings.has(key):
		return crossings[key]
	if out.positions[higher] < out.positions[lower]:
		var swap := lower
		lower = higher
		higher = swap
	var at := side[lower] / (side[lower] - side[higher])
	var point := out.positions[lower].lerp(out.positions[higher], at)
	var uv := out.uvs[lower].lerp(out.uvs[higher], at) if has_uv else Vector2.ZERO
	var home := Vector3i((point / tolerance).floor())
	for o in 27:
		for v: int in near.get(home + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1), []):
			if out.positions[v].distance_to(point) <= tolerance and (not has_uv or out.uvs[v].is_equal_approx(uv)):
				crossings[key] = v
				return v
	out.positions.append(point)
	if has_uv:
		out.uvs.append(uv)
	var made := out.positions.size() - 1
	if not near.has(home):
		near[home] = []
	(near[home] as Array).append(made)
	crossings[key] = made
	return made
