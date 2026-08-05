extends Control

const DAEMON_PATH = "../../target/release/cartridge-daemon.exe"
const MAKER_PATH = "../../target/release/cartridge-maker.exe"
const EVENTS_FILE = "user://events.log"
const UI_CONFIG_FILE = "user://launcher.cfg"
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.50
const POLL_INTERVAL = 0.2

const _WU = preload("res://win_utils.gd")
const _UK = preload("res://ui_kit.gd")
const _WF = preload("res://wizard.gd")

var daemon_pid: int = -1
var cartridge_data: Dictionary = {}
var events_file_path: String = ""
var events_read: int = 0
var wave_time: float = 0.0
@onready var fireflies_node: Node2D = $Fireflies
@onready var ui_container: Control = $UIContainer

enum Tab { GAMES, SETTINGS, NETWORK }
var current_tab: int = Tab.GAMES
var selected_index: int = -1
var nav_axis: int = 0
var nav_hold_time: float = 0.0
var nav_first: bool = true
var nav_repeated: bool = false
var last_launch_ms: int = 0

var wizard: WizardFlow = WizardFlow.new()

var wizard_active: bool:
	get: return wizard.active
	set(v): wizard.active = v
var wizard_step: int:
	get: return wizard.step
	set(v): wizard.step = v
var wizard_data: Dictionary:
	get: return wizard.data
	set(v): wizard.data = v
var browser_selected: int:
	get: return wizard.browser_selected
	set(v): wizard.browser_selected = v
var settings_editing: LineEdit:
	get: return wizard.settings_editing
	set(v): wizard.settings_editing = v

# ── Animation state ────────────────────────────────────────────────────────
var focus_tween: Tween
const FOCUS_SCALE_FOCUSED: Vector2 = Vector2(1.02, 1.02)
const FOCUS_SCALE_UNFOCUSED: Vector2 = Vector2.ONE
const FOCUS_MODULATE_UNFOCUSED: float = 0.55
const FOCUS_DURATION: float = 0.18
const NAV_INITIAL_DELAY: float = 0.45
const NAV_REPEAT_RATE: float = 0.13

var tab_tween: Tween
var wave_tween: Tween

@onready var cartridge_list: VBoxContainer = $UIContainer/TabPages/GamesPage/GamesScroll/CartridgeList
@onready var games_scroll: ScrollContainer = $UIContainer/TabPages/GamesPage/GamesScroll
@onready var clock_label: Label = $UIContainer/ClockLabel
@onready var date_label: Label = $UIContainer/DateLabel
@onready var wave_bg: ColorRect = $Background
@onready var cat_games: Label = $UIContainer/CategoryRow/CatGames
@onready var cat_settings: Label = $UIContainer/CategoryRow/CatSettings
@onready var cat_network: Label = $UIContainer/CategoryRow/CatNetwork
@onready var tab_pages: Control = $UIContainer/TabPages
@onready var wizard_container: Control = $UIContainer/WizardContainer
@onready var wizard_title: Label = $UIContainer/WizardContainer/WizardTitle
@onready var breadcrumb: Label = $UIContainer/WizardContainer/Breadcrumb
@onready var wizard_list: VBoxContainer = $UIContainer/WizardContainer/WizardScroll/WizardList
@onready var wizard_scroll: ScrollContainer = $UIContainer/WizardContainer/WizardScroll
@onready var wizard_extra: Control = $UIContainer/WizardContainer/WizardExtra
@onready var hint_bar: Label = $UIContainer/HintBar
@onready var games_page: Control = $UIContainer/TabPages/GamesPage
@onready var underline: ColorRect = $UIContainer/CategoryRow/Underline
@onready var category_row: Control = $UIContainer/CategoryRow
@onready var settings_title: Label = $UIContainer/TabPages/SettingsPage/SettingsTitle
@onready var settings_label: Label = $UIContainer/TabPages/SettingsPage/SettingsLabel
@onready var scale_container: Control = $UIContainer/TabPages/SettingsPage/ScaleContainer
@onready var scale_slider: HSlider = $UIContainer/TabPages/SettingsPage/ScaleContainer/ScaleSlider
@onready var scale_label: Label = $UIContainer/TabPages/SettingsPage/ScaleContainer/ScaleLabel


