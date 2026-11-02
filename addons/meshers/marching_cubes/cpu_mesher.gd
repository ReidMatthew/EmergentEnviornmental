@tool
class_name MarchingCubesCpuMesher
extends Mesher
## Marching cubes in plain GDScript. Slowest backend, but it runs everywhere (including the
## Compatibility renderer) and is the reference the other backends are checked against.
##
## Vertices are shared between neighbouring cells, and normals come from the density
## gradient, so the surface is smooth and matches across chunk seams as long as the grid
## has one sample of padding on every side of the cells being polygonised.
##
## Faces in [member MesherGrid.transitions] get Transvoxel transition cells: the last layer of
## cells next to such a face is squeezed away from it, and the gap is filled with cells that
## use the finer neighbour's samples on the face, so the surfaces meet exactly.


func polygonize(grid: MesherGrid) -> MeshData:
	var out := MeshData.new()
	var values := grid.get_values()
	var size := grid.size
	var sx := size.x
	var sxy := size.x * size.y
	var iso := grid.iso
	var begin := grid.cell_begin
	var end := grid.get_cell_end()
	var tri := MarchingCubesTables.tri_table
	var edge_origin := MarchingCubesTables.EDGE_ORIGIN
	var edge_axis := MarchingCubesTables.EDGE_AXIS
	var axis_stride := PackedInt32Array([1, sx, sxy])

	var corner := PackedInt32Array()
	for c in MarchingCubesTables.CORNERS:
		corner.append(c.x + c.y * sx + c.z * sxy)
	var c1 := corner[1]
	var c2 := corner[2]
	var c3 := corner[3]
	var c4 := corner[4]
	var c5 := corner[5]
	var c6 := corner[6]
	var c7 := corner[7]
	var edge_offset := PackedInt32Array()
	for o in edge_origin:
		edge_offset.append(o.x + o.y * sx + o.z * sxy)

	var builder := _Builder.new()
	builder.grid = grid
	builder.values = values
	builder.has_materials = grid.materials.size() == values.size()
	builder.skirts = grid.skirt_depth > 0.0
	builder.transition_faces = grid.get_transition_faces()
	builder.vertex_of_edge.resize(values.size() * 3)
	builder.vertex_of_edge.fill(-1)
	var vertex_of_edge := builder.vertex_of_edge
	var indices := builder.indices

	for z in range(begin.z, end.z):
		for y in range(begin.y, end.y):
			var row := sx * y + sxy * z
			for x in range(begin.x, end.x):
				var i := row + x
				var cube := 0
				if values[i] < iso: cube |= 1
				if values[i + c1] < iso: cube |= 2
				if values[i + c2] < iso: cube |= 4
				if values[i + c3] < iso: cube |= 8
				if values[i + c4] < iso: cube |= 16
				if values[i + c5] < iso: cube |= 32
				if values[i + c6] < iso: cube |= 64
				if values[i + c7] < iso: cube |= 128
				if cube == 0 or cube == 255:
					continue

				var t := cube << 4
				var edge := tri[t]
				while edge != -1:
					var a := i + edge_offset[edge]
					var axis := edge_axis[edge]
					var vi := vertex_of_edge[a * 3 + axis]
					if vi < 0:
						vi = builder.edge_vertex(a, Vector3i(x, y, z) + edge_origin[edge], axis)
					indices.append(vi)
					t += 1
					edge = tri[t]

	for transition in grid.transitions:
		builder.add_transition(transition)

	if MarchingCubesTables.FLIP_WINDING:
		for k in range(0, indices.size(), 3):
			var tmp := indices[k + 1]
			indices[k + 1] = indices[k + 2]
			indices[k + 2] = tmp

	out.vertices = builder.vertices
	out.normals = builder.normals
	out.colors = builder.colors
	out.indices = indices
	if builder.skirts:
		MesherSkirts.add(out, grid, builder.face_masks)
	return out


## Central-difference gradient at sample [param p] (index [param i]), one-sided at the grid
## border. Points from inside to outside, so it is the outward normal.
static func _gradient(values: PackedFloat32Array, size: Vector3i, p: Vector3i, i: int) -> Vector3:
	var sx := size.x
	var sxy := size.x * size.y
	return Vector3(
		_diff(values, i, 1, p.x, size.x),
		_diff(values, i, sx, p.y, size.y),
		_diff(values, i, sxy, p.z, size.z))


static func _diff(values: PackedFloat32Array, i: int, stride: int, coord: int, count: int) -> float:
	if coord <= 0:
		return values[i + stride] - values[i]
	if coord >= count - 1:
		return values[i] - values[i - stride]
	return (values[i + stride] - values[i - stride]) * 0.5


