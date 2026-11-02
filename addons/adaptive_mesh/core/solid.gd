@tool
class_name Solid
extends Resource
## A closed triangle mesh: the thing booleans cut and join. Each triangle carries a
## [i]tag[/i], an int the caller picks (for example 0 for the authored surface and 1 for
## faces a brush made), which survives booleans and picks the material it is drawn with.
##
## Vertices are shared between triangles (indexed). [member uvs] is either empty or one per
## vertex. Normals aren't stored: [method build_surfaces] works them out when drawing.

@export var positions := PackedVector3Array()
## Three per triangle, clockwise seen from outside (Godot's front faces).
@export var indices := PackedInt32Array()
## One per triangle.
@export var tags := PackedInt32Array()
## Empty, or one per vertex.
@export var uvs := PackedVector2Array()


## Builds a solid from every surface of [param mesh]. Surface [code]s[/code] gets tag
## [code]first_tag + s[/code]. Vertices at the same position (and UV) are merged, so meshes
## split at UV or normal seams (such as [BoxMesh]) come out closed. Positions are first
## snapped to a grid of [param merge_distance], so corners that differ only by float noise
## merge too (0 turns that off).
static func from_mesh(mesh: Mesh, first_tag: int = 0, merge_distance: float = 1e-5) -> Solid:
	var solid := Solid.new()
	var has_uv := false
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_TEX_UV] != null and (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() > 0:
			has_uv = true
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var surface_uvs := PackedVector2Array()
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			surface_uvs = arrays[Mesh.ARRAY_TEX_UV]
		var surface_indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			surface_indices = arrays[Mesh.ARRAY_INDEX]
		if surface_indices.is_empty():
			surface_indices.resize(vertices.size())
			for i in vertices.size():
				surface_indices[i] = i
		var base := solid.positions.size()
		solid.positions.append_array(vertices)
		if has_uv:
			if surface_uvs.size() == vertices.size():
				solid.uvs.append_array(surface_uvs)
			else:
				var blank := PackedVector2Array()
				blank.resize(vertices.size())
				solid.uvs.append_array(blank)
		for i in surface_indices:
			solid.indices.append(base + i)
		var tag := first_tag + s
		for t in surface_indices.size() / 3:
			solid.tags.append(tag)
	if merge_distance > 0.0:
		for i in solid.positions.size():
			solid.positions[i] = (solid.positions[i] / merge_distance).round() * merge_distance
	solid.weld()
	return solid


func get_triangle_count() -> int:
	return indices.size() / 3


func is_empty() -> bool:
	return indices.is_empty()


func get_aabb() -> AABB:
	if positions.is_empty():
		return AABB()
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"aabb", positions)
	var box := AABB(positions[0], Vector3.ZERO)
	for p in positions:
		box = box.expand(p)
	return box


## The volume enclosed (positive for a closed, outward-facing solid).
func get_volume() -> float:
	if NativeKernel.on():
		return (ClassDB.class_call_static(NativeKernel.CLASS, &"volume_centre", positions, indices) as Array)[0]
	var volume := 0.0
	for t in indices.size() / 3:
		var a := positions[indices[t * 3]]
		volume += a.dot(positions[indices[t * 3 + 2]].cross(positions[indices[t * 3 + 1]]))
	return volume / 6.0


## A few dozen corners of this solid's convex hull, spread around it (the furthest corner
## in each of 64 directions), moved towards the origin by [param shrink]. Physics engines
## build hulls from these more reliably and quickly than from every corner (cut faces have
## many in a plane), and the hull stays inside the solid's.
func get_hull_points(shrink: float = 1.0) -> PackedVector3Array:
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"hull_points", positions, shrink)
	var used := {}
	var points := PackedVector3Array()
	if positions.is_empty():
		return points
	for k in 64:
		# Directions evenly around a sphere (a Fibonacci spiral).
		var y := 1.0 - (k + 0.5) / 32.0
		var ring := sqrt(1.0 - y * y)
		var angle := k * 2.399963
		var direction := Vector3(cos(angle) * ring, y, sin(angle) * ring)
		var best := 0
		var furthest := -INF
		for v in positions.size():
			var along := positions[v].dot(direction)
			if along > furthest:
				furthest = along
				best = v
		if not used.has(best):
			used[best] = true
			points.append(positions[best] * shrink)
	return points