func _ready() -> void:
	print("[%s] INIT: Launcher starting" % WinUtils.ts())
	_setup_gamepad_actions()
	_layout_ui()
	_update_ui_pivot()
	events_file_path = ProjectSettings.globalize_path(EVENTS_FILE)
	print("[%s] INIT: events.log = %s" % [WinUtils.ts(), events_file_path])
	_update_clock()
	_create_new_cartridge_card()
	_start_daemon()
	_switch_tab(Tab.GAMES)
	if not $Timer.timeout.is_connected(_on_timer_timeout):
		$Timer.timeout.connect(_on_timer_timeout)
	$Timer.wait_time = POLL_INTERVAL
	$Timer.start()
	fireflies_node.set_script(preload("res://fireflies.gd"))
	if fireflies_node.has_method("setup"): fireflies_node.setup()
	wizard.init(self, cartridge_data, cartridge_list, wizard_list, wizard_scroll,
		wizard_title, breadcrumb, wizard_extra, wizard_container, hint_bar, games_page, category_row)
	if not wizard.cartridge_created.is_connected(_add_cartridge):
		wizard.cartridge_created.connect(_add_cartridge)
	_close_wizard()
	_move_underline_to(cat_games, false)
	scale_slider.min_value = UI_SCALE_MIN
	scale_slider.max_value = UI_SCALE_MAX
	scale_slider.value = _load_ui_scale()
	scale_slider.value_changed.connect(_on_scale_changed)
	_on_scale_changed(scale_slider.value)
	get_viewport().size_changed.connect(_on_viewport_resized)
	print("[%s] INIT: Ready — polling every %.1fs" % [WinUtils.ts(), POLL_INTERVAL])


func _setup_gamepad_actions() -> void:
	for action in ["tab_prev", "tab_next", "ui_select_folder"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
	for pair in [[0, "ui_accept"], [1, "ui_cancel"], [2, "ui_select"], [3, "ui_select_folder"], [3, "ui_select"]]:
		var ev = InputEventJoypadButton.new()
		ev.button_index = pair[0]
		if not InputMap.action_has_event(pair[1], ev):
			InputMap.action_add_event(pair[1], ev)
	for pair in [[JOY_BUTTON_LEFT_SHOULDER, "tab_prev"], [JOY_BUTTON_RIGHT_SHOULDER, "tab_next"]]:
		var ev = InputEventJoypadButton.new()
		ev.button_index = pair[0]
		if not InputMap.action_has_event(pair[1], ev):
			InputMap.action_add_event(pair[1], ev)
	for pair in [[KEY_Q, "tab_prev"], [KEY_E, "tab_next"], [KEY_F, "ui_select_folder"], [KEY_Y, "ui_select_folder"],
		[KEY_X, "ui_select"],
		[KEY_BRACKETLEFT, "tab_prev"], [KEY_BRACKETRIGHT, "tab_next"]]:
		var k = InputEventKey.new()
		k.keycode = pair[0]
		if not InputMap.action_has_event(pair[1], k):
			InputMap.action_add_event(pair[1], k)


# ── Process ────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	wave_time += delta
	wave_bg.material.set_shader_parameter("wave_time", wave_time)
	if Engine.get_process_frames() % 30 == 0: _update_clock()
	if nav_axis != 0:
		if nav_first:
			_move_selection(nav_axis); nav_first = false; nav_hold_time = 0.0
		else:
			nav_hold_time += delta
			var d = NAV_INITIAL_DELAY if not nav_repeated else NAV_REPEAT_RATE
			if nav_hold_time >= d:
				_move_selection(nav_axis); nav_hold_time -= d; nav_repeated = true
	if nav_axis != 0 and not Input.is_action_pressed("ui_up") and not Input.is_action_pressed("ui_down"):
		nav_axis = 0; nav_first = true; nav_repeated = false


func _update_clock() -> void:
	var dt = Time.get_datetime_dict_from_system()
	clock_label.text = "%02d:%02d" % [dt.hour, dt.minute]
	date_label.text = "%d/%d" % [dt.month, dt.day]


# ── Tab switching ──────────────────────────────────────────────────────────
func _switch_tab(tab: int) -> void:
	print("[%s] TAB: → %d" % [WinUtils.ts(), tab])
	var old_tab := current_tab
	current_tab = tab

	# ── Animate underline ──
	var target_label: Label
	match tab:
		Tab.GAMES: target_label = cat_games
		Tab.SETTINGS: target_label = cat_settings
		_: target_label = cat_network
	_move_underline_to(target_label, true)

	# ── Fade pages ──
	if old_tab != tab:
		if tab_tween and tab_tween.is_valid(): tab_tween.kill()
		var old_page: Control = tab_pages.get_child(old_tab)
		var new_page: Control = tab_pages.get_child(tab)
		for i in tab_pages.get_child_count():
			var page := tab_pages.get_child(i) as Control
			if i != old_tab and i != tab:
				page.visible = false
				page.modulate.a = 1.0
		old_page.visible = true
		old_page.modulate.a = 1.0
		# Hide new page instantly, start fade-in after old fades out
		new_page.visible = true
		new_page.modulate.a = 0.0
		tab_tween = create_tween()
		tab_tween.tween_property(old_page, "modulate:a", 0.0, 0.12).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
		tab_tween.tween_callback(func():
			old_page.visible = false; old_page.modulate.a = 1.0)
		tab_tween.tween_property(new_page, "modulate:a", 1.0, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	else:
		var page: Control = tab_pages.get_child(tab)
		page.visible = true; page.modulate.a = 1.0
	if tab == Tab.SETTINGS:
		scale_slider.grab_focus()

	# ── Category label modulate ──
	cat_games.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.GAMES else 0.28)
	cat_settings.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.SETTINGS else 0.28)
	cat_network.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.NETWORK else 0.28)

	# ── Wave pulse ──
	_pulse_wave()

	selected_index = -1; _refresh_selection()


