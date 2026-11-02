@tool
class_name SdfDualContouringCpuMesher
extends DualMesher
## Dual contouring of signed distance data (Carrera, Wang, Batty, Stein and Sellán, SIGGRAPH
## 2026, arXiv:2604.00157) in plain GDScript. Like [DualContouringCpuMesher] it keeps sharp
## edges and corners, but it needs only the sampled distances: no exact normals. Each sample
## is treated as a sphere the surface should touch (radius = its distance), and vertices
## and the Hermite data (crossing points and normals) are refined together until the mesh
## fits those spheres.
##
## Outline, per outer iteration:
## [br]1. Triangulate the current mesh and give every sample near the surface to the cell
##    holding its closest point on the mesh.
## [br]2. In every cell, move the vertex to fit the cell's samples: the distance from each
##    sample to the cell's local mesh (the vertex fanned to the cell's crossing points)
##    should equal its radius. Solved by linearising along the sample-to-mesh direction and
##    iterating ([member inner_iterations]), with a pull towards the tangent planes of the
##    Hermite data ([member hermite_weight]) and a damping term ([member regularization]).
## [br]3. Fit a plane to the four vertices around every crossed edge and move the edge's
##    crossing and normal towards it ([member update_weight]).
##
## [b]Samples must be distances[/b] in output units (iso subtracted), as they are for an SDF.
## It is far slower than dual contouring, and vertices depend on samples around their cell,
## so neighbouring blocks don't meet exactly: use it for single blocks or offline meshing of
## sharp, CAD-like shapes. The paper's defaults are 100 outer and 100 inner iterations; the
## ones here are lower and stop early once vertices settle.

## Outer iterations (assign samples, place vertices, update Hermite data).
@export_range(1, 200) var outer_iterations := 6
## Inner iterations of each cell's vertex fit per outer iteration.
@export_range(1, 200) var inner_iterations := 6
## Weight of the Hermite (tangent plane) term against the distance term. Paper default 0.02.
@export_range(0.0, 10.0, 0.001) var hermite_weight := 0.02
## How far each outer iteration moves crossings and normals towards the fitted planes, 0 to
## 1. Paper default 0.2.
@export_range(0.0, 1.0, 0.01) var update_weight := 0.2
## Damping that keeps each linearised step close to the last one (the paper's mu, 0.01 to
## 0.1).
@export_range(0.0, 10.0, 0.001) var regularization := 0.1
## Stop when no vertex moves more than this (in cells).
@export_range(0.0, 1.0, 0.0001) var tolerance := 0.001
## Samples within this many cells of the surface are fitted.
@export_range(0.5, 4.0, 0.1) var band := 1.5
## Clamp vertices into their cell.
@export var keep_in_cell := true

const _DIAGONAL := 1.7320508


func _needs_every_quad() -> bool:
	return true


func _place_vertices(s: DualMesher.Surface) -> void:
	_init_hermite(s)
	var positions := s.cell_position
	for c in s.get_cell_count():
		var mass := Vector3.ZERO
		for e in s.cell_edges[c]:
			mass += s.edge_point[e]
		positions[c] = mass / maxi(s.cell_edges[c].size(), 1)
	s.cell_position = positions

	var nodes := _band_samples(s)
	var node_points: PackedVector3Array = nodes[0]
	var node_radius: PackedFloat32Array = nodes[1]
	var candidates := _candidate_quads(s, node_points, node_radius)
	var quads_of_edge := _quad_of_edge(s)
	var segments := _cell_segments(s)

	for k in outer_iterations:
		var assigned := _assign(s, node_points, node_radius, candidates)
		var moved := _fit_vertices(s, assigned, node_points, node_radius, segments)
		_update_hermite(s, quads_of_edge)
		if moved < tolerance:
			break

	var normals := s.cell_normal
	for c in s.get_cell_count():
		var sum := Vector3.ZERO
		for e in s.cell_edges[c]:
			sum += s.edge_normal[e]
		normals[c] = sum.normalized() if sum.length_squared() > 0.0 else Vector3.UP
	s.cell_normal = normals


# Crossing normals: the trilinear gradient at the crossing, averaged over the cells around
# the edge (paper eq. 2).
func _init_hermite(s: DualMesher.Surface) -> void:
	var normals := s.edge_normal
	for e in s.edge_sample.size():
		var a := s.edge_axis[e]
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		var p := s.edge_coord(e)
		var sum := Vector3.ZERO
		for k in 4:
			var c := p
			c[u] -= k & 1
			c[v] -= k >> 1
			if s.has_cell(c):
				sum += s.gradient_in_cell(c, s.edge_point[e]).normalized()
		normals[e] = sum.normalized() if sum.length_squared() > 0.0 else Vector3.UP
	s.edge_normal = normals