## Where the enclosed volume is centred (its centre of mass at even density), or the middle
## of its box if it encloses nothing.
func get_centre() -> Vector3:
	if NativeKernel.on():
		return (ClassDB.class_call_static(NativeKernel.CLASS, &"volume_centre", positions, indices) as Array)[1]
	var weighted := Vector3.ZERO
	var total := 0.0
	for t in indices.size() / 3:
		var a := positions[indices[t * 3]]
		var b := positions[indices[t * 3 + 1]]
		var c := positions[indices[t * 3 + 2]]
		var volume := a.dot(c.cross(b))  # (six times the tetrahedron with the origin)
		weighted += (a + b + c) * volume
		total += volume
	if absf(total) < 1e-12:
		return get_aabb().get_center()
	return weighted / (total * 4.0)


## True if [param point] is inside this (closed) solid: a ray from it crosses the surface
## an odd number of times.
func encloses(point: Vector3) -> bool:
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"encloses", positions, indices, point)
	# A slightly skewed ray, so it doesn't run along edges of axis-aligned faces.
	var direction := Vector3(1.0, 0.0011, 0.0007).normalized()
	var crossings := 0
	for t in indices.size() / 3:
		var hit: Variant = Geometry3D.ray_intersects_triangle(point, direction, positions[indices[t * 3]],
				positions[indices[t * 3 + 1]], positions[indices[t * 3 + 2]])
		if hit != null:
			crossings += 1
	return crossings % 2 == 1


## The parts of this solid that don't touch each other (triangles joined through shared
## corners, matched by position), as separate solids. One part: a list with this solid.
func get_islands() -> Array[Solid]:
	if NativeKernel.on():
		var found: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"islands", positions, indices, tags, uvs)
		var islands: Array[Solid] = []
		if found.is_empty():
			islands.append(self)
		for arrays: Array in found:
			islands.append(NativeKernel.to_solid(arrays))
		return islands
	var parent := []  # (an Array, so the lambda below changes this one, not a copy)
	parent.resize(positions.size())
	var by_position := {}
	for v in positions.size():
		parent[v] = by_position.get(positions[v], v)
		by_position[positions[v]] = parent[v]
	var find := func(v: int) -> int:
		while parent[v] != v:
			parent[v] = parent[parent[v]]
			v = parent[v]
		return v
	for t in indices.size() / 3:
		var a: int = find.call(indices[t * 3])
		for c in range(1, 3):
			var b: int = find.call(indices[t * 3 + c])
			if a != b:
				parent[b] = a
	var island_of := {}  # root vertex -> island index
	var parts: Array[Solid] = []
	var has_uv := uvs.size() == positions.size()
	for t in indices.size() / 3:
		var island: int = island_of.get(find.call(indices[t * 3]), -1)
		if island < 0:
			island = parts.size()
			island_of[find.call(indices[t * 3])] = island
			var part := Solid.new()
			part.positions = positions
			part.uvs = uvs if has_uv else PackedVector2Array()
			parts.append(part)
		parts[island].indices.append_array([indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]])
		parts[island].tags.append(tags[t])
	if parts.size() <= 1:
		var whole: Array[Solid] = [self]
		return whole
	for part in parts:
		part.remove_unused()
	return parts


