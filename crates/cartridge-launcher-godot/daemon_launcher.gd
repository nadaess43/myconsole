extends Control

const DAEMON_PATH = "../../target/release/cartridge-daemon.exe"
const MAKER_PATH = "../../target/release/cartridge-maker.exe"
const EVENTS_FILE = "res://events.log"
const POLL_INTERVAL = 0.2

var daemon_pid: int = -1
var cartridge_data: Dictionary = {}
var events_file_path: String = ""
var last_mtime: int = 0
var wave_time: float = 0.0

enum Tab { GAMES, SETTINGS, NETWORK }
var current_tab: int = Tab.GAMES
var selected_index: int = -1
var nav_axis: int = 0
var nav_hold_time: float = 0.0
var nav_first: bool = true
var last_launch_ms: int = 0
const NAV_INITIAL_DELAY: float = 0.50
const NAV_REPEAT_RATE: float = 0.15

var wizard_active: bool = false
var wizard_creating: bool = false
var wizard_step: int = 0
var wizard_data: Dictionary = {}
var browser_path: String = "C:\\"
var browser_items: Array = []
var browser_selected: int = 0

@onready var cartridge_list: VBoxContainer = $UIContainer/TabPages/GamesPage/CartridgeList
@onready var clock_label: Label = $UIContainer/ClockLabel
@onready var date_label: Label = $UIContainer/DateLabel
@onready var wave_bg: ColorRect = $Background
@onready var cat_games: Label = $UIContainer/CategoryRow/CatGames
@onready var cat_settings: Label = $UIContainer/CategoryRow/CatSettings
@onready var cat_network: Label = $UIContainer/CategoryRow/CatNetwork
@onready var tab_pages: Control = $UIContainer/TabPages
@onready var wizard_container: Control = $UIContainer/WizardContainer
@onready var breadcrumb: Label = $UIContainer/WizardContainer/Breadcrumb
@onready var wizard_list: VBoxContainer = $UIContainer/WizardContainer/WizardList
@onready var wizard_extra: Control = $UIContainer/WizardContainer/WizardExtra
@onready var hint_bar: Label = $UIContainer/HintBar
@onready var games_page: Control = $UIContainer/TabPages/GamesPage


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
			var d = NAV_INITIAL_DELAY if nav_hold_time < 0.05 else NAV_REPEAT_RATE
			if nav_hold_time >= d: _move_selection(nav_axis); nav_hold_time -= d
	if nav_axis != 0 and not Input.is_action_pressed("ui_up") and not Input.is_action_pressed("ui_down"):
		nav_axis = 0; nav_first = true


func _update_clock() -> void:
	var dt = Time.get_datetime_dict_from_system()
	clock_label.text = "%02d:%02d" % [dt.hour, dt.minute]
	date_label.text = "%d/%d" % [dt.month, dt.day]


# ── Tab switching ──────────────────────────────────────────────────────────
func _switch_tab(tab: int) -> void:
	print("[%s] TAB: → %d" % [_ts(), tab])
	current_tab = tab
	for page in tab_pages.get_children(): page.visible = false
	tab_pages.get_child(tab).visible = true
	cat_games.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.GAMES else 0.28)
	cat_settings.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.SETTINGS else 0.28)
	cat_network.self_modulate = Color(1, 1, 1, 1.0 if tab == Tab.NETWORK else 0.28)
	selected_index = -1; _refresh_selection()


