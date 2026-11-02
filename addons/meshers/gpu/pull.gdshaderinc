// Vertex pulling for MarchingCubesGpuIndirectMesher: reads a chunk's triangles from the triangle
// pool instead of a vertex buffer. Include it in a spatial shader and call ms_pull_vertex()
// first thing in vertex():
//
//   #include "<relative path to>/pull.gdshaderinc"
//   varying flat float material_id;
//   void vertex() {
//       float id;  // a varying can't be passed as an out argument directly
//       ms_pull_vertex(INSTANCE_ID, VERTEX_ID, VERTEX, NORMAL, id);
//       material_id = id;
//   }
//
// The presenter sets ms_triangle_pool (per material) and ms_vertex_base (per chunk).
// Pool vertex format (see indirect.glsl): one rgba32f texel, xyz = position, w = an
// exact integer holding the octahedral normal (2 x 8 bits) | material id << 16.

uniform sampler2D ms_triangle_pool : filter_nearest;
instance uniform int ms_vertex_base = 0;

const int MS_VERTICES_PER_INSTANCE = 192;

vec3 ms_oct_decode(vec2 e) {
	vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-n.z, 0.0);
	n.x += n.x >= 0.0 ? -t : t;
	n.y += n.y >= 0.0 ? -t : t;
	return normalize(n);
}

void ms_pull_vertex(int instance_id, int vertex_id, inout vec3 vertex, inout vec3 normal, out float material_id) {
	int i = ms_vertex_base + instance_id * MS_VERTICES_PER_INSTANCE + vertex_id;
	int w = textureSize(ms_triangle_pool, 0).x;
	vec4 d = texelFetch(ms_triangle_pool, ivec2(i % w, i / w), 0);
	vertex = d.xyz;
	uint packed = uint(d.w);
	vec2 e = vec2(float(packed & 255u), float((packed >> 8u) & 255u)) / 255.0 * 2.0 - 1.0;
	normal = ms_oct_decode(e);
	material_id = float(packed >> 16u);
}
