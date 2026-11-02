#[vertex]
#version 450

// The water's smoothed surface written into the scene's depth buffer (a triangle over the whole picture), so what is drawn after
// it (the transparent pass: glass, other effects) is hidden behind the water as it is behind anything.

void main() {
	vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

#include "fluid_params.glslinc"

layout(set = 0, binding = 0) uniform sampler2D smooth_depth;

void main() {
	float d = texelFetch(smooth_depth, ivec2(gl_FragCoord.xy), 0).r;
	if (d >= 0.9999) {
		discard;
	}
	vec2 uv = gl_FragCoord.xy * u.screen.zw;
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 ray = h.xyz / h.w;
	vec4 clip = u.proj * vec4(ray * (d * u.sizes.y / -ray.z), 1.0);
	gl_FragDepth = clip.z / clip.w;
}
