extends Control

const DAEMON_PATH = "../../target/release/cartridge-daemon.exe"
const MAKER_PATH = "../../target/release/cartridge-maker.exe"
const EVENTS_FILE = "res://events.log"
const POLL_INTERVAL = 0.2

var daemon_pid: int = -1
var cartridge_data: Dictionary = {}
var events_file_path: String = ""
var events_read: int = 0
var wave_time: float = 0.0
var fireflies: Array = []
var firefly_time: float = 0.0
var firefly_texture: ImageTexture
@onready var fireflies_node: Node2D = $Fireflies

enum Tab { GAMES, SETTINGS, NETWORK }
var current_tab: int = Tab.GAMES
var selected_index: int = -1
var nav_axis: int = 0
var nav_hold_time: float = 0.0
var nav_first: bool = true
var nav_repeated: bool = false
var last_launch_ms: int = 0

# ── Wizard steps ──
const STEP_MODE = 0
const STEP_FOLDER = 1      # copy: source folder | existing: cartridge folder
const STEP_DEST = 2        # copy only: destination folder
const STEP_SETTINGS = 3
const STEP_SUMMARY = 4
const STEP_EXE_PICK = 8

var wizard_active: bool = false
var wizard_creating: bool = false
var wizard_mode: String = ""      # "copy" | "existing" | "game"
var game_settings_id: String = ""
var wizard_step: int = 0
var wizard_data: Dictionary = {}
var browser_path: String = "C:\\"
var browser_root: String = ""     # root folder of the current exe browser
var browser_show_files: bool = false
var browser_items: Array = []
var browser_selected: int = 0
var settings_editing: LineEdit = null   # LineEdit currently being typed into

# ── Animation state ────────────────────────────────────────────────────────
var focus_tween: Tween
const FOCUS_SCALE_FOCUSED: Vector2 = Vector2(1.04, 1.04)
const FOCUS_SCALE_UNFOCUSED: Vector2 = Vector2(0.97, 0.97)
const FOCUS_MODULATE_UNFOCUSED: float = 0.55
const FOCUS_DURATION: float = 0.18
const NAV_INITIAL_DELAY: float = 0.45
const NAV_REPEAT_RATE: float = 0.13

var tab_tween: Tween
var wave_tween: Tween

@onready var cartridge_list: VBoxContainer = $UIContainer/TabPages/GamesPage/CartridgeList
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