# Samples within [member band] of the surface, as [positions, radii] in grid space.
func _band_samples(s: DualMesher.Surface) -> Array:
	var points := PackedVector3Array()
	var radii := PackedFloat32Array()
	var scale := 1.0 / s.grid.spacing
	var i := 0
	for z in s.size.z:
		for y in s.size.y:
			for x in s.size.x:
				var r := absf(s.values[i] - s.iso) * scale
				if r <= band:
					points.append(Vector3(x, y, z))
					radii.append(r)
				i += 1
	return [points, radii]


# Quads each sample could be closest to: those touching a cell within its radius plus one
# cell. Topology doesn't change while vertices move, so this is done once.
func _candidate_quads(s: DualMesher.Surface, points: PackedVector3Array, radii: PackedFloat32Array) -> Array:
	var quads_of_cell: Array[PackedInt32Array] = []
	quads_of_cell.resize(s.get_cell_count())
	for q in s.get_quad_count():
		for k in 4:
			var c := s.quad_cells[q * 4 + k]
			var list := quads_of_cell[c]
			list.append(q)
			quads_of_cell[c] = list
	var out := []
	out.resize(points.size())
	var seen := {}
	for n in points.size():
		var reach := radii[n] + 1.0
		var lo := Vector3i((points[n] - Vector3.ONE * reach).floor())
		var hi := Vector3i((points[n] + Vector3.ONE * reach).floor())
		seen.clear()
		var list := PackedInt32Array()
		for z in range(lo.z, hi.z + 1):
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var c := s.cell_at(Vector3i(x, y, z))
					if c < 0:
						continue
					for q in quads_of_cell[c]:
						if not seen.has(q):
							seen[q] = true
							list.append(q)
		out[n] = list
	return out


# The quad crossing each edge, or -1 for edges with cells missing around them.
func _quad_of_edge(s: DualMesher.Surface) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(s.edge_sample.size())
	out.fill(-1)
	for q in s.get_quad_count():
		out[s.quad_edge[q]] = q
	return out


# Each cell's local surface as pairs of its crossed edges that share a face of the cell
# (two crossings on a face join directly; four are paired around the corners that differ
# from the face centre).
func _cell_segments(s: DualMesher.Surface) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for c in s.get_cell_count():
		var coord := s.cell_coord[c]
		var pairs := PackedInt32Array()
		for w in 3:
			for side in 2:
				var on_face := PackedInt32Array()
				for e in s.cell_edges[c]:
					var a := s.edge_axis[e]
					if a == w:
						continue
					if s.edge_coord(e)[w] - coord[w] == side:
						on_face.append(e)
				if on_face.size() == 2:
					pairs.append_array(on_face)
				elif on_face.size() == 4:
					pairs.append_array(_pair_ambiguous(s, coord, w, side, on_face))
		out.append(pairs)
	return out


func _pair_ambiguous(s: DualMesher.Surface, coord: Vector3i, w: int, side: int, edges: PackedInt32Array) -> PackedInt32Array:
	var u := (w + 1) % 3
	var v := (w + 2) % 3
	var corners: Array[Vector3i] = []
	var total := 0.0
	for k in 4:
		var p := coord
		p[w] += side
		p[u] += k & 1
		p[v] += k >> 1
		corners.append(p)
		total += s.values[p.x + s.strides[1] * p.y + s.strides[2] * p.z]
	var centre_inside := total * 0.25 < s.iso
	var out := PackedInt32Array()
	for p in corners:
		var inside := s.values[p.x + s.strides[1] * p.y + s.strides[2] * p.z] < s.iso
		if inside == centre_inside:
			continue
		# The corner is cut off from the centre: join the two crossings next to it.
		for e in edges:
			var ec := s.edge_coord(e)
			var a := s.edge_axis[e]
			if ec == p or (ec + _unit(a)) == p:
				out.append(e)
	return out


static func _unit(axis: int) -> Vector3i:
	var v := Vector3i.ZERO
	v[axis] = 1
	return v


# Gives each sample to the cell holding its closest point on the current mesh (paper
# section 4.1). Returns per cell the sample ids.
func _assign(s: DualMesher.Surface, points: PackedVector3Array, radii: PackedFloat32Array, candidates: Array) -> Array[PackedInt32Array]:
	var triangles := PackedInt32Array()
	for q in s.get_quad_count():
		triangles.append_array(s.quad_triangles(q))
	var positions := s.cell_position
	var out: Array[PackedInt32Array] = []
	out.resize(s.get_cell_count())
	for n in points.size():
		var u := points[n]
		var best := INF
		var best_point := Vector3.ZERO
		for q: int in candidates[n]:
			for t in range(q * 6, q * 6 + 6, 3):
				var a := positions[triangles[t]]
				var b := positions[triangles[t + 1]]
				var c := positions[triangles[t + 2]]
				var w := closest_on_triangle(u, a, b, c)
				var p := a * w.x + b * w.y + c * w.z
				var d := u.distance_squared_to(p)
				if d < best:
					best = d
					best_point = p
		if best == INF or sqrt(best) > _DIAGONAL + radii[n]:
			continue
		var cell := s.cell_at(Vector3i(best_point.floor()))
		if cell < 0:
			continue
		var list := out[cell]
		list.append(n)
		out[cell] = list
	return out


