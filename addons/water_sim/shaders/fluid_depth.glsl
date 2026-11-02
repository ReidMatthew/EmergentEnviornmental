#[vertex]
#version 450

#define SKIP_THIN
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

// The distance from the camera, from the scene's depth buffer.
float scene_distance(vec2 uv) {
	float depth = texture(scene_depth, uv).r;
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -h.z / h.w;
}

void main() {
	// The particle's front.
	float enter, leave;
	if (!ms_hit(v_uv, v_radius, v_axis, enter, leave)) {
		discard;
	}
	float z = v_view_z + enter;
	vec2 uv = gl_FragCoord.xy * u.screen.zw;
	if (z > scene_distance(uv)) {
		discard;
	}
	gl_FragDepth = z / u.sizes.y;
}