func _ready() -> void:
	print("[%s] INIT: Launcher starting" % _ts())
	_setup_gamepad_actions()
	events_file_path = ProjectSettings.globalize_path(EVENTS_FILE)
	print("[%s] INIT: events.log = %s" % [_ts(), events_file_path])
	_update_clock()
	_create_new_cartridge_card()
	_start_daemon()
	_switch_tab(Tab.GAMES)
	_close_wizard()
	hint_bar.visible = false
	if not $Timer.timeout.is_connected(_on_timer_timeout):
		$Timer.timeout.connect(_on_timer_timeout)
	$Timer.wait_time = POLL_INTERVAL
	$Timer.start()
	_setup_fireflies()
	_move_underline_to(cat_games, false)
	print("[%s] INIT: Ready — polling every %.1fs" % [_ts(), POLL_INTERVAL])


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
	for pair in [[KEY_Q, "tab_prev"], [KEY_E, "tab_next"], [KEY_F, "ui_select_folder"],
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
	_update_fireflies(delta)


func _update_clock() -> void:
	var dt = Time.get_datetime_dict_from_system()
	clock_label.text = "%02d:%02d" % [dt.hour, dt.minute]
	date_label.text = "%d/%d" % [dt.month, dt.day]


# ── Tab switching ──────────────────────────────────────────────────────────
func _switch_tab(tab: int) -> void:
	print("[%s] TAB: → %d" % [_ts(), tab])
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


# ── Input ──────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if wizard_active and settings_editing != null:
		# ── Typing into a settings field — swallow nav keys, let letters pass ──
		var k = event as InputEventKey
		if k != null:
			if k.pressed and not k.echo:
				if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER or k.keycode == KEY_ESCAPE:
					_settings_exit_edit()
					accept_event(); return
				if k.keycode == KEY_UP or k.keycode == KEY_DOWN or k.keycode == KEY_TAB:
					accept_event(); return
			return
		var j = event as InputEventJoypadButton
		if j != null:
			if j.pressed and j.button_index == JOY_BUTTON_A:
				_settings_exit_edit()
				accept_event(); return
			accept_event(); return
		if event is InputEventJoypadMotion:
			accept_event(); return
		accept_event(); return
	if wizard_active:
		if event.is_action_pressed("ui_cancel"):
			if _browser_can_go_up():
				var prev = browser_path
				browser_path = browser_path.get_base_dir(); _render_wizard_step()
				print("[%s] WIZARD: B (back)  %s → %s" % [_ts(), prev, browser_path])
			elif wizard_step == STEP_MODE:
				print("[%s] WIZARD: B (cancel wizard)" % _ts())
				_close_wizard()
			elif wizard_mode == "game" and wizard_step == STEP_SETTINGS:
				_close_game_settings()
			else:
				print("[%s] WIZARD: B (prev step)" % _ts())
				_prev_step()
			accept_event(); return
		if event.is_action_pressed("ui_select_folder"):
			_wizard_select_folder(); accept_event(); return
	if event.is_action_pressed("ui_select"):
		if not wizard_active:
			_open_selected_game_settings()
			accept_event(); return
	if event.is_action_pressed("tab_prev"):
		if not wizard_active: _switch_tab(wrapi(current_tab - 1, 0, 3))
		accept_event(); return
	if event.is_action_pressed("tab_next"):
		if not wizard_active: _switch_tab(wrapi(current_tab + 1, 0, 3))
		accept_event(); return
	if event.is_action_pressed("ui_up"): nav_axis = -1; nav_first = true; nav_hold_time = 0.0; nav_repeated = false; accept_event(); return
	if event.is_action_pressed("ui_down"): nav_axis = 1; nav_first = true; nav_hold_time = 0.0; nav_repeated = false; accept_event(); return
	if event.is_action_released("ui_up") or event.is_action_released("ui_down"): nav_axis = 0; nav_first = true; nav_repeated = false
	if event.is_action_pressed("ui_accept"):
		if event is InputEventKey and event.echo: return
		_activate_selected(); accept_event(); return


func _move_selection(direction: int) -> void:
	if wizard_active:
		browser_selected = wrapi(browser_selected + direction, 0, browser_items.size())
		_refresh_browser(); return
	if current_tab != Tab.GAMES: return
	var children = cartridge_list.get_children()
	if children.is_empty(): return
	selected_index = wrapi(selected_index + direction, 0, children.size())
	_refresh_selection()


func _refresh_selection() -> void:
	_refresh_list(cartridge_list.get_children(), selected_index)
func _refresh_browser() -> void:
	_refresh_list(wizard_list.get_children(), browser_selected)
	var kids = wizard_list.get_children()
	if wizard_scroll and browser_selected >= 0 and browser_selected < kids.size():
		wizard_scroll.ensure_control_visible(kids[browser_selected])
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
	var exec_rel = m.get("execPath", "")
	var exe = "%s:\\%s\\%s" % [data.drive, data.folder, exec_rel]
	if not FileAccess.file_exists(exe):
		exe = "%s:\\%s\\%s" % [data.drive, data.folder, "data/" + exec_rel]
		if not FileAccess.file_exists(exe):
			print("[%s] LAUNCH: exe not found — %s" % [_ts(), exe]); return
	var args = PackedStringArray()
	var raw_args = m.get("execArgs", null)
	if raw_args != null and raw_args is Array:
		for a in raw_args: args.append(str(a))
	print("[%s] LAUNCH: \"%s\"  →  %s  args=%s" % [_ts(), m.get("title","?"), exe, args])
	var pid = OS.create_process(exe, args)
	print("[%s] LAUNCH: PID = %d" % [_ts(), pid])


# ── Wizard: open / close ───────────────────────────────────────────────────
func _open_wizard() -> void:
	wizard_active = true; wizard_mode = ""; game_settings_id = ""
	wizard_step = STEP_MODE; wizard_data.clear()
	wizard_data["save_mode"] = "on_card"; wizard_data["checksum"] = "on"
	browser_path = "C:\\"; browser_root = ""; browser_show_files = false
	print("[%s] WIZARD: Open" % _ts())
	games_page.visible = false; wizard_container.visible = true; hint_bar.visible = true
	_render_wizard_step()

func _close_wizard() -> void:
	wizard_active = false; wizard_creating = false
	settings_editing = null
	games_page.visible = true; wizard_container.visible = false; hint_bar.visible = false
	selected_index = 0; _refresh_selection()
	print("[%s] WIZARD: Close" % _ts())

func _prev_step() -> void:
	if wizard_step == STEP_EXE_PICK:
		# B in the exe browser goes back to the settings page (no step between)
		wizard_step = STEP_SETTINGS
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_wizard_step()
	elif wizard_step >= 1:
		wizard_step -= 1
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_wizard_step()
	else:
		_close_wizard()

func _next_step() -> void:
	var prev = wizard_step
	wizard_step += 1; browser_selected = 0; browser_items.clear()
	print("[%s] WIZARD: Step %d → %d" % [_ts(), prev, wizard_step])
	_render_wizard_step()

func _wizard_activate() -> void:
	match wizard_step:
		STEP_MODE: _wizard_step0_activate()
		STEP_FOLDER: _wizard_folder_activate()
		STEP_DEST: _wizard_folder_activate()
		STEP_SETTINGS: _wizard_settings_activate()
		STEP_SUMMARY: _wizard_summary_activate()
		STEP_EXE_PICK: _wizard_exe_pick_activate()


# ── Wizard: render ─────────────────────────────────────────────────────────
func _render_wizard_step() -> void:
	_clear_wizard_children(); wizard_extra.visible = false
	match wizard_step:
		STEP_MODE:
			wizard_title.text = "New Cartridge"
			breadcrumb.text = "Games > New Cartridge > Select Source"
			hint_bar.text = "A — Select   B — Cancel"
			for item in [["Copy game from folder...", "Copy files onto the cartridge", "copy"],
						 ["Use folder already on drive", "Turn an existing folder into a cartridge", "existing"]]:
				var card = _make_glass_card(item[0], item[1]); card.set_meta("wizard_action", item[2])
				wizard_list.add_child(card)
			browser_items = [{}, {}]; browser_selected = 0; _refresh_browser()
		STEP_FOLDER:
			if wizard_mode == "copy":
				wizard_title.text = "Select game folder to copy"
				breadcrumb.text = "Games > New Cartridge > Select Source Folder"
			else:
				wizard_title.text = "Select cartridge folder"
				breadcrumb.text = "Games > New Cartridge > Select Folder"
			hint_bar.text = "A — Enter   Y — Select folder   B — Back"
			_build_browser(browser_path)
		STEP_DEST:
			wizard_title.text = "Select destination folder"
			breadcrumb.text = "Games > New Cartridge > Select Destination Folder"
			hint_bar.text = "A — Enter   Y — Select folder   B — Back"
			_build_browser(browser_path)
		STEP_SETTINGS:
			if wizard_mode == "game":
				wizard_title.text = "Game Settings"
				breadcrumb.text = "Games > Settings"
				hint_bar.text = "A — Edit field / Select   B — Back"
			else:
				wizard_title.text = "Cartridge Settings"
				breadcrumb.text = "Games > New Cartridge > Settings"
				hint_bar.text = "A — Edit field / Select   B — Back"
			_build_settings_page()
		STEP_SUMMARY:
			wizard_title.text = "Confirm"
			breadcrumb.text = "Games > New Cartridge > Confirm"
			hint_bar.text = "A — Create   B — Back"
			_build_summary_page()
		STEP_EXE_PICK:
			wizard_title.text = "Select executable"
			breadcrumb.text = "Games > Select Executable"
			hint_bar.text = "A — Select file   B — Back"
			_build_browser(browser_path, true)

func _clear_wizard_children() -> void:
	for c in wizard_list.get_children():
		wizard_list.remove_child(c); c.queue_free()
	for c in wizard_extra.get_children():
		wizard_extra.remove_child(c); c.queue_free()


# ── Wizard steps ───────────────────────────────────────────────────────────
func _wizard_step0_activate() -> void:
	var card = wizard_list.get_children()[browser_selected]
	wizard_mode = card.get_meta("wizard_action", "copy")
	wizard_data["source"] = wizard_mode
	print("[%s] WIZARD: source = %s" % [_ts(), wizard_mode])
	_next_step()

func _wizard_folder_activate() -> void:
	var children = wizard_list.get_children()
	if children.is_empty(): return
	var switch_drive = children[browser_selected].get_meta("switch_drive", "")
	if switch_drive != "":
		browser_path = "%s:\\" % switch_drive
		print("[%s] WIZARD: switch drive → %s" % [_ts(), browser_path])
		_render_wizard_step()
		return
	var fname = children[browser_selected].get_meta("folder_name", "")
	if fname != "":
		browser_path = _join_win(browser_path, fname)
		print("[%s] WIZARD: enter folder \"%s\"  →  %s" % [_ts(), fname, browser_path])
		_render_wizard_step()
		return
	# No folder/switch meta — treat as "select this folder" (empty-dir card)
	if not _is_drive_root(browser_path):
		_wizard_select_folder()

func _wizard_exe_pick_activate() -> void:
	var children = wizard_list.get_children()
	if children.is_empty(): return
	var switch_drive = children[browser_selected].get_meta("switch_drive", "")
	if switch_drive != "":
		browser_path = "%s:\\" % switch_drive
		_render_wizard_step()
		return
	var fname = children[browser_selected].get_meta("folder_name", "")
	if fname != "":
		browser_path = _join_win(browser_path, fname)
		print("[%s] WIZARD: enter folder \"%s\"  →  %s" % [_ts(), fname, browser_path])
		_render_wizard_step()
		return
	var fpath: Variant = children[browser_selected].get_meta("pick_file", null)
	if fpath != null:
		_exec_picked(str(fpath))

func _exec_picked(rel: String) -> void:
	if rel == "":
		wizard_data.erase("exec")
		print("[%s] WIZARD: executable → (auto-detect)" % _ts())
	else:
		wizard_data["exec"] = rel
		print("[%s] WIZARD: executable → \"%s\"" % [_ts(), rel])
	browser_root = ""; browser_show_files = false
	wizard_step = STEP_SETTINGS; browser_selected = 0
	_render_wizard_step()

func _wizard_select_folder() -> void:
	if wizard_step == STEP_FOLDER or wizard_step == STEP_DEST:
		if _is_drive_root(browser_path): return
		if wizard_step == STEP_FOLDER:
			if wizard_mode == "copy":
				wizard_data["game_path"] = browser_path
				wizard_data["name"] = browser_path.get_file()
				browser_path = "C:\\"
				print("[%s] WIZARD: source folder \"%s\"" % [_ts(), wizard_data["game_path"]])
			else:
				# existing folder on the drive — turn it into a cartridge right away
				wizard_data["folder"] = browser_path
				wizard_data["name"] = browser_path.get_file()
				print("[%s] WIZARD: cartridge folder \"%s\"" % [_ts(), browser_path])
				_create_manifest_in_place()
				return
		else:
			wizard_data["dest_path"] = browser_path
			print("[%s] WIZARD: destination folder \"%s\"" % [_ts(), browser_path])
		_next_step()

func _create_manifest_in_place() -> void:
	var target = str(wizard_data.get("folder", browser_path))
	var folder = target.get_file()
	print("[%s] MANIFEST: creating in-place at %s" % [_ts(), target])
	var exe := ""
	if wizard_data.has("exec") and str(wizard_data["exec"]) != "":
		exe = str(wizard_data["exec"])
		print("[%s] MANIFEST: using chosen exe = \"%s\"" % [_ts(), exe])
	else:
		exe = _find_exe_recursive(target, 0)
		if exe != "":
			print("[%s] MANIFEST: auto-detected exe = \"%s\"" % [_ts(), exe])
	if exe == "":
		print("[%s] MANIFEST: no exe found, using default \"game.exe\"" % _ts())
	var save_mode = str(wizard_data.get("save_mode", "on_card"))
	if save_mode == "on_card":
		DirAccess.make_dir_absolute(_join_win(target, "saves"))
		print("[%s] MANIFEST: created saves/ directory" % _ts())
	var exe_path = (exe if exe != "" else "game.exe").replace("\\", "/")
	var manifest = {
		"formatVersion": 1,
		"cartridgeId": _uuid_v4(),
		"title": str(wizard_data.get("name", folder)),
		"execPath": exe_path,
		"saveMode": save_mode,
		"createdAt": _now_utc_rfc3339()
	}
	if save_mode == "on_card":
		manifest["savePath"] = "saves"
	var f = FileAccess.open(_join_win(target, "manifest.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "  "))
		f.close()
		print("[%s] MANIFEST: SUCCESS — %s" % [_ts(), _join_win(target, "manifest.json")])
		# Direct UI inject — don't wait for daemon rescan
		var ev = {"id": manifest["cartridgeId"], "title": manifest["title"],
			"drive": target[0], "folder": target.substr(3)}
		_add_cartridge(ev)
	else:
		print("[%s] MANIFEST: ERROR — could not write %s" % [_ts(), _join_win(target, "manifest.json")])
	_close_wizard()

func _wizard_settings_activate() -> void:
	var children = wizard_list.get_children()
	if browser_selected >= 0 and browser_selected < children.size():
		var sel = children[browser_selected]
		if sel is LineEdit:
			_settings_enter_edit(sel)
			return
		if sel.get_meta("toggle_save", false):
			_capture_settings_text()
			wizard_data["save_mode"] = "local" if wizard_data.get("save_mode", "on_card") == "on_card" else "on_card"
			print("[%s] WIZARD: save_mode → %s" % [_ts(), wizard_data["save_mode"]])
			_render_wizard_step()
			return
		if sel.get_meta("pick_exe", false):
			_capture_settings_text()
			_wizard_exe_choose()
			return
		if not sel.get_meta("confirm_settings", false):
			return   # plain label / checksum — no action
	_capture_settings_text()
	print("[%s] WIZARD: settings confirmed — name=\"%s\" save=%s exec=%s" % [_ts(), wizard_data.get("name","?"), wizard_data.get("save_mode","?"), wizard_data.get("exec","(auto)")])
	if wizard_mode == "game":
		_save_game_settings()
	else:
		_next_step()

func _wizard_exe_choose() -> void:
	var root := "C:\\"
	if wizard_mode == "game":
		var e = cartridge_data.get(game_settings_id, {})
		root = "%s:\\%s" % [str(e.get("drive", "")), str(e.get("folder", ""))]
	elif wizard_mode == "existing":
		root = str(wizard_data.get("folder", root))
	else:
		root = str(wizard_data.get("game_path", root))
	browser_root = root
	browser_path = root
	browser_show_files = false
	wizard_step = STEP_EXE_PICK; browser_selected = 0
	print("[%s] WIZARD: exe browser root = %s" % [_ts(), root])
	_render_wizard_step()

func _wizard_summary_activate() -> void:
	if wizard_mode == "copy":
		_wizard_create()
	else:
		_create_manifest_in_place()

func _wizard_create() -> void:
	if wizard_creating: return
	wizard_creating = true
	print("[%s] WIZARD: Step %d — Creating cartridge" % [_ts(), STEP_SUMMARY])
	print("[%s] WIZARD:   source = %s" % [_ts(), wizard_data.get("game_path","?")])
	print("[%s] WIZARD:   dest   = %s" % [_ts(), wizard_data.get("dest_path","?")])
	print("[%s] WIZARD:   name   = %s" % [_ts(), wizard_data.get("name","?")])
	_clear_wizard_children()
	wizard_extra.visible = false
	wizard_title.text = "Creating Cartridge"
	breadcrumb.text = "Games > New Cartridge > Creating..."
	hint_bar.text = ""

	var title = Label.new()
	title.text = "Creating Cartridge"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wizard_list.add_child(title)

	var sp1 = Control.new(); sp1.custom_minimum_size = Vector2(0, 16); wizard_list.add_child(sp1)

	var pb = ProgressBar.new(); pb.name = "ProgBar"
	pb.custom_minimum_size = Vector2(400, 22)
	pb.value = 0
	wizard_list.add_child(pb)

	var sp2 = Control.new(); sp2.custom_minimum_size = Vector2(0, 12); wizard_list.add_child(sp2)

	var st = Label.new(); st.name = "StatusLabel"
	st.text = "Preparing..."
	st.add_theme_font_size_override("font_size", 12)
	st.add_theme_color_override("font_color", Color(0.5, 0.7, 1, 0.85))
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wizard_list.add_child(st)

	var dt = Label.new(); dt.name = "DetailLabel"
	dt.text = ""
	dt.add_theme_font_size_override("font_size", 11)
	dt.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4, 0.7))
	dt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wizard_list.add_child(dt)

	_do_create()

func _do_create() -> void:
	var maker = ProjectSettings.globalize_path(MAKER_PATH)
	var pb = wizard_list.get_node_or_null("ProgBar") as ProgressBar
	var st = wizard_list.get_node_or_null("StatusLabel") as Label
	var dt = wizard_list.get_node_or_null("DetailLabel") as Label

	var game_path = wizard_data.get("game_path", "")
	var dest_path = str(wizard_data.get("dest_path", ""))
	var cart_name = wizard_data.get("name", "Game")
	var save_mode = wizard_data.get("save_mode", "on_card")

	print("[%s] MAKER: maker.exe = %s" % [_ts(), maker])

	if not FileAccess.file_exists(maker):
		print("[%s] MAKER: ERROR — cartridge-maker.exe NOT FOUND" % _ts())
		if st: st.text = "Error: cartridge-maker.exe not found"
		if dt: dt.text = maker
		return
	if game_path == "":
		print("[%s] MAKER: ERROR — game_path is empty" % _ts())
		if st: st.text = "Error: no source path"
		return
	if dest_path == "":
		print("[%s] MAKER: ERROR — dest_path is empty" % _ts())
		if st: st.text = "Error: no destination path"
		return

	# ── Build arguments WITHOUT _q() — Godot's PackedStringArray handles quoting ──
	var args = PackedStringArray([
		"make",
		game_path,
		dest_path,
		"--name", cart_name,
		"--save-mode", save_mode,
		"--non-interactive"
	])
	if wizard_data.has("exec") and str(wizard_data["exec"]) != "":
		args.append("--exec")
		args.append(str(wizard_data["exec"]))
	var pid = OS.create_process(maker, args)
	print("[%s] MAKER: PID = %d" % [_ts(), pid])
	print("[%s] MAKER: args = make \"%s\" \"%s\" --name \"%s\" --save-mode %s --exec \"%s\" --non-interactive" % [_ts(), game_path, dest_path, cart_name, save_mode, wizard_data.get("exec","")])

	if pid <= 0:
		print("[%s] MAKER: ERROR — OS.create_process returned %d" % [_ts(), pid])
		if st: st.text = "Error: failed to start maker process"
		return

	# ── Poll the maker process until it finishes (max 120s) ──
	if st: st.text = "Running cartridge-maker.exe..."
	if pb: pb.value = 0
	var waited := 0.0
	const POLL_STEP := 0.25
	const MAX_WAIT := 120.0

	while waited < MAX_WAIT:
		await _delay(POLL_STEP)
		waited += POLL_STEP
		if pb: pb.value = minf(waited / MAX_WAIT * 100.0, 99.0)
		if st: st.text = "Running... (%.0fs)" % waited
		if not OS.is_process_running(pid):
			break

	var exit_code := -1
	if not OS.is_process_running(pid):
		exit_code = OS.get_process_exit_code(pid)
		print("[%s] MAKER: process exited with code %d after %.1fs" % [_ts(), exit_code, waited])
	else:
		print("[%s] MAKER: process still running after %.1fs — giving up" % [_ts(), waited])
		OS.kill(pid)

	# ── Check result ──
	var expected = _join_win(dest_path, cart_name) + "\\manifest.json"
	print("[%s] MAKER: Checking %s  (exit_code=%d)" % [_ts(), expected, exit_code])

	if exit_code == 0 and FileAccess.file_exists(expected):
		if pb: pb.value = 100
		if st: st.text = "Complete!"
		if dt: dt.text = "%s" % _join_win(dest_path, cart_name)
		print("[%s] MAKER: SUCCESS — %s" % [_ts(), expected])
		# Direct UI inject — read manifest and add to list
		var mf = FileAccess.open(expected, FileAccess.READ)
		if mf:
			var mn = JSON.parse_string(mf.get_as_text()); mf.close()
			if mn != null:
				var ev = {"id": str(mn.get("cartridgeId", "")), "title": str(mn.get("title", cart_name)),
					"drive": dest_path[0], "folder": cart_name}
				_add_cartridge(ev)
				print("[%s] MAKER: injected into UI — \"%s\"" % [_ts(), ev.title])
		await _delay(1.5)
		_close_wizard()
		return

	# ── Failure: show real diagnostics ──
	if pb: pb.value = 100
	var err_msg := ""
	if exit_code == -1:
		err_msg = "Maker timed out (120s)"
	elif exit_code != 0:
		err_msg = "Maker failed (exit code %d)" % exit_code
	else:
		err_msg = "Manifest not found (maker exited OK but no output)"
	print("[%s] MAKER: FAIL — %s" % [_ts(), err_msg])
	print("[%s] MAKER:   expected = %s" % [_ts(), expected])

	if st: st.text = err_msg
	if dt: dt.text = "See console (~ key) for diagnostics"

	# Diagnostic: list destination contents
	var dest_drive = dest_path.substr(0, 1)
	var diag = DirAccess.open("%s:\\" % dest_drive)
	if diag:
		diag.list_dir_begin()
		var item = diag.get_next()
		var found = []
		while item != "":
			found.append(item)
			item = diag.get_next()
		var listing = str(found)
		print("[%s] MAKER:   drive %s: contents = %s" % [_ts(), dest_drive, listing])
		if dt: dt.text = "Drive contents: %s" % listing

	# Also log the game_path structure for debugging
	var game_dir = DirAccess.open(game_path)
	if game_dir:
		game_dir.list_dir_begin()
		var item2 = game_dir.get_next()
		var exe_count := 0
		while item2 != "":
			if item2.to_lower().ends_with(".exe"): exe_count += 1
			item2 = game_dir.get_next()
		print("[%s] MAKER:   source '%s' has %d .exe files" % [_ts(), game_path, exe_count])
		if exe_count == 0:
			if dt: dt.text += " | Source has NO .exe files!"

	await _delay(3.0)
	_close_wizard()

func _delay(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func _ts() -> String:
	var dt = Time.get_datetime_dict_from_system()
	return "%02d:%02d:%02d" % [dt.hour, dt.minute, dt.second]


func _now_utc_rfc3339() -> String:
	var utc = Time.get_datetime_dict_from_unix_time(Time.get_unix_time_from_system(), true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second]


func _is_drive_root(path: String) -> bool:
	var s = path.trim_suffix("\\").trim_suffix("/")
	return s.length() == 2 and s.ends_with(":")

func _join_win(base: String, sub: String) -> String:
	return base.trim_suffix("\\").trim_suffix("/") + "\\" + sub

func _uuid_v4() -> String:
	var b = PackedByteArray(); b.resize(16)
	for i in 16: b[i] = randi() % 256
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
		b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7], b[8],b[9], b[10],b[11], b[12],b[13],b[14],b[15]]

