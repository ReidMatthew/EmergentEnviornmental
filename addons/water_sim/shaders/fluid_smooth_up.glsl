#[compute]
#version 450

// The smoothed depth back at the picture's size: each pixel with water takes the four half-size texels round it (bilinear weights),
// each counted by how near it is to the pixel's own depth, so the edges stay where the full-size depth has them and a pixel of water
// in front of other water isn't pulled back to it. A pixel none of them is near keeps its own depth. 1 where there is no water.

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D smoothed;
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D dst;
layout(set = 0, binding = 3) uniform sampler2D own;
layout(set = 0, binding = 4, r32ui) uniform restrict readonly uimage2D near_small;

layout(push_constant, std430) uniform Push {
	// 1: own is the near pass's depth buffer, and the pixel's depth the nearer of it and near_small (see fluid_smooth_down.glsl).
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

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(u.screen.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	float d = texelFetch(own, p, 0).r;
	if (pc.fused != 0) {
		uint v = max(packed_big(d), imageLoad(near_small, p).r);
		d = v == 0u ? 1.0 : float((~v) >> 8) / 16777215.0;
	}
	if (d >= 0.9999) {
		imageStore(dst, p, vec4(1.0));
		return;
	}
	ivec2 half_size = textureSize(smoothed, 0);
	// The pixel's centre in the half-size texels' coordinates, and the four texels round it.
	vec2 at = (vec2(p) + 0.5) * 0.5 - 0.5;
	ivec2 base = ivec2(floor(at));
	vec2 f = at - vec2(base);
	float sigma_d = u.sizes.w / u.sizes.y;
	float inv_sd2 = -0.5 / (sigma_d * sigma_d);
	float sum = 0.0;
	float weights = 0.0;
	for (int i = 0; i < 4; i++) {
		ivec2 o = ivec2(i & 1, i >> 1);
		ivec2 q = clamp(base + o, ivec2(0), half_size - 1);
		float s = texelFetch(smoothed, q, 0).r;
		if (s >= 0.9999) {
			continue;
		}
		float bilinear = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
		float dd = s - d;
		float w = bilinear * exp(inv_sd2 * dd * dd);
		sum += w * s;
		weights += w;
	}
	imageStore(dst, p, vec4(weights > 1e-4 ? sum / weights : d));
}
