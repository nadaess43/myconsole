class_name WizardFlow
extends RefCounted

const STEP_MODE = 0
const STEP_FOLDER = 1
const STEP_DEST = 2
const STEP_SETTINGS = 3
const STEP_SUMMARY = 4
const STEP_EXE_PICK = 8

signal cartridge_created(ev)

var active: bool = false
var creating: bool = false
var maker_pid: int = -1
var mode: String = ""
var game_settings_id: String = ""
var step: int = 0
var data: Dictionary = {}
var browser_path: String = "C:\\"
var browser_root: String = ""
var browser_show_files: bool = false
var browser_items: Array = []
var browser_selected: int = 0
var settings_editing: LineEdit = null
var settings_editing_original: String = ""

var _owner: Control
const MAKER_PATH = "../../target/release/cartridge-maker.exe"

var _wizard_list: VBoxContainer
var _wizard_scroll: ScrollContainer
var _wizard_title: Label
var _breadcrumb: Label
var _wizard_extra: Control
var _wizard_container: Control
var _hint_bar: Label
var _games_page: Control
var _category_row: Control
var _card_data: Dictionary
var _card_list: VBoxContainer

var _focus_tween: Tween
const FOCUS_SCALE_FOCUSED: Vector2 = Vector2(1.02, 1.02)
const FOCUS_SCALE_UNFOCUSED: Vector2 = Vector2.ONE
const FOCUS_MODULATE_UNFOCUSED: float = 0.55
const FOCUS_DURATION: float = 0.18

func init(owner: Control, card_data: Dictionary, card_list: VBoxContainer,
		wiz_list: VBoxContainer, wiz_scroll: ScrollContainer, wiz_title: Label,
		wiz_bread: Label, wiz_extra: Control, wiz_container: Control,
		hint: Label, games: Control, category: Control) -> void:
	_owner = owner
	_card_data = card_data
	_card_list = card_list
	_wizard_list = wiz_list
	_wizard_scroll = wiz_scroll
	_wizard_title = wiz_title
	_breadcrumb = wiz_bread
	_wizard_extra = wiz_extra
	_wizard_container = wiz_container
	_hint_bar = hint
	_games_page = games
	_category_row = category


func open() -> void:
	active = true; mode = ""; game_settings_id = ""
	step = STEP_MODE; data.clear()
	data["save_mode"] = "on_card"; data["checksum"] = "on"
	browser_path = "C:\\"; browser_root = ""; browser_show_files = false
	print("[%s] WIZARD: Open" % _ts())
	_games_page.visible = false; _wizard_container.visible = true; _hint_bar.visible = true
	_category_row.visible = false
	_render_step()

func close() -> void:
	if creating and maker_pid > 0 and OS.is_process_running(maker_pid):
		OS.kill(maker_pid)
	maker_pid = -1
	active = false; creating = false
	settings_editing = null
	settings_editing_original = ""
	_games_page.visible = true; _wizard_container.visible = false; _hint_bar.visible = false
	_category_row.visible = true
	print("[%s] WIZARD: Close" % _ts())

func prev_step() -> void:
	if step == STEP_EXE_PICK:
		step = STEP_SETTINGS
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_step()
	elif step == STEP_SETTINGS and mode == "existing":
		step = STEP_FOLDER
		browser_path = str(data.get("folder", "C:\\")).get_base_dir()
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_step()
	elif step == STEP_SETTINGS and mode == "copy":
		step = STEP_DEST
		browser_path = str(data.get("dest_browser_path", "C:\\"))
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_step()
	elif step == STEP_DEST:
		step = STEP_FOLDER
		browser_path = str(data.get("source_browser_path", "C:\\"))
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_step()
	elif step >= 1:
		step -= 1
		browser_selected = 0; browser_root = ""; browser_show_files = false
		_render_step()
	else:
		close()

func next_step() -> void:
	var prev = step
	step += 1; browser_selected = 0; browser_items.clear()
	print("[%s] WIZARD: Step %d → %d" % [_ts(), prev, step])
	_render_step()

func activate() -> void:
	match step:
		STEP_MODE: _step0_activate()
		STEP_FOLDER: _folder_activate()
		STEP_DEST: _folder_activate()
		STEP_SETTINGS: _settings_activate()
		STEP_SUMMARY: _summary_activate()
		STEP_EXE_PICK: _exe_pick_activate()

func handle_input(event: InputEvent) -> bool:
	if active and creating:
		return true
	if active and settings_editing != null:
		var k = event as InputEventKey
		if k != null:
			if k.pressed and not k.echo:
				if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
					_exit_edit(true)
					return true
				if k.keycode == KEY_ESCAPE:
					_exit_edit(false)
					return true
				if k.keycode == KEY_UP or k.keycode == KEY_DOWN or k.keycode == KEY_TAB:
					return true
			return false
		var j = event as InputEventJoypadButton
		if j != null:
			if j.pressed and j.button_index == JOY_BUTTON_A:
				_exit_edit(true)
				return true
			if j.pressed and j.button_index == JOY_BUTTON_B:
				_exit_edit(false)
				return true
			return true
		if event is InputEventJoypadMotion:
			return true
		return false
	if active:
		if event.is_action_pressed("ui_cancel"):
			if _is_browser_step() and _browser_can_go_up():
				var prev = browser_path
				browser_path = browser_path.get_base_dir(); _render_step()
				print("[%s] WIZARD: B (back)  %s → %s" % [_ts(), prev, browser_path])
			elif step == STEP_MODE:
				print("[%s] WIZARD: B (cancel wizard)" % _ts())
				close()
			elif mode == "game" and step == STEP_SETTINGS:
				close_game_settings()
			else:
				print("[%s] WIZARD: B (prev step)" % _ts())
				prev_step()
			return true
		if event.is_action_pressed("ui_select_folder"):
			_select_folder_action(); return true
	return false