# Moves every cell's vertex to fit its samples (paper section 4.2). Returns the largest move.
func _fit_vertices(s: DualMesher.Surface, assigned: Array[PackedInt32Array], points: PackedVector3Array,
		radii: PackedFloat32Array, segments: Array[PackedInt32Array]) -> float:
	var positions := s.cell_position
	var moved := 0.0
	var ata := PackedFloat64Array()
	var atb := PackedFloat64Array()
	for c in s.get_cell_count():
		var start := positions[c]
		var x := start
		var pairs := segments[c]
		var samples := assigned[c]
		var coord := Vector3(s.cell_coord[c])
		for r in inner_iterations:
			ata.resize(0)
			ata.resize(9)
			atb.resize(0)
			atb.resize(3)
			for k in 3:
				ata[k * 4] = regularization
				atb[k] = regularization * x[k]
			for e in s.cell_edges[c]:
				var n := s.edge_normal[e]
				Qef.add_plane(ata, atb, n, n.dot(s.edge_point[e]), hermite_weight)
			for j in samples:
				var u := points[j]
				var best := INF
				var best_w := Vector3.ZERO
				var best_a := Vector3.ZERO
				var best_b := Vector3.ZERO
				for k in range(0, pairs.size(), 2):
					var ha := s.edge_point[pairs[k]]
					var hb := s.edge_point[pairs[k + 1]]
					var w := closest_on_triangle(u, x, ha, hb)
					var d := u.distance_squared_to(x * w.x + ha * w.y + hb * w.z)
					if d < best:
						best = d
						best_w = w
						best_a = ha
						best_b = hb
				if best == INF or best_w.x <= 0.0:
					continue  # the closest point doesn't move with the vertex
				var to := x * best_w.x + best_a * best_w.y + best_b * best_w.z - u
				if to.length_squared() < 1e-12:
					continue
				var dir := to.normalized()
				var target := u + dir * radii[j]
				# (alpha x + beta ha + gamma hb - target) . dir = 0, linear in x.
				var rhs := (target - best_a * best_w.y - best_b * best_w.z).dot(dir)
				Qef.add_plane(ata, atb, dir * best_w.x, rhs, 1.0)
			var next := Qef.solve_3x3(ata, atb, x)
			if keep_in_cell:
				next = next.clamp(coord, coord + Vector3.ONE)
			var step := next.distance_to(x)
			x = next
			if step < tolerance:
				break
		positions[c] = x
		moved = maxf(moved, x.distance_to(start))
	s.cell_position = positions
	return moved


# Fits a plane to the four vertices around each crossed edge and moves the crossing and its
# normal towards it (paper eq. 7).
func _update_hermite(s: DualMesher.Surface, quad_of_edge: PackedInt32Array) -> void:
	var points := s.edge_point
	var normals := s.edge_normal
	var corners := PackedVector3Array()
	corners.resize(4)
	for e in points.size():
		var q := quad_of_edge[e]
		if q < 0:
			continue
		for k in 4:
			corners[k] = s.cell_position[s.quad_cells[q * 4 + k]]
		var plane := Qef.fit_plane(corners)
		var centre: Vector3 = plane[0]
		var n: Vector3 = plane[1]
		if n.dot(normals[e]) < 0.0:
			n = -n
		var a := s.edge_axis[e]
		var low := Vector3(s.edge_coord(e))
		if absf(n[a]) > 1e-6:
			var t := clampf(n.dot(centre - low) / n[a], 0.0, 1.0)
			var y := low
			y[a] += t
			points[e] += (y - points[e]) * update_weight
		var blended := n + normals[e] * update_weight
		if blended.length_squared() > 0.0:
			normals[e] = blended.normalized()
	s.edge_point = points
	s.edge_normal = normals


## Barycentric weights (for a, b, c) of the point of triangle a b c closest to [param p]
## (Ericson, Real-Time Collision Detection, 5.1.5).
static func closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return Vector3(1, 0, 0)
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return Vector3(0, 1, 0)
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0 and d1 - d3 != 0.0:
		var t := d1 / (d1 - d3)
		return Vector3(1.0 - t, t, 0)
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return Vector3(0, 0, 1)
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0 and d2 - d6 != 0.0:
		var t := d2 / (d2 - d6)
		return Vector3(1.0 - t, 0, t)
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0 and (d4 - d3) + (d5 - d6) != 0.0:
		var t := (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return Vector3(0, 1.0 - t, t)
	var sum := va + vb + vc
	if sum == 0.0:  # degenerate triangle: nearest corner
		var da := p.distance_squared_to(a)
		var db := p.distance_squared_to(b)
		var dc := p.distance_squared_to(c)
		if da <= db and da <= dc:
			return Vector3(1, 0, 0)
		return Vector3(0, 1, 0) if db <= dc else Vector3(0, 0, 1)
	var v := vb / sum
	var w := vc / sum
	return Vector3(1.0 - v - w, v, w)