# ── Input ──────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if wizard_active:
		if event.is_action_pressed("ui_cancel"):
			# In browser mode (step 2 for both paths): B = go up one folder level
			if wizard_step == 2 and not _is_drive_root(browser_path):
				var prev = browser_path
				browser_path = browser_path.get_base_dir(); _render_wizard_step()
				print("[%s] WIZARD: B (back)  %s → %s" % [_ts(), prev, browser_path])
			elif wizard_step == 0:
				print("[%s] WIZARD: B (cancel wizard)" % _ts())
				_close_wizard()
			else:
				print("[%s] WIZARD: B (prev step)" % _ts())
				_prev_step()
			accept_event(); return
		if event.is_action_pressed("ui_select_folder"):
			_wizard_select_folder(); accept_event(); return
	if event.is_action_pressed("tab_prev"):
		if not wizard_active: _switch_tab(wrapi(current_tab - 1, 0, 3))
		accept_event(); return
	if event.is_action_pressed("tab_next"):
		if not wizard_active: _switch_tab(wrapi(current_tab + 1, 0, 3))
		accept_event(); return
	if event.is_action_pressed("ui_up"): nav_axis = -1; nav_first = true; nav_hold_time = 0.0; accept_event(); return
	if event.is_action_pressed("ui_down"): nav_axis = 1; nav_first = true; nav_hold_time = 0.0; accept_event(); return
	if event.is_action_released("ui_up") or event.is_action_released("ui_down"): nav_axis = 0; nav_first = true
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
func _refresh_list(children: Array, sel: int) -> void:
	for i in children.size():
		var card = children[i]; var s = card.get_theme_stylebox("panel") as StyleBoxFlat
		if s == null: continue
		if i == sel:
			s.border_color = Color(0.50, 0.70, 0.95, 0.45)
			s.bg_color = Color(1, 1, 1, 0.09)
			card.self_modulate = Color(1, 1, 1, 1)
		else:
			s.border_color = Color(1, 1, 1, 0.06)
			s.bg_color = Color(1, 1, 1, 0.04)
			card.self_modulate = Color(1, 1, 1, 0.85)


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
	wizard_active = true; wizard_step = 0; wizard_data.clear()
	wizard_data["save_mode"] = "on_card"; wizard_data["checksum"] = "on"
	print("[%s] WIZARD: Open" % _ts())
	games_page.visible = false; wizard_container.visible = true; hint_bar.visible = true
	_render_wizard_step()

func _close_wizard() -> void:
	wizard_active = false; wizard_creating = false
	games_page.visible = true; wizard_container.visible = false; hint_bar.visible = false
	selected_index = 0; _refresh_selection()
	print("[%s] WIZARD: Close" % _ts())

func _prev_step() -> void:
	if wizard_step >= 1:
		wizard_step -= 1
		browser_selected = 0
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
		0: _wizard_step0_activate()
		1: _wizard_step1_activate()
		2: _wizard_step2_activate()
		3: _wizard_step3_finish()
		4: _wizard_step4_activate()


# ── Wizard: render ─────────────────────────────────────────────────────────
func _render_wizard_step() -> void:
	_clear_wizard_children(); wizard_extra.visible = false
	match wizard_step:
		0:
			breadcrumb.text = "Games > New Cartridge > Select Source"
			hint_bar.text = "A — Select   B — Cancel"
			for item in [["Copy game from folder...", "Copy files onto the cartridge", "copy"],
						 ["Use folder already on drive", "Turn an existing folder into a cartridge", "existing"]]:
				var card = _make_glass_card(item[0], item[1]); card.set_meta("wizard_action", item[2])
				wizard_list.add_child(card)
			browser_items = [{}, {}]; browser_selected = 0; _refresh_browser()
		1:
			# Step 1: always select drive
			breadcrumb.text = "Games > New Cartridge > Select Drive"
			hint_bar.text = "A — Select drive   B — Back"
			_build_drive_list()
		2:
			# Step 2: browser — game folder (copy) or cartridge folder (existing)
			var src = wizard_data.get("source", "copy")
			if src == "copy":
				breadcrumb.text = "Games > New Cartridge > Select Game Folder"
			else:
				breadcrumb.text = "Games > New Cartridge > Select Folder"
			hint_bar.text = "A — Enter   Y — Select folder   B — Back"
			_build_browser(browser_path)
		3:
			breadcrumb.text = "Games > New Cartridge > Settings"
			hint_bar.text = "A — Confirm   B — Back"
			_build_settings_page()
		4:
			breadcrumb.text = "Games > New Cartridge > Confirm"
			hint_bar.text = "A — Create   B — Back"
			_build_summary_page()

func _clear_wizard_children() -> void:
	for c in wizard_list.get_children():
		wizard_list.remove_child(c); c.queue_free()
	for c in wizard_extra.get_children():
		wizard_extra.remove_child(c); c.queue_free()


