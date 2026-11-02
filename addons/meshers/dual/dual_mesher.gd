@tool
@abstract
class_name DualMesher
extends Mesher
## Base for the dual meshers (dual contouring and its variants): one vertex in every cell the
## surface passes through, joined by a quad across every grid edge the surface crosses.
## Subclasses only decide where each cell's vertex goes ([method _place_vertices]); finding
## the crossings, joining quads, normals and materials happen here.
##
## [b]Blocks.[/b] A grid meshes the quads of grid edges in its cell range, reaching one cell
## past [member MesherGrid.cell_end] (the cell whose lowest sample is the last one in the
## range), so give the grid one sample of padding past the range, as for marching cubes.
## Neighbouring blocks that share their boundary samples then mesh every edge exactly once
## and, when vertex placement only reads the cell's own samples, put the shared cells'
## vertices in the same place, so the blocks join without gaps.
##
## Not supported: [member MesherGrid.transitions] (Transvoxel is a marching cubes scheme)
## and [member MesherGrid.skirt_depth]. Grids that set them mesh without them, with a
## warning.

## Shade every triangle flat (vertices aren't shared between triangles) instead of smoothly
## with one normal per cell vertex. Dual contouring keeps sharp edges in the geometry; flat
## shading shows them.
@export var flat_shading := false

var _warned := false


func polygonize(grid: MesherGrid) -> MeshData:
	if not _warned and (not grid.transitions.is_empty() or grid.skirt_depth > 0.0):
		_warned = true
		push_warning("%s: transition cells and skirts aren't supported; meshing without them."
				% get_script().get_global_name())
	var surface := Surface.new(grid, _needs_every_quad())
	if surface.get_cell_count() > 0:
		_place_vertices(surface)
	return surface.build_mesh(flat_shading)


## Sets [member Surface.cell_position] (grid space: sample units, from sample (0, 0, 0)) and
## [member Surface.cell_normal] for every cell of [param surface]. Runs on worker threads.
@abstract func _place_vertices(surface: Surface) -> void


## True to get every quad the grid's samples allow in [member Surface.quad_cells] (with
## [member Surface.quad_owned] saying which this grid meshes), for placements that look past
## the cell range. False gets only the quads this grid meshes, and only their cells.
func _needs_every_quad() -> bool:
	return false


