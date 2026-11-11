extends SceneTree

func _init() -> void:
	var Steps = load("res://scripts/steps_builder.gd")
	var data = JSON.parse_string(FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]))
	var all_lines: Array = data["lines"]
	for i in all_lines.size():
		all_lines[i]["i"] = i
	var lines: Array = Steps.text_lines(all_lines)
	var words := []
	for l in lines:
		words.append(Steps.line_words(l))
	var steps: Array = Steps.build_sentence_steps(lines, words)
	var split := 0
	for i in steps.size():
		var s: Dictionary = steps[i]
		if int(s["parts"]) > 1:
			if int(s["part"]) == 1:
				split += 1
			var parts := []
			for seg in s["segs"]:
				var ws: Array = words[int(seg["l"])]
				var t := []
				for w in range(int(seg["a"]), int(seg["b"]) + 1):
					t.append(ws[w]["t"])
				parts.append(" ".join(t))
			var l0: Dictionary = lines[int(s["segs"][0]["l"])]
			if true:
				print("step %d = sentence %d part %d/%d (page %d col %d): %s" % [i, int(s["sid"]) + 1, s["part"], s["parts"], int(l0["p"]) + 1, int(l0["c"]), " / ".join(parts).left(40)])
	print("sentences=%d steps=%d split sentences=%d" % [int(steps[steps.size() - 1]["sid"]) + 1, steps.size(), split])
	quit()