func _find_exe_recursive(base: String, depth: int) -> String:
	if depth > 3: return ""
	var dir = DirAccess.open(base)
	if dir == null: return ""
	dir.list_dir_begin()
	var dname = dir.get_next()
	var folders = []
	while dname != "":
		if dname.begins_with("."): dname = dir.get_next(); continue
		if dir.current_is_dir():
			folders.append(dname)
		elif dname.to_lower().ends_with(".exe") and not dname.to_lower().begins_with("unitycrashhandler") and not dname.to_lower().begins_with("unins"):
			return dname
		dname = dir.get_next()
	for fd in folders:
		var sub = _find_exe_recursive(_join_win(base, fd), depth + 1)
		if sub != "": return fd + "\\" + sub
	return ""


# ── Browser ────────────────────────────────────────────────────────────────
func _build_browser(path: String, show_files: bool = false) -> void:
	browser_path = path; browser_show_files = show_files; _clear_wizard_children()
	var pl = Label.new(); pl.text = browser_path; pl.add_theme_font_size_override("font_size", 13)
	pl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90, 0.85)); wizard_extra.add_child(pl); wizard_extra.visible = true
	browser_items.clear()

	# At drive root: offer switching to any other drive (all modes)
	if _is_drive_root(path):
		for c in range(65, 91):
			var ch = char(c); var dp = "%s:\\" % ch
			if dp == path: continue  # don't show current drive
			var td = DirAccess.open(dp)
			if td == null: continue
			browser_items.append({"action":"drive","drive":ch})
			var card = _make_glass_card("%s:\\" % ch, _drive_label(dp))
			card.set_meta("switch_drive", ch)
			wizard_list.add_child(card)

	var dir = DirAccess.open(path)
	var folders := []
	var files := []
	if dir:
		dir.list_dir_begin()
		var dname = dir.get_next()
		while dname != "":
			if not dname.begins_with("."):
				if dir.current_is_dir():
					var full_path = _join_win(path, dname)
					if DirAccess.open(full_path) != null:
						folders.append(dname)
				elif show_files and dname.to_lower().ends_with(".exe"):
					files.append(dname)
			dname = dir.get_next()
		folders.sort(); files.sort()

	if show_files:
		browser_items.append({"action":"auto"})
		var acard = _make_glass_card("(Auto-detect)", "let the tool find the best executable")
		acard.set_meta("pick_file", "")
		wizard_list.add_child(acard)

	for fname in files:
		var abs: String = _join_win(path, str(fname))
		var rel: String = abs
		if browser_root != "" and abs.begins_with(browser_root):
			rel = abs.substr(browser_root.length()).trim_prefix("\\").trim_prefix("/")
		browser_items.append({"action":"file","name":fname})
		var fcard = _make_glass_card(fname, "executable · %s" % rel.replace("\\", "/"))
		fcard.set_meta("pick_file", rel.replace("\\", "/"))
		wizard_list.add_child(fcard)

	for fname in folders:
		browser_items.append({"action":"folder","name":fname})
		var card = _make_glass_card(fname, "")
		card.set_meta("folder_name", fname)
		wizard_list.add_child(card)

	browser_selected = 0; _refresh_browser()
	if browser_items.is_empty():
		if show_files:
			hint_bar.text = "B — Back"
			var card = _make_glass_card("(No executables here)", browser_path)
			wizard_list.add_child(card)
			browser_items.append({"action":"none"})
		else:
			hint_bar.text = "Y — Select this folder   B — Back"
			var card = _make_glass_card("(Select this folder)", browser_path)
			wizard_list.add_child(card)
			browser_items.append({"action":"folder","name":""})

