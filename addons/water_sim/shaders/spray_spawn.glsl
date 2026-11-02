#[compute]
#version 450

#include "spray.glslinc"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// The spray the simulation shed (eight floats each in its space: x, y, z, substance, velocity, what shed it) into the pool, scattered
// a little so a stream of them reads as spray, not as copies of the water. Each one shed makes u.scatter.z particles (pc.count is
// all of them).
layout(set = 0, binding = 2, std430) restrict readonly buffer Spawns {
	vec4 spawns[];
};

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.count) {
		return;
	}
	uint from = i / max(uint(u.scatter.z), 1u);
	vec4 a = spawns[from * 2u];
	vec4 b = spawns[from * 2u + 1u];
	uint state = spray_hash(pc.seed ^ (i * 0x9E3779B1u));
	vec3 jitter = vec3(spray_random(state), spray_random(state), spray_random(state)) * 2.0 - 1.0;
	vec3 kick = vec3(spray_random(state), spray_random(state), spray_random(state)) * 2.0 - 1.0;
	vec3 pos = (u.world_from_solver * vec4(a.xyz, 1.0)).xyz + jitter * u.scatter.x;
	vec3 vel = mat3(u.world_from_solver) * b.xyz;
	vel += kick * (length(vel) * u.scatter.y + u.scatter.w);
	float life = u.life.x * (1.0 + u.life.y * (spray_random(state) * 2.0 - 1.0));
	uint at = (pc.head + i) % pc.capacity;
	spray[at].pos_age = vec4(pos, 0.0);
	spray[at].vel_life = vec4(vel, max(life, 0.05));
	spray[at].extra = vec4(a.w, 0.0, 0.0, 0.0);
}
