shader_type canvas_item;

uniform float wave_time = 0.0;
uniform vec4 color_top : source_color = vec4(0.04, 0.08, 0.22, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.01, 0.03, 0.10, 1.0);

void fragment() {
	vec2 uv = UV;

	// Soft radial/vertical gradient — brighter at top-center, fading to dark
	float radial = 1.0 - distance(uv, vec2(0.5, 0.25)) * 0.7;
	vec4 gradient = mix(color_bottom, color_top, smoothstep(0.0, 0.85, uv.y));
	gradient.rgb *= 0.85 + radial * 0.15;

	// ── Subtle warm spot in upper-right, fades with distance ──
	float spot_dist = distance(uv, vec2(0.82, 0.12));
	float spot = smoothstep(0.5, 0.0, spot_dist) * 0.04;
	vec3 spot_color = vec4(0.12, 0.10, 0.18, 1.0).rgb;
	gradient.rgb += spot_color * spot;

	// ── Very subtle random-ish pulse (slow sine + tiny offset) ──
	float pulse = 0.94 + 0.06 * sin(wave_time * 0.45 + sin(wave_time * 0.17) * 0.5);

	// ── Primary ribbon: wide, translucent, slow ──
	float w1  = sin(uv.x * 4.0 + wave_time * 0.30) * 0.055 * pulse;
	w1 += sin(uv.x * 2.7 + wave_time * 0.45) * 0.040 * pulse;
	w1 += sin(uv.x * 6.5 + wave_time * 0.55) * 0.018 * pulse;
	float y1 = 0.44 + w1;

	float d1 = abs(uv.y - y1);
	float glow1 = smoothstep(0.22, 0.0, d1) * 0.30 * pulse;
	glow1 += smoothstep(0.09, 0.0, d1) * 0.16 * pulse;
	float core1 = smoothstep(0.005, 0.0, d1) * 0.50 * pulse;
	core1 += smoothstep(0.016, 0.0, d1) * 0.18 * pulse;

	// ── Secondary ribbon: thinner, faster, offset ──
	float w2  = sin(uv.x * 5.8 - wave_time * 0.50) * 0.020 * pulse;
	w2 += cos(uv.x * 3.6 + wave_time * 0.35) * 0.024 * pulse;
	float y2 = 0.52 + w2;

	float d2 = abs(uv.y - y2);
	float glow2 = smoothstep(0.10, 0.0, d2) * 0.14 * pulse;
	glow2 += smoothstep(0.04, 0.0, d2) * 0.07 * pulse;

	// ── Tertiary wave: very wide, very subtle ──
	float w3  = sin(uv.x * 2.2 - wave_time * 0.20) * 0.065 * pulse;
	w3 += cos(uv.x * 1.5 + wave_time * 0.15) * 0.055 * pulse;
	float y3 = 0.38 + w3;

	float d3 = abs(uv.y - y3);
	float glow3 = smoothstep(0.35, 0.0, d3) * 0.05 * pulse;

	// ── Combine ──
	vec3 wave_col = vec3(0.40, 0.65, 0.92);
	vec3 core_col = vec3(0.72, 0.84, 1.0);

	COLOR = gradient;
	COLOR.rgb = mix(COLOR.rgb, wave_col, glow1 + glow2 + glow3);
	COLOR.rgb = mix(COLOR.rgb, core_col, core1);
}