func _move_underline_to(label: Label, animate: bool) -> void:
	var target_x: float = label.position.x
	var target_w: float = label.size.x
	if animate:
		var ut = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		ut.tween_property(underline, "position:x", target_x, 0.25)
		ut.parallel().tween_property(underline, "size:x", target_w, 0.25)
	else:
		underline.position.x = target_x
		underline.size.x = target_w


func _pulse_wave() -> void:
	if wave_tween and wave_tween.is_valid(): wave_tween.kill()
	wave_bg.material.set_shader_parameter("wave_intensity", 1.0)
	wave_tween = create_tween()
	wave_tween.tween_property(wave_bg.material, "shader_parameter/wave_intensity", 1.3, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	wave_tween.tween_property(wave_bg.material, "shader_parameter/wave_intensity", 1.0, 0.65).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)

func _on_scale_changed(value: float) -> void:
	var clamped = clampf(value, UI_SCALE_MIN, UI_SCALE_MAX)
	if scale_slider.value != clamped:
		scale_slider.value = clamped
	scale_label.text = "UI Scale: %.2fx" % clamped
	_update_ui_pivot()
	ui_container.scale = Vector2(clamped, clamped)
	var config = ConfigFile.new()
	config.set_value("ui", "scale", clamped)
	config.save(UI_CONFIG_FILE)

func _load_ui_scale() -> float:
	var config = ConfigFile.new()
	if config.load(UI_CONFIG_FILE) == OK:
		return clampf(float(config.get_value("ui", "scale", 1.0)), UI_SCALE_MIN, UI_SCALE_MAX)
	return 1.0

func _update_ui_pivot() -> void:
	if ui_container == null: return
	ui_container.pivot_offset = get_viewport_rect().size * 0.5

func _on_viewport_resized() -> void:
	_layout_ui()
	_update_ui_pivot()

