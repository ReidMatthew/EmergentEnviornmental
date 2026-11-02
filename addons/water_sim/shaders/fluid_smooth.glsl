#[compute]
#version 450

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// The depth (a fraction of the far limit; 1 where there is no water), and where the smoothed depth goes.
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D dst;

layout(push_constant, std430) uniform Push {
	// (1, 0) along the rows, (0, 1) down the columns.
	vec2 dir;
	// The most pixels the filter reaches (0: 20). A wide pass takes every few pixels, and the sphere edges come through the gaps
	// as a crosshatch of that spacing that crawls as the water moves; so the last pass along each axis is held to 4 pixels and
	// takes every one, which smooths that spacing away.
	float limit;
	float unused;
} pc;

// A bilateral blur along one direction: pixels near in the picture and in depth count, so the surface is smoothed (the bumps
// of the spheres go) while the edges between water and what is behind it, or between a wave and what it folds over, stay.
// It runs on the depth at half the picture's size (fluid_smooth_down.glsl; fluid_smooth_up.glsl brings it back), its pixels twice
// as wide.
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	float d = texelFetch(src, p, 0).r;
	if (d >= 0.9999) {
		imageStore(dst, p, vec4(1.0));
		return;
	}
	float z = d * u.sizes.y;
	float focal = abs(u.proj[1][1]) * 0.5 * float(size.y);
	float radius_px = clamp(u.sizes.z * focal / z, 1.0, pc.limit > 0.0 ? pc.limit : 20.0);
	int reach = int(ceil(radius_px));
	float sigma_px = radius_px * 0.5 + 0.001;
	float sigma_d = u.sizes.w / u.sizes.y;
	// A wide filter takes every few pixels (at most 8 taps a side): the Gaussian is smooth over that step.
	int stride = max(1, (reach + 7) / 8);
	int taps = reach / stride;
	// The Gaussian along the picture, w(j) = exp(a j^2) for the tap j strides out, by a recurrence (w(j) = w(j - 1) exp(a (2 j - 1))) in
	// place of an exp a tap; the depth's is still one a tap, it differs for every one.
	float a = -0.5 * float(stride * stride) / (sigma_px * sigma_px);
	float step_w = exp(a);
	float grow = exp(2.0 * a);
	float spatial = 1.0;
	float inv_sd2 = -0.5 / (sigma_d * sigma_d);
	// (The pixel itself: a tap with the depth difference 0 and weight 1.)
	float sum = d;
	float weights = 1.0;
	for (int j = 1; j <= taps; j++) {
		spatial *= step_w;
		step_w *= grow;
		ivec2 off = ivec2(pc.dir * float(j * stride));
		for (int side = 0; side < 2; side++) {
			ivec2 q = side == 0 ? p + off : p - off;
			if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) {
				continue;
			}
			float e = texelFetch(src, q, 0).r;
			if (e >= 0.9999) {
				continue;
			}
			float dd = e - d;
			float w = spatial * exp(inv_sd2 * dd * dd);
			sum += w * e;
			weights += w;
		}
	}
	imageStore(dst, p, vec4(sum / max(weights, 1e-6)));
}