# ── Wizard steps ───────────────────────────────────────────────────────────
func _wizard_step0_activate() -> void:
	var card = wizard_list.get_children()[browser_selected]
	wizard_data["source"] = card.get_meta("wizard_action", "copy")
	print("[%s] WIZARD: source = %s" % [_ts(), wizard_data["source"]])
	_next_step()

func _wizard_step1_activate() -> void:
	var children = wizard_list.get_children()
	if children.is_empty(): return
	wizard_data["drive"] = children[browser_selected].get_meta("drive_letter", "")
	browser_path = "%s:\\" % wizard_data["drive"]
	print("[%s] WIZARD: drive = %s:" % [_ts(), wizard_data["drive"]])
	_next_step()

func _wizard_step2_activate() -> void:
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

func _wizard_select_folder() -> void:
	if wizard_step != 2: return
	if _is_drive_root(browser_path): return
	print("[%s] WIZARD: select folder \"%s\"" % [_ts(), browser_path])
	if wizard_data.get("source", "") == "existing":
		_create_manifest_in_place()
	else:
		wizard_data["game_path"] = browser_path
		_next_step()

func _create_manifest_in_place() -> void:
	var target = browser_path
	var folder = browser_path.get_file()
	print("[%s] MANIFEST: creating in-place at %s" % [_ts(), target])
	var exe = _find_exe_recursive(browser_path, 0)
	if exe != "":
		print("[%s] MANIFEST: auto-detected exe = \"%s\"" % [_ts(), exe])
	if exe == "":
		print("[%s] MANIFEST: no exe found, using default \"game.exe\"" % _ts())
	DirAccess.make_dir_absolute(_join_win(target, "saves"))
	print("[%s] MANIFEST: created saves/ directory" % _ts())
	var exe_path = (exe if exe != "" else "game.exe").replace("\\", "/")
	var manifest = {
		"formatVersion": 1,
		"cartridgeId": _uuid_v4(),
		"title": folder,
		"execPath": exe_path,
		"saveMode": "on_card",
		"savePath": "saves",
		"createdAt": Time.get_datetime_string_from_system()
	}
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

func _wizard_step3_finish() -> void:
	var ni = wizard_list.get_node_or_null("NameInput") as LineEdit
	if ni: wizard_data["name"] = ni.text.strip_edges()
	print("[%s] WIZARD: settings confirmed — name=\"%s\" save=%s" % [_ts(), wizard_data.get("name","?"), wizard_data.get("save_mode","?")])
	_next_step()

