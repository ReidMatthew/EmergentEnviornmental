#[compute]
#version 450

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// The scene's picture as it is, so the water can be shaded from it (see through it) while it is written over.
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D dst;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= int(u.screen.x) || p.y >= int(u.screen.y)) {
		return;
	}
	imageStore(dst, p, texelFetch(src, p, 0));
}
