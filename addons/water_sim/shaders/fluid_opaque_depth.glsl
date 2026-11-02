#[vertex]
#version 450

// The near particles of the opaque look (drawn from the list fluid_raster.glsl makes, which rasterizes the small ones): each
// particle's nearest point in a depth buffer, with the substance in the depth's lowest 8 mantissa bits (a change of one part in
// 32,000, below what the test tells apart), so the nearest particle's substance is kept with no colour target. The vertex stage
// sets that depth (FRONT_DEPTH) and the fragment shader writes none, so hidden pixels are rejected before it runs.
#define SKIP_THIN
#define FRONT_DEPTH
#include "fluid_params.glslinc"
#include "fluid_shape.glslinc"
#include "fluid_vertex.glslinc"

#[fragment]
#version 450

#include "fluid_params.glslinc"
#include "fluid_shape.glslinc"

layout(set = 0, binding = 2) uniform sampler2D scene_depth;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in float v_view_z;
layout(location = 2) in flat int v_substance;
layout(location = 3) in float v_radius;
layout(location = 4) in flat vec3 v_axis;


float scene_distance(vec2 uv) {
	float depth = texture(scene_depth, uv).r;
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -h.z / h.w;
}

void main() {
	float enter, leave;
	if (!ms_hit(v_uv, v_radius, v_axis, enter, leave)) {
		discard;
	}
	float z = v_view_z + enter;
	vec2 uv = gl_FragCoord.xy * u.screen.zw;
	if (z > scene_distance(uv)) {
		discard;
	}
}