func _layout_ui() -> void:
	if category_row == null: return
	var viewport = get_viewport_rect().size
	var content_width = minf(482.0, maxf(300.0, viewport.x - 40.0))
	var content_left = (viewport.x - content_width) * 0.5
	var content_right = content_left + content_width
	var category_width = minf(540.0, maxf(300.0, viewport.x - 40.0))
	var category_left = (viewport.x - category_width) * 0.5
	var category_top = viewport.y * 0.5083
	category_row.position = Vector2(category_left, category_top)
	category_row.size = Vector2(category_width, 35.0)
	var games_top = viewport.y * 0.6
	var games_bottom = maxf(games_top + 120.0, viewport.y - 52.0)
	games_scroll.position = Vector2(content_left, games_top)
	games_scroll.size = Vector2(content_width, games_bottom - games_top)
	var wizard_title_top = category_top + 23.0
	wizard_title.position = Vector2(content_left + 6.0, wizard_title_top)
	wizard_title.size = Vector2(content_width, 26.0)
	breadcrumb.position = Vector2(content_left + 6.0, wizard_title_top + 30.0)
	breadcrumb.size = Vector2(content_width, 20.0)
	wizard_extra.position = Vector2(content_left + 6.0, wizard_title_top + 54.0)
	wizard_extra.size = Vector2(content_width, 20.0)
	var wizard_top = wizard_title_top + 82.0
	var wizard_bottom = maxf(wizard_top + 120.0, viewport.y - 38.0)
	wizard_scroll.position = Vector2(content_left, wizard_top)
	wizard_scroll.size = Vector2(content_width, wizard_bottom - wizard_top)
	hint_bar.position = Vector2(content_left, viewport.y - 34.0)
	hint_bar.size = Vector2(content_width, 24.0)
	settings_title.position = Vector2(content_left + 6.0, category_top + 45.0)
	settings_title.size = Vector2(content_width, 26.0)
	settings_label.position = Vector2(content_left + 26.0, category_top + 81.0)
	settings_label.size = Vector2(content_width - 52.0, 64.0)
	scale_container.position = Vector2(content_left + 26.0, category_top + 145.0)
	scale_container.size = Vector2(content_width - 52.0, 40.0)


