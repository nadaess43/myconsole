extends RefCounted
class_name UiKit

static func make_glass_card(title: String, subtitle: String, icon: Texture2D = null) -> PanelContainer:
	var card = PanelContainer.new(); card.custom_minimum_size = Vector2(460, 52)
	card.pivot_offset = Vector2(230, 26)
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.04)
	style.set_corner_radius_all(8)
	style.border_width_left = 1; style.border_width_right = 1
	style.border_width_top = 1; style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.06)
	style.content_margin_left = 16; style.content_margin_right = 16
	style.content_margin_top = 7; style.content_margin_bottom = 7
	card.add_theme_stylebox_override("panel", style)
	var hbox = HBoxContainer.new(); hbox.add_theme_constant_override("separation", 12)
	if icon:
		var tr = TextureRect.new(); tr.texture = icon; tr.custom_minimum_size = Vector2(36, 36)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hbox.add_child(tr)
		card.set_meta("icon_rect", tr)
	else:
		var dot = ColorRect.new(); dot.custom_minimum_size = Vector2(4, 4)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.color = Color(1, 1, 1, 0.12)
		hbox.add_child(dot)
		card.set_meta("icon_rect", dot)
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t = Label.new(); t.text = title; t.add_theme_font_size_override("font_size", 16)
	t.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99, 1.0))
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.clip_text = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var s = Label.new(); s.text = subtitle; s.add_theme_font_size_override("font_size", 12)
	s.add_theme_color_override("font_color", Color(0.66, 0.72, 0.82, 0.85))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.clip_text = true
	s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vbox.add_child(t); vbox.add_child(s); hbox.add_child(vbox); card.add_child(hbox)
	card.set_meta("title_label", t)
	card.set_meta("subtitle_label", s)
	return card

static func add_label_style(lbl: Label) -> void:
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90, 0.85))