func _wizard_step4_activate() -> void:
	if wizard_creating: return
	wizard_creating = true
	print("[%s] WIZARD: Step 4 — Creating cartridge" % _ts())
	print("[%s] WIZARD:   source = %s" % [_ts(), wizard_data.get("game_path","?")])
	print("[%s] WIZARD:   drive  = %s:" % [_ts(), wizard_data.get("drive","?")])
	print("[%s] WIZARD:   name   = %s" % [_ts(), wizard_data.get("name","?")])
	_clear_wizard_children()
	wizard_extra.visible = false
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
	var drive = wizard_data.get("drive", "C")
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

	# ── Build arguments WITHOUT _q() — Godot's PackedStringArray handles quoting ──
	var args = PackedStringArray([
		"make",
		game_path,
		"%s:\\" % drive,
		"--name", cart_name,
		"--save-mode", save_mode,
		"--non-interactive"
	])
	var pid = OS.create_process(maker, args)
	print("[%s] MAKER: PID = %d" % [_ts(), pid])
	print("[%s] MAKER: args = make \"%s\" \"%s:\\\" --name \"%s\" --save-mode %s --non-interactive" % [_ts(), game_path, drive, cart_name, save_mode])

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
	var expected = "%s:\\%s\\manifest.json" % [drive, cart_name]
	print("[%s] MAKER: Checking %s  (exit_code=%d)" % [_ts(), expected, exit_code])

	if exit_code == 0 and FileAccess.file_exists(expected):
		if pb: pb.value = 100
		if st: st.text = "Complete!"
		if dt: dt.text = "%s:\\%s" % [drive, cart_name]
		print("[%s] MAKER: SUCCESS — %s" % [_ts(), expected])
		# Direct UI inject — read manifest and add to list
		var mf = FileAccess.open(expected, FileAccess.READ)
		if mf:
			var mn = JSON.parse_string(mf.get_as_text()); mf.close()
			if mn != null:
				var ev = {"id": str(mn.get("cartridgeId", "")), "title": str(mn.get("title", cart_name)),
					"drive": drive, "folder": cart_name}
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

	# Diagnostic: list drive contents
	var diag = DirAccess.open("%s:\\" % drive)
	if diag:
		diag.list_dir_begin()
		var item = diag.get_next()
		var found = []
		while item != "":
			found.append(item)
			item = diag.get_next()
		var listing = str(found)
		print("[%s] MAKER:   drive %s: contents = %s" % [_ts(), drive, listing])
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
func _build_browser(path: String) -> void:
	browser_path = path; _clear_wizard_children()
	var pl = Label.new(); pl.text = browser_path; pl.add_theme_font_size_override("font_size", 10)
	pl.add_theme_color_override("font_color", Color(0.45, 0.50, 0.58, 0.55)); wizard_extra.add_child(pl); wizard_extra.visible = true
	browser_items.clear()

	# At drive root: show drives for switching (copy mode). Existing users are on target drive already.
	var is_root = _is_drive_root(path)
	if is_root and wizard_data.get("source", "") == "copy":
		for c in range(65, 91):
			var ch = char(c); var dp = "%s:\\" % ch
			if dp == path: continue  # don't show current drive
			var td = DirAccess.open(dp)
			if td == null: continue
			browser_items.append({"action":"drive","drive":ch})
			var card = _make_glass_card("%s:\\" % ch, "switch to this drive")
			card.set_meta("switch_drive", ch)
			wizard_list.add_child(card)

	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var dname = dir.get_next()
		var folders = []
		while dname != "":
			if dir.current_is_dir() and not dname.begins_with("."):
				var full_path = _join_win(path, dname)
				if DirAccess.open(full_path) != null:
					folders.append(dname)
			dname = dir.get_next()
		folders.sort()
		for fname in folders:
			browser_items.append({"action":"folder","name":fname})
			var card = _make_glass_card(fname, ""); card.set_meta("folder_name", fname)
			wizard_list.add_child(card)
	browser_selected = 0; _refresh_browser()
	if browser_items.is_empty():
		hint_bar.text = "Y — Select this folder   B — Back"
		var card = _make_glass_card("(Select this folder)", browser_path)
		wizard_list.add_child(card)
		browser_items.append({"action":"folder","name":""})


# ── Drive list ─────────────────────────────────────────────────────────────
func _build_drive_list() -> void:
	browser_items.clear()
	for c in range(65, 91):
		var ch = char(c); var dp = "%s:\\" % ch; var dir = DirAccess.open(dp)
		if dir == null: continue
		var label = "empty"
		if dp.begins_with("C:"): label = "system"
		var cnt = 0; dir.list_dir_begin(); var dn = dir.get_next()
		while dn != "":
			if dir.current_is_dir() and FileAccess.file_exists(dp + dn + "/manifest.json"): cnt += 1
			dn = dir.get_next()
		if cnt > 0: label = "%d cartridge%s" % [cnt, "s" if cnt > 1 else ""]
		var card = _make_glass_card("%s:\\" % ch, label); card.set_meta("drive_letter", ch)
		wizard_list.add_child(card); browser_items.append({"drive":ch})
	browser_selected = 0; _refresh_browser()


# ── Settings page ──────────────────────────────────────────────────────────
func _build_settings_page() -> void:
	var nl = Label.new(); nl.text = "Name:"; _add_label_style(nl); wizard_list.add_child(nl)
	var ni = LineEdit.new(); ni.name = "NameInput"; ni.text = wizard_data.get("name","My Game")
	ni.add_theme_font_size_override("font_size", 14); ni.add_theme_color_override("font_color", Color(0.94, 0.95, 0.97, 0.92))
	ni.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.8))
	ni.add_theme_constant_override("margin_left", 8); ni.add_theme_constant_override("margin_right", 8)
	wizard_list.add_child(ni)
	var sm = Label.new(); sm.text = "Save mode:  %s" % wizard_data.get("save_mode","on_card"); _add_label_style(sm)
	wizard_list.add_child(sm)
	var cs = Label.new(); cs.text = "Checksum:   %s" % wizard_data.get("checksum","on"); _add_label_style(cs)
	wizard_list.add_child(cs)
	browser_items = [{},{},{}]; browser_selected = 0; _refresh_browser()

