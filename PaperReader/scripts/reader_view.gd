extends Control
## HighReader reading view.
## Pages are stacked vertically in "doc units" (page width = 1.0).
##
## Modes:
##   sentence - one sentence per tap (default)
##   line     - one text line per tap
##   floats   - one figure / table per tap
##   free     - no highlight; drag and pinch to look around
## Tap right of the back area to go forward, inside it (left side) to go back.
## Swipe right-to-left to open Contents.

signal closed

const Steps := preload("res://scripts/steps_builder.gd")
const SettingsPanel := preload("res://scripts/settings_panel.gd")
const ContentsPanel := preload("res://scripts/contents_panel.gd")

const MODES := ["sentence", "line", "floats", "free"]
const MODE_NAMES := ["Sentence", "Line", "Floats", "Free"]
const PAGE_GAP := 0.02
const FOCUS_Y := 0.40          # where the highlight sits, as a share of the usable height
const MAX_TEXTURE_WIDTH := 3200
const SWIPE_OPEN := 140.0

const DEFAULTS := {
	"mode": "sentence",
	"fit": "text",
	"color": Color(1.0, 0.80, 0.10),
	"color_by_kind": true,
	"style": "box",
	"fill": 0.22,
	"dim": 0.42,
	"back_zone": 0.33,
	"skip_side": false,
}
const KIND_COLORS := {
	"heading": Color(0.30, 0.65, 1.0),
	"figure": Color(0.35, 0.85, 0.45),
	"table": Color(0.75, 0.50, 1.0),
}

var cam := Vector2.ZERO:       # doc-space point shown at the view's top-left
	set(v):
		cam = v
		queue_redraw()
var zoom := 1.0:
	set(v):
		zoom = v
		queue_redraw()

var cfg := DEFAULTS.duplicate()
var doc_name := ""
var page_rects: Array[Rect2] = []
var all_lines: Array = []       # every analyzed line; "i" = reading-order index
var floats: Array = []          # analysis floats, each with "key" = reading-order index
var lines: Array = []           # lines read in text modes
var words: Array = []           # words[li] for lines[li]
var steps: Array = []
var contents: Array = []        # [{"t", "l"}] headings
var current := 0
var _col_bounds := {}
var text_available := true

var _textures := {}             # page -> {"tex": Texture2D, "w": int}
var _tween: Tween
var _pressed := false
var _dragging := false
var _press_pos := Vector2.ZERO
var _press_time := 0
var _progress := ConfigFile.new()
var _settings_file := ConfigFile.new()
var _progress_path := "user://progress.cfg"
var _settings_path := "user://settings.cfg"
var _storage_dir := ""

var _top: PanelContainer
var _bottom: PanelContainer
var _title: Label
var _status: Label
var _bar: ProgressBar
var _mode_btn: OptionButton
var _notice: Label
var _settings: SettingsPanel
var _contents: ContentsPanel


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	_storage_dir = Pdf.storage_dir()
	_progress_path = Pdf.data_path("progress.cfg")
	_settings_path = Pdf.data_path("settings.cfg")
	_progress.load(_progress_path)
	_settings_file.load(_settings_path)
	for k in DEFAULTS:
		cfg[k] = _settings_file.get_value("reader", k, DEFAULTS[k])
	_build_ui()
	resized.connect(_on_resized)


# ------------------------------------------------------------------ public API

func open_document(path: String, analysis: Dictionary) -> void:
	doc_name = path.get_file()
	_title.text = doc_name.get_basename()
	_textures.clear()

	page_rects.clear()
	var y := 0.0
	for size in analysis.get("pages", []):
		var h: float = float(size[1]) / max(float(size[0]), 1.0)
		page_rects.append(Rect2(0, y, 1.0, h))
		y += h + PAGE_GAP

	all_lines = analysis.get("lines", [])
	for i in all_lines.size():
		all_lines[i]["i"] = i
	floats = analysis.get("floats", [])
	for fi in floats.size():
		floats[fi]["key"] = 1 << 30
	for l in all_lines:
		var f := int(l.get("f", -1))
		if f >= 0 and f < floats.size():
			floats[f]["key"] = min(int(floats[f]["key"]), int(l["i"]))

	_rebuild_text()
	# Horizontal extent of each column on each page ("page:col" -> Vector2(x0, x1)).
	_col_bounds.clear()
	for l in all_lines:
		var ck := "%d:%d" % [int(l["p"]), int(l.get("c", 0))]
		var b: Vector2 = _col_bounds.get(ck, Vector2(INF, -INF))
		_col_bounds[ck] = Vector2(min(b.x, float(l["x0"])), max(b.y, float(l["x1"])))
	text_available = not lines.is_empty()

	_notice.visible = not text_available
	for i in 3:
		_mode_btn.set_item_disabled(i, not text_available)
	var mode: String = cfg["mode"] if text_available else "free"
	var saved: int = _progress.get_value("progress", doc_name, 0)
	_set_mode(mode, saved * KEY_SCALE, false)
	grab_focus()