# ── Input ──────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if wizard.handle_input(event):
		accept_event(); return
	if event.is_action_pressed("ui_select"):
		if not wizard.active:
			_open_selected_game_settings()
			accept_event(); return
	if event.is_action_pressed("tab_prev"):
		if not wizard.active: _switch_tab(wrapi(current_tab - 1, 0, 3))
		accept_event(); return
	if event.is_action_pressed("tab_next"):
		if not wizard.active: _switch_tab(wrapi(current_tab + 1, 0, 3))
		accept_event(); return
	if current_tab == Tab.SETTINGS and not wizard.active:
		if event.is_action_pressed("ui_accept"):
			scale_slider.grab_focus()
			accept_event(); return
		if event.is_action_pressed("ui_left"):
			scale_slider.value = maxf(scale_slider.min_value, scale_slider.value - scale_slider.step)
			accept_event(); return
		if event.is_action_pressed("ui_right"):
			scale_slider.value = minf(scale_slider.max_value, scale_slider.value + scale_slider.step)
			accept_event(); return
		if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
			accept_event(); return
	if event is InputEventKey and event.echo and (event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		accept_event(); return
	if event.is_action_pressed("ui_up"): nav_axis = -1; nav_first = true; nav_hold_time = 0.0; nav_repeated = false; accept_event(); return
	if event.is_action_pressed("ui_down"): nav_axis = 1; nav_first = true; nav_hold_time = 0.0; nav_repeated = false; accept_event(); return
	if event.is_action_released("ui_up") or event.is_action_released("ui_down"): nav_axis = 0; nav_first = true; nav_repeated = false
	if event.is_action_pressed("ui_accept"):
		if event is InputEventKey and event.echo: return
		_activate_selected(); accept_event(); return


func _move_selection(direction: int) -> void:
	if wizard.move_selection(direction):
		return
	if current_tab != Tab.GAMES: return
	var children = cartridge_list.get_children()
	if children.is_empty(): return
	selected_index = wrapi(selected_index + direction, 0, children.size())
	_refresh_selection()


func _refresh_selection() -> void:
	_refresh_list(cartridge_list.get_children(), selected_index)
func _refresh_list(children: Array, sel: int) -> void:
	if children.is_empty(): return
	if focus_tween and focus_tween.is_valid(): focus_tween.kill()
	focus_tween = create_tween().set_parallel(true).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	for i in children.size():
		var card = children[i]
		var s = card.get_theme_stylebox("panel") as StyleBoxFlat
		if s == null: continue
		if i == sel:
			s.border_color = Color(0.50, 0.70, 0.95, 0.45)
			s.bg_color = Color(1, 1, 1, 0.09)
			focus_tween.tween_property(card, "self_modulate", Color(1, 1, 1, 1), FOCUS_DURATION)
			focus_tween.tween_property(card, "scale", FOCUS_SCALE_FOCUSED, FOCUS_DURATION)
		else:
			s.border_color = Color(1, 1, 1, 0.06)
			s.bg_color = Color(1, 1, 1, 0.04)
			focus_tween.tween_property(card, "self_modulate", Color(1, 1, 1, FOCUS_MODULATE_UNFOCUSED), FOCUS_DURATION)
			focus_tween.tween_property(card, "scale", FOCUS_SCALE_UNFOCUSED, FOCUS_DURATION)
	if sel >= 0 and sel < children.size():
		games_scroll.ensure_control_visible(children[sel])


func _activate_selected() -> void:
	if wizard_active: _wizard_activate(); return
	if current_tab != Tab.GAMES: return
	var children = cartridge_list.get_children()
	if selected_index < 0 or selected_index >= children.size(): return
	var card = children[selected_index]
	var act = card.get_meta("action", "")
	match act:
		"new_cartridge": _open_wizard()
		"launch_game": _launch_game(card.get_meta("cartridge_id", ""))


# ── Game launching ─────────────────────────────────────────────────────────
func _launch_game(cart_id: String) -> void:
	var now_ms = Time.get_ticks_msec()
	if now_ms - last_launch_ms < 1000: return
	last_launch_ms = now_ms
	var data = cartridge_data.get(cart_id, null)
	if data == null: return
	var card_node = data.get("card_node", null)
	if card_node != null:
		card_node.self_modulate = Color(0.6, 0.8, 1.0, 0.5)
		await _delay(0.15)
		card_node.self_modulate = Color(1, 1, 1, 1)
	var mp = "%s:\\%s\\manifest.json" % [data.drive, data.folder]
	if not FileAccess.file_exists(mp): return
	var f = FileAccess.open(mp, FileAccess.READ)
	if f == null: return
	var m = JSON.parse_string(f.get_as_text()); f.close()
	if m == null: return
	var exec_rel = str(m.get("execPath", ""))
	if not WinUtils.is_safe_relative_path(exec_rel):
		print("[%s] LAUNCH: unsafe executable path — %s" % [WinUtils.ts(), exec_rel]); return
	var exe = WinUtils.resolve_cartridge_path(str(data.drive), str(data.folder), exec_rel)
	if not FileAccess.file_exists(exe) and not exec_rel.to_lower().begins_with("data/"):
		exe = WinUtils.resolve_cartridge_path(str(data.drive), str(data.folder), "data/" + exec_rel)
	if exe == "" or not FileAccess.file_exists(exe):
		print("[%s] LAUNCH: exe not found — %s" % [WinUtils.ts(), exe]); return
	var args = PackedStringArray()
	var raw_args = m.get("execArgs", null)
	if raw_args != null and raw_args is Array:
		for a in raw_args: args.append(str(a))
	var root = WinUtils.cartridge_root(str(data.drive), str(data.folder))
	var working_dir = exe.get_base_dir()
	var cwd_rel = str(m.get("cwd", ""))
	if cwd_rel != "":
		if not WinUtils.is_safe_relative_path(cwd_rel):
			print("[%s] LAUNCH: unsafe working directory — %s" % [WinUtils.ts(), cwd_rel]); return
		working_dir = WinUtils.resolve_cartridge_path(str(data.drive), str(data.folder), cwd_rel)
		if working_dir == "" or DirAccess.open(working_dir) == null:
			print("[%s] LAUNCH: working directory not found — %s" % [WinUtils.ts(), working_dir]); return
	print("[%s] LAUNCH: \"%s\"  →  %s  cwd=%s args=%s" % [WinUtils.ts(), m.get("title","?"), exe, working_dir, args])
	var pid = _start_process(exe, args, working_dir)
	print("[%s] LAUNCH: PID = %d" % [WinUtils.ts(), pid])

func _start_process(exe: String, args: PackedStringArray, working_dir: String) -> int:
	var arg_values: Array = []
	for value in args:
		arg_values.append("'" + str(value).replace("'", "''") + "'")
	var command = "$p=Start-Process -FilePath '%s' -WorkingDirectory '%s' -ArgumentList @(%s) -PassThru; $p.Id" % [
		exe.replace("'", "''"), working_dir.replace("'", "''"), ",".join(arg_values)]
	var output: Array = []
	var result = OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command], output)
	if result != 0: return -1
	for line in output:
		var pid = str(line).strip_edges().to_int()
		if pid > 0: return pid
	return -1

