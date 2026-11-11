extends RefCounted
## Turns analyzed lines into reading "steps".
## A text step is {"segs": [{"l": line index, "a": first word, "b": last word}], "k": kind}.
## A float step is {"float": index into analysis "floats", "k": "figure"|"table"}.
##
## Line mode: one step per line.
## Sentence mode: a step runs until a word ending in . ; ? or !, and can span lines,
## columns and pages. It also ends where the font size changes, and consecutive
## heading lines are read together.

## Words like "et al." or "Fig." that end with a period but don't end a sentence.
const ABBREVIATIONS := [
	"al.", "e.g.", "i.e.", "fig.", "figs.", "eq.", "eqs.", "sec.", "secs.", "tab.",
	"no.", "nos.", "vs.", "cf.", "approx.", "resp.", "dr.", "mr.", "ms.", "prof.",
	"st.", "ref.", "refs.", "ch.", "pp.", "p.", "vol.", "et.", "ca.", "viz.",
	"incl.", "w.r.t.", "a.k.a.", "def.", "thm.", "lem.", "prop.", "alg.", "app.",
]
const CLOSERS := ")]}\"'”’»"
const OPENERS := "([{\"'“‘«"
## Kinds never read in Sentence/Line mode (floats have their own mode).
const SKIPPED_KINDS := ["small", "footnote", "caption", "table"]
## Font size change (pt) that ends a sentence.
const FONT_CHANGE := 0.6
## Safety net for text without punctuation (code, reference lists).
const MAX_SENTENCE_LINES := 8

static var _initial := RegEx.create_from_string("^[A-Z]\\.$")
static var _section_number := RegEx.create_from_string("^(\\d+(\\.\\d+)*\\.?|[IVX]+\\.|[A-Z]\\.)\\s+\\S")


## A heading line that starts its own heading ("3.1 Dataset"), not a continuation.
static func starts_heading(line: Dictionary) -> bool:
	return _section_number.search(String(line.get("t", ""))) != null


## Lines read in Sentence/Line mode: no floats, captions, tables or notes.
## With skip_side, side columns (margin quotes/notes) are left out too.
static func text_lines(all_lines: Array, skip_side := false) -> Array:
	var side := side_columns(all_lines) if skip_side else {}
	return all_lines.filter(func(l):
		return not (l.get("k", "body") in SKIPPED_KINDS) and int(l.get("f", -1)) < 0 \
			and not side.has("%d:%d" % [int(l["p"]), int(l.get("c", 0))]))


## Side columns: on a page with several columns, a column less than 60% as wide
## as the widest one (e.g. a narrow column of margin quotes). Returns {"page:col": true}.
static func side_columns(all_lines: Array) -> Dictionary:
	var bounds := {}   # "p:c" -> Vector2(x0, x1)
	for l in all_lines:
		var c := int(l.get("c", 0))
		if c == 0:
			continue
		var k := "%d:%d" % [int(l["p"]), c]
		var b: Vector2 = bounds.get(k, Vector2(INF, -INF))
		bounds[k] = Vector2(min(b.x, float(l["x0"])), max(b.y, float(l["x1"])))
	var widest := {}   # page -> widest column width
	var count := {}    # page -> number of columns
	for k in bounds:
		var p := int(k.split(":")[0])
		var w: float = bounds[k].y - bounds[k].x
		widest[p] = max(float(widest.get(p, 0.0)), w)
		count[p] = int(count.get(p, 0)) + 1
	var side := {}
	for k in bounds:
		var p := int(k.split(":")[0])
		if int(count[p]) >= 2 and bounds[k].y - bounds[k].x < 0.6 * float(widest[p]):
			side[k] = true
	return side


## Words of a line as [{"t": text, "x0": float, "x1": float}] in page-normalized x.
static func line_words(line: Dictionary) -> Array:
	var out := []
	var ws = line.get("ws")
	var wx = line.get("wx")
	if ws is Array and wx is Array and wx.size() == ws.size() * 2:
		for i in ws.size():
			out.append({"t": String(ws[i]), "x0": float(wx[i * 2]), "x1": float(wx[i * 2 + 1])})
		return out
	# Fallback for older analysis files: spread words by character count.
	var text: String = line.get("t", "")
	var parts := text.split(" ", false)
	var x0 := float(line.get("x0", 0.0))
	var x1 := float(line.get("x1", 1.0))
	var total := float(max(text.length(), 1))
	var pos := 0
	for p in parts:
		var at := text.find(p, pos)
		out.append({"t": p, "x0": lerp(x0, x1, at / total), "x1": lerp(x0, x1, (at + p.length()) / total)})
		pos = at + p.length()
	return out


static func build_line_steps(lines: Array, words: Array) -> Array:
	var steps := []
	for li in lines.size():
		if words[li].is_empty():
			continue
		steps.append({"segs": [{"l": li, "a": 0, "b": words[li].size() - 1}], "k": lines[li].get("k", "body")})
	return steps


