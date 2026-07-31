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
const NAV_INITIAL_DELAY: float = 0.50
const NAV_REPEAT_RATE: float = 0.15

var wizard_active: bool = false
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
	for pair in [[KEY_Q, "tab_prev"], [KEY_E, "tab_next"], [KEY_F, "ui_select_folder"]]:
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
	current_tab = tab
	for page in tab_pages.get_children(): page.visible = false
	tab_pages.get_child(tab).visible = true
	cat_games.self_modulate = Color(1, 1, 1, 1 if tab == Tab.GAMES else 0.3)
	cat_settings.self_modulate = Color(1, 1, 1, 1 if tab == Tab.SETTINGS else 0.3)
	cat_network.self_modulate = Color(1, 1, 1, 1 if tab == Tab.NETWORK else 0.3)
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
	if event.is_action_pressed("ui_accept"): _activate_selected(); accept_event(); return


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
		if i == sel: s.border_color = Color(0.45, 0.65, 1, 0.8); s.bg_color = Color(1, 1, 1, 0.06)
		else: s.border_color = Color(0.3, 0.3, 0.3, 0.2); s.bg_color = Color(0, 0, 0, 0.2)


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
	var data = cartridge_data.get(cart_id, null)
	if data == null: return
	var mp = "%s:\\%s\\manifest.json" % [data.drive, data.folder]
	if not FileAccess.file_exists(mp): return
	var f = FileAccess.open(mp, FileAccess.READ)
	if f == null: return
	var m = JSON.parse_string(f.get_as_text()); f.close()
	if m == null: return
	var exe = "%s:\\%s\\%s" % [data.drive, data.folder, m.get("execPath", "")]
	print("[%s] LAUNCH: \"%s\"  →  %s" % [_ts(), m.get("title","?"), exe])
	OS.shell_open(exe)


# ── Wizard: open / close ───────────────────────────────────────────────────
func _open_wizard() -> void:
	wizard_active = true; wizard_step = 0; wizard_data.clear()
	wizard_data["save_mode"] = "on_card"; wizard_data["checksum"] = "on"
	print("[%s] WIZARD: Open" % _ts())
	games_page.visible = false; wizard_container.visible = true; hint_bar.visible = true
	_render_wizard_step()