# ── Wizard: forwarders ────────────────────────────────────────────────────
func _open_wizard() -> void:
	wizard.open()

func _close_wizard() -> void:
	wizard.close()
	selected_index = 0
	_refresh_selection()

func _prev_step() -> void:
	wizard.prev_step()

func _next_step() -> void:
	wizard.next_step()

func _wizard_activate() -> void:
	wizard.activate()

func _wizard_select_folder() -> void:
	wizard.select_folder()
# ── Glass card ─────────────────────────────────────────────────────────────
func _create_new_cartridge_card() -> void:
	var card = UiKit.make_glass_card("+ New Cartridge", "Create a cartridge from a game folder")
	card.set_meta("action", "new_cartridge")
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT: _open_wizard())
	cartridge_list.add_child(card)

func _delay(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

# ── Daemon ─────────────────────────────────────────────────────────────────
func _start_daemon() -> void:
	var da = _resolve_binary(DAEMON_PATH)
	print("[%s] DAEMON: path = %s" % [WinUtils.ts(), da])
	if not FileAccess.file_exists(da):
		print("[%s] DAEMON: ERROR — daemon.exe not found" % WinUtils.ts())
		return
	if FileAccess.file_exists(events_file_path):
		var d = DirAccess.open("user://")
		if d:
			d.remove("events.log")
			print("[%s] DAEMON: Removed old events.log" % WinUtils.ts())
	events_read = 0
	daemon_pid = OS.create_process(da, PackedStringArray(["--events-file", events_file_path]))
	if daemon_pid > 0:
		print("[%s] DAEMON: Started PID=%d" % [WinUtils.ts(), daemon_pid])
	else:
		print("[%s] DAEMON: ERROR — failed to start process" % WinUtils.ts())

func _resolve_binary(release_path: String) -> String:
	var release = ProjectSettings.globalize_path(release_path)
	if FileAccess.file_exists(release): return release
	var debug_path = release_path.replace("/release/", "/debug/")
	var debug = ProjectSettings.globalize_path(debug_path)
	if FileAccess.file_exists(debug):
		print("[%s] TOOL: using debug binary %s" % [WinUtils.ts(), debug])
		return debug
	return release
func _exit_tree() -> void:
	if wizard.active: wizard.close()
	if daemon_pid > 0: OS.kill(daemon_pid)
func _on_timer_timeout() -> void:
	if not FileAccess.file_exists(events_file_path): return
	var f = FileAccess.open(events_file_path, FileAccess.READ)
	if f == null:
		return
	var lines = f.get_as_text().split("\n", false)
	f.close()
	if lines.size() < events_read:
		events_read = 0
	for i in range(events_read, lines.size()):
		var s = str(lines[i]).strip_edges()
		if s.is_empty():
			continue
		var d = JSON.parse_string(s)
		if d == null:
			break
		events_read = i + 1
		match d.get("type", ""):
			"inserted":
				print("[%s] EVENTS: inserted  \"%s\"  %s:\\%s  id=%s" % [WinUtils.ts(), d.get("title","?"), d.get("drive","?"), d.get("folder","?"), d.get("id","?")])
				_add_cartridge(d)
			"updated":
				_update_cartridge(d)
			"removed":
				print("[%s] EVENTS: removed   id=%s" % [WinUtils.ts(), d.get("id","?")])
				_remove_cartridge(d.get("id", ""))

func _add_cartridge(data: Dictionary) -> void:
	var cid = data.get("id",""); var tt = data.get("title",""); var dr = data.get("drive",""); var fd = data.get("folder","")
	if cartridge_data.has(cid):
		var cn = cartridge_data[cid].get("card_node", null)
		if cn != null and is_instance_valid(cn): cn.self_modulate = Color(1,1,1,1)
		return
	var icon_tex = null
	var m = WinUtils.read_manifest(dr, fd)
	if m.has("iconPath") and str(m["iconPath"]) != "":
		icon_tex = WinUtils.load_texture(WinUtils.resolve_cartridge_path(str(dr), str(fd), str(m["iconPath"])))
	if icon_tex == null and m.has("coverPath") and str(m["coverPath"]) != "":
		icon_tex = WinUtils.load_texture(WinUtils.resolve_cartridge_path(str(dr), str(fd), str(m["coverPath"])))
	var card = UiKit.make_glass_card(tt, "%s:\\%s" % [dr, fd], icon_tex)
	card.set_meta("action","launch_game"); card.set_meta("cartridge_id",cid)
	card.set_meta("manifest", m)
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			selected_index = cartridge_list.get_children().find(card); _refresh_selection(); _launch_game(cid))
	cartridge_list.add_child(card); cartridge_data[cid]={title=tt,drive=dr,folder=fd,card_node=card}
	if cartridge_data.size() == 1: selected_index = cartridge_list.get_children().find(card); _refresh_selection()
	print("[%s] UI: + \"%s\"  (%s:\\%s)  total=%d" % [WinUtils.ts(), tt, dr, fd, cartridge_data.size()])