## Android Back: close Settings or Contents if open, otherwise leave the document.
func go_back() -> void:
	if _settings.visible:
		_settings.close()
	elif _contents.is_open:
		_contents.close()
	else:
		close_document()


func close_document() -> void:
	_save_progress()
	_contents.close()
	_settings.close()
	_textures.clear()
	Pdf.close_pdf()
	closed.emit()


static func saved_progress(doc: String, progress_path: String) -> float:
	var c := ConfigFile.new()
	if c.load(progress_path) != OK or not c.has_section_key("progress", doc):
		return -1.0
	var total: int = c.get_value("totals", doc, 0)
	return float(c.get_value("progress", doc, 0)) / max(total - 1, 1)


# ------------------------------------------------------------------ modes & steps
#
# Positions are "keys": reading-order line index * KEY_SCALE + word index.
# `_anchor` is the reading position. It only changes when the reader moves
# (tap, Contents, scrolling in Free mode), never when switching modes, so
# switching Sentence <-> Line <-> Floats always comes back to the same place.

const KEY_SCALE := 10000

var _anchor := 0
var _active_mode := ""


func _mode() -> String:
	return MODES[_mode_btn.selected]


func _set_mode(mode: String, key: int, animate: bool) -> void:
	_mode_btn.select(MODES.find(mode))
	_active_mode = mode
	_anchor = key
	match mode:
		"sentence":
			steps = Steps.build_sentence_steps(lines, words)
		"line":
			steps = Steps.build_line_steps(lines, words)
		"floats":
			steps = Steps.build_float_steps(floats)
		_:
			steps = []
	current = _step_at_key(key)
	if mode == "free":
		_update_status()
		queue_redraw()
	else:
		_go_to_current(animate)


## The step containing position `key`, or the first one after it.
func _step_at_key(key: int) -> int:
	for i in steps.size():
		if _step_end(steps[i]) >= key:
			return i
	return max(steps.size() - 1, 0)


## Key where a step starts.
func _step_key(step: Dictionary) -> int:
	if step.has("float"):
		return int(floats[int(step["float"])]["key"]) * KEY_SCALE
	var s: Dictionary = step["segs"][0]
	return int(lines[int(s["l"])]["i"]) * KEY_SCALE + int(s["a"])


## Key where a step ends.
func _step_end(step: Dictionary) -> int:
	if step.has("float"):
		return int(floats[int(step["float"])]["key"]) * KEY_SCALE
	var segs: Array = step["segs"]
	var s: Dictionary = segs[segs.size() - 1]
	return int(lines[int(s["l"])]["i"]) * KEY_SCALE + int(s["b"])


## The reading position now (Free mode: what is in view).
func _current_key() -> int:
	if _active_mode == "free":
		return _key_at_view()
	return _anchor


## Key of the earliest line in view (Free mode).
func _key_at_view() -> int:
	var top := cam.y + _usable().position.y / _scale()
	var bottom := cam.y + size.y / _scale()
	var best := -1
	for l in all_lines:
		var y := _line_rect(l).position.y
		if y >= top and y <= bottom and (best < 0 or int(l["i"]) < best):
			best = int(l["i"])
	return max(best, 0) * KEY_SCALE


func _moved_to_current() -> void:
	_anchor = _step_key(steps[current])
	_go_to_current(true)


func next_step() -> void:
	if _active_mode == "free":
		return
	if current < steps.size() - 1:
		current += 1
		_moved_to_current()
	else:
		_status.text = "End of document"


