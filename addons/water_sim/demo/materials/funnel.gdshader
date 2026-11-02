// The tornado's funnel: unshaded streaks winding up a cone, fading at the top and bottom.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec4 color : source_color = vec4(0.85, 0.92, 1.0, 0.35);
uniform float streaks = 5.0;
uniform float twist = 2.0;

void fragment() {
	float s = fract(UV.x * streaks + UV.y * twist - TIME * 0.6);
	float streak = smoothstep(0.0, 0.25, s) * (1.0 - smoothstep(0.45, 0.7, s));
	float ends = smoothstep(0.0, 0.25, UV.y) * (1.0 - smoothstep(0.75, 1.0, UV.y));
	ALBEDO = color.rgb;
	ALPHA = color.a * streak * ends;
}