static func build_sentence_steps(lines: Array, words: Array) -> Array:
	var flat := []
	for li in lines.size():
		for wi in words[li].size():
			flat.append([li, wi, String(words[li][wi]["t"])])

	var steps := []
	var segs := []
	var kind := ""
	var seg_l := -1
	var seg_a := 0
	var seg_b := -1

	for fi in flat.size():
		var li: int = flat[fi][0]
		var wi: int = flat[fi][1]
		var word: String = flat[fi][2]
		var line: Dictionary = lines[li]
		var k: String = line.get("k", "body")

		if li != seg_l:
			# Close the piece of the sentence on the previous line.
			if seg_l >= 0 and seg_b >= seg_a:
				segs.append({"l": seg_l, "a": seg_a, "b": seg_b})
			if not segs.is_empty() and _breaks_between(lines, int(segs[segs.size() - 1]["l"]), li, segs.size()):
				steps.append({"segs": segs, "k": kind})
				segs = []
			seg_l = li
			seg_a = wi
			kind = k
		seg_b = wi

		if k == "heading":
			continue   # headings run to the end of the heading block
		var next_word: String = flat[fi + 1][2] if fi + 1 < flat.size() else ""
		if ends_sentence(word, next_word):
			segs.append({"l": seg_l, "a": seg_a, "b": seg_b})
			steps.append({"segs": segs, "k": kind})
			segs = []
			seg_a = wi + 1   # the next sentence may start later on this line
			seg_b = wi

	if seg_l >= 0 and seg_b >= seg_a:
		segs.append({"l": seg_l, "a": seg_a, "b": seg_b})
	if not segs.is_empty():
		steps.append({"segs": segs, "k": kind})
	return split_by_region(steps, lines)


## Splits each sentence where it moves to another column or page, so every part
## gets its own highlight and tap. Adds "sid" (sentence number), "part", "parts".
static func split_by_region(steps: Array, lines: Array) -> Array:
	var out := []
	for sid in steps.size():
		var step: Dictionary = steps[sid]
		var groups := []
		var region := ""
		for s in step["segs"]:
			var line: Dictionary = lines[int(s["l"])]
			var r := "%d:%d" % [int(line["p"]), int(line.get("c", 0))]
			if r != region:
				groups.append([])
				region = r
			groups[groups.size() - 1].append(s)
		for gi in groups.size():
			out.append({"segs": groups[gi], "k": step["k"], "sid": sid, "part": gi + 1, "parts": groups.size()})
	return out


## Whether a sentence must end between line `prev` and line `cur`.
static func _breaks_between(lines: Array, prev: int, cur: int, seg_count: int) -> bool:
	var a: Dictionary = lines[prev]
	var b: Dictionary = lines[cur]
	if a.get("k", "body") != b.get("k", "body"):
		return true
	if absf(float(a.get("s", 0.0)) - float(b.get("s", 0.0))) > FONT_CHANGE:
		return true
	if b.get("k") == "heading":
		return int(a["p"]) != int(b["p"]) or starts_heading(b)   # merge wrapped heading lines
	return seg_count >= MAX_SENTENCE_LINES


static func build_float_steps(floats: Array) -> Array:
	var steps := []
	for i in floats.size():
		steps.append({"float": i, "k": floats[i].get("k", "figure")})
	return steps


## Contents entries: [{"t": heading text, "l": first line index}] from heading runs.
static func build_contents(lines: Array) -> Array:
	var out := []
	var li := 0
	while li < lines.size():
		if lines[li].get("k") != "heading":
			li += 1
			continue
		var start := li
		var parts := [String(lines[li].get("t", ""))]
		while li + 1 < lines.size() and lines[li + 1].get("k") == "heading" \
				and int(lines[li + 1]["p"]) == int(lines[start]["p"]) and not starts_heading(lines[li + 1]) \
				and absf(float(lines[li + 1].get("s", 0.0)) - float(lines[start].get("s", 0.0))) <= FONT_CHANGE:
			li += 1
			parts.append(String(lines[li].get("t", "")))
		out.append({"t": " ".join(parts), "l": start})
		li += 1
	return out


static func ends_sentence(word: String, next_word: String) -> bool:
	var w := word
	while w.length() > 0 and CLOSERS.contains(w[w.length() - 1]):
		w = w.substr(0, w.length() - 1)
	if w.is_empty():
		return false
	if w.ends_with(";") or w.ends_with("?") or w.ends_with("!"):
		return true
	if not w.ends_with("."):
		return false

	var core := w
	while core.length() > 0 and OPENERS.contains(core[0]):
		core = core.substr(1)
	if core.to_lower() in ABBREVIATIONS:
		return false
	if _initial.search(core):
		return false   # a name initial like "J."

	# "et al. found", "e.g. the" ... a lowercase next word means the sentence goes on.
	var n := next_word
	while n.length() > 0 and OPENERS.contains(n[0]):
		n = n.substr(1)
	if n.length() > 0:
		var c := n[0]
		if c != c.to_upper() and c == c.to_lower():
			return false
	return true
