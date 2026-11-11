extends SceneTree

func _init() -> void:
	var Steps = load("res://scripts/steps_builder.gd")
	for path in OS.get_cmdline_user_args():
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		var all_lines: Array = data["lines"]
		for i in all_lines.size():
			all_lines[i]["i"] = i
		var side: Dictionary = Steps.side_columns(all_lines)
		var pages := {}
		for k in side:
			pages[int(k.split(":")[0])] = true
		var keep: Array = Steps.text_lines(all_lines, false)
		var skip: Array = Steps.text_lines(all_lines, true)
		print("%s: side columns on %d of %d pages; text lines %d -> %d when skipping" % [path.get_file().left(30), pages.size(), data["pages"].size(), keep.size(), skip.size()])
	quit()
