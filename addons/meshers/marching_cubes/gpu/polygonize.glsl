#[compute]
#version 450

// Marching cubes in two passes, producing the same indexed mesh as MarchingCubesCpuMesher:
//   pass 0 (edges): one thread per sample in the cell range. For each of its three edges
//                   that the surface crosses, append a vertex and record its index.
//   pass 1 (cells): one thread per cell. Look up the case and append triangle indices
//                   using the vertices recorded in pass 0.
//   pass 2 (transitions): one thread per transition cell (x, y) of each face (z), for
//                   faces in MesherGrid.transitions. Appends its full-resolution vertices
//                   and its triangles, using pass 0's vertices on the half-resolution side.
// Used by MarchingCubesGpuMesher, which reads the result back.
// MarchingCubesGpuIndirectMesher uses indirect.glsl; both share common.glslinc.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Samples: float bits, or four bytes per uint (see common.glslinc).
layout(set = 0, binding = 0, std430) restrict readonly buffer Values { uint values_raw[]; };
// Material ids, four bytes per uint.
layout(set = 0, binding = 1, std430) restrict readonly buffer Materials { uint materials[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer TriTable { int tri_table[]; };
// Vertex index per grid edge (edge_key). Only crossed edges are written, and pass 1 only
// reads crossed edges, so it never needs clearing.
layout(set = 0, binding = 3, std430) restrict buffer EdgeVertex { int edge_vertex[]; };
// Tightly packed so readback converts straight to PackedVector3Array / PackedColorArray.
layout(set = 0, binding = 4, std430) restrict writeonly buffer Positions { float positions[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer Normals { float normals[]; };
layout(set = 0, binding = 6, std430) restrict writeonly buffer Colors { vec4 colors[]; };
layout(set = 0, binding = 7, std430) restrict writeonly buffer Indices { int indices[]; };
// Shared by every grid in a batch: (vertex count, index count) per grid, at params.extra.x.
layout(set = 0, binding = 8, std430) restrict buffer Counters { uint counters[]; };
layout(set = 0, binding = 9, std430) restrict readonly buffer TransitionCases { int transition_cases[]; };
layout(set = 0, binding = 10, std430) restrict readonly buffer TransitionData { uint transition_data[]; };

layout(push_constant, std430) uniform Params {
	ivec4 size;       // samples per axis; w = 1 if materials are present
	ivec4 cell_begin; // first cell; w = pass
	ivec4 cell_end;   // one past the last cell; w = 1 to flip winding
	vec4 origin;      // position of sample 0; w = spacing
	vec4 misc;        // x = iso level, y = samples are bytes, z/w = byte center/scale
	ivec4 extra;      // x = this grid's counter pair in a batch, y = transition faces (bit
	                  // mask), z = transition width (float bits)
} params;

int transition_faces() {
	return params.extra.y;
}

float transition_width() {
	return intBitsToFloat(params.extra.z);
}

#include "common.glslinc"
#include "transition.glslinc"

void edge_pass(ivec3 p) {
	if (any(greaterThan(p, params.cell_end.xyz))) {
		return;
	}
	for (int axis = 0; axis < 3; axis++) {
		vec3 position;
		vec3 n;
		uint material;
		if (!crossing(p, axis, position, n, material)) {
			continue;
		}
		uint vi = atomicAdd(counters[params.extra.x * 2], 1u);
		positions[vi * 3u] = position.x;
		positions[vi * 3u + 1u] = position.y;
		positions[vi * 3u + 2u] = position.z;
		normals[vi * 3u] = n.x;
		normals[vi * 3u + 1u] = n.y;
		normals[vi * 3u + 2u] = n.z;
		colors[vi] = vec4(float(material) / 255.0, 0.0, 0.0, 1.0);
		edge_vertex[edge_key(p, axis)] = int(vi);
	}
}

void cell_pass(ivec3 c) {
	if (any(greaterThanEqual(c, params.cell_end.xyz))) {
		return;
	}
	int cube = cube_index(c);
	if (cube == 0 || cube == 255) {
		return;
	}
	int t = cube * 16;
	int count = case_entry_count(cube);
	uint start = atomicAdd(counters[params.extra.x * 2 + 1], uint(count));
	bool flip = params.cell_end.w != 0;
	for (int k = 0; k < count; k += 3) {
		int i0 = edge_vertex[cell_edge_key(c, tri_table[t + k])];
		int i1 = edge_vertex[cell_edge_key(c, tri_table[t + k + 1])];
		int i2 = edge_vertex[cell_edge_key(c, tri_table[t + k + 2])];
		uint o = start + uint(k);
		indices[o] = i0;
		indices[o + 1u] = flip ? i2 : i1;
		indices[o + 2u] = flip ? i1 : i2;
	}
}

void transition_pass(ivec3 g) {
	int face = g.z;
	if (face >= 6) {
		return;
	}
	TransitionFace f = transition_face(face);
	if (!f.present || g.x >= f.cells_u || g.y >= f.cells_v) {
		return;
	}
	int i0 = g.x * 2;
	int j0 = g.y * 2;
	int c = transition_case(f, i0, j0);
	if (c == 0 || c == 511) {
		return;
	}
	int base = c * TRANSITION_STRIDE;
	int vertex_count = transition_cases[base];
	int triangle_count = transition_cases[base + 1];
	int fine_count = 0;
	for (int n = 0; n < vertex_count; n++) {
		if ((transition_cases[base + 2 + n] >> 4) < 9) {
			fine_count++;
		}
	}
	uint samples = uint(params.size.x * params.size.y * params.size.z);
	uint first_vertex = atomicAdd(counters[params.extra.x * 2], uint(fine_count));
	uint first_index = atomicAdd(counters[params.extra.x * 2 + 1], uint(triangle_count * 3));
	if (first_index + uint(triangle_count * 3) > samples * 15u) {
		return;  // out of index space (never in practice)
	}
	bool room = first_vertex + uint(fine_count) <= samples * 3u;
	int local[12];
	uint next = first_vertex;
	float iso = params.misc.x;
	for (int n = 0; n < vertex_count; n++) {
		int code = transition_cases[base + 2 + n];
		int ea = code >> 4;
		int eb = code & 15;
		local[n] = -1;
		if (ea < 9) {
			if (!room) {
				continue;
			}
			vec3 position;
			vec3 normal;
			uint material;
			int mask;
			fine_vertex(f, face, i0, j0, ea, eb, position, normal, material, mask);
			positions[next * 3u] = position.x;
			positions[next * 3u + 1u] = position.y;
			positions[next * 3u + 2u] = position.z;
			normals[next * 3u] = normal.x;
			normals[next * 3u + 1u] = normal.y;
			normals[next * 3u + 2u] = normal.z;
			colors[next] = vec4(float(material) / 255.0, 0.0, 0.0, 1.0);
			local[n] = int(next);
			next++;
		} else {
			ivec3 pa;
			int axis;
			coarse_edge(f, face, g.x, g.y, ea - 9, eb - 9, pa, axis);
			ivec3 pb = pa;
			pb[axis] += 1;
			// Pass 0 wrote this edge's vertex if the grid's samples cross it, which they do
			// whenever they agree with the transition samples (the terrain makes sure).
			if ((value_at(pa) < iso) != (value_at(pb) < iso)) {
				local[n] = edge_vertex[edge_key(pa, axis)];
			}
		}
	}
	bool flip = params.cell_end.w != 0;
	for (int k = 0; k < triangle_count; k++) {
		int a = local[transition_cases[base + 14 + k * 3]];
		int b = local[transition_cases[base + 14 + k * 3 + (flip ? 2 : 1)]];
		int d = local[transition_cases[base + 14 + k * 3 + (flip ? 1 : 2)]];
		uint o = first_index + uint(k * 3);
		bool ok = a >= 0 && b >= 0 && d >= 0;
		indices[o] = ok ? a : 0;
		indices[o + 1u] = ok ? b : 0;
		indices[o + 2u] = ok ? d : 0;
	}
}

void main() {
	if (params.cell_begin.w == 2) {
		transition_pass(ivec3(gl_GlobalInvocationID));
		return;
	}
	ivec3 p = params.cell_begin.xyz + ivec3(gl_GlobalInvocationID);
	if (params.cell_begin.w == 0) {
		edge_pass(p);
	} else {
		cell_pass(p);
	}
}