## What a dual mesher works on: the grid edges the surface crosses, the cells with a vertex
## and the quads joining them. Positions are in grid space (sample units, from sample
## (0, 0, 0)); [method build_mesh] maps them to output space.
class Surface:
	var grid: MesherGrid
	var values: PackedFloat32Array
	var iso := 0.0
	var size := Vector3i.ZERO
	## Index step along x, y, z.
	var strides := PackedInt32Array()

	## Edges the surface crosses: lower sample index, axis, crossing point (linear
	## interpolation), whether the lower sample is the inside one, and a normal for meshers
	## that keep one per edge.
	var edge_sample := PackedInt32Array()
	var edge_axis := PackedInt32Array()
	var edge_point := PackedVector3Array()
	var edge_low_inside := PackedByteArray()
	var edge_normal := PackedVector3Array()

	## Cells with a vertex: lowest sample, the crossed edges of their 12, the vertex and its
	## normal (set by the mesher), and a material id.
	var cell_coord: Array[Vector3i] = []
	var cell_edges: Array[PackedInt32Array] = []
	var cell_position := PackedVector3Array()
	var cell_normal := PackedVector3Array()
	var cell_material := PackedInt32Array()

	## Four cell ids per quad, in front-face order (outward normal (c - a) x (b - a) for
	## both triangles), and the edge each quad crosses.
	var quad_cells := PackedInt32Array()
	var quad_edge := PackedInt32Array()
	var quad_owned := PackedByteArray()

	var _edge_of := PackedInt32Array()
	var _cell_of := PackedInt32Array()

	func _init(from: MesherGrid, every_quad: bool) -> void:
		grid = from
		values = from.get_values()
		iso = from.iso
		size = from.size
		strides = PackedInt32Array([1, size.x, size.x * size.y])
		_edge_of.resize(values.size() * 3)
		_edge_of.fill(-1)
		_cell_of.resize(values.size())
		_cell_of.fill(-1)
		var begin := from.cell_begin
		var end := from.get_cell_end()
		for a in 3:
			var u := (a + 1) % 3
			var v := (a + 2) % 3
			# Inclusive range of each edge's lower sample p. Its quad's cells run from
			# p - 1 to p along u and v, so those need samples from p - 1 to p + 1.
			var lo := Vector3i.ZERO
			var hi := Vector3i.ZERO
			for b in 3:
				if every_quad:
					lo[b] = 0 if b == a else 1
					hi[b] = size[b] - 2
				elif b == a:
					lo[b] = begin[b]
					hi[b] = end[b] - 1
				else:
					lo[b] = begin[b] + 1
					hi[b] = mini(end[b], size[b] - 2)
			var stride := strides[a]
			for z in range(lo.z, hi.z + 1):
				for y in range(lo.y, hi.y + 1):
					var row := strides[1] * y + strides[2] * z
					for x in range(lo.x, hi.x + 1):
						var i := row + x
						var low_inside := values[i] < iso
						if low_inside == (values[i + stride] < iso):
							continue
						var p := Vector3i(x, y, z)
						var owned := true
						if every_quad:
							for b in 3:
								var first := begin[b] if b == a else begin[b] + 1
								var last := end[b] - 1 if b == a else end[b]
								if p[b] < first or p[b] > last:
									owned = false
						var c0 := p
						c0[u] -= 1
						c0[v] -= 1
						var c1 := p
						c1[v] -= 1
						var c3 := p
						c3[u] -= 1
						# Seen from +a, c0 c1 p c3 runs counterclockwise; front faces are
						# clockwise seen from outside, which is +a when the low end is inside.
						var ids := PackedInt32Array([_cell(c0), _cell(c1), _cell(p), _cell(c3)])
						if low_inside:
							ids = PackedInt32Array([ids[0], ids[3], ids[2], ids[1]])
						quad_cells.append_array(ids)
						quad_edge.append(_edge(i, a, p))
						quad_owned.append(1 if owned else 0)
		cell_position.resize(cell_coord.size())
		cell_normal.resize(cell_coord.size())

	func get_cell_count() -> int:
		return cell_coord.size()

	func get_quad_count() -> int:
		return quad_edge.size()

	## Cell id of the cell with lowest sample [param c], or -1 when it has no vertex.
	func cell_at(c: Vector3i) -> int:
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x > size.x - 2 or c.y > size.y - 2 or c.z > size.z - 2:
			return -1
		return _cell_of[c.x + strides[1] * c.y + strides[2] * c.z]

	## True when the grid has all eight samples of the cell with lowest sample [param c].
	func has_cell(c: Vector3i) -> bool:
		return c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x <= size.x - 2 and c.y <= size.y - 2 and c.z <= size.z - 2

	## Lowest sample of edge [param e].
	func edge_coord(e: int) -> Vector3i:
		var i := edge_sample[e]
		return Vector3i(i % size.x, (i / size.x) % size.y, i / strides[2])

	## Gradient of the trilinear interpolation of cell [param c]'s samples at [param p]
	## (grid space, clamped into the cell). Points from inside to outside.
	func gradient_in_cell(c: Vector3i, p: Vector3) -> Vector3:
		var i := c.x + strides[1] * c.y + strides[2] * c.z
		var sx := strides[1]
		var sxy := strides[2]
		var v000 := values[i]
		var v100 := values[i + 1]
		var v010 := values[i + sx]
		var v110 := values[i + sx + 1]
		var v001 := values[i + sxy]
		var v101 := values[i + sxy + 1]
		var v011 := values[i + sxy + sx]
		var v111 := values[i + sxy + sx + 1]
		var t := (p - Vector3(c)).clamp(Vector3.ZERO, Vector3.ONE)
		return Vector3(
				lerpf(lerpf(v100 - v000, v110 - v010, t.y), lerpf(v101 - v001, v111 - v011, t.y), t.z),
				lerpf(lerpf(v010 - v000, v110 - v100, t.x), lerpf(v011 - v001, v111 - v101, t.x), t.z),
				lerpf(lerpf(v001 - v000, v101 - v100, t.x), lerpf(v011 - v010, v111 - v110, t.x), t.y))

	## Triangle corners (cell ids, three per triangle) for quad [param q]: split along the
	## diagonal that bends the quad least, the shorter one on a tie.
	func quad_triangles(q: int) -> PackedInt32Array:
		var k := q * 4
		var a := quad_cells[k]
		var b := quad_cells[k + 1]
		var c := quad_cells[k + 2]
		var d := quad_cells[k + 3]
		var pa := cell_position[a]
		var pb := cell_position[b]
		var pc := cell_position[c]
		var pd := cell_position[d]
		var flat_ac := _normal(pa, pb, pc).dot(_normal(pa, pc, pd))
		var flat_bd := _normal(pb, pc, pd).dot(_normal(pb, pd, pa))
		if flat_ac > flat_bd + 1e-6 or (absf(flat_ac - flat_bd) <= 1e-6
				and pa.distance_squared_to(pc) <= pb.distance_squared_to(pd)):
			return PackedInt32Array([a, b, c, a, c, d])
		return PackedInt32Array([b, c, d, b, d, a])

	## The quads this grid meshes as [MeshData] in output space.
	func build_mesh(flat: bool) -> MeshData:
		var out := MeshData.new()
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		var origin := grid.origin
		var spacing := grid.spacing
		var vertex_of := PackedInt32Array()
		vertex_of.resize(cell_coord.size())
		vertex_of.fill(-1)
		for q in quad_edge.size():
			if quad_owned[q] == 0:
				continue
			var corners := quad_triangles(q)
			for t in range(0, 6, 3):
				var ids := [corners[t], corners[t + 1], corners[t + 2]]
				if flat:
					var p0 := origin + cell_position[ids[0]] * spacing
					var p1 := origin + cell_position[ids[1]] * spacing
					var p2 := origin + cell_position[ids[2]] * spacing
					var n := _normal(p0, p1, p2)
					if n == Vector3.ZERO:
						n = cell_normal[ids[0]]
					for e in 3:
						indices.append(vertices.size())
						vertices.append([p0, p1, p2][e])
						normals.append(n)
						colors.append(Color8(cell_material[ids[e]], 0, 0))
					continue
				for cell: int in ids:
					if vertex_of[cell] < 0:
						vertex_of[cell] = vertices.size()
						vertices.append(origin + cell_position[cell] * spacing)
						normals.append(cell_normal[cell])
						colors.append(Color8(cell_material[cell], 0, 0))
					indices.append(vertex_of[cell])
		out.vertices = vertices
		out.normals = normals
		out.colors = colors
		out.indices = indices
		return out

	# Outward unit normal of triangle a b c (Godot front faces are clockwise), or zero.
	static func _normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
		var n := (c - a).cross(b - a)
		return n / sqrt(n.length_squared()) if n.length_squared() > 1e-20 else Vector3.ZERO

	func _cell(c: Vector3i) -> int:
		var i := c.x + strides[1] * c.y + strides[2] * c.z
		if _cell_of[i] >= 0:
			return _cell_of[i]
		var id := cell_coord.size()
		_cell_of[i] = id
		cell_coord.append(c)
		var edges := PackedInt32Array()
		for a in 3:
			var u := (a + 1) % 3
			var v := (a + 2) % 3
			for k in 4:
				var p := c
				p[u] += k & 1
				p[v] += k >> 1
				var j := p.x + strides[1] * p.y + strides[2] * p.z
				if (values[j] < iso) != (values[j + strides[a]] < iso):
					edges.append(_edge(j, a, p))
		cell_edges.append(edges)
		cell_material.append(_material(i))
		return id

	func _edge(i: int, axis: int, p: Vector3i) -> int:
		var key := i * 3 + axis
		if _edge_of[key] >= 0:
			return _edge_of[key]
		var va := values[i]
		var vb := values[i + strides[axis]]
		var f := 0.5 if va == vb else clampf((iso - va) / (vb - va), 0.0, 1.0)
		var point := Vector3(p)
		point[axis] += f
		var id := edge_sample.size()
		_edge_of[key] = id
		edge_sample.append(i)
		edge_axis.append(axis)
		edge_point.append(point)
		edge_low_inside.append(1 if va < iso else 0)
		edge_normal.append(Vector3.ZERO)
		return id

	# The most common material among the cell's inside samples (lowest id on a tie).
	func _material(i: int) -> int:
		if grid.materials.size() != values.size():
			return 0
		var counts := {}
		for k in 8:
			var j := i + (k & 1) + strides[1] * ((k >> 1) & 1) + strides[2] * (k >> 2)
			if values[j] < iso:
				var id := grid.materials[j]
				counts[id] = counts.get(id, 0) + 1
		var best := 0
		var best_count := 0
		for id: int in counts:
			if counts[id] > best_count or (counts[id] == best_count and id < best):
				best = id
				best_count = counts[id]
		return best
