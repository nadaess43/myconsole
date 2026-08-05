extends RefCounted
class_name WinUtils

static func ts() -> String:
	var dt = Time.get_datetime_dict_from_system()
	return "%02d:%02d:%02d" % [dt.hour, dt.minute, dt.second]

static func now_utc_rfc3339() -> String:
	var utc = Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second]

static func uuid_v4() -> String:
	var b = PackedByteArray(); b.resize(16)
	for i in 16: b[i] = randi() % 256
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
		b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7], b[8],b[9], b[10],b[11], b[12],b[13],b[14],b[15]]

static func join_win(base: String, sub: String) -> String:
	return base.trim_suffix("\\").trim_suffix("/") + "\\" + sub

static func is_safe_relative_path(path: String) -> bool:
	var normalized = path.replace("\\", "/")
	if normalized.is_empty() or normalized.begins_with("/"):
		return false
	if normalized.length() >= 2 and normalized[1] == ":":
		return false
	for part in normalized.split("/", false):
		if part == "..": return false
	return true

static func cartridge_root(drive: String, folder: String) -> String:
	return "%s:\\%s" % [drive, folder]

static func resolve_cartridge_path(drive: String, folder: String, relative: String) -> String:
	if not is_safe_relative_path(relative): return ""
	return join_win(cartridge_root(drive, folder), relative.replace("/", "\\"))

static func is_drive_root(path: String) -> bool:
	var s = path.trim_suffix("\\").trim_suffix("/")
	return s.length() == 2 and s.ends_with(":")

static func find_exe_recursive(base: String, depth: int) -> String:
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
		var sub = find_exe_recursive(join_win(base, fd), depth + 1)
		if sub != "": return fd + "\\" + sub
	return ""

static func drive_label(dp: String) -> String:
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

static func read_manifest(drive: String, folder: String) -> Dictionary:
	var mp = join_win(cartridge_root(drive, folder), "manifest.json")
	if not FileAccess.file_exists(mp): return {}
	var f = FileAccess.open(mp, FileAccess.READ)
	if f == null: return {}
	var d = JSON.parse_string(f.get_as_text()); f.close()
	if d is not Dictionary: return {}
	d["formatVersion"] = int(d.get("formatVersion", 1))
	return d

static func load_texture(path: String) -> ImageTexture:
	var absolute = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	if not FileAccess.file_exists(absolute): return null
	var img = Image.new()
	var err = img.load(absolute)
	if err != OK and absolute.to_lower().ends_with(".ico"):
		var converted = "user://icon_%d.png" % Time.get_ticks_msec()
		if convert_image_to_png(path, converted):
			err = img.load(converted)
	if err != OK: return null
	return ImageTexture.create_from_image(img)

static func convert_image_to_png(source: String, output_png: String) -> bool:
	var source_path = ProjectSettings.globalize_path(source) if source.begins_with("user://") else source
	var output_path = ProjectSettings.globalize_path(output_png) if output_png.begins_with("user://") else output_png
	var escaped_source = source_path.replace("'", "''")
	var escaped_output = output_path.replace("'", "''")
	var script = (
		"Add-Type -AssemblyName System.Drawing;" +
		"$i=[System.Drawing.Image]::FromFile('%s');" % escaped_source +
		"$i.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png);" % escaped_output +
		"$i.Dispose()"
	)
	var output = []
	return OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], output) == 0

static func copy_file(source: String, destination: String) -> bool:
	var source_path = ProjectSettings.globalize_path(source) if source.begins_with("user://") else source
	var destination_path = ProjectSettings.globalize_path(destination) if destination.begins_with("user://") else destination
	if not FileAccess.file_exists(source_path): return false
	var input = FileAccess.open(source_path, FileAccess.READ)
	if input == null: return false
	var output_dir = destination_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(output_dir)
	var output = FileAccess.open(destination_path, FileAccess.WRITE)
	if output == null:
		input.close()
		return false
	output.store_buffer(input.get_buffer(input.get_length()))
	input.close(); output.close()
	return true

static func remove_file(path: String) -> bool:
	var absolute = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	if not FileAccess.file_exists(absolute): return true
	return DirAccess.remove_absolute(absolute) == OK

static func parse_args(text: String) -> Array:
	var result: Array = []
	var current := ""
	var quote := ""
	for ch in text:
		if quote != "":
			if ch == quote:
				quote = ""
			else:
				current += ch
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == " " or ch == "\t":
			if current != "":
				result.append(current); current = ""
		else:
			current += ch
	if current != "": result.append(current)
	return result

static func format_args(args: Array) -> String:
	var result: Array = []
	for value in args:
		var text = str(value)
		if text.contains(" ") or text.contains("\t") or text.contains("\""):
			result.append("\"" + text.replace("\"", "\\\"") + "\"")
		else:
			result.append(text)
	return " ".join(result)

static func sanitize_folder_name(name: String) -> String:
	var result := name.strip_edges()
	var forbidden = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
	var cleaned := ""
	for ch in result:
		cleaned += "_" if forbidden.has(ch) else ch
	result = cleaned.strip_edges().trim_suffix(".")
	if result.is_empty() or result == "." or result == "..": result = "Unknown Game"
	var stem = result.to_upper().get_basename()
	if ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"].has(stem):
		result = "_" + result
	return result

static func extract_exe_icon(exe_path: String, output_png: String) -> bool:
	var exe_path_absolute = ProjectSettings.globalize_path(exe_path) if exe_path.begins_with("user://") else exe_path
	var output_path_absolute = ProjectSettings.globalize_path(output_png) if output_png.begins_with("user://") else output_png
	var escaped_exe = exe_path_absolute.replace("'", "''")
	var escaped_out = output_path_absolute.replace("'", "''")
	var script = (
		"Add-Type -AssemblyName System.Drawing;" +
		"$i=[System.Drawing.Icon]::ExtractAssociatedIcon('%s');" % escaped_exe +
		"if(-not $i){exit 1};" +
		"$b=$i.ToBitmap();" +
		"$b.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png);" % escaped_out +
		"$i.Dispose();$b.Dispose()"
	)
	var out = []
	var ret = OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], out)
	return ret == 0