func _browser_can_go_up() -> bool:
	if _is_drive_root(browser_path): return false
	if browser_root != "" and browser_path == browser_root: return false
	return true

func _drive_label(dp: String) -> String:
	var label := "empty"
	if dp.begins_with("C:"): label = "system"
	var dir = DirAccess.open(dp)
	if dir:
		var cnt := 0
		dir.list_dir_begin()
		var dn = dir.get_next()
		while dn != "":
			if dir.current_is_dir() and FileAccess.file_exists(dp + dn + "/manifest.json"): cnt += 1
			dn = dir.get_next()
		if cnt > 0: label = "%d cartridge%s" % [cnt, "s" if cnt > 1 else ""]
	return label


# ── Settings page ──────────────────────────────────────────────────────────
func _build_settings_page() -> void:
	settings_editing = null
	var game_mode := wizard_mode == "game"
	var nl = Label.new(); nl.text = "Name:"; _add_label_style(nl); wizard_list.add_child(nl)
	var ni = LineEdit.new(); ni.name = "NameInput"; ni.text = str(wizard_data.get("name","My Game"))
	ni.focus_mode = Control.FOCUS_NONE
	ni.add_theme_font_size_override("font_size", 15); ni.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
	ni.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
	ni.add_theme_color_override("selection_color", Color(0.3, 0.55, 0.9, 0.5))
	ni.add_theme_constant_override("margin_left", 8); ni.add_theme_constant_override("margin_right", 8)
	wizard_list.add_child(ni)
	var exe_display := "(auto-detect)"
	if wizard_data.has("exec") and str(wizard_data["exec"]) != "":
		exe_display = str(wizard_data["exec"])
	var el = Label.new(); el.text = "Executable:  %s" % exe_display; _add_label_style(el); wizard_list.add_child(el)
	var ec = _make_glass_card("Choose executable...", "browse for the game .exe")
	ec.set_meta("pick_exe", true)
	wizard_list.add_child(ec)
	if game_mode:
		var al = Label.new(); al.text = "Launch arguments:"; _add_label_style(al); wizard_list.add_child(al)
		var ai = LineEdit.new(); ai.name = "ArgsInput"; ai.text = str(wizard_data.get("args",""))
		ai.focus_mode = Control.FOCUS_NONE
		ai.add_theme_font_size_override("font_size", 14); ai.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
		ai.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
		ai.add_theme_constant_override("margin_left", 8); ai.add_theme_constant_override("margin_right", 8)
		wizard_list.add_child(ai)
		var wl = Label.new(); wl.text = "Working directory (relative):"; _add_label_style(wl); wizard_list.add_child(wl)
		var wi = LineEdit.new(); wi.name = "CwdInput"; wi.text = str(wizard_data.get("cwd",""))
		wi.focus_mode = Control.FOCUS_NONE
		wi.add_theme_font_size_override("font_size", 14); wi.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
		wi.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
		wi.add_theme_constant_override("margin_left", 8); wi.add_theme_constant_override("margin_right", 8)
		wizard_list.add_child(wi)
	var sm = _make_glass_card("Save mode:  %s" % wizard_data.get("save_mode","on_card"), "A — toggle on_card / local")
	sm.set_meta("toggle_save", true)
	wizard_list.add_child(sm)
	var cs = Label.new(); cs.text = "Checksum:   %s" % wizard_data.get("checksum","on"); _add_label_style(cs)
	wizard_list.add_child(cs)
	var done = _make_glass_card("Save & Close" if game_mode else "Continue", "apply these settings")
	done.set_meta("confirm_settings", true)
	wizard_list.add_child(done)
	browser_items = []
	for c in wizard_list.get_children(): browser_items.append({})
	browser_selected = 1; _refresh_browser()

