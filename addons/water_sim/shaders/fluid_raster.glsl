#[compute]
#version 450

// Every particle once, before the triangles: the ones bigger on screen than u.extra.z pixels (radius) are copied to a list the
// hardware passes draw (an indirect draw, so the vertex stage never sees the rest), and the small ones are rasterized here instead
// (a far particle covers a pixel or two, and the vertex work and triangle setup for millions of them is what a far view spends its
// time on). Those off the screen or behind the eye are left out of both.
//
// A small particle writes its sphere's front, packed with its substance, into the pixels it covers with an atomic maximum of
// ~(depth, substance), so the nearest wins (as in Schütz et al., "Rendering Point Clouds with Compute Shaders"). In the
// translucent look (pc.thickness) it also adds its thickness to the thickness sums, as fluid_thickness.glsl does for the big ones:
// fixed point, by an atomic add into a buffer that fluid_thickness_resolve.glsl adds to that pass's targets. Only the thickness:
// its colour is the substance's in front at that pixel (one atomic instead of seven, which a far view's many particles a pixel
// would queue on).

#include "fluid_params.glslinc"
#include "fluid_shape.glslinc"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer Points {
	uvec2 point[];
} pts;
layout(set = 0, binding = 2) uniform sampler2D scene_depth;
layout(set = 0, binding = 3, r32ui) uniform restrict uimage2D nearest;
// The big particles, for the hardware passes.
layout(set = 0, binding = 4, std430) restrict writeonly buffer Big {
	uvec2 point[];
} big;
// The hardware passes' indirect draw: vertices an instance, instances (the big particles), first vertex, first instance.
layout(set = 0, binding = 5, std430) restrict buffer Draw {
	uint vertices;
	uint instances;
	uint first_vertex;
	uint first_instance;
} draw;
// The small particles' thickness, a value for each of the thickness target's pixels (see fluid_thickness_resolve.glsl).
layout(set = 0, binding = 6, std430) restrict buffer Sums {
	uint sum[];
} sums;

layout(push_constant, std430) uniform Push {
	uint count;
	// Whether to add up the thickness too (the translucent look).
	uint thickness;
	// How many points a row of the dispatch holds (past what one axis can hold, see _raster_groups in fluid_effect.gd).
	uint row;
	uint unused;
} pc;

// The sums' fixed point: 1/4096 m of thickness (a pixel holds up to a million metres of water).
const float SUM_SCALE = 4096.0;

shared uint group_count;
shared uint group_base;

float scene_distance(vec2 uv) {
	float depth = textureLod(scene_depth, uv, 0.0).r;
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -h.z / h.w;
}

void add_depth(vec2 pixel, float radius_px, float z, float radius, uint substance) {
	ivec2 size = ivec2(u.screen.xy);
	// Every pixel whose centre is within the circle, and at least the one the centre falls in.
	float r = max(radius_px, 0.5);
	int reach = int(ceil(r));
	ivec2 centre = ivec2(floor(pixel));
	for (int y = -reach; y <= reach; y++) {
		for (int x = -reach; x <= reach; x++) {
			ivec2 p = centre + ivec2(x, y);
			if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
				continue;
			}
			vec2 off = (vec2(p) + 0.5 - pixel) / r;
			float d2 = dot(off, off);
			if (d2 > 1.0 && !(x == 0 && y == 0)) {
				continue;
			}
			float front = z - sqrt(max(1.0 - d2, 0.0)) * radius;
			if (front > scene_distance((vec2(p) + 0.5) * u.screen.zw)) {
				continue;
			}
			float d = clamp(front / u.sizes.y, 0.0, 1.0);
			imageAtomicMax(nearest, p, ~((uint(d * 16777215.0) << 8) | substance));
		}
	}
}