## A copy with every position moved by [param xform]. Mirroring transforms flip the
## winding back, so the copy stays outward-facing.
func transformed(xform: Transform3D) -> Solid:
	var out := Solid.new()
	out.positions = xform * positions
	out.indices = indices.duplicate()
	out.tags = tags.duplicate()
	out.uvs = uvs.duplicate()
	if xform.basis.determinant() < 0.0:
		for t in range(0, out.indices.size(), 3):
			var swap := out.indices[t + 1]
			out.indices[t + 1] = out.indices[t + 2]
			out.indices[t + 2] = swap
	return out


## The space this solid passes through moving by [param offset]: a copy at the start, a
## copy at the end, and a band joining them along the silhouette (the Minkowski sum with
## the segment). For a sphere that is a capsule whose ends keep the sphere's exact
## triangles. The band is split into [param segments] rows along [param offset].
##
## Only right for convex solids (spheres, boxes); a concave one would come out
## self-intersecting. UVs are dropped.
func swept(offset: Vector3, segments: int = 1) -> Solid:
	# Without UVs, so vertices split at UV seams merge and edges pair up by index.
	var source := Solid.new()
	source.positions = positions
	source.indices = indices
	source.tags = tags
	source.weld()
	if offset.is_zero_approx():
		return source
	segments = maxi(segments, 1)
	var n := source.positions.size()
	var out := Solid.new()
	out.positions = source.positions.duplicate()
	for p in source.positions:
		out.positions.append(p + offset)
	# Faces looking along the offset go to the end copy, the rest stay at the start.
	var at_end := PackedByteArray()
	at_end.resize(source.indices.size() / 3)
	var edge_owner := {}  # Vector2i(a, b) -> triangle, for every directed edge
	for t in source.indices.size() / 3:
		var a := source.positions[source.indices[t * 3]]
		var normal := (source.positions[source.indices[t * 3 + 2]] - a).cross(
				source.positions[source.indices[t * 3 + 1]] - a)
		at_end[t] = 1 if normal.dot(offset) >= 0.0 else 0
		var base := n if at_end[t] else 0
		for c in 3:
			out.indices.append(source.indices[t * 3 + c] + base)
		out.tags.append(source.tags[t])
		for e in 3:
			edge_owner[Vector2i(source.indices[t * 3 + e], source.indices[t * 3 + (e + 1) % 3])] = t
	# Silhouette: start-side edges whose twin is on an end-side face. Each gets a strip of
	# quads b0 -> a0 -> a1 -> b1, with in-between copies of its vertices per row.
	var rows := {}  # vertex -> PackedInt32Array of its copies, start to end
	for key: Vector2i in edge_owner:
		var t: int = edge_owner[key]
		var twin: int = edge_owner.get(Vector2i(key.y, key.x), -1)
		if at_end[t] or twin < 0 or not at_end[twin]:
			continue
		var column_a := _sweep_column(out, rows, key.x, n, offset, segments)
		var column_b := _sweep_column(out, rows, key.y, n, offset, segments)
		for r in segments:
			out.indices.append_array([column_b[r], column_a[r], column_a[r + 1]])
			out.indices.append_array([column_b[r], column_a[r + 1], column_b[r + 1]])
			out.tags.append(source.tags[t])
			out.tags.append(source.tags[t])
	out.remove_unused()
	return out


static func _snap(p: Vector3) -> Vector3i:
	return Vector3i((p * 1e5).round())


## Repair for imported meshes: merges vertices closer than [param tolerance] (each into
## the first one found), drops triangles that collapse, and returns how many vertices were
## merged. For pieces that should meet but are a little apart, such as a terrain split by
## material whose borders don't quite line up. Keep it well below the shortest real edge.
func merge_close(tolerance: float) -> int:
	var cell := maxf(tolerance, 1e-9)
	var grid := {}  # Vector3i cell -> Array of kept vertex indices
	var remap := PackedInt32Array()
	remap.resize(positions.size())
	var merged := 0
	for v in positions.size():
		var p := positions[v]
		var home := Vector3i((p / cell).floor())
		var found := -1
		for o in 27:
			var key := home + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1)
			for w: int in grid.get(key, []):
				if positions[w].distance_to(p) <= tolerance:
					found = w
					break
			if found >= 0:
				break
		if found >= 0:
			remap[v] = found
			merged += 1
		else:
			remap[v] = v
			if not grid.has(home):
				grid[home] = []
			(grid[home] as Array).append(v)
	if merged == 0:
		return 0
	for i in indices.size():
		indices[i] = remap[indices[i]]
	_drop_degenerate()
	remove_unused()
	return merged


