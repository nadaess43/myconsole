extends Node2D

var firefly_time: float = 0.0
var firefly_texture: ImageTexture

func setup() -> void:
	firefly_texture = _make_firefly_texture()
	var vp_size: Vector2 = get_viewport_rect().size
	var band_top: float = vp_size.y * 0.32
	var band_bottom: float = vp_size.y * 0.62
	for i in 60:
		var s := Sprite2D.new()
		s.texture = firefly_texture
		s.modulate = Color(0.4, 0.6, 1.0, 0.0)
		s.scale = Vector2.ONE * randf_range(0.3, 0.7)
		var pos := Vector2(randf_range(vp_size.x * 0.2, vp_size.x * 0.88), randf_range(band_top, band_bottom))
		s.position = pos
		add_child(s)

func _process(delta: float) -> void:
	firefly_time += delta
	for s in get_children():
		if not s is Sprite2D: continue
		var si = s.get_meta("ff_speed", 0.0)
		if si == 0.0:
			si = randf_range(0.2, 0.55)
			s.set_meta("ff_speed", si)
			s.set_meta("ff_phase", randf_range(0, TAU))
			s.set_meta("ff_drift", randf_range(0, TAU))
			s.set_meta("ff_base", s.position)
		var speed: float = si
		var phase: float = s.get_meta("ff_phase", 0.0)
		var drift: float = s.get_meta("ff_drift", 0.0)
		var base_pos: Vector2 = s.get_meta("ff_base", Vector2.ZERO)
		var t: float = firefly_time * speed + phase
		var a: float = (sin(t) * 0.5 + 0.5) * 0.35 + 0.05
		s.modulate.a = a
		s.position = base_pos + Vector2(sin(t * 0.3 + drift) * 6.0, cos(t * 0.25) * 4.0)

func _make_firefly_texture() -> ImageTexture:
	var size := 16
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size / 2.0, size / 2.0)
	for x in size:
		for y in size:
			var d: float = Vector2(x, y).distance_to(center) / (size / 2.0)
			var a: float = clamp(1.0 - d, 0.0, 1.0)
			a = pow(a, 2.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
