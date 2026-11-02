#[vertex]
#version 450

// The opaque look's surface written into the scene's depth buffer (a triangle over the whole picture), so what is drawn after it (the
// transparent pass: glass, other effects) is hidden behind the water as it is behind anything. As fluid_scene_depth.glsl, from the
// half-size depth.

void main() {
	vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

#include "fluid_params.glslinc"

layout(set = 0, binding = 0) uniform sampler2D smooth_depth;

#include "fluid_opaque_surface.glslinc"

void main() {
	vec4 s;
	vec2 f;
	float d;
	if (!opaque_depth(ivec2(gl_FragCoord.xy), s, f, d)) {
		discard;
	}
	vec3 at = view_position(gl_FragCoord.xy * u.screen.zw, d * u.sizes.y);
	vec4 clip = u.proj * vec4(at, 1.0);
	gl_FragDepth = clip.z / clip.w;
}