func _update_cartridge(data: Dictionary) -> void:
	var cid = str(data.get("id", ""))
	if not cartridge_data.has(cid):
		_add_cartridge(data)
		return
	var entry = cartridge_data[cid]
	entry["title"] = data.get("title", entry.get("title", "?"))
	entry["drive"] = data.get("drive", entry.get("drive", "?"))
	entry["folder"] = data.get("folder", entry.get("folder", "?"))
	var card = entry.get("card_node", null)
	if card != null and is_instance_valid(card):
		var title_label = card.get_meta("title_label", null)
		if title_label != null: title_label.text = str(entry["title"])
		var subtitle_label = card.get_meta("subtitle_label", null)
		if subtitle_label != null: subtitle_label.text = "%s:\\%s" % [entry["drive"], entry["folder"]]

func _refresh_cartridge_card(cart_id: String) -> void:
	if not cartridge_data.has(cart_id): return
	var entry = cartridge_data[cart_id]
	var old_card = entry.get("card_node", null)
	var old_index = cartridge_list.get_children().find(old_card)
	var payload = {"id": cart_id, "title": entry.get("title", "Game"),
		"drive": entry.get("drive", ""), "folder": entry.get("folder", "")}
	if old_card != null and is_instance_valid(old_card):
		cartridge_list.remove_child(old_card)
		old_card.queue_free()
	cartridge_data.erase(cart_id)
	_add_cartridge(payload)
	selected_index = clampi(old_index, 0, cartridge_list.get_child_count() - 1)
	_refresh_selection()

func _remove_cartridge(cart_id: String) -> void:
	var e = cartridge_data.get(cart_id, null); if e == null: return
	var title = e.get("title", "?")
	cartridge_data.erase(cart_id)
	var card_node = e.get("card_node", null)
	if card_node != null and is_instance_valid(card_node):
		var tw = create_tween()
		tw.tween_property(card_node, "self_modulate:a", 0.0, 0.25)
		tw.tween_callback(func():
			if is_instance_valid(card_node):
				cartridge_list.remove_child(card_node)
				card_node.queue_free()
			_fix_selection_after_removal())
	else:
		_fix_selection_after_removal()
	print("[%s] UI: - \"%s\"  total=%d" % [WinUtils.ts(), title, cartridge_data.size()])

func _fix_selection_after_removal() -> void:
	var children = cartridge_list.get_children()
	if selected_index >= children.size():
		selected_index = children.size() - 1
	_refresh_selection()

func _open_selected_game_settings() -> void:
	if current_tab != Tab.GAMES: return
	var children = cartridge_list.get_children()
	if selected_index < 0 or selected_index >= children.size(): return
	var card = children[selected_index]
	if card.get_meta("action", "") != "launch_game": return
	_open_game_settings(card.get_meta("cartridge_id", ""))

func _open_game_settings(cart_id: String) -> void:
	wizard.open_game_settings(cart_id)

func _close_game_settings() -> void:
	wizard.close_game_settings()
	selected_index = 0
	_refresh_selection()