func prev_step() -> void:
	if _active_mode != "free" and current > 0:
		current -= 1
		_moved_to_current()


func jump_to_contents(index: int) -> void:
	if index < 0 or index >= contents.size():
		return
	var key := int(lines[int(contents[index]["l"])]["i"]) * KEY_SCALE
	if _active_mode == "free":
		var r := _line_rect(lines[int(contents[index]["l"])])
		_animate_to(Vector2(cam.x, r.position.y - _usable().position.y / _scale() - 0.02), zoom)
	else:
		current = _step_at_key(key)
		_moved_to_current()

# ------------------------------------------------------------------ framing

## Doc-space rectangles the current step highlights, each with its page.
func _step_rects(step: Dictionary) -> Array:
	var out := []
	if step.has("float"):
		var f: Dictionary = floats[int(step["float"])]
		out.append([int(f["p"]), _norm_rect(int(f["p"]), f)])
		return out
	for s in step["segs"]:
		out.append([int(lines[int(s["l"])]["p"]), _seg_rect(s)])
	return out


func _go_to_current(animate: bool) -> void:
	if steps.is_empty():
		_status.text = "No figures or tables found." if _mode() == "floats" else "Nothing to read here."
		queue_redraw()
		return
	var step: Dictionary = steps[current]
	var is_float := step.has("float")
	var rects := _step_rects(step)

	# Frame the part of the step on the first piece's page and column.
	var col := 0
	var page: int = rects[0][0]
	if not is_float:
		col = int(lines[int(step["segs"][0]["l"])].get("c", 0))
	var focus: Rect2 = rects[0][1]
	for i in range(1, rects.size()):
		var li := int(step["segs"][i]["l"])
		if rects[i][0] == page and int(lines[li].get("c", 0)) == col:
			focus = focus.merge(rects[i][1])

	var usable := _usable()
	var base := _base_scale()
	var z := 1.0
	var center_x := -1.0
	var fit_text := false
	match "text" if is_float else String(cfg["fit"]):
		"text":
			# The highlight, from its leftmost to its rightmost edge (plus the box
			# padding), fills the screen width. Very tall steps are fitted by height.
			var line_h: float = rects[0][1].size.y
			var w: float = max(focus.size.x + line_h * 0.5, 0.01)
			z = usable.size.x * 0.96 / (w * base)
			z = min(z, usable.size.y * 0.85 / (max(focus.size.y, 0.001) * base))
			z = clamp(z, 0.5, 6.0)
			fit_text = true
		"column":
			if col != 0:
				var cb: Vector2 = _col_bounds.get("%d:%d" % [page, col], Vector2(0.0, 1.0))
				var pw := page_rects[page].size.x
				z = usable.size.x * 0.95 / (max(cb.y - cb.x, 0.15) * pw * base)
				center_x = page_rects[page].position.x + (cb.x + cb.y) / 2.0 * pw
		_:
			z = 1.0

	var visible_w := size.x / (base * z)
	if center_x < 0.0:
		center_x = focus.get_center().x
	var x: float
	if fit_text:
		x = center_x - visible_w / 2.0
	elif visible_w >= 1.0:
		x = 0.5 - visible_w / 2.0
	else:
		x = clamp(center_x - visible_w / 2.0, -0.02, 1.02 - visible_w)

	var scale := base * z
	var y: float
	if focus.size.y * scale > usable.size.y * 0.6:
		y = focus.position.y - (usable.position.y + usable.size.y * 0.08) / scale
	else:
		y = focus.get_center().y - (usable.position.y + usable.size.y * FOCUS_Y) / scale

	if animate:
		_animate_to(Vector2(x, y), z)
	else:
		if _tween:
			_tween.kill()
		zoom = z
		cam = Vector2(x, y)
	_update_status()
	_save_progress()
	queue_redraw()


func _animate_to(target_cam: Vector2, target_zoom: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "cam", target_cam, 0.28)
	_tween.tween_property(self, "zoom", target_zoom, 0.28)


## Screen area between the top and bottom bars.
func _usable() -> Rect2:
	var top := _top.size.y if _top else 0.0
	var bottom := _bottom.size.y if _bottom else 0.0
	return Rect2(0, top, size.x, max(size.y - top - bottom, 1.0))


