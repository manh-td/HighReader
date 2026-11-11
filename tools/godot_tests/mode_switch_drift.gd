extends SceneTree
## Simulates switching Sentence <-> Line with the reader's old and new position mapping.

var Steps

func _init() -> void:
	Steps = load("res://scripts/steps_builder.gd")
	var data = JSON.parse_string(FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]))
	var all_lines: Array = data["lines"]
	for i in all_lines.size():
		all_lines[i]["i"] = i
	var lines: Array = Steps.text_lines(all_lines)
	var words := []
	for l in lines:
		words.append(Steps.line_words(l))
	var sent: Array = Steps.build_sentence_steps(lines, words)
	var line_steps: Array = Steps.build_line_steps(lines, words)

	for variant in ["old", "anchor"]:
		var moved := 0
		var drift_total := 0
		for start in range(0, sent.size(), 7):
			var cur := start
			var anchor := _key(lines, sent[start], variant)
			for round in 3:   # sentence -> line -> sentence, three times
				var k := anchor if variant == "anchor" else _key(lines, sent[cur], variant)
				var li := _find(lines, line_steps, k, variant)
				var k2 := anchor if variant == "anchor" else _key(lines, line_steps[li], variant)
				cur = _find(lines, sent, k2, variant)
			if cur != start:
				moved += 1
				drift_total += cur - start
		print("%s mapping: %d of %d sentences moved after 3 round trips (total drift %d)" % [
			variant, moved, ceili(sent.size() / 7.0), drift_total])
	quit()


func _key(lines: Array, step: Dictionary, variant: String) -> int:
	var s: Dictionary = step["segs"][0]
	if variant == "old":
		return int(lines[int(s["l"])]["i"])
	return int(lines[int(s["l"])]["i"]) * 10000 + int(s["a"])


func _end(lines: Array, step: Dictionary) -> int:
	var segs: Array = step["segs"]
	var s: Dictionary = segs[segs.size() - 1]
	return int(lines[int(s["l"])]["i"]) * 10000 + int(s["b"])


func _find(lines: Array, steps: Array, key: int, variant: String) -> int:
	for i in steps.size():
		if variant == "old":
			if _key(lines, steps[i], "old") >= key:
				return i
		elif _end(lines, steps[i]) >= key:
			return i
	return steps.size() - 1
