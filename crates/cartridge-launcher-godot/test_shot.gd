extends SceneTree

var inst: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://main.tscn")
	inst = scene.instantiate()
	root.add_child(inst)
	for i in 20:
		await process_frame
	inst._open_wizard()
	await process_frame
	inst.browser_selected = 0
	inst._wizard_activate()   # copy
	await process_frame
	var kids = inst.wizard_list.get_children()
	for i in kids.size():
		if kids[i].get_meta("folder_name", "") != "":
			inst.browser_selected = i
			break
	inst._wizard_activate()   # enter source folder
	await process_frame
	inst._wizard_select_folder()   # Y — select source
	await process_frame
	kids = inst.wizard_list.get_children()
	for i in kids.size():
		if kids[i].get_meta("folder_name", "") != "":
			inst.browser_selected = i
			break
	inst._wizard_activate()   # enter dest folder
	await process_frame
	inst._wizard_select_folder()   # Y — select dest
	await process_frame
	print("SHOT: on settings step=", inst.wizard_step, " children=", inst.wizard_list.get_child_count())
	await create_timer(35.0).timeout
	quit(0)
