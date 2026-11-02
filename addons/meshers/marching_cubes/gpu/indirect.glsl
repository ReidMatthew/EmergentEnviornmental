#[compute]
#version 450

// Marching cubes for MarchingCubesGpuIndirectMesher. Triangles go straight into a slot of the
// triangle pool texture, where the indirect MultiMesh's vertex shader pulls them from
// (pull.gdshaderinc). Nothing is read back.
//   pass 0 (edges):    one thread per sample. Each crossed edge stores its packed vertex
//                      at its edge key.
//   pass 1 (cells):    one thread per cell. Appends the cell's triangles to the slot,
//                      plus seam skirt quads for triangle edges on the chunk boundary
//                      when params.skirt.x > 0 (see MesherSkirts).
//   pass 3 (transitions): one thread per transition cell (x, y) of each face (z), for faces
//                      in MesherGrid.transitions. Appends its triangles, plus seam skirts on
//                      its edges along the chunk boundary.
//   pass 2 (finalize): one workgroup per grid (runs last). Writes the draw's instance count (64
//                      triangles per instance) and turns the rest of the last instance
//                      into zero-area triangles.
//
// Pool vertex format (one rgba32f texel): xyz = position, w = an exact integer below 2^24
// holding the octahedral normal (2 x 8 bits) | material id << 16. Float rather than uint
// because Texture2DRD can't wrap integer formats; keeping w an exact integer means no NaN
// or denormal bit patterns that a texture fetch could alter.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Samples: float bits, or four bytes per uint (see common.glslinc).
layout(set = 0, binding = 0, std430) restrict readonly buffer Values { uint values_raw[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Materials { uint materials[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer TriTable { int tri_table[]; };
// Pool texel per edge key (see above). Only crossed edges are written and read.
layout(set = 0, binding = 3, std430) restrict buffer Vertices { vec4 vertices[]; };
// Per grid in the batch: triangles produced (may exceed the slot) and instances to draw.
layout(set = 0, binding = 4, std430) restrict buffer TriangleCounts { uint triangle_counts[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer DrawCounts { uint draw_counts[]; };
layout(set = 0, binding = 6, rgba32f) restrict writeonly uniform image2D pool;
layout(set = 0, binding = 7, std430) restrict readonly buffer TransitionCases { int transition_cases[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer TransitionData { uint transition_data[]; };

layout(push_constant, std430) uniform Params {
	ivec4 size;       // samples per axis; w = 1 if materials are present
	ivec4 cell_begin; // first cell; w = pass
	ivec4 cell_end;   // one past the last cell; w = 1 to flip winding
	vec4 origin;      // position of sample 0; w = spacing
	vec4 misc;        // x = iso level, y = samples are bytes, z/w = byte center/scale
	ivec4 slot;       // x = grid index in batch, y = first pool vertex, z = capacity in
	                  // triangles (multiple of 64), w = pool texture width
	vec4 skirt;       // x = seam skirt depth (output units, 0 = none)
	ivec4 transition; // x = transition faces (bit mask), y = transition width (float bits)
} params;

int transition_faces() {
	return params.transition.x;
}

float transition_width() {
	return intBitsToFloat(params.transition.y);
}

#include "common.glslinc"
#include "transition.glslinc"

const uint TRIANGLES_PER_INSTANCE = 64u;

float pack_normal_material(vec3 n, uint material) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 e = n.xy;
	if (n.z < 0.0) {
		e = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	}
	uvec2 q = uvec2(round(clamp(e * 0.5 + 0.5, 0.0, 1.0) * 255.0));
	return float(q.x | (q.y << 8u) | ((material & 0xFFu) << 16u));
}

void store(uint vertex, vec4 v) {
	int i = params.slot.y + int(vertex);
	int w = params.slot.w;
	imageStore(pool, ivec2(i % w, i / w), v);
}

void edge_pass(ivec3 p) {
	if (any(greaterThan(p, params.cell_end.xyz))) {
		return;
	}
	for (int axis = 0; axis < 3; axis++) {
		vec3 position;
		vec3 n;
		uint material;
		if (crossing(p, axis, position, n, material)) {
			vertices[edge_key(p, axis)] = vec4(position, pack_normal_material(n, material));
		}
	}
}

vec3 unpack_normal(float packed_value) {
	uint packed = uint(packed_value);
	vec2 e = vec2(float(packed & 255u), float((packed >> 8u) & 255u)) / 255.0 * 2.0 - 1.0;
	vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-n.z, 0.0);
	n.x += n.x >= 0.0 ? -t : t;
	n.y += n.y >= 0.0 ? -t : t;
	return normalize(n);
}

// The skirt vertex [depth] below v, against its normal (see MesherSkirts); keeps v's packed
// normal and material.
vec4 sink(vec4 v, float depth) {
	return vec4(v.xyz - unpack_normal(v.w) * depth, v.w);
}

void store_triangle(uint triangle, vec4 a, vec4 b, vec4 c) {
	store(triangle * 3u, a);
	store(triangle * 3u + 1u, b);
	store(triangle * 3u + 2u, c);
}

// A double-sided skirt quad (four triangles) from edge a-b down to a2-b2.
void store_quad(uint triangle, uint capacity, vec4 a, vec4 b, vec4 a2, vec4 b2) {
	if (triangle + 3u < capacity) {
		store_triangle(triangle, a, b, b2);
		store_triangle(triangle + 1u, a, b2, a2);
		store_triangle(triangle + 2u, a, b2, b);
		store_triangle(triangle + 3u, a, a2, b2);
	}
}

// Boundary faces of the vertex on the cell's edge [edge], after squeezing (see
// regular_face_mask).
int cell_edge_face_mask(ivec3 c, int edge) {
	return regular_face_mask(c + EDGE_ORIGIN[edge], EDGE_AXIS[edge]);
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
	int entries = case_entry_count(cube);
	bool flip = params.cell_end.w != 0;
	float depth = params.skirt.x;

	// Count skirt quads first so the cell reserves all its triangles in one atomic.
	int skirt_quads = 0;
	if (depth > 0.0) {
		for (int k = 0; k < entries; k += 3) {
			for (int e = 0; e < 3; e++) {
				int a = tri_table[t + k + e];
				int b = tri_table[t + k + (e + 1) % 3];
				if ((cell_edge_face_mask(c, a) & cell_edge_face_mask(c, b)) != 0) {
					skirt_quads++;
				}
			}
		}
	}
	// Each skirt quad is double-sided: four triangles.
	uint first = atomicAdd(triangle_counts[params.slot.x], uint(entries / 3 + skirt_quads * 4));
	uint capacity = uint(params.slot.z);
	uint triangle = first;
	for (int k = 0; k < entries; k += 3) {
		int e0 = tri_table[t + k];
		int e1 = tri_table[t + k + (flip ? 2 : 1)];
		int e2 = tri_table[t + k + (flip ? 1 : 2)];
		vec4 v0 = vertices[cell_edge_key(c, e0)];
		vec4 v1 = vertices[cell_edge_key(c, e1)];
		vec4 v2 = vertices[cell_edge_key(c, e2)];
		if (triangle < capacity) {
			store_triangle(triangle, v0, v1, v2);
		}
		triangle++;
		if (depth <= 0.0) {
			continue;
		}
		int edges[3] = int[3](e0, e1, e2);
		vec4 verts[3] = vec4[3](v0, v1, v2);
		for (int e = 0; e < 3; e++) {
			int ea = edges[e];
			int eb = edges[(e + 1) % 3];
			if ((cell_edge_face_mask(c, ea) & cell_edge_face_mask(c, eb)) == 0) {
				continue;
			}
			vec4 a = verts[e];
			vec4 b = verts[(e + 1) % 3];
			store_quad(triangle, capacity, a, b, sink(a, depth), sink(b, depth));
			triangle += 4u;
		}
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
	float iso = params.misc.x;
	vec4 verts[12];
	int masks[12];
	bool valid[12];
	for (int n = 0; n < vertex_count; n++) {
		int code = transition_cases[base + 2 + n];
		int ea = code >> 4;
		int eb = code & 15;
		if (ea < 9) {
			vec3 position;
			vec3 normal;
			uint material;
			int mask;
			fine_vertex(f, face, i0, j0, ea, eb, position, normal, material, mask);
			verts[n] = vec4(position, pack_normal_material(normal, material));
			masks[n] = mask;
			valid[n] = true;
		} else {
			ivec3 pa;
			int axis;
			coarse_edge(f, face, g.x, g.y, ea - 9, eb - 9, pa, axis);
			ivec3 pb = pa;
			pb[axis] += 1;
			// Pass 0 stored this edge's vertex if the grid's samples cross it, which they do
			// whenever they agree with the transition samples (the terrain makes sure).
			valid[n] = (value_at(pa) < iso) != (value_at(pb) < iso);
			verts[n] = valid[n] ? vertices[edge_key(pa, axis)] : vec4(0.0);
			masks[n] = regular_face_mask(pa, axis);
		}
	}
	bool flip = params.cell_end.w != 0;
	float seam_depth = params.skirt.x;
	// Count seam skirt quads first so the cell reserves all its triangles in one atomic.
	int quads = 0;
	if (seam_depth > 0.0) {
		for (int k = 0; k < triangle_count * 3; k++) {
			int a = transition_cases[base + 14 + k];
			int b = transition_cases[base + 14 + (k / 3) * 3 + (k % 3 + 1) % 3];
			if ((masks[a] & masks[b]) != 0) {
				quads++;
			}
		}
	}
	uint triangle = atomicAdd(triangle_counts[params.slot.x], uint(triangle_count + quads * 4));
	uint capacity = uint(params.slot.z);
	for (int k = 0; k < triangle_count; k++) {
		int t = base + 14 + k * 3;
		int i[3] = int[3](transition_cases[t], transition_cases[t + (flip ? 2 : 1)], transition_cases[t + (flip ? 1 : 2)]);
		bool ok = valid[i[0]] && valid[i[1]] && valid[i[2]];
		if (triangle < capacity) {
			if (ok) {
				store_triangle(triangle, verts[i[0]], verts[i[1]], verts[i[2]]);
			} else {
				store_triangle(triangle, vec4(0.0), vec4(0.0), vec4(0.0));
			}
		}
		triangle++;
		if (seam_depth <= 0.0) {
			continue;
		}
		for (int e = 0; e < 3; e++) {
			int ia = i[e];
			int ib = i[(e + 1) % 3];
			if ((masks[ia] & masks[ib]) == 0) {
				continue;
			}
			vec4 a = verts[ia];
			vec4 b = verts[ib];
			store_quad(triangle, capacity, a, b, sink(a, seam_depth), sink(b, seam_depth));
			triangle += 4u;
		}
	}
}

void finalize() {
	uint grid = uint(params.slot.x);
	uint count = min(triangle_counts[grid], uint(params.slot.z));
	uint instances = (count + TRIANGLES_PER_INSTANCE - 1u) / TRIANGLES_PER_INSTANCE;
	uint lane = gl_LocalInvocationIndex;
	if (lane == 0u) {
		draw_counts[grid] = instances;
	}
	uint pad = count + lane;
	if (pad < instances * TRIANGLES_PER_INSTANCE) {
		store(pad * 3u, vec4(0.0));
		store(pad * 3u + 1u, vec4(0.0));
		store(pad * 3u + 2u, vec4(0.0));
	}
}

void main() {
	if (params.cell_begin.w == 2) {
		finalize();
		return;
	}
	if (params.cell_begin.w == 3) {
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