## Repair for imported meshes: where a vertex on the open edge of the surface lies on
## another open edge (within [param tolerance]) instead of meeting its ends, splits that
## edge's triangle there, so the two sides share the vertex. Returns how many triangles
## were split. Run [method merge_close] first.
func fix_t_junctions(tolerance: float) -> int:
	if NativeKernel.on():
		var fixed: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"fix_t_junctions", positions, indices, tags,
				uvs, tolerance)
		positions = fixed[0]
		indices = fixed[1]
		tags = fixed[2]
		uvs = fixed[3]
		return fixed[4]
	var splits := 0
	for round in 8:
		var boundary := _open_edges()  # Vector2i(a, b) -> triangle
		var vertices := {}
		for edge: Vector2i in boundary:
			vertices[edge.x] = true
			vertices[edge.y] = true
		var done := 0
		var split_triangles := {}
		for edge: Vector2i in boundary:
			var t: int = boundary[edge]
			if split_triangles.has(t):
				continue
			var a := positions[edge.x]
			var b := positions[edge.y]
			var ab := b - a
			var best := -1
			var best_along := 0.0
			for v: int in vertices:
				if v == edge.x or v == edge.y:
					continue
				var along := (positions[v] - a).dot(ab) / ab.length_squared()
				if along <= 1e-4 or along >= 1.0 - 1e-4:
					continue
				if positions[v].distance_to(a + ab * along) <= tolerance and (best < 0 or along < best_along):
					best = v
					best_along = along
			if best < 0:
				continue
			# Triangle (a, b, c) becomes (a, v, c) and (v, b, c).
			var c := -1
			for k in 3:
				var w := indices[t * 3 + k]
				if w != edge.x and w != edge.y:
					c = w
			indices[t * 3] = edge.x
			indices[t * 3 + 1] = best
			indices[t * 3 + 2] = c
			indices.append_array([best, edge.y, c])
			tags.append(tags[t])
			split_triangles[t] = true
			done += 1
		splits += done
		if done == 0:
			break
	return splits


## The open edges of the surface as loops of vertex indices, each in the direction its
## triangles run. Empty for a closed solid.
func get_boundary_loops() -> Array[PackedInt32Array]:
	var next := {}
	for edge: Vector2i in _open_edges():
		next[edge.x] = edge.y
	var loops: Array[PackedInt32Array] = []
	var seen := {}
	for start: int in next:
		if seen.has(start):
			continue
		var loop := PackedInt32Array()
		var v := start
		while not seen.has(v) and next.has(v):
			seen[v] = true
			loop.append(v)
			v = next[v]
		loops.append(loop)
	return loops


