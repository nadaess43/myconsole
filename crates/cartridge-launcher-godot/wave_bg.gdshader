shader_type canvas_item;

uniform float wave_time = 0.0;
uniform vec4 color_top : source_color = vec4(0.04, 0.08, 0.22, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.01, 0.03, 0.10, 1.0);

void fragment() {
	// Soft radial/vertical gradient — brighter at top-center, fading to dark
	float radial = 1.0 - distance(UV, vec2(0.5, 0.25)) * 0.7;
	vec4 gradient = mix(color_bottom, color_top, smoothstep(0.0, 0.85, UV.y));
	gradient.rgb *= 0.85 + radial * 0.15;

	// ── Primary ribbon: wide, translucent, slow ──
	float w1  = sin(UV.x * 4.0 + wave_time * 0.30) * 0.055;
	w1 += sin(UV.x * 2.7 + wave_time * 0.45) * 0.040;
	w1 += sin(UV.x * 6.5 + wave_time * 0.55) * 0.018;
	float y1 = 0.44 + w1;

	float d1 = abs(UV.y - y1);
	float glow1 = smoothstep(0.22, 0.0, d1) * 0.28;
	glow1 += smoothstep(0.09, 0.0, d1) * 0.18;
	float core1 = smoothstep(0.005, 0.0, d1) * 0.55;
	core1 += smoothstep(0.016, 0.0, d1) * 0.20;

	// ── Secondary ribbon: thinner, faster, offset ──
	float w2  = sin(UV.x * 5.8 - wave_time * 0.50) * 0.022;
	w2 += cos(UV.x * 3.6 + wave_time * 0.35) * 0.028;
	float y2 = 0.52 + w2;

	float d2 = abs(UV.y - y2);
	float glow2 = smoothstep(0.10, 0.0, d2) * 0.15;
	glow2 += smoothstep(0.04, 0.0, d2) * 0.08;

	// ── Tertiary wave: very wide, very subtle ──
	float w3  = sin(UV.x * 2.2 - wave_time * 0.20) * 0.070;
	w3 += cos(UV.x * 1.5 + wave_time * 0.15) * 0.060;
	float y3 = 0.38 + w3;

	float d3 = abs(UV.y - y3);
	float glow3 = smoothstep(0.35, 0.0, d3) * 0.06;

	// ── Combine ──
	vec3 wave_col = vec3(0.40, 0.65, 0.92);       // soft blue glow
	vec3 core_col = vec3(0.72, 0.84, 1.0);         // bright core

	COLOR = gradient;
	COLOR.rgb = mix(COLOR.rgb, wave_col, glow1 + glow2 + glow3);
	COLOR.rgb = mix(COLOR.rgb, core_col, core1);
}