func _settings_enter_edit(le: LineEdit) -> void:
	if le == null: return
	settings_editing = le
	le.focus_mode = Control.FOCUS_ALL
	le.grab_focus()
	le.caret_column = le.text.length()
	print("[%s] WIZARD: editing \"%s\"" % [_ts(), le.name])
	hint_bar.text = "Type...   A / Enter — done   Esc — cancel"

func _settings_exit_edit() -> void:
	if settings_editing == null: return
	var le = settings_editing
	settings_editing = null
	if is_instance_valid(le):
		le.focus_mode = Control.FOCUS_NONE
		le.release_focus()
	_capture_settings_text()
	hint_bar.text = "A — Edit field / Select   B — Back"

func _capture_settings_text() -> void:
	var ni = wizard_list.get_node_or_null("NameInput") as LineEdit
	if ni: wizard_data["name"] = ni.text.strip_edges()
	if wizard_mode == "game":
		var ai = wizard_list.get_node_or_null("ArgsInput") as LineEdit
		if ai: wizard_data["args"] = ai.text.strip_edges()
		var wi = wizard_list.get_node_or_null("CwdInput") as LineEdit
		if wi: wizard_data["cwd"] = wi.text.strip_edges()

func _add_label_style(lbl: Label) -> void:
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90, 0.85))


