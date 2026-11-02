// Cel-shaded see-through liquid for a WaterSimSurfaceView: a few hard light bands, a hard
// highlight and a bright rim where the surface turns away from the camera.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;

uniform vec4 color : source_color = vec4(0.25, 0.62, 0.95, 0.78);
// Colour of the darkest band, as a fraction of color.
uniform float shadow = 0.55;
uniform int bands : hint_range(1, 6) = 2;
uniform vec4 rim_color : source_color = vec4(0.85, 0.96, 1.0, 1.0);
uniform float rim_width : hint_range(0.0, 1.0) = 0.25;
uniform float highlight_size : hint_range(0.0, 1.0) = 0.06;

void fragment() {
	ALBEDO = color.rgb;
	float facing = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = step(1.0 - rim_width, facing);
	EMISSION = rim_color.rgb * rim * 0.5;
	ALPHA = mix(color.a, 1.0, rim * 0.6);
	ROUGHNESS = 1.0;
}

void light() {
	float lit = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0) * ATTENUATION;
	float band = floor(lit * float(bands) + 0.5) / float(bands);
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * mix(shadow, 1.0, band);
	vec3 half_vector = normalize(LIGHT + VIEW);
	SPECULAR_LIGHT += LIGHT_COLOR / PI * step(1.0 - highlight_size, dot(NORMAL, half_vector)) * ATTENUATION;
}