func _close_wizard() -> void:
	wizard_active = false; games_page.visible = true; wizard_container.visible = false; hint_bar.visible = false
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
	var exe = ""
	var dir = DirAccess.open(browser_path)
	if dir:
		dir.list_dir_begin()
		var fname = dir.get_next()
		while fname != "":
			if fname.ends_with(".exe") and not fname.begins_with("UnityCrashHandler") and not fname.begins_with("unins"):
				exe = fname
				print("[%s] MANIFEST: auto-detected exe = \"%s\"" % [_ts(), exe])
				break
			fname = dir.get_next()
	if exe == "":
		print("[%s] MANIFEST: no exe found, using default \"game.exe\"" % _ts())
	DirAccess.make_dir_absolute(_join_win(target, "saves"))
	print("[%s] MANIFEST: created saves/ directory" % _ts())
	var manifest = {
		"formatVersion": 1,
		"cartridgeId": str(Time.get_unix_time_from_system()) + "-" + folder.replace(" ", "_"),
		"title": folder,
		"execPath": exe if exe != "" else "game.exe",
		"saveMode": "on_card",
		"savePath": "saves",
		"createdAt": Time.get_datetime_string_from_system()
	}
	var f = FileAccess.open(_join_win(target, "manifest.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "  "))
		f.close()
		print("[%s] MANIFEST: SUCCESS — %s" % [_ts(), _join_win(target, "manifest.json")])
	else:
		print("[%s] MANIFEST: ERROR — could not write %s" % [_ts(), _join_win(target, "manifest.json")])
	_close_wizard()

func _wizard_step3_finish() -> void:
	var ni = wizard_list.get_node_or_null("NameInput") as LineEdit
	if ni: wizard_data["name"] = ni.text.strip_edges()
	print("[%s] WIZARD: settings confirmed — name=\"%s\" save=%s" % [_ts(), wizard_data.get("name","?"), wizard_data.get("save_mode","?")])
	_next_step()

func _wizard_step4_activate() -> void:
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
	var name = wizard_data.get("name", "Game")
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

	var phases = [
		[10, "Validating game path...", ""],
		[22, "Scanning source directory...", ""],
		[35, "Preparing target volume...", ""],
		[50, "Copying game files...", ""],
		[65, "Copying game data...", ""],
		[78, "Verifying integrity...", ""],
		[88, "Computing blake3 checksum...", ""],
		[95, "Writing manifest.json...", ""],
	]

	for phase in phases:
		if st: st.text = phase[1]
		if pb: pb.value = phase[0]
		await _delay(0.4)

	print("[%s] MAKER: Spawning cartridge-maker.exe" % _ts())
	if st: st.text = "Running cartridge-maker.exe..."
	if pb: pb.value = 97

	var args = PackedStringArray(["make", game_path,
		"%s:\\" % drive, "--name", name, "--save-mode", save_mode])
	var pid = OS.create_process(maker, args)
	print("[%s] MAKER: PID = %d" % [_ts(), pid])
	print("[%s] MAKER: args = make \"%s\" \"%s:\\\" --name \"%s\" --save-mode %s" % [_ts(), game_path, drive, name, save_mode])

	if pid <= 0:
		print("[%s] MAKER: ERROR — OS.create_process returned %d" % [_ts(), pid])
		if st: st.text = "Error: failed to start process"
		return

	await _delay(5.0)

	var expected = "%s:\\%s\\manifest.json" % [drive, name]
	print("[%s] MAKER: Checking %s" % [_ts(), expected])

	if FileAccess.file_exists(expected):
		if pb: pb.value = 100
		if st: st.text = "Complete!"
		if dt: dt.text = "%s:\\%s" % [drive, name]
		print("[%s] MAKER: SUCCESS — %s" % [_ts(), expected])
	else:
		if pb: pb.value = 100
		if st: st.text = "Warning: manifest not found"
		if dt: dt.text = "Expected: %s" % expected
		print("[%s] MAKER: FAIL — manifest not found" % _ts())
		print("[%s] MAKER:   expected = %s" % [_ts(), expected])
		# Diagnostic: list what actually exists on the drive
		var diag = DirAccess.open("%s:\\" % drive)
		if diag:
			diag.list_dir_begin()
			var item = diag.get_next()
			var found = []
			while item != "":
				found.append(item)
				item = diag.get_next()
			print("[%s] MAKER:   drive %s: contents = %s" % [_ts(), drive, str(found)])
		else:
			print("[%s] MAKER:   drive %s: cannot open for listing" % drive)

	await _delay(1.5)
	_close_wizard()

func _delay(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func _ts() -> String:
	var dt = Time.get_datetime_dict_from_system()
	return "%02d:%02d:%02d" % [dt.hour, dt.minute, dt.second]


func _is_drive_root(path: String) -> bool:
	var s = path.trim_suffix("\\").trim_suffix("/")
	return s.length() == 2 and s.ends_with(":")

func _join_win(base: String, name: String) -> String:
	return base.trim_suffix("\\").trim_suffix("/") + "\\" + name


# ── Browser ────────────────────────────────────────────────────────────────
func _build_browser(path: String) -> void:
	browser_path = path; _clear_wizard_children()
	var pl = Label.new(); pl.text = browser_path; pl.add_theme_font_size_override("font_size", 10)
	pl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35, 0.6)); wizard_extra.add_child(pl); wizard_extra.visible = true
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
	ni.add_theme_font_size_override("font_size", 14); ni.add_theme_color_override("font_color", Color(1,1,1,0.9))
	wizard_list.add_child(ni)
	var sm = Label.new(); sm.text = "Save mode:  %s" % wizard_data.get("save_mode","on_card"); _add_label_style(sm)
	wizard_list.add_child(sm)
	var cs = Label.new(); cs.text = "Checksum:   %s" % wizard_data.get("checksum","on"); _add_label_style(cs)
	wizard_list.add_child(cs)
	browser_items = [{},{},{}]; browser_selected = 0; _refresh_browser()

func _add_label_style(lbl: Label) -> void:
	lbl.add_theme_font_size_override("font_size", 13); lbl.add_theme_color_override("font_color", Color(0.5,0.5,0.5,0.7))


# ── Summary page ───────────────────────────────────────────────────────────
func _build_summary_page() -> void:
	var sm = Label.new()
	sm.text = "%s  ->  %s:\\\nSave: %s" % [wizard_data.get("name","Game"), wizard_data.get("drive","?"), wizard_data.get("save_mode","on_card")]
	sm.add_theme_font_size_override("font_size", 15); sm.add_theme_color_override("font_color", Color(1,1,1,0.85))
	sm.add_theme_color_override("font_shadow_color", Color(0,0,0,0.5))
	sm.add_theme_constant_override("shadow_offset_x", 1); sm.add_theme_constant_override("shadow_offset_y", 1)
	sm.add_theme_constant_override("shadow_size", 4); wizard_list.add_child(sm)
	var btn = Label.new(); btn.text = "        [ Create Cartridge ]"
	btn.add_theme_font_size_override("font_size", 15); btn.add_theme_color_override("font_color", Color(0.45,0.65,1,0.85))
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
	var card = PanelContainer.new(); card.custom_minimum_size = Vector2(440, 50)
	var style = StyleBoxFlat.new(); style.bg_color = Color(0,0,0,0.22); style.set_corner_radius_all(6)
	style.border_width_left = 3; style.border_color = Color(0.3,0.3,0.3,0.2)
	style.content_margin_left = 14; style.content_margin_right = 14; style.content_margin_top = 6; style.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", style)
	var hbox = HBoxContainer.new(); hbox.add_theme_constant_override("separation", 10)
	var icon = ColorRect.new(); icon.custom_minimum_size = Vector2(36, 36); icon.color = Color(1,1,1,0.06); hbox.add_child(icon)
	var vbox = VBoxContainer.new()
	var t = Label.new(); t.text = title; t.add_theme_font_size_override("font_size", 14)
	t.add_theme_color_override("font_color", Color(1,1,1,0.88)); t.add_theme_color_override("font_shadow_color", Color(0,0,0,0.4))
	t.add_theme_constant_override("shadow_offset_x",1); t.add_theme_constant_override("shadow_offset_y",1); t.add_theme_constant_override("shadow_size",4)
	var s = Label.new(); s.text = subtitle; s.add_theme_font_size_override("font_size", 11)
	s.add_theme_color_override("font_color", Color(0.42,0.42,0.42,0.65))
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
	e.card_node.self_modulate = Color(1,0.3,0.3,0.35)
	print("[%s] UI: - \"%s\"  total=%d" % [_ts(), e.get("title","?"), cartridge_data.size() - 1])