## Closes an open, upward-facing sheet (a terrain surface) into a solid: walls run straight
## down from its open edge to height [param floor_y], and a flat floor closes the bottom.
## Walls and floor get [param tag]. The sheet must have exactly one open edge loop (no
## holes). Returns false, unchanged, if it hasn't.
func close_to_floor(floor_y: float, tag: int) -> bool:
	var loops := get_boundary_loops()
	if loops.size() != 1:
		push_warning("Solid.close_to_floor: the surface has %d open edge loops, needs exactly 1." % loops.size())
		return false
	var loop := loops[0]
	var count := loop.size()
	var floor_start := positions.size()
	var outline := PackedVector2Array()
	for v in loop:
		var p := positions[v]
		positions.append(Vector3(p.x, floor_y, p.z))
		outline.append(Vector2(p.x, p.z))
	if uvs.size() == floor_start:
		uvs.resize(positions.size())
	for i in count:
		# Open edge a -> b: the wall runs b -> a along it, then down and back.
		var a := loop[i]
		var b := loop[(i + 1) % count]
		var fa := floor_start + i
		var fb := floor_start + (i + 1) % count
		indices.append_array([b, a, fa, b, fa, fb])
		tags.append_array([tag, tag])
	var floor_triangles := Geometry2D.triangulate_polygon(outline)
	if floor_triangles.is_empty():
		push_warning("Solid.close_to_floor: couldn't triangulate the floor outline.")
		return false
	for f in range(0, floor_triangles.size(), 3):
		var tri := [floor_start + floor_triangles[f], floor_start + floor_triangles[f + 1], floor_start + floor_triangles[f + 2]]
		var p0 := positions[tri[0]]
		# The floor faces down.
		if (positions[tri[2]] - p0).cross(positions[tri[1]] - p0).y > 0.0:
			tri = [tri[0], tri[2], tri[1]]
		indices.append_array(tri)
		tags.append(tag)
	return true


# Directed edges with no twin: the open edge of the surface. Vector2i(a, b) -> triangle.
func _open_edges() -> Dictionary:
	var directed := {}
	for t in indices.size() / 3:
		for e in 3:
			directed[Vector2i(indices[t * 3 + e], indices[t * 3 + (e + 1) % 3])] = t
	var out := {}
	for edge: Vector2i in directed:
		if not directed.has(Vector2i(edge.y, edge.x)):
			out[edge] = directed[edge]
	return out


func _drop_degenerate() -> void:
	var kept_indices := PackedInt32Array()
	var kept_tags := PackedInt32Array()
	for t in indices.size() / 3:
		var a := indices[t * 3]
		var b := indices[t * 3 + 1]
		var c := indices[t * 3 + 2]
		if a != b and b != c and a != c and positions[a] != positions[b] and positions[b] != positions[c] 				and positions[a] != positions[c]:
			kept_indices.append_array([a, b, c])
			kept_tags.append(tags[t])
	indices = kept_indices
	tags = kept_tags


## Drops vertices no triangle uses.
func remove_unused() -> void:
	var remap := PackedInt32Array()
	remap.resize(positions.size())
	remap.fill(-1)
	var kept := PackedVector3Array()
	var kept_uvs := PackedVector2Array()
	var has_uv := uvs.size() == positions.size()
	for i in indices.size():
		var v := indices[i]
		if remap[v] < 0:
			remap[v] = kept.size()
			kept.append(positions[v])
			if has_uv:
				kept_uvs.append(uvs[v])
		indices[i] = remap[v]
	positions = kept
	uvs = kept_uvs


# Copies of [param vertex] from the start copy to the end copy, adding the in-between ones
# the first time they're needed.
static func _sweep_column(out: Solid, rows: Dictionary, vertex: int, n: int, offset: Vector3, segments: int) -> PackedInt32Array:
	if rows.has(vertex):
		return rows[vertex]
	var column := PackedInt32Array([vertex])
	for r in range(1, segments):
		column.append(out.positions.size())
		out.positions.append(out.positions[vertex] + offset * (float(r) / segments))
	column.append(vertex + n)
	rows[vertex] = column
	return column