func _update_status() -> void:
	var mode := _mode()
	if mode == "free" or steps.is_empty():
		var p := _page_at_view()
		_status.text = "Free scroll   ·   Page %d / %d" % [p + 1, page_rects.size()]
		_bar.max_value = max(page_rects.size() - 1, 1)
		_bar.value = p
		return
	var step: Dictionary = steps[current]
	var page: int = _step_rects(step)[0][0]
	var noun: String = {"sentence": "Sentence", "line": "Line", "floats": "Figure/Table"}[mode]
	var number := current + 1
	var total := steps.size()
	var part := ""
	if step.has("sid"):
		# Sentences split across columns/pages count once; show which part this is.
		number = int(step["sid"]) + 1
		total = int(steps[steps.size() - 1]["sid"]) + 1
		if int(step["parts"]) > 1:
			part = " (part %d of %d)" % [int(step["part"]), int(step["parts"])]
	_status.text = "%s %d / %d%s   ·   Page %d / %d" % [noun, number, total, part, page + 1, page_rects.size()]
	_bar.max_value = max(steps.size() - 1, 1)
	_bar.value = current


func _page_at_view() -> int:
	var mid := cam.y + size.y * 0.5 / _scale()
	for i in page_rects.size():
		if mid <= page_rects[i].end.y + PAGE_GAP:
			return i
	return max(page_rects.size() - 1, 0)


func _save_progress() -> void:
	if doc_name.is_empty():
		return
	_progress.set_value("progress", doc_name, _current_key() / KEY_SCALE)
	_progress.set_value("totals", doc_name, all_lines.size())
	_progress.save(_progress_path)


func _save_settings() -> void:
	for k in cfg:
		_settings_file.set_value("reader", k, cfg[k])
	_settings_file.save(_settings_path)


# ------------------------------------------------------------------ geometry

func _base_scale() -> float:
	return max(size.x, 1.0)


func _scale() -> float:
	return _base_scale() * zoom


func _to_screen(r: Rect2) -> Rect2:
	var s := _scale()
	return Rect2((r.position - cam) * s, r.size * s)


func _norm_rect(page: int, d: Dictionary) -> Rect2:
	var pr := page_rects[page]
	var x0 := float(d["x0"])
	var y0 := float(d["y0"])
	return Rect2(pr.position.x + x0 * pr.size.x, pr.position.y + y0 * pr.size.y,
		(float(d["x1"]) - x0) * pr.size.x, (float(d["y1"]) - y0) * pr.size.y)


func _line_rect(line: Dictionary) -> Rect2:
	var p := int(line["p"])
	if p < 0 or p >= page_rects.size():
		return Rect2()
	return _norm_rect(p, line)


## Doc-space rectangle covering words a..b of one text line.
func _seg_rect(seg: Dictionary) -> Rect2:
	var li := int(seg["l"])
	var line: Dictionary = lines[li]
	var r := _line_rect(line)
	var ws: Array = words[li]
	if ws.is_empty():
		return r
	var pr := page_rects[int(line["p"])]
	var x0 := pr.position.x + float(ws[int(seg["a"])]["x0"]) * pr.size.x
	var x1 := pr.position.x + float(ws[int(seg["b"])]["x1"]) * pr.size.x
	return Rect2(x0, r.position.y, x1 - x0, r.size.y)


func _visible_pages() -> Array[int]:
	var out: Array[int] = []
	var top := cam.y
	var bottom := cam.y + size.y / _scale()
	for i in page_rects.size():
		var r := page_rects[i]
		if r.end.y >= top and r.position.y <= bottom:
			out.append(i)
	return out


# ------------------------------------------------------------------ textures