# ── Summary page ───────────────────────────────────────────────────────────
func _build_summary_page() -> void:
	var dest := "?"
	var verb := "Create Cartridge"
	if wizard_mode == "copy":
		dest = str(wizard_data.get("dest_path", "?"))
	else:
		dest = str(wizard_data.get("folder", "?"))
		verb = "Write Manifest"
	var exe_line := "auto-detect"
	if wizard_data.has("exec") and str(wizard_data["exec"]) != "":
		exe_line = str(wizard_data["exec"])
	var sm = Label.new()
	sm.text = "%s\n→ %s\nSave: %s\nExec: %s" % [wizard_data.get("name","Game"), dest, wizard_data.get("save_mode","on_card"), exe_line]
	sm.add_theme_font_size_override("font_size", 15); sm.add_theme_color_override("font_color", Color(0.90, 0.92, 0.95, 0.85))
	sm.add_theme_color_override("font_shadow_color", Color(0,0,0,0.3))
	sm.add_theme_constant_override("shadow_offset_x", 1); sm.add_theme_constant_override("shadow_offset_y", 1)
	sm.add_theme_constant_override("shadow_size", 2); wizard_list.add_child(sm)
	
	var btn = PanelContainer.new(); btn.custom_minimum_size = Vector2(280, 40)
	var st = StyleBoxFlat.new()
	st.bg_color = Color(0.40, 0.60, 0.85, 0.18)
	st.set_corner_radius_all(6)
	st.border_width_left = 1; st.border_width_right = 1; st.border_width_top = 1; st.border_width_bottom = 1
	st.border_color = Color(0.5, 0.7, 0.95, 0.35)
	st.content_margin_top = 6; st.content_margin_bottom = 6
	btn.add_theme_stylebox_override("panel", st)
	var lbl = Label.new(); lbl.text = verb; lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.90, 0.98, 0.95))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; btn.add_child(lbl)
	wizard_list.add_child(btn)
	browser_items = [{},{}]; browser_selected = 1; _refresh_browser()