// The sphere's volume shared over the thickness pixels it covers, by the chord through it at each pixel's centre (what the
// hardware pass adds up for a big one), so a particle smaller than a pixel still counts in full instead of flickering in and out
// as it crosses pixel centres. The part in front of the scene only, as there.
void add_thickness(vec2 ndc, float radius_px, float z, float radius) {
	int shrink = int(u.extra.x);
	ivec2 size = (ivec2(u.screen.xy) + shrink - 1) / shrink;
	float to_target = float(size.y) / u.screen.y;
	vec2 pixel = (ndc * 0.5 + 0.5) * vec2(size);
	float r = max(radius_px * to_target, 1e-4);
	int reach = int(ceil(r));
	ivec2 centre = ivec2(floor(pixel));
	float total = 0.0;
	for (int y = -reach; y <= reach; y++) {
		for (int x = -reach; x <= reach; x++) {
			vec2 off = (vec2(centre + ivec2(x, y)) + 0.5 - pixel) / r;
			total += sqrt(max(1.0 - dot(off, off), 0.0));
		}
	}
	// (No pixel centre inside the circle: all of it to the pixel its centre is in.)
	bool one = total <= 0.0;
	// A thickness pixel's area (m²) at the particle's distance; the volume over it is the thickness it adds.
	float pixel_m = z / (abs(u.proj[1][1]) * 0.5 * float(size.y));
	float volume = 4.0 / 3.0 * 3.14159265 * radius * radius * radius;
	float per = volume / (pixel_m * pixel_m) * u.thickness.x * SUM_SCALE / (one ? 1.0 : total);
	for (int y = -reach; y <= reach; y++) {
		for (int x = -reach; x <= reach; x++) {
			ivec2 p = centre + ivec2(x, y);
			if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
				continue;
			}
			vec2 off = (vec2(p) + 0.5 - pixel) / r;
			float chord = one ? (x == 0 && y == 0 ? 1.0 : 0.0) : sqrt(max(1.0 - dot(off, off), 0.0));
			if (chord <= 0.0) {
				continue;
			}
			if (z - chord * radius > scene_distance((vec2(p) + 0.5) * float(shrink) * u.screen.zw)) {
				continue;
			}
			atomicAdd(sums.sum[p.y * size.x + p.x], uint(per * chord + 0.5));
		}
	}
}

void main() {
	if (gl_LocalInvocationIndex == 0u) {
		group_count = 0u;
	}
	barrier();
	uint i = gl_GlobalInvocationID.x + gl_GlobalInvocationID.y * pc.row;
	bool live = i < pc.count;
	uvec2 q = live ? pts.point[i] : uvec2(0u);
	int packed = int(q.y >> 16);
	// (Room a block of the solver's own points didn't use: no particle has this word.)
	live = live && packed != 0xFFFF;
	// (Small ones are drawn as spheres.)
	float radius = ms_radius(packed);
	vec3 place = vec3(float(q.x & 0xFFFFu), float(q.x >> 16), float(q.y & 0xFFFFu)) * u.extent.xyz;
	vec3 view = (u.view_from_solver * vec4(ms_anchored(place, radius), 1.0)).xyz;
	float z = -view.z;
	float focal = abs(u.proj[1][1]) * 0.5 * u.screen.y;
	float radius_px = radius * focal / max(z, 1e-6);
	vec4 clip = u.proj * vec4(view, 1.0);
	vec2 ndc = clip.xy / clip.w;
	vec2 pixel = (ndc * 0.5 + 0.5) * u.screen.xy;
	// Behind the eye (the hardware pass leaves those out too), or wholly off the picture.
	float margin = radius_px + 1.0;
	live = live && z >= radius && pixel.x > -margin && pixel.y > -margin && pixel.x < u.screen.x + margin && pixel.y < u.screen.y + margin;
	bool is_big = live && radius_px >= u.extra.z;
	// The big ones into the list: a slot each within the group, one atomic for the group.
	uint slot = 0u;
	if (is_big) {
		slot = atomicAdd(group_count, 1u);
	}
	barrier();
	if (gl_LocalInvocationIndex == 0u && group_count > 0u) {
		group_base = atomicAdd(draw.instances, group_count);
	}
	barrier();
	if (is_big) {
		big.point[group_base + slot] = q;
	}
	if (!live || is_big) {
		return;
	}
	if (pc.thickness != 0u) {
		add_thickness(ndc, radius_px, z, radius);
	}
	// (Thickness-only particles of thinned deep water are inside it: not part of the surface.)
	if ((packed & 0x8000) == 0) {
		add_depth(pixel, radius_px, z, radius, uint(packed & 63));
	}
}