func _process(_delta: float) -> void:
	if page_rects.is_empty() or not visible:
		return
	var vis := _visible_pages()
	var wanted := {}
	for p in vis:
		wanted[p] = true
	if _mode() != "free" and current + 1 < steps.size():
		for r in _step_rects(steps[current + 1]):
			wanted[r[0]] = true

	for p in _textures.keys():
		if not wanted.has(p) and not wanted.has(p - 1) and not wanted.has(p + 1):
			_textures.erase(p)

	# Load at most one page per frame, visible pages first.
	var need_w := _needed_texture_width()
	var order: Array = []
	order.append_array(vis)
	order.append_array(wanted.keys())
	for p in order:
		var entry = _textures.get(p)
		if entry == null or int(entry["w"]) < need_w * 0.85:
			var tex := Pdf.render_page(p, need_w)
			if tex:
				_textures[p] = {"tex": tex, "w": need_w}
				queue_redraw()
			break

	if _mode() == "free" and _dragging:
		_update_status()


func _needed_texture_width() -> int:
	var win := DisplayServer.window_get_size()
	var phys_per_logical: float = float(win.x) / max(get_viewport_rect().size.x, 1.0)
	var w := int(ceil(_base_scale() * max(zoom, 1.0) * phys_per_logical / 256.0)) * 256
	return clamp(w, 256, MAX_TEXTURE_WIDTH)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.12, 0.14))
	for p in _visible_pages():
		var r := _to_screen(page_rects[p])
		var entry = _textures.get(p)
		if entry:
			draw_texture_rect(entry["tex"], r, false)
		else:
			draw_rect(r, Color(0.96, 0.96, 0.96))

	if _mode() == "free" or steps.is_empty():
		return
	var step: Dictionary = steps[current]
	var holes := []   # [page, padded doc rect]
	for pr in _step_rects(step):
		var r: Rect2 = pr[1]
		var pad: float = r.size.y * 0.15 if not step.has("float") else 0.008
		holes.append([pr[0], r.grow_individual(pad * 1.5, pad, pad * 1.5, pad)])

	var dim: float = cfg["dim"]
	if dim > 0.01:
		# Shade everything, then paint the page back inside each highlighted piece.
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, dim))
		for h in holes:
			_draw_page_patch(h[0], h[1])

	var c: Color = cfg["color"]
	if cfg["color_by_kind"] and KIND_COLORS.has(step.get("k", "")):
		c = KIND_COLORS[step["k"]]
	var fill: float = cfg["fill"]
	for h in holes:
		var sr := _to_screen(h[1])
		match String(cfg["style"]):
			"fill":
				draw_rect(sr, Color(c, fill), true)
			"outline":
				draw_rect(sr, Color(c, 0.95), false, 3.0)
			"underline":
				var t: float = max(3.0, sr.size.y * 0.08)
				draw_rect(Rect2(sr.position.x, sr.end.y - t, sr.size.x, t), Color(c, max(fill * 3.0, 0.6)))
			_:
				draw_rect(sr, Color(c, fill), true)
				draw_rect(sr, Color(c, 0.95), false, 3.0)


func _draw_page_patch(page: int, doc_rect: Rect2) -> void:
	var pr := page_rects[page]
	var clip := doc_rect.intersection(pr)
	if not clip.has_area():
		return
	var entry = _textures.get(page)
	if entry == null:
		draw_rect(_to_screen(clip), Color(0.96, 0.96, 0.96))
		return
	var tex: Texture2D = entry["tex"]
	var tsize := tex.get_size()
	var src := Rect2((clip.position - pr.position) / pr.size * tsize, clip.size / pr.size * tsize)
	draw_texture_rect_region(tex, _to_screen(clip), src)


# ------------------------------------------------------------------ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressed = true
				_dragging = false
				_press_pos = mb.position
				_press_time = Time.get_ticks_msec()
			else:
				if _pressed:
					_on_release(mb.position)
				_pressed = false
			accept_event()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not _view_locked():
			var dir := -1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			_pan(Vector2(0, dir * 60.0))
			accept_event()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_press_pos) > 18.0:
			_dragging = true
		if _dragging and not _view_locked():
			_pan(-mm.relative)
		accept_event()
	elif event is InputEventMagnifyGesture and not _view_locked():
		var g := event as InputEventMagnifyGesture
		if _tween:
			_tween.kill()
		# Zoom around the pinch point.
		var before := cam + g.position / _scale()
		zoom = clamp(zoom * g.factor, 0.5, 4.0)
		cam = before - g.position / _scale()
		accept_event()