func move_selection(direction: int) -> bool:
	if not active: return false
	var item_count = _wizard_list.get_child_count()
	if item_count <= 0: return true
	browser_selected = wrapi(browser_selected + direction, 0, item_count)
	_refresh_browser()
	return true

func _is_browser_step() -> bool:
	return step == STEP_FOLDER or step == STEP_DEST or step == STEP_EXE_PICK

func select_folder() -> void:
	_select_folder_action()

func open_game_settings(cart_id: String) -> void:
	if not _card_data.has(cart_id): return
	game_settings_id = cart_id
	var e = _card_data[cart_id]
	active = true; mode = "game"; step = STEP_SETTINGS
	data.clear()
	data["save_mode"] = "on_card"; data["checksum"] = "on"
	var m = WinUtils.read_manifest(str(e.get("drive", "")), str(e.get("folder", "")))
	data["name"] = m.get("title", e.get("title", "Game"))
	data["exec"] = m.get("execPath", "")
	var raw_args = m.get("execArgs", null)
	if raw_args is Array:
		data["args"] = WinUtils.format_args(raw_args)
	elif raw_args != null:
		data["args"] = str(raw_args)
	else:
		data["args"] = ""
	data["cwd"] = m.get("cwd", "")
	data["save_mode"] = str(m.get("saveMode", "on_card"))
	data["existing_icon"] = str(m.get("iconPath", ""))
	data["existing_cover"] = str(m.get("coverPath", ""))
	data["clear_icon"] = false; data["clear_cover"] = false
	browser_path = "C:\\"; browser_root = ""; browser_show_files = false
	print("[%s] SETTINGS: open for %s" % [_ts(), data["name"]])
	_games_page.visible = false; _wizard_container.visible = true; _hint_bar.visible = true
	_category_row.visible = false
	_render_step()

func close_game_settings() -> void:
	game_settings_id = ""
	close()

func render_step() -> void:
	_render_step()

func _render_step() -> void:
	_clear_children(); _wizard_extra.visible = false
	match step:
		STEP_MODE:
			_wizard_title.text = "New Cartridge"
			_breadcrumb.text = "Games > New Cartridge > Select Source"
			_hint_bar.text = "A — Select   B — Cancel"
			for item in [["Copy game from folder...", "Copy files onto the cartridge", "copy"],
						 ["Use folder already on drive", "Turn an existing folder into a cartridge", "existing"]]:
				var card = UiKit.make_glass_card(item[0], item[1]); card.set_meta("wizard_action", item[2])
				_wizard_list.add_child(card)
			browser_items = [{}, {}]; browser_selected = 0; _refresh_browser()
		STEP_FOLDER:
			if mode == "copy":
				_wizard_title.text = "Select game folder to copy"
				_breadcrumb.text = "Games > New Cartridge > Select Source Folder"
			else:
				_wizard_title.text = "Select cartridge folder"
				_breadcrumb.text = "Games > New Cartridge > Select Folder"
			_hint_bar.text = "A — Enter   Y — Select folder   B — Back"
			_build_browser(browser_path)
		STEP_DEST:
			_wizard_title.text = "Select destination folder"
			_breadcrumb.text = "Games > New Cartridge > Select Destination Folder"
			_hint_bar.text = "A — Enter   Y — Select folder   B — Back"
			_build_browser(browser_path)
		STEP_SETTINGS:
			if mode != "game":
				_auto_extract_icon()
			if mode == "game":
				_wizard_title.text = "Game Settings"
				_breadcrumb.text = "Games > Settings"
				_hint_bar.text = "A — Edit field / Select   B — Back"
			else:
				_wizard_title.text = "Cartridge Settings"
				_breadcrumb.text = "Games > New Cartridge > Settings"
				_hint_bar.text = "A — Edit field / Select   B — Back"
			_build_settings_page()
		STEP_SUMMARY:
			_wizard_title.text = "Confirm"
			_breadcrumb.text = "Games > New Cartridge > Confirm"
			_hint_bar.text = "A — Create   B — Back"
			_build_summary_page()
		STEP_EXE_PICK:
			_wizard_title.text = "Select executable"
			_breadcrumb.text = "Games > Select Executable"
			_hint_bar.text = "A — Select file   B — Back"
			_build_browser(browser_path, true)

func _clear_children() -> void:
	for c in _wizard_list.get_children():
		_wizard_list.remove_child(c); c.queue_free()
	for c in _wizard_extra.get_children():
		_wizard_extra.remove_child(c); c.queue_free()