## Inserts each of [param points] that lies on an edge (within [param tolerance], away from
## its ends) into that edge, splitting the triangles on both sides, so the solid stays
## closed and keeps its shape. For seams against a neighbour that has extra vertices along
## a shared edge (T-junctions). Returns how many points were inserted.
func split_edges_at(points: PackedVector3Array, tolerance: float) -> int:
	if NativeKernel.on():
		var split: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"split_edges_at", positions, indices, tags,
				uvs, points, tolerance)
		positions = split[0]
		indices = split[1]
		tags = split[2]
		uvs = split[3]
		return split[4]
	var inserted := 0
	var has_uv := uvs.size() == positions.size()
	for p in points:
		# Already a corner here (or as good as): inserting it again would make slivers.
		var present := false
		for q in positions:
			if q.distance_squared_to(p) <= tolerance * tolerance:
				present = true
				break
		if present:
			continue
		var found := -1
		var found_t := 0.0
		for i in indices.size():
			var a := positions[indices[i]]
			var b := positions[indices[i - 2 if i % 3 == 2 else i + 1]]
			var ab := b - a
			var length_squared := ab.length_squared()
			if length_squared <= tolerance * tolerance:
				continue
			var t := (p - a).dot(ab) / length_squared
			if t * t * length_squared <= tolerance * tolerance or (1.0 - t) * (1.0 - t) * length_squared <= tolerance * tolerance:
				continue  # at (or past) an end
			if t < 0.0 or t > 1.0 or (a + ab * t).distance_squared_to(p) > tolerance * tolerance:
				continue
			found = i
			found_t = t
			break
		if found < 0:
			continue
		var pa := positions[indices[found]]
		var pb := positions[indices[found - 2 if found % 3 == 2 else found + 1]]
		# Every triangle with the edge (either way round, matched by position: across a UV
		# seam the two sides have their own vertices) becomes two. Each side gets its own new
		# vertex, with its own UV.
		var made := {}  # Vector2i(lower, higher vertex of a side's edge) -> new vertex
		for t in indices.size() / 3:
			for c in 3:
				var x := indices[t * 3 + c]
				var y := indices[t * 3 + (c + 1) % 3]
				if not ((positions[x] == pa and positions[y] == pb) or (positions[x] == pb and positions[y] == pa)):
					continue
				var key := Vector2i(mini(x, y), maxi(x, y))
				var v: int = made.get(key, -1)
				if v < 0:
					v = positions.size()
					positions.append(p)
					if has_uv:
						var from := x if positions[x] == pa else y
						var to := y if from == x else x
						uvs.append(uvs[from].lerp(uvs[to], found_t))
					made[key] = v
				var z := indices[t * 3 + (c + 2) % 3]
				indices[t * 3 + (c + 1) % 3] = v
				indices.append_array([v, y, z])
				tags.append(tags[t])
				break
		inserted += 1
	if inserted > 0:
		_drop_degenerate()
	return inserted


## Merges vertices with exactly the same position and UV, and drops triangles that end up
## with two corners in one place.
func weld() -> void:
	if NativeKernel.on():
		var welded: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"weld", positions, indices, tags, uvs)
		positions = welded[0]
		indices = welded[1]
		tags = welded[2]
		uvs = welded[3]
		return
	var lookup := {}
	var remap := PackedInt32Array()
	remap.resize(positions.size())
	var new_positions := PackedVector3Array()
	var new_uvs := PackedVector2Array()
	var has_uv := uvs.size() == positions.size()
	for i in positions.size():
		var key: Variant = [positions[i], uvs[i]] if has_uv else positions[i]
		var j: int = lookup.get(key, -1)
		if j < 0:
			j = new_positions.size()
			lookup[key] = j
			new_positions.append(positions[i])
			if has_uv:
				new_uvs.append(uvs[i])
		remap[i] = j
	var new_indices := PackedInt32Array()
	var new_tags := PackedInt32Array()
	for t in indices.size() / 3:
		var a := remap[indices[t * 3]]
		var b := remap[indices[t * 3 + 1]]
		var c := remap[indices[t * 3 + 2]]
		# Collapsed, or flat with two corners in one place (vertices split only by UV).
		if a == b or b == c or a == c or new_positions[a] == new_positions[b] or new_positions[b] == new_positions[c] 				or new_positions[a] == new_positions[c]:
			continue
		new_indices.append_array([a, b, c])
		new_tags.append(tags[t])
	positions = new_positions
	uvs = new_uvs
	indices = new_indices
	tags = new_tags


