#[compute]
#version 450

#include "spray.glslinc"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Every spray particle a frame: gravity, air drag, age. A falling one that has gone just behind the scene's depth (the water's surface
// is in it: see fluid_scene_depth.glsl) has landed: it stops and fades out. One far behind is only hidden, and flies on.
layout(set = 0, binding = 2) uniform sampler2D scene_depth;

const float LAND_FADE = 0.12;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.capacity) {
		return;
	}
	Spray s = spray[i];
	if (s.vel_life.w <= 0.0) {
		return;
	}
	float dt = u.motion.w;
	s.pos_age.w += dt;
	if (s.pos_age.w >= s.vel_life.w) {
		spray[i].vel_life.w = 0.0;
		return;
	}
	if (s.extra.y == 0.0) {
		vec3 v = (s.vel_life.xyz + u.motion.xyz * dt) * exp(-u.life.z * dt);
		s.pos_age.xyz += v * dt;
		s.vel_life.xyz = v;
		if (s.pos_age.w > u.look.w && v.y < 0.0) {
			vec4 view = u.view_from_world * vec4(s.pos_age.xyz, 1.0);
			vec4 clip = u.proj * view;
			if (view.z < 0.0 && clip.w > 0.0) {
				vec2 ndc = clip.xy / clip.w;
				vec2 uv = ndc * 0.5 + 0.5;
				if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
					float d = texelFetch(scene_depth, ivec2(uv * u.screen.xy), 0).r;
					vec4 h = u.inv_proj * vec4(ndc, d, 1.0);
					float scene_z = -h.z / h.w;
					float behind = -view.z - scene_z;
					if (behind > 0.0 && behind < u.life.w) {
						// Landed: it stays where it hit and fades.
						s.extra.y = 1.0;
						s.vel_life.xyz = vec3(0.0);
						s.vel_life.w = min(s.vel_life.w, s.pos_age.w + LAND_FADE);
					}
				}
			}
		}
	}
	spray[i] = s;
}