func _refresh_browser() -> void:
	var kids = _wizard_list.get_children()
	if kids.is_empty(): return
	if _focus_tween and _focus_tween.is_valid(): _focus_tween.kill()
	_focus_tween = _owner.create_tween().set_parallel(true).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	for i in kids.size():
		var card = kids[i]
		if card is Control and not card.has_meta("wizard_mouse_bound"):
			card.set_meta("wizard_mouse_bound", true)
			card.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
					browser_selected = _wizard_list.get_children().find(card)
					_refresh_browser()
					activate())
		var s = card.get_theme_stylebox("panel") as StyleBoxFlat
		if s == null: continue
		if i == browser_selected:
			s.border_color = Color(0.50, 0.70, 0.95, 0.45)
			s.bg_color = Color(1, 1, 1, 0.09)
			_focus_tween.tween_property(card, "self_modulate", Color(1, 1, 1, 1), FOCUS_DURATION)
			_focus_tween.tween_property(card, "scale", FOCUS_SCALE_FOCUSED, FOCUS_DURATION)
		else:
			s.border_color = Color(1, 1, 1, 0.06)
			s.bg_color = Color(1, 1, 1, 0.04)
			_focus_tween.tween_property(card, "self_modulate", Color(1, 1, 1, FOCUS_MODULATE_UNFOCUSED), FOCUS_DURATION)
			_focus_tween.tween_property(card, "scale", FOCUS_SCALE_UNFOCUSED, FOCUS_DURATION)
	if _wizard_scroll and browser_selected >= 0 and browser_selected < kids.size():
		_wizard_scroll.ensure_control_visible(kids[browser_selected])

# ── Build browser ──
func _build_browser(path: String, show_files: bool = false) -> void:
	browser_path = path; browser_show_files = show_files; _clear_children()
	var pl = Label.new(); pl.text = browser_path; pl.add_theme_font_size_override("font_size", 13)
	pl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90, 0.85)); _wizard_extra.add_child(pl); _wizard_extra.visible = true
	browser_items.clear()
	if WinUtils.is_drive_root(path):
		for c in range(65, 91):
			var ch = char(c); var dp = "%s:\\" % ch
			if dp == path: continue
			var td = DirAccess.open(dp)
			if td == null: continue
			browser_items.append({"action":"drive","drive":ch})
			var card = UiKit.make_glass_card("%s:\\" % ch, WinUtils.drive_label(dp))
			card.set_meta("switch_drive", ch)
			_wizard_list.add_child(card)
	var dir = DirAccess.open(path)
	var folders := []
	var files := []
	if dir:
		dir.list_dir_begin()
		var dname = dir.get_next()
		while dname != "":
			if not dname.begins_with("."):
				if dir.current_is_dir():
					var full_path = WinUtils.join_win(path, dname)
					if DirAccess.open(full_path) != null:
						folders.append(dname)
				elif show_files and dname.to_lower().ends_with(".exe"):
					files.append(dname)
			dname = dir.get_next()
		folders.sort(); files.sort()
	if show_files:
		browser_items.append({"action":"auto"})
		var acard = UiKit.make_glass_card("(Auto-detect)", "let the tool find the best executable")
		acard.set_meta("pick_file", "")
		_wizard_list.add_child(acard)
	for fname in files:
		var abs: String = WinUtils.join_win(path, str(fname))
		var rel: String = abs
		if browser_root != "" and abs.begins_with(browser_root):
			rel = abs.substr(browser_root.length()).trim_prefix("\\").trim_prefix("/")
		browser_items.append({"action":"file","name":fname})
		var fcard = UiKit.make_glass_card(fname, "executable · %s" % rel.replace("\\", "/"))
		fcard.set_meta("pick_file", rel.replace("\\", "/"))
		_wizard_list.add_child(fcard)
	for fname in folders:
		browser_items.append({"action":"folder","name":fname})
		var card = UiKit.make_glass_card(fname, "")
		card.set_meta("folder_name", fname)
		_wizard_list.add_child(card)
	browser_selected = 0; _refresh_browser()
	if browser_items.is_empty():
		if show_files:
			_hint_bar.text = "B — Back"
			var card = UiKit.make_glass_card("(No executables here)", browser_path)
			_wizard_list.add_child(card)
			browser_items.append({"action":"none"})
		else:
			_hint_bar.text = "Y — Select this folder   B — Back"
			var card = UiKit.make_glass_card("(Select this folder)", browser_path)
			_wizard_list.add_child(card)
			browser_items.append({"action":"folder","name":""})
		browser_selected = 0
		_refresh_browser()

func _browser_can_go_up() -> bool:
	if WinUtils.is_drive_root(browser_path): return false
	if browser_root != "" and browser_path == browser_root: return false
	return true

# ── Step handlers ──
func _step0_activate() -> void:
	var card = _wizard_list.get_children()[browser_selected]
	mode = card.get_meta("wizard_action", "copy")
	data["source"] = mode
	print("[%s] WIZARD: source = %s" % [_ts(), mode])
	next_step()

func _folder_activate() -> void:
	var children = _wizard_list.get_children()
	if children.is_empty(): return
	var switch_drive = children[browser_selected].get_meta("switch_drive", "")
	if switch_drive != "":
		browser_path = "%s:\\" % switch_drive
		print("[%s] WIZARD: switch drive → %s" % [_ts(), browser_path])
		_render_step()
		return
	var fname = children[browser_selected].get_meta("folder_name", "")
	if fname != "":
		browser_path = WinUtils.join_win(browser_path, fname)
		print("[%s] WIZARD: enter folder \"%s\"  →  %s" % [_ts(), fname, browser_path])
		_render_step()
		return
	if not WinUtils.is_drive_root(browser_path):
		_select_folder_action()

func _exe_pick_activate() -> void:
	var children = _wizard_list.get_children()
	if children.is_empty(): return
	var switch_drive = children[browser_selected].get_meta("switch_drive", "")
	if switch_drive != "":
		browser_path = "%s:\\" % switch_drive
		_render_step()
		return
	var fname = children[browser_selected].get_meta("folder_name", "")
	if fname != "":
		browser_path = WinUtils.join_win(browser_path, fname)
		print("[%s] WIZARD: enter folder \"%s\"  →  %s" % [_ts(), fname, browser_path])
		_render_step()
		return
	var fpath: Variant = children[browser_selected].get_meta("pick_file", null)
	if fpath != null:
		_exec_picked(str(fpath))

func _exec_picked(rel: String) -> void:
	if rel == "":
		data.erase("exec")
		print("[%s] WIZARD: executable → (auto-detect)" % _ts())
	else:
		data["exec"] = rel
		print("[%s] WIZARD: executable → \"%s\"" % [_ts(), rel])
	browser_root = ""; browser_show_files = false
	step = STEP_SETTINGS; browser_selected = 0
	_render_step()

func _select_folder_action() -> void:
	if step != STEP_FOLDER and step != STEP_DEST: return
	if step == STEP_FOLDER:
		if WinUtils.is_drive_root(browser_path): return
		if mode == "copy":
			data["game_path"] = browser_path
			data["name"] = browser_path.get_file()
			data["source_browser_path"] = browser_path
			browser_path = "C:\\"
			print("[%s] WIZARD: source folder \"%s\"" % [_ts(), data["game_path"]])
		else:
			data["folder"] = browser_path
			data["game_path"] = browser_path
			data["name"] = browser_path.get_file()
			print("[%s] WIZARD: cartridge folder \"%s\"" % [_ts(), browser_path])
			step = STEP_SETTINGS
			browser_selected = 0
			_render_step()
			return
	else:
		if browser_path.is_empty(): return
		data["dest_path"] = browser_path
		data["dest_browser_path"] = browser_path
		print("[%s] WIZARD: destination folder \"%s\"" % [_ts(), browser_path])
	next_step()

# ── Icon / Cover ────────────────────────────────────────────────────────
func _auto_extract_icon() -> void:
	if data.has("icon") and str(data["icon"]) != "": return
	var exe_path := ""
	if data.has("exec") and str(data["exec"]) != "":
		exe_path = str(data["exec"])
		var gp = str(data.get("game_path", ""))
		if gp != "" and not FileAccess.file_exists(exe_path):
			exe_path = WinUtils.join_win(gp, exe_path)
	else:
		var gp = str(data.get("game_path", ""))
		if gp != "":
			exe_path = WinUtils.find_exe_recursive(gp, 0)
	if exe_path == "" or not FileAccess.file_exists(exe_path): return
	var out = "user://_icon_preview.png"
	if WinUtils.extract_exe_icon(exe_path, out):
		data["_icon_auto"] = out
		print("[%s] WIZARD: auto-extracted icon from \"%s\"" % [_ts(), exe_path.get_file()])