func _on_release(pos: Vector2) -> void:
	var d := pos - _press_pos
	var quick := Time.get_ticks_msec() - _press_time < 600
	# Right-to-left swipe opens Contents (in Free mode only from the right edge).
	var from_edge := _press_pos.x > size.x * 0.85
	if _dragging and quick and d.x < -SWIPE_OPEN and absf(d.x) > absf(d.y) * 2.0 \
			and (_mode() != "free" or from_edge):
		_open_contents()
		if _mode() != "free":
			_go_to_current(true)   # undo the pan the swipe caused
		return
	if _dragging:
		return
	if _mode() == "free":
		return
	if pos.x < size.x * float(cfg["back_zone"]):
		prev_step()
	else:
		next_step()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _settings.visible or _contents.is_open:
		return
	if event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down") or event.is_action_pressed("ui_accept"):
		next_step()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		prev_step()
		get_viewport().set_input_as_handled()


## In "Fit to text" (and Floats) the view follows the highlight: no pinch or drag.
func _view_locked() -> bool:
	if _active_mode == "free" or steps.is_empty():
		return false
	return _active_mode == "floats" or String(cfg["fit"]) == "text"


func _pan(screen_delta: Vector2) -> void:
	if _tween:
		_tween.kill()
	cam += screen_delta / _scale()


func _on_resized() -> void:
	if page_rects.is_empty():
		return
	if _mode() != "free" and not steps.is_empty():
		_go_to_current(false)


# ------------------------------------------------------------------ UI

func _open_contents() -> void:
	var cur := -1
	var key := _current_key()
	for i in contents.size():
		if int(lines[int(contents[i]["l"])]["i"]) * KEY_SCALE <= key:
			cur = i
	_contents.set_entries(contents, cur)
	_contents.open()


func _on_setting_changed(key: String, value: Variant) -> void:
	cfg[key] = value
	_save_settings()
	if key == "fit" and _mode() != "free":
		_go_to_current(true)
	elif key == "skip_side":
		var anchor := _current_key()
		_rebuild_text()
		_set_mode(_active_mode, anchor, true)
	queue_redraw()


## Recomputes the lines read in text modes (and Contents) from the current settings.
func _rebuild_text() -> void:
	lines = Steps.text_lines(all_lines, bool(cfg["skip_side"]))
	words.clear()
	for l in lines:
		words.append(Steps.line_words(l))
	contents = Steps.build_contents(lines)


func _build_ui() -> void:
	_top = PanelContainer.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top.add_theme_stylebox_override("panel", _bar_style())
	add_child(_top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_top.add_child(row)

	var back := Button.new()
	back.text = "< Library"
	back.pressed.connect(close_document)
	row.add_child(back)

	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_title)

	_mode_btn = OptionButton.new()
	for n in MODE_NAMES:
		_mode_btn.add_item(n)
	_mode_btn.item_selected.connect(func(i):
		var key := _current_key()
		cfg["mode"] = MODES[i]
		_save_settings()
		_set_mode(MODES[i], key, true))
	row.add_child(_mode_btn)

	var contents_btn := Button.new()
	contents_btn.text = "Contents"
	contents_btn.pressed.connect(_open_contents)
	row.add_child(contents_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.pressed.connect(func(): _settings.open(cfg, _storage_dir))
	row.add_child(settings_btn)

	_bottom = PanelContainer.new()
	_bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bottom.add_theme_stylebox_override("panel", _bar_style())
	add_child(_bottom)
	var col := VBoxContainer.new()
	_bottom.add_child(col)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_status)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 8
	col.add_child(_bar)

	_notice = Label.new()
	_notice.text = "This PDF has no text layer (it looks scanned).\nOnly Free mode is available."
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_notice.position.y = 90
	var nb := StyleBoxFlat.new()
	nb.bg_color = Color(0.55, 0.15, 0.15, 0.92)
	nb.set_corner_radius_all(10)
	nb.set_content_margin_all(14)
	_notice.add_theme_stylebox_override("normal", nb)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.visible = false
	add_child(_notice)

	_contents = ContentsPanel.new()
	_contents.picked.connect(jump_to_contents)
	add_child(_contents)

	_settings = SettingsPanel.new()
	_settings.changed.connect(_on_setting_changed)
	add_child(_settings)


func _bar_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.92)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb
