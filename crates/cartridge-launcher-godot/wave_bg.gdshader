shader_type canvas_item;

uniform float wave_time = 0.0;
uniform vec4 color_top : source_color = vec4(0.02, 0.09, 0.13, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.03, 0.20, 0.32, 1.0);

void fragment() {
	vec4 bg = mix(color_top, color_bottom, UV.y);

	// слой 1 — основная волна
	float w1 = sin(UV.x * 5.5 + wave_time * 0.35) * 0.022;
	w1 += sin(UV.x * 3.8 + wave_time * 0.22) * 0.028;
	w1 += sin(UV.x * 8.0 + wave_time * 0.50) * 0.012;
	float y1 = 0.50 + w1;

	// слой 2 — вторая волна, другая скорость/фаза
	float w2 = sin(UV.x * 7.0 - wave_time * 0.55) * 0.012;
	w2 += cos(UV.x * 4.5 + wave_time * 0.30) * 0.018;
	float y2 = 0.56 + w2;

	// слой 3 — диагональный блик, как на ПС3 (зависит от UV.x + UV.y)
	float w3 = sin((UV.x + UV.y * 0.6) * 6.0 - wave_time * 0.4) * 0.03;
	float y3 = 0.40 + w3;

	float d1 = abs(UV.y - y1);
	float glow1 = smoothstep(0.12, 0.0, d1) * 0.28;
	glow1 += smoothstep(0.05, 0.0, d1) * 0.20;

	float d2 = abs(UV.y - y2);
	float glow2 = smoothstep(0.07, 0.0, d2) * 0.14;

	float d3 = abs(UV.y - y3);
	float glow3 = smoothstep(0.09, 0.0, d3) * 0.16;

	float core = smoothstep(0.004, 0.0, d1) * 0.55;
	core += smoothstep(0.014, 0.0, d1) * 0.18;

	// лёгкий сдвиг оттенка бликов во времени — не статично
	vec3 glow_col = vec3(0.45, 0.85, 1.0) + vec3(sin(wave_time * 0.15) * 0.05, 0.0, cos(wave_time * 0.12) * 0.04);

	COLOR = bg;
	COLOR.rgb *= 1.12;
	COLOR.rgb = mix(COLOR.rgb, glow_col, glow1 + glow2 + glow3);
	COLOR.rgb = mix(COLOR.rgb, vec3(0.85, 0.92, 1.0), core);
}