func _pick_file(key: String, filter_pair: Array, title: String) -> void:
	var fd = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.title = title
	fd.add_filter(filter_pair[0], filter_pair[1])
	fd.size = Vector2(600, 450)
	fd.file_selected.connect(func(path: String):
		var selected_path = path
		if key == "icon" and path.to_lower().ends_with(".ico"):
			var converted = "user://custom_icon_%d.png" % Time.get_ticks_msec()
			if not WinUtils.convert_image_to_png(path, converted):
				_hint_bar.text = "ERROR: cannot read icon"
				fd.queue_free()
				return
			selected_path = ProjectSettings.globalize_path(converted)
		data[key] = selected_path
		data["clear_%s" % key] = false
		if key == "icon": data.erase("_icon_auto")
		_render_step()
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	_owner.add_child(fd)
	fd.popup_centered()

func _clear_icon(key: String) -> void:
	data.erase(key)
	if mode == "game":
		data["clear_%s" % key] = true
	else:
		data.erase("clear_%s" % key)
	if key == "icon": data.erase("_icon_auto")
	_render_step()

# ── Manifest / Create ──
func _create_manifest_in_place() -> void:
	var target = str(data.get("folder", browser_path))
	var folder = target.get_file()
	print("[%s] MANIFEST: creating in-place at %s" % [_ts(), target])
	if WinUtils.is_drive_root(target) or DirAccess.open(target) == null:
		_hint_bar.text = "ERROR: choose a cartridge folder"
		return
	var exe := ""
	if data.has("exec") and str(data["exec"]) != "":
		exe = str(data["exec"])
		print("[%s] MANIFEST: using chosen exe = \"%s\"" % [_ts(), exe])
	else:
		exe = WinUtils.find_exe_recursive(target, 0)
		if exe != "":
			print("[%s] MANIFEST: auto-detected exe = \"%s\"" % [_ts(), exe])
	if exe == "" or not WinUtils.is_safe_relative_path(exe) or not FileAccess.file_exists(WinUtils.join_win(target, exe)):
		print("[%s] MANIFEST: ERROR — no valid executable found" % _ts())
		_hint_bar.text = "ERROR: choose a valid executable"
		return
	var save_mode = str(data.get("save_mode", "on_card"))
	if save_mode == "on_card":
		DirAccess.make_dir_recursive_absolute(WinUtils.join_win(target, "saves"))
		print("[%s] MANIFEST: created saves/ directory" % _ts())
	var drive = target.substr(0, 1)
	var relative_folder = target.substr(3)
	var manifest = WinUtils.read_manifest(drive, relative_folder)
	if manifest.is_empty():
		manifest = {"formatVersion": 1, "cartridgeId": WinUtils.uuid_v4(), "platform": "pc",
			"createdAt": WinUtils.now_utc_rfc3339()}
	manifest["title"] = str(data.get("name", folder)).strip_edges()
	if manifest["title"] == "": manifest["title"] = folder
	manifest["execPath"] = exe.replace("\\", "/")
	manifest["saveMode"] = save_mode
	if save_mode == "on_card":
		manifest["savePath"] = "saves"
	else:
		manifest.erase("savePath")
	if not _apply_manifest_asset(target, manifest, "icon", "iconPath", "icon"):
		return
	if not _apply_manifest_asset(target, manifest, "cover", "coverPath", "cover"):
		return
	if not manifest.has("iconPath"):
		var icon_abs = WinUtils.join_win(target, "icon.png")
		if WinUtils.extract_exe_icon(WinUtils.join_win(target, exe), icon_abs):
			manifest["iconPath"] = "icon.png"
	var f = FileAccess.open(WinUtils.join_win(target, "manifest.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "  "))
		f.close()
		print("[%s] MANIFEST: SUCCESS — %s" % [_ts(), WinUtils.join_win(target, "manifest.json")])
		var ev = {"id": manifest["cartridgeId"], "title": manifest["title"],
			"drive": drive, "folder": relative_folder}
		cartridge_created.emit(ev)
	else:
		print("[%s] MANIFEST: ERROR — could not write %s" % [_ts(), WinUtils.join_win(target, "manifest.json")])
	close()

func _apply_manifest_asset(target: String, manifest: Dictionary, data_key: String, manifest_key: String, base_name: String) -> bool:
	var source = str(data.get(data_key, ""))
	if source != "":
		var ext = source.get_extension().to_lower()
		if ext == "": ext = "png"
		var relative = "%s.%s" % [base_name, ext]
		var previous = str(manifest.get(manifest_key, ""))
		if previous != relative and WinUtils.is_safe_relative_path(previous) and previous != "":
			WinUtils.remove_file(WinUtils.join_win(target, previous))
		if not WinUtils.copy_file(source, WinUtils.join_win(target, relative)):
			_hint_bar.text = "ERROR: cannot copy %s" % data_key
			return false
		manifest[manifest_key] = relative
	elif data.get("clear_%s" % data_key, false):
		var old = str(manifest.get(manifest_key, ""))
		if WinUtils.is_safe_relative_path(old) and old != "":
			WinUtils.remove_file(WinUtils.join_win(target, old))
		manifest.erase(manifest_key)
	return true

# ── Settings ──
func _build_settings_page() -> void:
	settings_editing = null
	settings_editing_original = ""
	var game_mode := mode == "game"
	var nl = Label.new(); nl.text = "Name:"; UiKit.add_label_style(nl); _wizard_list.add_child(nl)
	var ni = LineEdit.new(); ni.name = "NameInput"; ni.text = str(data.get("name","My Game"))
	ni.focus_mode = Control.FOCUS_NONE
	ni.add_theme_font_size_override("font_size", 15); ni.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
	ni.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
	ni.add_theme_color_override("selection_color", Color(0.3, 0.55, 0.9, 0.5))
	ni.add_theme_constant_override("margin_left", 8); ni.add_theme_constant_override("margin_right", 8)
	_wizard_list.add_child(ni)
	var exe_display := "(auto-detect)"
	if data.has("exec") and str(data["exec"]) != "":
		exe_display = str(data["exec"])
	var el = Label.new(); el.text = "Executable:  %s" % exe_display; UiKit.add_label_style(el); _wizard_list.add_child(el)
	var ec = UiKit.make_glass_card("Choose executable...", "browse for the game .exe")
	ec.set_meta("pick_exe", true)
	_wizard_list.add_child(ec)

	var ic_s = _asset_display_name("icon")
	var il = Label.new(); il.text = "Icon:  %s" % ic_s; UiKit.add_label_style(il); _wizard_list.add_child(il)
	var ic = UiKit.make_glass_card("Choose Icon...", "select a custom icon image (.png/.jpg/.ico)", WinUtils.load_texture(_asset_preview_path("icon")))
	ic.set_meta("pick_icon", true); _wizard_list.add_child(ic)
	if data.has("icon") and str(data["icon"]) != "":
		var ir = UiKit.make_glass_card("Remove Custom Icon" if game_mode else "↩ Reset Icon", "use automatic extraction" if not game_mode else "delete the cartridge icon")
		ir.set_meta("clear_icon", true); _wizard_list.add_child(ir)
	elif game_mode and str(data.get("existing_icon", "")) != "" and not data.get("clear_icon", false):
		var ir_existing = UiKit.make_glass_card("Remove Icon", "delete the current cartridge icon")
		ir_existing.set_meta("clear_icon", true); _wizard_list.add_child(ir_existing)

	var cv_s = _asset_display_name("cover")
	var cl = Label.new(); cl.text = "Cover:  %s" % cv_s; UiKit.add_label_style(cl); _wizard_list.add_child(cl)
	var cc = UiKit.make_glass_card("Choose Cover...", "select a box-art image (.png/.jpg)", WinUtils.load_texture(_asset_preview_path("cover")))
	cc.set_meta("pick_cover", true); _wizard_list.add_child(cc)
	if data.has("cover") and str(data["cover"]) != "":
		var cr = UiKit.make_glass_card("↩ Reset Cover", "remove custom cover")
		cr.set_meta("clear_cover", true); _wizard_list.add_child(cr)
	elif game_mode and str(data.get("existing_cover", "")) != "" and not data.get("clear_cover", false):
		var cr_existing = UiKit.make_glass_card("Remove Cover", "delete the current cartridge cover")
		cr_existing.set_meta("clear_cover", true); _wizard_list.add_child(cr_existing)

	if game_mode:
		var al = Label.new(); al.text = "Launch arguments:"; UiKit.add_label_style(al); _wizard_list.add_child(al)
		var ai = LineEdit.new(); ai.name = "ArgsInput"; ai.text = str(data.get("args",""))
		ai.focus_mode = Control.FOCUS_NONE
		ai.add_theme_font_size_override("font_size", 14); ai.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
		ai.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
		ai.add_theme_constant_override("margin_left", 8); ai.add_theme_constant_override("margin_right", 8)
		_wizard_list.add_child(ai)
		var wl = Label.new(); wl.text = "Working directory (relative):"; UiKit.add_label_style(wl); _wizard_list.add_child(wl)
		var wi = LineEdit.new(); wi.name = "CwdInput"; wi.text = str(data.get("cwd",""))
		wi.focus_mode = Control.FOCUS_NONE
		wi.add_theme_font_size_override("font_size", 14); wi.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.95))
		wi.add_theme_color_override("caret_color", Color(0.5, 0.7, 0.95, 0.9))
		wi.add_theme_constant_override("margin_left", 8); wi.add_theme_constant_override("margin_right", 8)
		_wizard_list.add_child(wi)
	var sm = UiKit.make_glass_card("Save mode:  %s" % data.get("save_mode","on_card"), "A — toggle on_card / local")
	sm.set_meta("toggle_save", true)
	_wizard_list.add_child(sm)
	var cs = Label.new(); cs.text = "Checksum:   %s" % data.get("checksum","on"); UiKit.add_label_style(cs)
	_wizard_list.add_child(cs)
	var done = UiKit.make_glass_card("Save & Close" if game_mode else "Continue", "apply these settings")
	done.set_meta("confirm_settings", true)
	_wizard_list.add_child(done)
	browser_items = []
	for c in _wizard_list.get_children(): browser_items.append({})
	browser_selected = 1; _refresh_browser()

func _asset_display_name(key: String) -> String:
	var custom = str(data.get(key, ""))
	if custom != "": return custom.get_file()
	if data.get("clear_%s" % key, false): return "(none)"
	var existing = str(data.get("existing_%s" % key, ""))
	if existing != "": return existing.get_file()
	if key == "icon" and data.has("_icon_auto"): return "(auto — from .exe)"
	return "(none)"

func _asset_preview_path(key: String) -> String:
	var custom = str(data.get(key, ""))
	if custom != "": return custom
	if data.get("clear_%s" % key, false): return ""
	var existing = str(data.get("existing_%s" % key, ""))
	if existing != "" and mode == "game":
		var e = _card_data.get(game_settings_id, {})
		return WinUtils.resolve_cartridge_path(str(e.get("drive", "")), str(e.get("folder", "")), existing)
	if key == "icon": return str(data.get("_icon_auto", ""))
	return ""

func _settings_activate() -> void:
	var children = _wizard_list.get_children()
	if browser_selected >= 0 and browser_selected < children.size():
		var sel = children[browser_selected]
		if sel is LineEdit:
			_enter_edit(sel)
			return
		if sel.get_meta("toggle_save", false):
			_capture_settings_text()
			data["save_mode"] = "local" if data.get("save_mode", "on_card") == "on_card" else "on_card"
			print("[%s] WIZARD: save_mode → %s" % [_ts(), data["save_mode"]])
			_render_step()
			return
		if sel.get_meta("pick_exe", false):
			_capture_settings_text()
			_exe_choose()
			return
		if sel.get_meta("pick_icon", false):
			_capture_settings_text()
			_pick_file("icon", ["*.png,*.jpg,*.ico", "Images (*.png, *.jpg, *.ico)"], "Choose Icon")
			return
		if sel.get_meta("clear_icon", false):
			_clear_icon("icon")
			return
		if sel.get_meta("pick_cover", false):
			_capture_settings_text()
			_pick_file("cover", ["*.png,*.jpg", "Images (*.png, *.jpg)"], "Choose Cover")
			return
		if sel.get_meta("clear_cover", false):
			_clear_icon("cover")
			return
		if not sel.get_meta("confirm_settings", false):
			return
	_capture_settings_text()
	print("[%s] WIZARD: settings confirmed — name=\"%s\" save=%s exec=%s" % [_ts(), data.get("name","?"), data.get("save_mode","?"), data.get("exec","(auto)")])
	if mode == "game":
		_save_game_settings()
	else:
		next_step()

func _enter_edit(le: LineEdit) -> void:
	if le == null: return
	settings_editing = le
	settings_editing_original = le.text
	le.focus_mode = Control.FOCUS_ALL
	le.grab_focus()
	le.caret_column = le.text.length()
	print("[%s] WIZARD: editing \"%s\"" % [_ts(), le.name])
	_hint_bar.text = "Type...   A / Enter — done   Esc — cancel"

func _exit_edit(commit: bool = true) -> void:
	if settings_editing == null: return
	var le = settings_editing
	settings_editing = null
	if is_instance_valid(le):
		if not commit:
			le.text = settings_editing_original
		le.focus_mode = Control.FOCUS_NONE
		le.release_focus()
	settings_editing_original = ""
	_capture_settings_text()
	_hint_bar.text = "A — Edit field / Select   B — Back"

func _capture_settings_text() -> void:
	var ni = _wizard_list.get_node_or_null("NameInput") as LineEdit
	if ni: data["name"] = ni.text.strip_edges()
	if mode == "game":
		var ai = _wizard_list.get_node_or_null("ArgsInput") as LineEdit
		if ai: data["args"] = ai.text.strip_edges()
		var wi = _wizard_list.get_node_or_null("CwdInput") as LineEdit
		if wi: data["cwd"] = wi.text.strip_edges()

func _exe_choose() -> void:
	var root := "C:\\"
	if mode == "game":
		var e = _card_data.get(game_settings_id, {})
		root = "%s:\\%s" % [str(e.get("drive", "")), str(e.get("folder", ""))]
	elif mode == "existing":
		root = str(data.get("folder", root))
	else:
		root = str(data.get("game_path", root))
	browser_root = root
	browser_path = root
	browser_show_files = false
	step = STEP_EXE_PICK; browser_selected = 0
	print("[%s] WIZARD: exe browser root = %s" % [_ts(), root])
	_render_step()

func _save_game_settings() -> void:
	var e = _card_data.get(game_settings_id, {})
	var drive = str(e.get("drive", "")); var folder = str(e.get("folder", ""))
	if drive == "" or folder == "":
		print("[%s] SETTINGS: ERROR — no drive/folder for %s" % [_ts(), game_settings_id])
		return
	var root = WinUtils.cartridge_root(drive, folder)
	var mp = WinUtils.join_win(root, "manifest.json")
	var m = WinUtils.read_manifest(drive, folder)
	if m.is_empty():
		m = {"formatVersion": 1, "cartridgeId": game_settings_id,
			"createdAt": WinUtils.now_utc_rfc3339(), "platform": "pc"}
	var title = str(data.get("name", "")).strip_edges()
	if title != "": m["title"] = title
	elif not m.has("title"): m["title"] = str(e.get("title", "Game"))
	var exec_rel = str(data.get("exec", ""))
	if exec_rel == "": exec_rel = WinUtils.find_exe_recursive(root, 0)
	if exec_rel != "":
		if not WinUtils.is_safe_relative_path(exec_rel) or not FileAccess.file_exists(WinUtils.join_win(root, exec_rel)):
			_hint_bar.text = "ERROR: executable path is invalid"
			return
		m["execPath"] = exec_rel.replace("\\", "/")
	if not m.has("execPath") or str(m["execPath"]) == "":
		_hint_bar.text = "ERROR: choose an executable"
		return
	var args_t = str(data.get("args", ""))
	if args_t == "":
		m.erase("execArgs")
	else:
		m["execArgs"] = WinUtils.parse_args(args_t)
	var cwd_t = str(data.get("cwd", ""))
	if cwd_t == "":
		m.erase("cwd")
	elif WinUtils.is_safe_relative_path(cwd_t):
		m["cwd"] = cwd_t
	else:
		_hint_bar.text = "ERROR: working directory must be relative"
		return
	m["saveMode"] = str(data.get("save_mode", "on_card"))
	if m["saveMode"] == "on_card":
		DirAccess.make_dir_recursive_absolute(WinUtils.join_win(root, "saves"))
		m["savePath"] = "saves"
	else:
		m.erase("savePath")
	if not _apply_manifest_asset(root, m, "icon", "iconPath", "icon"): return
	if not _apply_manifest_asset(root, m, "cover", "coverPath", "cover"): return
	var f = FileAccess.open(mp, FileAccess.WRITE)
	if f == null:
		print("[%s] SETTINGS: ERROR — cannot write %s (card read-only?)" % [_ts(), mp])
		_hint_bar.text = "ERROR: cannot write manifest — card read-only?"
		return
	f.store_string(JSON.stringify(m, "  ")); f.close()
	print("[%s] SETTINGS: saved → %s" % [_ts(), mp])
	if _card_data.has(game_settings_id):
		var cd = _card_data[game_settings_id]
		cd["title"] = m["title"]
		var card_node = cd.get("card_node", null)
		if card_node != null and is_instance_valid(card_node):
			var tl = card_node.get_meta("title_label", null)
			if tl != null: tl.text = m["title"]
	_owner._refresh_cartridge_card(game_settings_id)
	_owner._close_game_settings()

# ── Summary ──
func _build_summary_page() -> void:
	var dest := "?"
	var verb := "Create Cartridge"
	if mode == "copy":
		dest = str(data.get("dest_path", "?"))
	else:
		dest = str(data.get("folder", "?"))
		verb = "Write Manifest"
	var exe_line := "auto-detect"
	if data.has("exec") and str(data["exec"]) != "":
		exe_line = str(data["exec"])
	var sm = Label.new()
	sm.text = "%s\n→ %s\nSave: %s\nExec: %s" % [data.get("name","Game"), dest, data.get("save_mode","on_card"), exe_line]
	sm.add_theme_font_size_override("font_size", 15); sm.add_theme_color_override("font_color", Color(0.90, 0.92, 0.95, 0.85))
	sm.add_theme_color_override("font_shadow_color", Color(0,0,0,0.3))
	sm.add_theme_constant_override("shadow_offset_x", 1); sm.add_theme_constant_override("shadow_offset_y", 1)
	sm.add_theme_constant_override("shadow_size", 2); _wizard_list.add_child(sm)

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
	_wizard_list.add_child(btn)
	browser_items = [{},{}]; browser_selected = 1; _refresh_browser()

func _summary_activate() -> void:
	if mode == "copy":
		_do_create()
	else:
		_create_manifest_in_place()

func _delay(sec: float) -> void:
	await _owner.get_tree().create_timer(sec).timeout

func _ts() -> String:
	return WinUtils.ts()

# ── Maker subprocess ──
func _do_create() -> void:
	if creating: return
	creating = true
	print("[%s] WIZARD: Step SUMMARY — Creating cartridge" % _ts())
	_clear_children()
	_wizard_extra.visible = false
	_wizard_title.text = "Creating Cartridge"
	_breadcrumb.text = "Games > New Cartridge > Creating..."
	_hint_bar.text = ""

	var title = Label.new()
	title.text = "Creating Cartridge"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wizard_list.add_child(title)

	var sp1 = Control.new(); sp1.custom_minimum_size = Vector2(0, 16); _wizard_list.add_child(sp1)

	var pb = ProgressBar.new(); pb.name = "ProgBar"
	pb.custom_minimum_size = Vector2(400, 22)
	pb.value = 0
	_wizard_list.add_child(pb)

	var sp2 = Control.new(); sp2.custom_minimum_size = Vector2(0, 12); _wizard_list.add_child(sp2)

	var st = Label.new(); st.name = "StatusLabel"
	st.text = "Preparing..."
	st.add_theme_font_size_override("font_size", 12)
	st.add_theme_color_override("font_color", Color(0.5, 0.7, 1, 0.85))
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wizard_list.add_child(st)

	var dt = Label.new(); dt.name = "DetailLabel"
	dt.text = ""
	dt.add_theme_font_size_override("font_size", 11)
	dt.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4, 0.7))
	dt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wizard_list.add_child(dt)

	_run_maker()

