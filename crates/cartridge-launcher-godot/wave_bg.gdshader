shader_type canvas_item;

uniform float wave_time = 0.0;
uniform vec4 color_top : source_color = vec4(0.06, 0.04, 0.16, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.01, 0.10, 0.20, 1.0);

void fragment() {
	// Smooth dark vertical gradient
	vec4 bg = mix(color_top, color_bottom, UV.y);

	// ── Primary silk ribbon (thick, slow, central) ──
	float w1 = sin(UV.x * 5.5 + wave_time * 0.35) * 0.022;
	w1 += sin(UV.x * 3.8 + wave_time * 0.22) * 0.028;
	w1 += sin(UV.x * 8.0 + wave_time * 0.50) * 0.012;
	float y1 = 0.50 + w1;

	// ── Secondary ribbon (thinner, faster, slightly above) ──
	float w2 = sin(UV.x * 7.0 - wave_time * 0.55) * 0.012;
	w2 += cos(UV.x * 4.5 + wave_time * 0.30) * 0.018;
	float y2 = 0.56 + w2;

	// ── Wide soft glow around both ribbons ──
	float d1 = abs(UV.y - y1);
	float glow1 = smoothstep(0.10, 0.0, d1) * 0.22;
	glow1 += smoothstep(0.05, 0.0, d1) * 0.15;

	float d2 = abs(UV.y - y2);
	float glow2 = smoothstep(0.06, 0.0, d2) * 0.10;

	// ── Bright core line on primary ribbon ──
	float core = smoothstep(0.004, 0.0, d1) * 0.45;
	core += smoothstep(0.012, 0.0, d1) * 0.15;

	vec3 glow_col = vec3(0.5, 0.7, 1.0);

	COLOR = bg;
	COLOR.rgb = mix(COLOR.rgb, glow_col, glow1 + glow2);
	COLOR.rgb = mix(COLOR.rgb, vec3(0.80, 0.88, 1.0), core);
}