## Edges not shared by exactly two triangles running opposite ways. 0 for a closed,
## consistently wound surface. Corners are matched by position, so UV seams don't count.
func count_open_edges() -> int:
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"count_open_edges", positions, indices)
	var ids := PackedInt32Array()
	ids.resize(positions.size())
	var lookup := {}
	for i in positions.size():
		var j: int = lookup.get(positions[i], -1)
		if j < 0:
			j = lookup.size()
			lookup[positions[i]] = j
		ids[i] = j
	var directed := {}
	for t in range(0, indices.size(), 3):
		for e in 3:
			var k := Vector2i(ids[indices[t + e]], ids[indices[t + (e + 1) % 3]])
			directed[k] = directed.get(k, 0) + 1
	var bad := 0
	for k: Vector2i in directed:
		if directed[k] != 1 or directed.get(Vector2i(k.y, k.x), 0) != 1:
			bad += 1
	return bad


## Every triangle as three positions, for [method ConcavePolygonShape3D.set_faces].
## Triangles tagged with any of [param skip_tags] are left out.
func get_faces(skip_tags: PackedInt32Array = PackedInt32Array()) -> PackedVector3Array:
	var started := StageProfile.begin()
	var out := _get_faces_work(skip_tags)
	StageProfile.end(&"collision faces", started)
	return out


func _get_faces_work(skip_tags: PackedInt32Array = PackedInt32Array()) -> PackedVector3Array:
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"faces", positions, indices, tags, skip_tags)
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	var n := 0
	for t in indices.size() / 3:
		if not skip_tags.is_empty() and skip_tags.has(tags[t]):
			continue
		for c in 3:
			faces[n] = positions[indices[t * 3 + c]]
			n += 1
	faces.resize(n)
	return faces


## Surface arrays for drawing, one entry per tag: [code][tag, arrays][/code], sorted by tag.
## A vertex's normal averages the faces around it that bend less than
## [param crease_angle] (degrees) from its own face, so curved cuts look smooth and sharp
## edges stay sharp. Triangles tagged with any of [param skip_tags] are left out, and don't
## count towards normals either.
##
## [param extra_faces] (three positions per triangle) are faces of a neighbouring piece:
## they aren't drawn, but vertices they share (to 1e-5) average their normals too, so
## shading carries across the seam. Safe to call from a worker thread.
func build_surfaces(crease_angle: float, skip_tags: PackedInt32Array = PackedInt32Array(),
		extra_faces: PackedVector3Array = PackedVector3Array()) -> Array:
	var started := StageProfile.begin()
	var out := _build_surfaces_work(crease_angle, skip_tags, extra_faces)
	StageProfile.end(&"surfaces", started)
	return out


