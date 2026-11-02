#[compute]
#version 450

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D smooth_depth;
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D color_out;
layout(set = 0, binding = 3) uniform sampler2D deep_sum;
layout(set = 0, binding = 4) uniform sampler2D shallow_sum;
layout(set = 0, binding = 5) uniform sampler2D scene_color;
layout(set = 0, binding = 6) uniform sampler2D scene_depth;

// A point of the water's surface in the camera's space, from where it is in the picture and how far away it is.
vec3 view_position(vec2 uv, float distance_m) {
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 ray = h.xyz / h.w;
	return ray * (-distance_m / ray.z);
}

// How far the water is at a neighbouring pixel, for the normal; where there is none there, or it is a different surface (a jump
// in depth), the pixel's own distance, so an edge reads as flat instead of tipping the normal right over.
float surface_distance(ivec2 p, ivec2 size, float own) {
	p = clamp(p, ivec2(0), size - 1);
	float d = texelFetch(smooth_depth, p, 0).r;
	if (d >= 0.9999) {
		return own;
	}
	float z = d * u.sizes.y;
	return abs(z - own) > u.sizes.w * 1.5 ? own : z;
}

float scene_distance(vec2 uv) {
	float depth = texture(scene_depth, uv).r;
	vec4 h = u.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -h.z / h.w;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(u.screen.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	float d = texelFetch(smooth_depth, p, 0).r;
	if (d >= 0.9999) {
		return;
	}
	float z0 = d * u.sizes.y;
	// The thickness and colours blurred over a disc (so single particles don't show in them), and how much of the disc is water
	// (so the edge of the water fades instead of cutting off in a row of bumps).
	float focal = abs(u.proj[1][1]) * 0.5 * u.screen.y;
	float radius_px = clamp(u.sizes.z * 0.5 * focal / z0, 1.0, 24.0);
	vec4 deep = vec4(0.0);
	vec4 shallow_acc = vec4(0.0);
	float covered = 0.0;
	float weights = 0.0;
	for (int i = 0; i < 20; i++) {
		float r = sqrt((float(i) + 0.5) / 20.0);
		float angle = float(i) * 2.39996323;
		ivec2 q = clamp(p + ivec2(round(vec2(cos(angle), sin(angle)) * r * radius_px)), ivec2(0), size - 1);
		float w = exp(-2.0 * r * r);
		ivec2 t = q / int(u.extra.x);
		deep += w * texelFetch(deep_sum, t, 0);
		shallow_acc += w * texelFetch(shallow_sum, t, 0);
		covered += w * (texelFetch(smooth_depth, q, 0).r < 0.9999 ? 1.0 : 0.0);
		weights += w;
	}
	deep /= weights;
	shallow_acc /= weights;
	covered /= weights;
	if (deep.a < 1e-4) {
		return;
	}
	float edge = smoothstep(0.2, 0.9, covered);
	vec2 uv = (vec2(p) + 0.5) * u.screen.zw;
	float z = d * u.sizes.y;
	vec3 here = view_position(uv, z);

	// The normal, from the smoothed depth: the neighbours on the side that is nearer in depth, so an edge doesn't bend it.
	float zl = surface_distance(p - ivec2(1, 0), size, z), zr = surface_distance(p + ivec2(1, 0), size, z);
	float zu = surface_distance(p - ivec2(0, 1), size, z), zd = surface_distance(p + ivec2(0, 1), size, z);
	vec3 dx = abs(zr - z) < abs(z - zl) ? view_position(uv + vec2(u.screen.z, 0.0), zr) - here : here - view_position(uv - vec2(u.screen.z, 0.0), zl);
	vec3 dy = abs(zd - z) < abs(z - zu) ? view_position(uv + vec2(0.0, u.screen.w), zd) - here : here - view_position(uv - vec2(0.0, u.screen.w), zu);
	vec3 n = normalize(cross(dx, dy));
	if (n.z < 0.0) {
		n = -n;
	}
	// Beside an edge of the water the normal can't be trusted: turn it towards the camera there, so no glints streak along the rim.
	float rim = smoothstep(0.7, 0.98, covered);
	n = normalize(mix(vec3(0.0, 0.0, 1.0), n, smoothstep(0.0, 1.0, rim)));
	vec3 v = normalize(-here);

	// How thick the water is here, and its colour: shallow and light where it is thin, deep where it is thick.
	float t = deep.a;
	vec3 deep_colour = deep.rgb / deep.a;
	vec3 shallow_colour = shallow_acc.rgb / deep.a;
	float deepness = 1.0 - exp(-t / u.thickness.y);
	vec3 body = mix(shallow_colour, deep_colour, deepness);

	// What shows through, bent by the surface (not from something in front of the water).
	vec2 bend = vec2(n.x, -n.y) * u.thickness.w * min(t, 1.0) / max(z, 1.0);
	vec2 ruv = uv + bend;
	if (scene_distance(ruv) < z) {
		ruv = uv;
	}
	vec3 behind = textureLod(scene_color, ruv, 0.0).rgb;
	float opacity = 1.0 - exp(-t * u.thickness.z);
	vec3 colour = mix(behind * mix(vec3(1.0), body, 0.55), body * (0.8 + 0.2 * max(dot(n, u.sun_dir.xyz), 0.0)), opacity);

	// The sky in it at a glancing angle, and the sun on it.
	float fresnel = 0.03 + (1.0 - 0.03) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
	colour = mix(colour, u.sky_color.rgb, fresnel * u.light.z);
	vec3 h = normalize(u.sun_dir.xyz + v);
	colour += u.sun_color.rgb * u.sun_dir.w * u.light.x * pow(max(dot(n, h), 0.0), u.light.y);
	colour = mix(texelFetch(scene_color, p, 0).rgb, colour, edge);
	imageStore(color_out, p, vec4(colour, 1.0));
}
