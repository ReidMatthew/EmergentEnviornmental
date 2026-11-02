shader_type spatial;
// A WaterSimLodView's particles: each read from the point buffer (as a texture), drawn as a see-through disc facing the camera
// in the colour of its level of detail. Levels: 0 the simulation's fine particles, 1 to 3 the coarser ones.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// The point buffer: one texel a point (x, y, z quantized to the extent, and the draw word).
uniform sampler2D points : filter_nearest;
uniform int width = 4096;
// How many points the buffer holds. It is read from the end, farthest block first, so the blend shows what is nearest on top.
uniform int count = 0;
uniform vec3 extent = vec3(1.0);
uniform mat4 to_world;
// A fine simulation particle's radius (m), and the drawn size as a multiple of the true one.
uniform float radius = 0.07;
uniform float size_scale = 0.6;
// Bit n set: level n is not drawn.
uniform int hidden_levels = 0;
uniform vec4 colors[4];
// Particles in sleeping blocks (the point word's bit 6, asked for with mark_asleep) are drawn in this colour instead.
uniform bool grey_asleep = false;
uniform vec4 asleep_color : source_color = vec4(0.5, 0.5, 0.5, 0.35);
// With grey_asleep: the sleeping particles are not drawn at all.
uniform bool hide_asleep = false;

varying flat int level;
varying flat int asleep;

void vertex() {
	int at = count - 1 - INSTANCE_ID;
	vec4 t = texelFetch(points, ivec2(at % width, at / width), 0);
	uvec4 u = uvec4(round(t * 65535.0));
	uint word = u.w;
	level = int((word >> 8u) & 3u);
	asleep = grey_asleep ? int((word >> 6u) & 1u) : 0;
	float r = radius * exp2(float(level));
	// (word 65535: room a block of the solver's own points didn't use, no particle.)
	if ((hidden_levels >> level & 1) != 0 || (hide_asleep && asleep != 0) || word == 65535u) {
		// Outside the clip volume: not drawn.
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec3 world = (to_world * vec4(vec3(u.xyz) / 65535.0 * extent, 1.0)).xyz;
		vec4 view = VIEW_MATRIX * vec4(world, 1.0);
		view.xy += VERTEX.xy * 2.0 * r * size_scale;
		POSITION = PROJECTION_MATRIX * view;
	}
}

void fragment() {
	vec2 d = UV * 2.0 - 1.0;
	if (dot(d, d) > 1.0) {
		discard;
	}
	vec4 color = asleep != 0 ? asleep_color : colors[level];
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