func _add_label_style(lbl: Label) -> void:
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68, 0.65))


# ── Summary page ───────────────────────────────────────────────────────────
func _build_summary_page() -> void:
	var sm = Label.new()
	sm.text = "%s  ->  %s:\\\nSave: %s" % [wizard_data.get("name","Game"), wizard_data.get("drive","?"), wizard_data.get("save_mode","on_card")]
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
	var lbl = Label.new(); lbl.text = "Create Cartridge"; lbl.add_theme_font_size_override("font_size", 15)
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
	var t = Label.new(); t.text = title; t.add_theme_font_size_override("font_size", 15)
	t.add_theme_color_override("font_color", Color(0.94, 0.95, 0.97, 0.92))
	var s = Label.new(); s.text = subtitle; s.add_theme_font_size_override("font_size", 11)
	s.add_theme_color_override("font_color", Color(0.45, 0.50, 0.58, 0.55))
	vbox.add_child(t); vbox.add_child(s); hbox.add_child(vbox); card.add_child(hbox)
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
	daemon_pid = OS.create_process(da, PackedStringArray(["--events-file", events_file_path]))
	if daemon_pid > 0:
		print("[%s] DAEMON: Started PID=%d" % [_ts(), daemon_pid])
	else:
		print("[%s] DAEMON: ERROR — failed to start process" % _ts())
func _exit_tree() -> void:
	if daemon_pid > 0: OS.kill(daemon_pid)
func _on_timer_timeout() -> void:
	if not FileAccess.file_exists(events_file_path): return
	var mt = FileAccess.get_modified_time(events_file_path)
	if mt == last_mtime:
		return
	last_mtime = mt
	print("[%s] EVENTS: Reading events.log" % _ts())
	var f = FileAccess.open(events_file_path, FileAccess.READ)
	if f == null:
		return
	var t = f.get_as_text()
	f.close()
	for raw in t.split("\n", false):
		var s = raw.strip_edges()
		if s.is_empty():
			continue
		var d = JSON.parse_string(s)
		if d == null:
			continue
		match d.get("type", ""):
			"inserted":
				print("[%s] EVENTS: inserted  \"%s\"  %s:\\%s  id=%s" % [_ts(), d.get("title","?"), d.get("drive","?"), d.get("folder","?"), d.get("id","?")])
				_add_cartridge(d)
			"removed":
				print("[%s] EVENTS: removed   id=%s" % [_ts(), d.get("id","?")])
				_remove_cartridge(d.get("id", ""))

func _add_cartridge(data: Dictionary) -> void:
	var cid = data.get("id",""); var tt = data.get("title",""); var dr = data.get("drive",""); var fd = data.get("folder","")
	if cartridge_data.has(cid): cartridge_data[cid].card_node.self_modulate = Color(1,1,1,1); return
	var card = _make_glass_card(tt, "%s:\\%s" % [dr, fd]); card.set_meta("action","launch_game"); card.set_meta("cartridge_id",cid)
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			selected_index = cartridge_list.get_children().find(card); _refresh_selection(); _launch_game(cid))
	cartridge_list.add_child(card); cartridge_data[cid]={title=tt,drive=dr,folder=fd,card_node=card}
	if cartridge_data.size() == 1: selected_index = cartridge_list.get_children().find(card); _refresh_selection()
	print("[%s] UI: + \"%s\"  (%s:\\%s)  total=%d" % [_ts(), tt, dr, fd, cartridge_data.size()])

func _remove_cartridge(cart_id: String) -> void:
	var e = cartridge_data.get(cart_id, null); if e == null: return
	var card_node = e.get("card_node", null)
	if card_node != null:
		cartridge_list.remove_child(card_node)
		card_node.queue_free()
	# Update selected_index if the removed card was before or at the current selection
	var children = cartridge_list.get_children()
	if selected_index >= children.size():
		selected_index = children.size() - 1
	_refresh_selection()
	cartridge_data.erase(cart_id)
	print("[%s] UI: - \"%s\"  total=%d" % [_ts(), e.get("title","?"), cartridge_data.size()])
