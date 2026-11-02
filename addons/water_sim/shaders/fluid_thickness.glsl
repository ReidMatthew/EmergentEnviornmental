#[vertex]
#version 450

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

// Added up over every particle in front of the scene: the deep colour weighted by the chord length through the particle (the
// alpha is the sum of the chords), and the shallow colour the same.
layout(location = 0) out vec4 deep_sum;
layout(location = 1) out vec4 shallow_sum;

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
	vec2 uv = gl_FragCoord.xy * (u.screen.zw * u.extra.x);
	float behind = scene_distance(uv);
	// Only the part of the particle in front of the scene counts.
	float front = v_view_z + enter;
	if (front > behind) {
		discard;
	}
	// Not cut off at the scene: where water meets a wall its thickness would thin to a sliver and show as streaks.
	float back = v_view_z + leave;
	float w = (back - front) * u.thickness.x;
	deep_sum = vec4(u.deep[v_substance].rgb * w, w);
	shallow_sum = vec4(u.shallow[v_substance].rgb * w, 0.0);
}
