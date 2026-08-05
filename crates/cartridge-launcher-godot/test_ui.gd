extends SceneTree

var inst: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://main.tscn")
	inst = scene.instantiate()
	root.add_child(inst)
	for i in 15:
		await process_frame
	print("T: ready, wizard_list ok=", inst.wizard_list != null, " scroll ok=", inst.wizard_scroll != null)

	inst._open_wizard()
	await process_frame
	inst.browser_selected = 0
	inst._wizard_activate()   # copy
	await process_frame
	var kids = inst.wizard_list.get_children()
	var fi := -1
	for i in kids.size():
		if kids[i].get_meta("folder_name", "") != "":
			fi = i
			break
	if fi < 0:
		print("T: no folders — abort")
		quit(1)
		return
	inst.browser_selected = fi
	inst._wizard_activate()   # enter source folder
	await process_frame
	inst._wizard_select_folder()   # Y
	await process_frame
	kids = inst.wizard_list.get_children()
	fi = -1
	for i in kids.size():
		if kids[i].get_meta("folder_name", "") != "":
			fi = i
			break
	inst.browser_selected = fi
	inst._wizard_activate()   # enter dest folder
	await process_frame
	inst._wizard_select_folder()   # Y
	await process_frame
	print("S3 step=", inst.wizard_step, " children=", inst.wizard_list.get_child_count())

	# ── A on NameInput row → enter edit mode ──
	inst.browser_selected = 1
	inst._wizard_activate()
	await process_frame
	var le = inst.wizard_list.get_node_or_null("NameInput") as LineEdit
	print("E1 editing=", inst.settings_editing != null, " focus_mode=", le.focus_mode, " focused=", le.has_focus())

	# ── Up key while editing must NOT move selection ──
	var up = InputEventKey.new(); up.keycode = KEY_UP; up.pressed = true
	inst._input(up)
	await process_frame
	print("E2 sel unchanged=", inst.browser_selected == 1, " editing=", inst.settings_editing != null)

	# ── Enter exits edit mode ──
	var enter = InputEventKey.new(); enter.keycode = KEY_ENTER; enter.pressed = true
	inst._input(enter)
	await process_frame
	print("E3 editing=", inst.settings_editing == null, " focus_mode=", le.focus_mode)

	# ── Navigate to Done button and confirm ──
	var done_idx := -1
	for i in inst.wizard_list.get_child_count():
		if inst.wizard_list.get_child(i).get_meta("confirm_settings", false):
			done_idx = i
			break
	inst.browser_selected = done_idx
	inst._wizard_activate()
	await process_frame
	print("S4 step=", inst.wizard_step, " children=", inst.wizard_list.get_child_count())

	# ── B walk back ──
	inst._prev_step(); await process_frame
	print("B1 step=", inst.wizard_step)
	inst._prev_step(); await process_frame
	print("B2 step=", inst.wizard_step)
	inst._prev_step(); await process_frame
	print("B3 step=", inst.wizard_step)
	inst._prev_step(); await process_frame
	print("B4 step=", inst.wizard_step)
	inst._prev_step(); await process_frame
	print("B5 closed=", not inst.wizard_active)

	# ── Game settings: A on name → edit, A on Done → save+close ──
	if inst.cartridge_data.size() > 0:
		var cid = inst.cartridge_data.keys()[0]
		inst._open_game_settings(cid)
		await process_frame
		print("G1 step=", inst.wizard_step, " children=", inst.wizard_list.get_child_count())
		inst.browser_selected = 1
		inst._wizard_activate()   # enter edit on NameInput
		await process_frame
		print("G2 editing=", inst.settings_editing != null)
		var ai = inst.wizard_list.get_node_or_null("ArgsInput") as LineEdit
		print("G3 args_input exists=", ai != null, " cwd_input exists=", inst.wizard_list.get_node_or_null("CwdInput") != null)
		var enter2 = InputEventKey.new(); enter2.keycode = KEY_ENTER; enter2.pressed = true
		inst._input(enter2)
		await process_frame
		done_idx = -1
		for i in inst.wizard_list.get_child_count():
			if inst.wizard_list.get_child(i).get_meta("confirm_settings", false):
				done_idx = i
				break
		inst.browser_selected = done_idx
		inst._wizard_activate()   # Save & Close
		await process_frame
		print("G4 active=", inst.wizard_active, " step=", inst.wizard_step)

	print("T: DONE")
	quit(0)