## Squeezes grid-space position [param p] of a vertex on the grid edge from sample
## [param pa] along [param axis] away from the transition faces in [param faces]: positions
## within a cell of such a face move into the part of that cell the transition cells don't
## use. Vertices on a boundary face without transition cells stay put, since the neighbour
## there meets them exactly.
static func squeeze(grid: MesherGrid, faces: int, p: Vector3, pa: Vector3i, axis: int) -> Vector3:
	if faces == 0:
		return p
	var begin := grid.cell_begin
	var end := grid.get_cell_end()
	for b in 3:
		if b == axis:
			continue
		if (pa[b] == begin[b] and faces & MesherSkirts.face_bit(b, false) == 0) \
				or (pa[b] == end[b] and faces & MesherSkirts.face_bit(b, true) == 0):
			return p
	var width := grid.transition_width
	var q := p
	for a in 3:
		if faces & MesherSkirts.face_bit(a, false) and p[a] < begin[a] + 1:
			q[a] = begin[a] + width + (p[a] - begin[a]) * (1.0 - width)
		elif faces & MesherSkirts.face_bit(a, true) and p[a] > end[a] - 1:
			q[a] = end[a] - width - (end[a] - p[a]) * (1.0 - width)
	return q


# Collects the mesh: regular vertices per grid edge, then transition cells.
class _Builder:
	var grid: MesherGrid
	var values: PackedFloat32Array
	var has_materials := false
	var skirts := false
	var transition_faces := 0
	var vertex_of_edge := PackedInt32Array()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	## Boundary faces per vertex, for skirts.
	var face_masks := PackedInt32Array()

	# Creates the vertex on the grid edge from sample index [param a] (at [param pa]) along
	# [param axis].
	func edge_vertex(a: int, pa: Vector3i, axis: int) -> int:
		var size := grid.size
		var stride: int = [1, size.x, size.x * size.y][axis]
		var b := a + stride
		var va := values[a]
		var vb := values[b]
		var iso := grid.iso
		var f := 0.5 if va == vb else clampf((iso - va) / (vb - va), 0.0, 1.0)
		var pb := pa
		pb[axis] += 1
		var p := Vector3(pa)
		p[axis] += f
		var squeezed := MarchingCubesCpuMesher.squeeze(grid, transition_faces, p, pa, axis)
		var vi := vertices.size()
		vertex_of_edge[a * 3 + axis] = vi
		vertices.append(grid.origin + squeezed * grid.spacing)
		var n := MarchingCubesCpuMesher._gradient(values, size, pa, a).lerp(
				MarchingCubesCpuMesher._gradient(values, size, pb, b), f)
		normals.append(n.normalized() if n.length_squared() > 0.0 else Vector3.UP)
		var id := 0
		if has_materials:
			id = grid.materials[a] if va < iso else grid.materials[b]
		colors.append(Color8(id, 0, 0))
		if skirts:
			var mask := MesherSkirts.edge_face_mask(grid, pa, axis)
			if squeezed != p:
				mask &= ~transition_faces  # moved off the face: the transition cells close it
			face_masks.append(mask)
		return vi

	func add_transition(transition: MesherTransition) -> void:
		var face := transition.face
		var axes := MesherTransition.axes(face)
		var w := axes.x
		var u := axes.y
		var v := axes.z
		var dims := MesherTransition.dimensions(grid, face)
		var begin := grid.cell_begin
		var end := grid.get_cell_end()
		var cells_u := end[u] - begin[u]
		var cells_v := end[v] - begin[v]
		var plane := end[w] if face & 1 else begin[w]
		var iso := grid.iso
		var lut := PackedFloat32Array()
		lut.resize(256)
		for k in 256:
			lut[k] = (k - grid.byte_center) * grid.byte_scale
		var slab := transition.bytes
		var has_ids := not transition.materials.is_empty()
		var fine_u := 2 * cells_u + 1
		# Vertex per full-resolution edge on the face: ((j * fine_u + i) * 2 + 0 along u / 1 along v).
		var fine_vertex := PackedInt32Array()
		fine_vertex.resize(fine_u * (2 * cells_v + 1) * 2)
		fine_vertex.fill(-1)
		var table := TransvoxelTables.cases
		var bit_samples := TransvoxelTables.BIT_SAMPLES
		var sample_value := PackedFloat32Array()
		sample_value.resize(9)
		var local := PackedInt32Array()
		local.resize(12)
		for cv in cells_v:
			for cu in cells_u:
				var i0 := 2 * cu
				var j0 := 2 * cv
				var case_index := 0
				for k in 9:
					var s := lut[slab[MesherTransition.index_of(dims, i0 + k % 3, j0 + k / 3, 0)]]
					sample_value[k] = s
				for bit in 9:
					if sample_value[bit_samples[bit]] < iso:
						case_index |= 1 << bit
				if case_index == 0 or case_index == 511:
					continue
				var base := case_index * TransvoxelTables.STRIDE
				var vertex_count := table[base]
				var triangle_count := table[base + 1]
				for n in vertex_count:
					var code := table[base + 2 + n]
					var ea := code >> 4
					var eb := code & 15
					if ea < 9:
						local[n] = _fine_vertex(transition, dims, fine_vertex, fine_u, lut, i0, j0, ea, eb,
								axes, plane, cells_u, cells_v, has_ids)
					else:
						# Half-resolution edge: an edge of the grid on the face.
						var ca := ea - 9
						var cb := eb - 9
						var pa := Vector3i.ZERO
						pa[w] = plane
						pa[u] = begin[u] + cu + mini(ca & 1, cb & 1)
						pa[v] = begin[v] + cv + mini(ca >> 1, cb >> 1)
						var edge_axis := u if (ca & 1) != (cb & 1) else v
						var a := grid.index_of(pa.x, pa.y, pa.z)
						var vi := vertex_of_edge[a * 3 + edge_axis]
						if vi < 0:
							vi = edge_vertex(a, pa, edge_axis)
						local[n] = vi
				for k in triangle_count * 3:
					indices.append(local[table[base + 14 + k]])

	# The vertex on the full-resolution face edge between samples [param ea] and [param eb]
	# of the transition cell at face sample ([param i0], [param j0]).
	func _fine_vertex(transition: MesherTransition, dims: Vector2i, fine_vertex: PackedInt32Array, fine_u: int,
			lut: PackedFloat32Array, i0: int, j0: int, ea: int, eb: int, axes: Vector3i, plane: int,
			cells_u: int, cells_v: int, has_ids: bool) -> int:
		var ia := i0 + ea % 3
		var ja := j0 + ea / 3
		var ib := i0 + eb % 3
		var jb := j0 + eb / 3
		if ia > ib or ja > jb:
			var ti := ia
			var tj := ja
			ia = ib
			ja = jb
			ib = ti
			jb = tj
		var along_v := 1 if jb != ja else 0
		var key := (ja * fine_u + ia) * 2 + along_v
		if fine_vertex[key] >= 0:
			return fine_vertex[key]
		var slab := transition.bytes
		var va := lut[slab[MesherTransition.index_of(dims, ia, ja, 0)]]
		var vb := lut[slab[MesherTransition.index_of(dims, ib, jb, 0)]]
		var iso := grid.iso
		var f := 0.5 if va == vb else clampf((iso - va) / (vb - va), 0.0, 1.0)
		var w := axes.x
		var u := axes.y
		var v := axes.z
		var p := Vector3.ZERO
		p[w] = plane
		p[u] = grid.cell_begin[u] + (ia + f * (ib - ia)) * 0.5
		p[v] = grid.cell_begin[v] + (ja + f * (jb - ja)) * 0.5
		var vi := vertices.size()
		fine_vertex[key] = vi
		vertices.append(grid.origin + p * grid.spacing)
		var n := _fine_gradient(transition, dims, lut, ia, ja, axes).lerp(
				_fine_gradient(transition, dims, lut, ib, jb, axes), f)
		normals.append(n.normalized() if n.length_squared() > 0.0 else Vector3.UP)
		var id := 0
		if has_ids:
			var inside_a := va < iso
			id = transition.materials[MesherTransition.face_index_of(dims, ia, ja) if inside_a
					else MesherTransition.face_index_of(dims, ib, jb)]
		colors.append(Color8(id, 0, 0))
		if skirts:
			var mask := 1 << transition.face
			if along_v == 0 and ja == 0:
				mask |= MesherSkirts.face_bit(v, false)
			elif along_v == 0 and ja == 2 * cells_v:
				mask |= MesherSkirts.face_bit(v, true)
			if along_v == 1 and ia == 0:
				mask |= MesherSkirts.face_bit(u, false)
			elif along_v == 1 and ia == 2 * cells_u:
				mask |= MesherSkirts.face_bit(u, true)
			face_masks.append(mask)
		return vi

	# Central-difference gradient of the transition samples at face sample (i, j), in grid axes.
	func _fine_gradient(transition: MesherTransition, dims: Vector2i, lut: PackedFloat32Array, i: int, j: int,
			axes: Vector3i) -> Vector3:
		var slab := transition.bytes
		var g := Vector3.ZERO
		g[axes.y] = (lut[slab[MesherTransition.index_of(dims, i + 1, j, 0)]]
				- lut[slab[MesherTransition.index_of(dims, i - 1, j, 0)]]) * 0.5
		g[axes.z] = (lut[slab[MesherTransition.index_of(dims, i, j + 1, 0)]]
				- lut[slab[MesherTransition.index_of(dims, i, j - 1, 0)]]) * 0.5
		g[axes.x] = (lut[slab[MesherTransition.index_of(dims, i, j, 1)]]
				- lut[slab[MesherTransition.index_of(dims, i, j, -1)]]) * 0.5
		return g
