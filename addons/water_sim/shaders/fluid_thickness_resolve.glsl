#[compute]
#version 450

// The translucent look's thickness from the small particles (added up in fixed point by fluid_raster.glsl) added to what the
// hardware pass drew for the big ones, a thickness pixel each, with a colour: the big ones' there if any drew, else the substance
// of the nearest small one under it (from the depth raster), else the first substance's. The sums are read and set back to zero,
// ready for the next frame.

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Sums {
	uint sum[];
} sums;
layout(set = 0, binding = 2, rgba16f) uniform restrict image2D deep_sum;
layout(set = 0, binding = 3, rgba16f) uniform restrict image2D shallow_sum;
layout(set = 0, binding = 4, r32ui) uniform restrict readonly uimage2D near_small;

// (fluid_raster.glsl's fixed point.)
const float SUM_SCALE = 4096.0;

void main() {
	int shrink = int(u.extra.x);
	ivec2 size = (ivec2(u.screen.xy) + shrink - 1) / shrink;
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	uint at = uint(p.y * size.x + p.x);
	uint s = sums.sum[at];
	if (s == 0u) {
		return;
	}
	sums.sum[at] = 0u;
	float w = float(s) / SUM_SCALE;
	vec4 deep = imageLoad(deep_sum, p);
	vec4 shallow = imageLoad(shallow_sum, p);
	vec3 deep_colour;
	vec3 shallow_colour;
	if (deep.a > 1e-4) {
		deep_colour = deep.rgb / deep.a;
		shallow_colour = shallow.rgb / deep.a;
	} else {
		// The nearest small particle in the picture pixels this one covers (0: none; the substance in the low bits of its complement).
		uint nearest = 0u;
		ivec2 screen = ivec2(u.screen.xy);
		for (int y = 0; y < shrink; y++) {
			for (int x = 0; x < shrink; x++) {
				ivec2 q = min(p * shrink + ivec2(x, y), screen - 1);
				nearest = max(nearest, imageLoad(near_small, q).r);
			}
		}
		int substance = nearest != 0u ? int((~nearest) & 63u) : 0;
		deep_colour = u.deep[substance].rgb;
		shallow_colour = u.shallow[substance].rgb;
	}
	imageStore(deep_sum, p, deep + vec4(deep_colour * w, w));
	imageStore(shallow_sum, p, shallow + vec4(shallow_colour * w, 0.0));
}