# ── Glass card ─────────────────────────────────────────────────────────────
func _create_new_cartridge_card() -> void:
	var card = _make_glass_card("+ New Cartridge", "Create a cartridge from a game folder")
	card.set_meta("action", "new_cartridge")
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT: _open_wizard())
	cartridge_list.add_child(card)

func _make_glass_card(title: String, subtitle: String) -> PanelContainer:
	var card = PanelContainer.new(); card.custom_minimum_size = Vector2(460, 52)
	card.pivot_offset = Vector2(230, 26)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.04)                 # стекло — почти прозрачное
	style.set_corner_radius_all(8)
	style.border_width_left = 1; style.border_width_right = 1
	style.border_width_top = 1; style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.06)               # тонкая светлая рамка
	style.content_margin_left = 16; style.content_margin_right = 16
	style.content_margin_top = 7; style.content_margin_bottom = 7
	card.add_theme_stylebox_override("panel", style)
	var hbox = HBoxContainer.new(); hbox.add_theme_constant_override("separation", 12)
	# Маленький индикатор вместо жирной иконки
	var dot = ColorRect.new(); dot.custom_minimum_size = Vector2(4, 4)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = Color(1, 1, 1, 0.12)
	hbox.add_child(dot)
	var vbox = VBoxContainer.new()
	var t = Label.new(); t.text = title; t.add_theme_font_size_override("font_size", 16)
	t.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99, 1.0))
	var s = Label.new(); s.text = subtitle; s.add_theme_font_size_override("font_size", 12)
	s.add_theme_color_override("font_color", Color(0.66, 0.72, 0.82, 0.85))
	vbox.add_child(t); vbox.add_child(s); hbox.add_child(vbox); card.add_child(hbox)
	card.set_meta("title_label", t)
	return card


# ── Daemon ─────────────────────────────────────────────────────────────────
func _start_daemon() -> void:
	var da = ProjectSettings.globalize_path(DAEMON_PATH)
	print("[%s] DAEMON: path = %s" % [_ts(), da])
	if not FileAccess.file_exists(da):
		print("[%s] DAEMON: ERROR — daemon.exe not found" % _ts())
		return
	if FileAccess.file_exists(events_file_path):
		var d = DirAccess.open("res://")
		if d:
			d.remove("events.log")
			print("[%s] DAEMON: Removed old events.log" % _ts())
	events_read = 0
	daemon_pid = OS.create_process(da, PackedStringArray(["--events-file", events_file_path]))
	if daemon_pid > 0:
		print("[%s] DAEMON: Started PID=%d" % [_ts(), daemon_pid])
	else:
		print("[%s] DAEMON: ERROR — failed to start process" % _ts())
func _exit_tree() -> void:
	if daemon_pid > 0: OS.kill(daemon_pid)
func _on_timer_timeout() -> void:
	if not FileAccess.file_exists(events_file_path): return
	var f = FileAccess.open(events_file_path, FileAccess.READ)
	if f == null:
		return
	var lines = f.get_as_text().split("\n", false)
	f.close()
	# File was recreated (new daemon session) — start over.
	if lines.size() < events_read:
		events_read = 0
	# Process only lines we haven't seen yet. If the daemon is mid-write
	# (partial trailing line), stop and retry next poll — nothing is skipped.
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
				print("[%s] EVENTS: inserted  \"%s\"  %s:\\%s  id=%s" % [_ts(), d.get("title","?"), d.get("drive","?"), d.get("folder","?"), d.get("id","?")])
				_add_cartridge(d)
			"removed":
				print("[%s] EVENTS: removed   id=%s" % [_ts(), d.get("id","?")])
				_remove_cartridge(d.get("id", ""))

