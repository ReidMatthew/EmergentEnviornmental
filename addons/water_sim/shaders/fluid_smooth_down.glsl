#[compute]
#version 450

// The depth at half size for the smoothing (fluid_smooth.glsl runs there, on a quarter of the pixels): each texel the nearest water of
// its 2 x 2 pixels, averaged with those of them on the same surface (within the smoothing's depth tolerance), so an edge between the
// water and water far behind it isn't blended into a surface between the two. 1 where none of the four has water.

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D dst;
layout(set = 0, binding = 3, r32ui) uniform restrict readonly uimage2D near_small;

layout(push_constant, std430) uniform Push {
	// 1: src is the near pass's depth buffer, and each pixel is the nearer of it and near_small, as fluid_resolve.glsl makes it
	// (the resolve's full-size depth is then not made at all); 0: src is that depth already.
	int fused;
	int unused_a;
	int unused_b;
	int unused_c;
} pc;

// As fluid_resolve.glsl.
uint packed_big(float depth) {
	if (depth >= 0.9999) {
		return 0u;
	}
	uint substance = (floatBitsToUint(depth) >> 4) & 63u;
	return ~((uint(depth * 16777215.0) << 8) | substance);
}

float depth_at(ivec2 p) {
	if (pc.fused == 0) {
		return texelFetch(src, p, 0).r;
	}
	uint v = max(packed_big(texelFetch(src, p, 0).r), imageLoad(near_small, p).r);
	return v == 0u ? 1.0 : float((~v) >> 8) / 16777215.0;
}

void main() {
	ivec2 h = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = imageSize(dst);
	if (h.x >= half_size.x || h.y >= half_size.y) {
		return;
	}
	ivec2 size = ivec2(u.screen.xy);
	float d[4];
	float nearest = 1.0;
	for (int i = 0; i < 4; i++) {
		ivec2 p = min(h * 2 + ivec2(i & 1, i >> 1), size - 1);
		d[i] = depth_at(p);
		nearest = min(nearest, d[i]);
	}
	if (nearest >= 0.9999) {
		imageStore(dst, h, vec4(1.0));
		return;
	}
	float same = u.sizes.w / u.sizes.y;
	float sum = 0.0;
	float n = 0.0;
	for (int i = 0; i < 4; i++) {
		if (d[i] - nearest < same) {
			sum += d[i];
			n += 1.0;
		}
	}
	imageStore(dst, h, vec4(sum / n));
}
