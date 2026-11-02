#[compute]
#version 450

// The opaque look: the smoothed surface of the nearest particles, lit (the sun, the sky in it at a glancing angle, a glint),
// coloured by the nearest particle's substance. No thickness or refraction: water as a solid-looking lit body, the way Liquid
// Crystal draws its particles; the translucent screen-space look is the other style (fluid_shade.glsl).

#include "fluid_params.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D smooth_depth;
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D color_out;
layout(set = 0, binding = 3) uniform sampler2D near_big;
layout(set = 0, binding = 4, r32ui) uniform restrict readonly uimage2D near_small;
layout(set = 0, binding = 5) uniform sampler2D scene_depth;

#define OPAQUE_TARGETS
#include "fluid_opaque_surface.glslinc"

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(u.screen.xy);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	vec4 s;
	vec2 f;
	float d;
	if (!opaque_depth(p, s, f, d)) {
		return;
	}
	vec2 uv = (vec2(p) + 0.5) * u.screen.zw;
	float z = d * u.sizes.y;
	// (What the scene has in front of the water, a pixel at a time, so its edge against a wall stays sharp.)
	vec4 scene_at = u.inv_proj * vec4(uv * 2.0 - 1.0, texelFetch(scene_depth, p, 0).r, 1.0);
	if (z > -scene_at.z / scene_at.w) {
		return;
	}
	vec3 here = view_position(uv, z);
	vec3 n = opaque_normal(uv, here, d, s, f);
	int substance = opaque_substance(p);
	vec3 view_dir = normalize(-here);
	// The body colour: the substance's deep colour, lighter where the surface faces the sky (shallow colour), lit by the sun.
	vec3 deep = u.deep[substance].rgb;
	vec3 shallow = u.shallow[substance].rgb;
	float up = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 body = mix(deep, shallow, up * 0.5);
	float diffuse = max(dot(n, u.sun_dir.xyz), 0.0);
	vec3 colour = body * (0.45 + 0.55 * diffuse * u.sun_dir.w) * mix(vec3(1.0), u.sun_color.rgb, 0.5);
	float fresnel = 0.03 + (1.0 - 0.03) * pow(1.0 - max(dot(n, view_dir), 0.0), 5.0);
	colour = mix(colour, u.sky_color.rgb, fresnel * u.light.z);
	vec3 h = normalize(u.sun_dir.xyz + view_dir);
	colour += u.sun_color.rgb * u.sun_dir.w * u.light.x * pow(max(dot(n, h), 0.0), u.light.y);
	imageStore(color_out, p, vec4(colour, 1.0));
}
