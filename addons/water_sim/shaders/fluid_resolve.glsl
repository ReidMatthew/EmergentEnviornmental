#[compute]
#version 450

// The opaque look's depth: the nearer of the hardware pass's particles and the compute-rasterized ones, as a fraction of the far
// limit (1 where there is no water), for the smoothing.

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D near_big;
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D depth_out;
layout(set = 0, binding = 3, r32ui) uniform restrict readonly uimage2D near_small;


// The near pass's depth (a fraction of the far limit, the substance in its low mantissa bits; 1 where nothing was drawn) as the
// compute rasterizer's packed value: ~(24-bit depth << 8 | substance), 0 for nothing, so the nearer of the two is the larger.
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
	uint v = max(packed_big(texelFetch(near_big, p, 0).r), imageLoad(near_small, p).r);
	imageStore(depth_out, p, vec4(v == 0u ? 1.0 : float((~v) >> 8) / 16777215.0));
}
