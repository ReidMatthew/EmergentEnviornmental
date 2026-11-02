#[vertex]
#version 450

#define SPRAY_READ_ONLY
#include "spray.glslinc"

// Each spray particle a soft quad facing the camera (D3D12 ignores point sizes), stretched back along its motion on the picture's
// plane, faded in as it starts and out as it ends.
layout(location = 0) out vec2 corner;
layout(location = 1) out vec4 tint;

const vec2 CORNERS[6] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));

void main() {
	Spray s = spray[gl_InstanceIndex];
	if (s.vel_life.w <= 0.0) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		return;
	}
	vec3 center = (u.view_from_world * vec4(s.pos_age.xyz, 1.0)).xyz;
	vec2 motion = (mat3(u.view_from_world) * s.vel_life.xyz).xy * u.look.z;
	float trail = length(motion);
	vec2 along = trail > 1e-4 ? motion / trail : vec2(1.0, 0.0);
	vec2 across = vec2(-along.y, along.x);
	float r = u.look.x;
	vec2 c = CORNERS[gl_VertexIndex];
	// (Its head at the particle, its tail behind it.)
	vec2 offset = along * (c.x * (r + trail * 0.5) - trail * 0.5) + across * (c.y * r);
	gl_Position = u.proj * vec4(center + vec3(offset, 0.0), 1.0);
	corner = c;
	float age = s.pos_age.w;
	float fade = smoothstep(0.0, 0.04, age) * (1.0 - smoothstep(s.vel_life.w * 0.6, s.vel_life.w, age));
	// (A streak spreads the same light over more of the picture.)
	float alpha = u.look.y * fade * r / (r + trail * 0.5);
	tint = vec4(u.colors[int(s.extra.x) & 63].rgb, alpha);
}

#[fragment]
#version 450

layout(location = 0) in vec2 corner;
layout(location = 1) in vec4 tint;
layout(location = 0) out vec4 frag_color;

void main() {
	float soft = 1.0 - dot(corner, corner);
	if (soft <= 0.0) {
		discard;
	}
	float a = tint.a * soft;
	frag_color = vec4(tint.rgb * a, a);
}