func _add_cartridge(data: Dictionary) -> void:
	var cid = data.get("id",""); var tt = data.get("title",""); var dr = data.get("drive",""); var fd = data.get("folder","")
	if cartridge_data.has(cid):
		var cn = cartridge_data[cid].get("card_node", null)
		if cn != null and is_instance_valid(cn): cn.self_modulate = Color(1,1,1,1)
		return
	var card = _make_glass_card(tt, "%s:\\%s" % [dr, fd]); card.set_meta("action","launch_game"); card.set_meta("cartridge_id",cid)
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			selected_index = cartridge_list.get_children().find(card); _refresh_selection(); _launch_game(cid))
	cartridge_list.add_child(card); cartridge_data[cid]={title=tt,drive=dr,folder=fd,card_node=card}
	if cartridge_data.size() == 1: selected_index = cartridge_list.get_children().find(card); _refresh_selection()
	print("[%s] UI: + \"%s\"  (%s:\\%s)  total=%d" % [_ts(), tt, dr, fd, cartridge_data.size()])

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
	print("[%s] UI: - \"%s\"  total=%d" % [_ts(), title, cartridge_data.size()])

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
	if not cartridge_data.has(cart_id): return
	game_settings_id = cart_id
	var e = cartridge_data[cart_id]
	wizard_active = true; wizard_mode = "game"; wizard_step = STEP_SETTINGS
	wizard_data.clear()
	wizard_data["save_mode"] = "on_card"; wizard_data["checksum"] = "on"
	var m = _read_manifest(str(e.get("drive", "")), str(e.get("folder", "")))
	wizard_data["name"] = m.get("title", e.get("title", "Game"))
	wizard_data["exec"] = m.get("execPath", "")
	var raw_args = m.get("execArgs", null)
	if raw_args is Array:
		wizard_data["args"] = " ".join(raw_args)
	elif raw_args != null:
		wizard_data["args"] = str(raw_args)
	else:
		wizard_data["args"] = ""
	wizard_data["cwd"] = m.get("cwd", "")
	wizard_data["save_mode"] = str(m.get("saveMode", "on_card"))
	browser_path = "C:\\"; browser_root = ""; browser_show_files = false
	print("[%s] SETTINGS: open for %s (%s:\\%s)" % [_ts(), wizard_data["name"], e.get("drive",""), e.get("folder","")])
	games_page.visible = false; wizard_container.visible = true; hint_bar.visible = true
	_render_wizard_step()

func _close_game_settings() -> void:
	game_settings_id = ""
	_close_wizard()

func _read_manifest(drive: String, folder: String) -> Dictionary:
	var mp = "%s:\\%s\\manifest.json" % [drive, folder]
	if not FileAccess.file_exists(mp): return {}
	var f = FileAccess.open(mp, FileAccess.READ)
	if f == null: return {}
	var d = JSON.parse_string(f.get_as_text()); f.close()
	if d is not Dictionary: return {}
	# Godot JSON turns every number into a float — the daemon (serde) needs
	# an integer formatVersion, so normalize it back before any round-trip.
	d["formatVersion"] = int(d.get("formatVersion", 1))
	return d

func _save_game_settings() -> void:
	var e = cartridge_data.get(game_settings_id, {})
	var drive = str(e.get("drive", "")); var folder = str(e.get("folder", ""))
	if drive == "" or folder == "":
		print("[%s] SETTINGS: ERROR — no drive/folder for %s" % [_ts(), game_settings_id])
		return
	var mp = "%s:\\%s\\manifest.json" % [drive, folder]
	var m = _read_manifest(drive, folder)
	if m.is_empty():
		m = {"formatVersion": 1, "cartridgeId": game_settings_id,
			"createdAt": _now_utc_rfc3339(), "platform": "pc"}
	if str(wizard_data.get("name", "")) != "":
		m["title"] = str(wizard_data["name"])
	var args_t = str(wizard_data.get("args", ""))
	if args_t == "":
		m.erase("execArgs")
	else:
		m["execArgs"] = [args_t]
	var cwd_t = str(wizard_data.get("cwd", ""))
	if cwd_t == "":
		m.erase("cwd")
	else:
		m["cwd"] = cwd_t
	if wizard_data.has("exec") and str(wizard_data["exec"]) != "":
		m["execPath"] = str(wizard_data["exec"])
	m["saveMode"] = str(wizard_data.get("save_mode", "on_card"))
	if m["saveMode"] == "on_card":
		m["savePath"] = "saves"
	else:
		m.erase("savePath")
	var f = FileAccess.open(mp, FileAccess.WRITE)
	if f == null:
		print("[%s] SETTINGS: ERROR — cannot write %s (card read-only?)" % [_ts(), mp])
		hint_bar.text = "ERROR: cannot write manifest — card read-only?"
		await _delay(2.0)
		_close_game_settings()
		return
	f.store_string(JSON.stringify(m, "  ")); f.close()
	print("[%s] SETTINGS: saved → %s" % [_ts(), mp])
	if cartridge_data.has(game_settings_id):
		var cd = cartridge_data[game_settings_id]
		cd["title"] = m["title"]
		var card_node = cd.get("card_node", null)
		if card_node != null and is_instance_valid(card_node):
			var tl = card_node.get_meta("title_label", null)
			if tl != null: tl.text = m["title"]
	_close_game_settings()

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

func _setup_fireflies() -> void:
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
		fireflies_node.add_child(s)
		fireflies.append({
			"sprite": s,
			"phase": randf_range(0, TAU),
			"speed": randf_range(0.2, 0.55),
			"base_pos": pos,
			"drift_seed": randf_range(0, TAU),
		})

func _update_fireflies(delta: float) -> void:
	firefly_time += delta
	for f in fireflies:
		var t: float = firefly_time * f.speed + f.phase
		var a: float = (sin(t) * 0.5 + 0.5) * 0.35 + 0.05
		f.sprite.modulate.a = a
		f.sprite.position = f.base_pos + Vector2(sin(t * 0.3 + f.drift_seed) * 6.0, cos(t * 0.25) * 4.0)
