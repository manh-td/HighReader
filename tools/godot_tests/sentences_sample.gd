extends SceneTree

func _init() -> void:
	var Steps = load("res://scripts/steps_builder.gd")
	var path := OS.get_cmdline_user_args()[0]
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	var lines: Array = Steps.text_lines(data["lines"])
	var words := []
	for l in lines:
		words.append(Steps.line_words(l))
	var steps: Array = Steps.build_sentence_steps(lines, words)
	print("lines=%d sentences=%d contents=%d floats=%d" % [lines.size(), steps.size(), Steps.build_contents(lines).size(), data["floats"].size()])
	for c in Steps.build_contents(lines): print("  TOC: ", c["t"].left(70))
	var shown := 0
	for s in steps:
		var parts := []
		for seg in s["segs"]:
			var ws: Array = words[int(seg["l"])]
			var t := []
			for i in range(int(seg["a"]), int(seg["b"]) + 1):
				t.append(ws[i]["t"])
			parts.append(" ".join(t))
		var p := int(lines[int(s["segs"][0]["l"])]["p"])
		if p == 0 or ((p == 6 or p == 7) and shown < 40):
			print("[p%d %s %d seg] %s" % [p + 1, s["k"], s["segs"].size(), " / ".join(parts).left(150)])
			shown += 1
	# Unit checks for the end-of-sentence rule.
	var cases := [["al.", "found", false], ["vulnerabilities.", "Drawing", true], ["[12];", "the", true],
		["Fig.", "2", false], ["e.g.", "GPT-4o", false], ["J.", "Smith", false], ["(0.17).", "This", true], ["works", "The", false]]
	for c in cases:
		var got: bool = Steps.ends_sentence(c[0], c[1])
		print("%s %s -> %s %s" % [c[0], c[1], got, "OK" if got == c[2] else "FAIL"])
	quit()