func _build_surfaces_work(crease_angle: float, skip_tags: PackedInt32Array = PackedInt32Array(),
		extra_faces: PackedVector3Array = PackedVector3Array()) -> Array:
	if NativeKernel.on():
		return ClassDB.class_call_static(NativeKernel.CLASS, &"build_surfaces", positions, indices, tags, uvs,
				crease_angle, skip_tags, extra_faces)
	var triangle_count := indices.size() / 3
	var extra_count := extra_faces.size() / 3
	var vertex_count := positions.size()
	var hidden := PackedByteArray()
	hidden.resize(triangle_count)
	if not skip_tags.is_empty():
		for t in triangle_count:
			if skip_tags.has(tags[t]):
				hidden[t] = 1
	var face_normals := PackedVector3Array()  # area-weighted; own triangles, then extra ones
	face_normals.resize(triangle_count + extra_count)
	var unit_normals := PackedVector3Array()
	unit_normals.resize(triangle_count + extra_count)
	for t in triangle_count + extra_count:
		var a: Vector3
		var b: Vector3
		var c: Vector3
		if t < triangle_count:
			a = positions[indices[t * 3]]
			b = positions[indices[t * 3 + 1]]
			c = positions[indices[t * 3 + 2]]
		else:
			var e := (t - triangle_count) * 3
			a = extra_faces[e]
			b = extra_faces[e + 1]
			c = extra_faces[e + 2]
		var n := (c - a).cross(b - a)
		face_normals[t] = n
		unit_normals[t] = n.normalized() if n.length_squared() > 0.0 else Vector3.ZERO
	# Vertices grouped by snapped position (so seam vertices computed separately on each
	# side still meet, and UV seams don't split smoothing), then the triangles around each
	# group as flat arrays: own visible triangles in order, then extra faces. Hidden
	# triangles don't count.
	var group_of := PackedInt32Array()
	group_of.resize(vertex_count)
	var groups := {}
	for v in vertex_count:
		var key := _snap(positions[v])
		var g: int = groups.get(key, -1)
		if g < 0:
			g = groups.size()
			groups[key] = g
		group_of[v] = g
	var extra_group := PackedInt32Array()
	extra_group.resize(extra_count * 3)
	for k in extra_count * 3:
		extra_group[k] = groups.get(_snap(extra_faces[k]), -1)
	var start := PackedInt32Array()
	start.resize(groups.size() + 1)
	for t in triangle_count:
		if not hidden[t]:
			for c in 3:
				start[group_of[indices[t * 3 + c]] + 1] += 1
	for k in extra_count * 3:
		if extra_group[k] >= 0:
			start[extra_group[k] + 1] += 1
	for g in groups.size():
		start[g + 1] += start[g]
	var around := PackedInt32Array()
	around.resize(start[groups.size()])
	var fill := start.duplicate()
	for t in triangle_count:
		if not hidden[t]:
			for c in 3:
				var g := group_of[indices[t * 3 + c]]
				around[fill[g]] = t
				fill[g] += 1
	for k in extra_count * 3:
		var g := extra_group[k]
		if g >= 0:
			around[fill[g]] = triangle_count + k / 3
			fill[g] += 1
	# Triangles per tag.
	var by_tag := {}
	for t in triangle_count:
		if hidden[t]:
			continue
		var tag := tags[t]
		if not by_tag.has(tag):
			by_tag[tag] = PackedInt32Array()
		var list: PackedInt32Array = by_tag[tag]
		list.append(t)
		by_tag[tag] = list
	var threshold := cos(deg_to_rad(crease_angle))
	var has_uv := uvs.size() == vertex_count
	var out := []
	var sorted_tags := by_tag.keys()
	sorted_tags.sort()
	# Output vertices are shared by corners with the same vertex and normal: a chain per
	# vertex of the output vertices made from it so far.
	var first_out := PackedInt32Array()
	first_out.resize(vertex_count)
	for tag: int in sorted_tags:
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var surface_uvs := PackedVector2Array()
		var surface_indices := PackedInt32Array()
		var next_out := PackedInt32Array()
		first_out.fill(-1)
		for t: int in by_tag[tag]:
			var own := unit_normals[t]
			for c in 3:
				var vi := indices[t * 3 + c]
				var g := group_of[vi]
				var normal := Vector3.ZERO
				for k in range(start[g], start[g + 1]):
					var other := around[k]
					if unit_normals[other].dot(own) >= threshold:
						normal += face_normals[other]
				normal = normal.normalized() if normal.length_squared() > 0.0 else own
				var out_index := first_out[vi]
				while out_index >= 0 and normals[out_index] != normal:
					out_index = next_out[out_index]
				if out_index < 0:
					out_index = vertices.size()
					vertices.append(positions[vi])
					normals.append(normal)
					surface_uvs.append(uvs[vi] if has_uv else Vector2.ZERO)
					next_out.append(first_out[vi])
					first_out[vi] = out_index
				surface_indices.append(out_index)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		if has_uv:
			arrays[Mesh.ARRAY_TEX_UV] = surface_uvs
		arrays[Mesh.ARRAY_INDEX] = surface_indices
		out.append([tag, arrays])
	return out