func _run_maker() -> void:
	var maker = _owner._resolve_binary(MAKER_PATH)
	var pb = _wizard_list.get_node_or_null("ProgBar") as ProgressBar
	var st = _wizard_list.get_node_or_null("StatusLabel") as Label
	var dt = _wizard_list.get_node_or_null("DetailLabel") as Label

	var game_path = data.get("game_path", "")
	var dest_path = str(data.get("dest_path", ""))
	var cart_name = WinUtils.sanitize_folder_name(str(data.get("name", "Game")))
	data["name"] = cart_name
	var save_mode = data.get("save_mode", "on_card")

	print("[%s] MAKER: maker.exe = %s" % [_ts(), maker])

	if not FileAccess.file_exists(maker):
		print("[%s] MAKER: ERROR — cartridge-maker.exe NOT FOUND" % _ts())
		if st: st.text = "Error: cartridge-maker.exe not found"
		if dt: dt.text = maker
		creating = false
		return
	if game_path == "":
		print("[%s] MAKER: ERROR — game_path is empty" % _ts())
		if st: st.text = "Error: no source path"
		creating = false
		return
	if dest_path == "":
		print("[%s] MAKER: ERROR — dest_path is empty" % _ts())
		if st: st.text = "Error: no destination path"
		creating = false
		return

	var args = PackedStringArray([
		"make",
		game_path,
		dest_path,
		"--name", cart_name,
		"--save-mode", save_mode,
		"--non-interactive"
	])
	if data.has("exec") and str(data["exec"]) != "":
		args.append("--exec")
		args.append(str(data["exec"]))
	if data.has("icon") and str(data["icon"]) != "":
		args.append("--icon")
		args.append(ProjectSettings.globalize_path(str(data["icon"])))
	if data.has("cover") and str(data["cover"]) != "":
		args.append("--cover")
		args.append(ProjectSettings.globalize_path(str(data["cover"])))
	maker_pid = OS.create_process(maker, args)
	var pid = maker_pid
	print("[%s] MAKER: PID = %d" % [_ts(), pid])

	if pid <= 0:
		print("[%s] MAKER: ERROR — OS.create_process returned %d" % [_ts(), pid])
		if st: st.text = "Error: failed to start maker process"
		maker_pid = -1
		creating = false
		return

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
		maker_pid = -1

	var expected = WinUtils.join_win(dest_path, cart_name) + "\\manifest.json"
	print("[%s] MAKER: Checking %s  (exit_code=%d)" % [_ts(), expected, exit_code])

	if exit_code == 0 and FileAccess.file_exists(expected):
		maker_pid = -1
		creating = false
		if pb: pb.value = 100
		if st: st.text = "Complete!"
		if dt: dt.text = "%s" % WinUtils.join_win(dest_path, cart_name)
		print("[%s] MAKER: SUCCESS — %s" % [_ts(), expected])
		var mf = FileAccess.open(expected, FileAccess.READ)
		if mf:
			var mn = JSON.parse_string(mf.get_as_text()); mf.close()
			if mn != null:
				var ev = {"id": str(mn.get("cartridgeId", "")), "title": str(mn.get("title", cart_name)),
					"drive": dest_path[0], "folder": cart_name}
				cartridge_created.emit(ev)
				print("[%s] MAKER: injected into UI — \"%s\"" % [_ts(), ev.title])
		await _delay(1.5)
		close()
		return

	if pb: pb.value = 100
	var err_msg := ""
	if exit_code == -1:
		err_msg = "Maker timed out (120s)"
	elif exit_code != 0:
		err_msg = "Maker failed (exit code %d)" % exit_code
	else:
		err_msg = "Manifest not found (maker exited OK but no output)"
	print("[%s] MAKER: FAIL — %s" % [_ts(), err_msg])

	if st: st.text = err_msg
	if dt: dt.text = "See console (~ key) for diagnostics"
	creating = false
	maker_pid = -1

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
	close()
