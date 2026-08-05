extends SceneTree

var inst: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://main.tscn")
	inst = scene.instantiate()
	root.add_child(inst)
	for i in 200:
		await process_frame
		if inst.cartridge_data.size() > 0:
			break
	print("T: cartridges=", inst.cartridge_data.size())
	if inst.cartridge_data.size() == 0:
		print("T: no cartridges — abort")
		quit(1)
		return
	var cid = inst.cartridge_data.keys()[0]
	inst._open_game_settings(cid)
	await process_frame
	print("G1 step=", inst.wizard_step, " children=", inst.wizard_list.get_child_count())
	inst.browser_selected = 1
	inst._wizard_activate()   # A on NameInput → edit
	await process_frame
	var le = inst.wizard_list.get_node_or_null("NameInput") as LineEdit
	print("G2 editing=", inst.settings_editing != null, " focused=", le.has_focus())
	var enter = InputEventKey.new(); enter.keycode = KEY_ENTER; enter.pressed = true
	inst._input(enter)
	await process_frame
	print("G3 editing=", inst.settings_editing != null)
	var done_idx := -1
	for i in inst.wizard_list.get_child_count():
		if inst.wizard_list.get_child(i).get_meta("confirm_settings", false):
			done_idx = i
			break
	print("G4 done_idx=", done_idx)
	inst.browser_selected = done_idx
	inst._wizard_activate()   # Save & Close
	await process_frame
	print("G5 active=", inst.wizard_active)
	quit(0)
