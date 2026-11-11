extends Control
## App shell: library screen (open / recent PDFs) and the reader view.

const ReaderView := preload("res://scripts/reader_view.gd")
const TouchScroll := preload("res://scripts/touch_scroll.gd")

var _library: Control
var _list: VBoxContainer
var _list_scroll: ScrollContainer
var _status: Label
var _progress: ProgressBar
var _open_btn: Button
var _reader: ReaderView

var _picking := false
var _loading_path := ""


func _ready() -> void:
	theme = _make_theme()

	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.14)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_build_library()

	_reader = ReaderView.new()
	_reader.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reader.visible = false
	_reader.closed.connect(_on_reader_closed)
	add_child(_reader)

	if not Pdf.is_available():
		_set_status("PDF engine runs only in the Android build. Export to the tablet to open papers.")
		_open_btn.disabled = true
	_refresh_library()
	if Pdf.is_available():
		var where := Label.new()
		where.text = "Files: " + Pdf.storage_dir()
		where.modulate = Color(1, 1, 1, 0.45)
		where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_library.get_child(0).add_child(where)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _reader and _reader.visible:
			_reader.go_back()
		else:
			get_tree().quit()


# ------------------------------------------------------------------ library UI

func _build_library() -> void:
	_library = MarginContainer.new()
	_library.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		_library.add_theme_constant_override("margin_" + side, 32)
	add_child(_library)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	_library.add_child(col)

	var title := Label.new()
	title.text = "HighReader"
	title.add_theme_font_size_override("font_size", 40)
	col.add_child(title)

	var hint := Label.new()
	hint.text = "Reads a paper one sentence at a time.\nTap the right side to go forward, the left side to go back. Swipe right-to-left for Contents."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	col.add_child(hint)

	_open_btn = Button.new()
	_open_btn.text = "Open PDF…"
	_open_btn.custom_minimum_size.y = 64
	_open_btn.pressed.connect(_on_open_pressed)
	col.add_child(_open_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)

	_progress = ProgressBar.new()
	_progress.visible = false
	_progress.max_value = 1.0
	_progress.step = 0.001
	col.add_child(_progress)

	var recent := Label.new()
	recent.text = "Recent"
	recent.add_theme_font_size_override("font_size", 26)
	col.add_child(recent)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list_scroll = scroll
	TouchScroll.setup(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)


func _refresh_library() -> void:
	for c in _list.get_children():
		c.queue_free()
	var files := Pdf.list_library()
	if files.is_empty():
		var empty := Label.new()
		empty.text = "No papers yet. Tap \"Open PDF…\" to add one."
		empty.modulate = Color(1, 1, 1, 0.5)
		_list.add_child(empty)
		return
	for f in files:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_list.add_child(row)

		var fname: String = f["name"]
		var p := ReaderView.saved_progress(fname, Pdf.data_path("progress.cfg"))
		var open := Button.new()
		open.text = fname.get_basename() + ("   ·   %d%%" % int(p * 100) if p >= 0 else "")
		open.alignment = HORIZONTAL_ALIGNMENT_LEFT
		open.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open.custom_minimum_size.y = 60
		TouchScroll.connect_button(_list_scroll, open, _open_path.bind(String(f["path"])))
		row.add_child(open)

		var del := Button.new()
		del.text = "Remove"
		TouchScroll.connect_button(_list_scroll, del, func():
			Pdf.delete_from_library(String(f["path"]))
			_refresh_library())
		row.add_child(del)


# ------------------------------------------------------------------ opening

func _on_open_pressed() -> void:
	_picking = true
	_set_status("Choose a PDF…")
	Pdf.pick_pdf()


func _open_path(path: String) -> void:
	if not _loading_path.is_empty():
		return
	_set_status("Opening %s…" % path.get_file())
	var info := Pdf.open_pdf(path)
	if info.is_empty():
		_set_status("Could not open this PDF: " + Pdf.last_error())
		return
	if not Pdf.start_analysis():
		_set_status("Could not start text analysis.")
		return
	_loading_path = path
	_progress.value = 0
	_progress.visible = true
	_open_btn.disabled = true
	_set_status("Analyzing text layout…")


func _process(_delta: float) -> void:
	if _picking:
		var s := Pdf.poll_pick()
		if s.begins_with("ok:"):
			_picking = false
			_open_path(s.substr(3))
		elif s == "cancelled":
			_picking = false
			_set_status("")
		elif s.begins_with("error:"):
			_picking = false
			_set_status("Could not import file: " + s.substr(6))
		elif s == "pending":
			_set_status("Importing…")

	if not _loading_path.is_empty():
		var state := Pdf.analysis_state()
		_progress.value = Pdf.analysis_progress()
		if state == "done":
			var result := Pdf.analysis_result()
			var path := _loading_path
			_finish_loading()
			_set_status("")
			_library.visible = false
			_reader.visible = true
			_reader.open_document(path, result)
		elif state == "error" or state == "idle":
			_finish_loading()
			_set_status("Text analysis failed: " + Pdf.last_error())
			Pdf.close_pdf()


func _finish_loading() -> void:
	_loading_path = ""
	_progress.visible = false
	_open_btn.disabled = not Pdf.is_available()


func _on_reader_closed() -> void:
	_reader.visible = false
	_library.visible = true
	_refresh_library()


func _set_status(text: String) -> void:
	_status.text = text


# ------------------------------------------------------------------ theme

func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.22, 0.23, 0.27)
	normal.set_corner_radius_all(10)
	normal.content_margin_left = 16
	normal.content_margin_right = 16
	normal.content_margin_top = 10
	normal.content_margin_bottom = 10
	var hover := normal.duplicate()
	hover.bg_color = Color(0.28, 0.30, 0.35)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.85, 0.65, 0.10)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.18, 0.18, 0.20)

	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Label", Color(0.93, 0.93, 0.95))
	# Check boxes: no button background, just the box and text.
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.set_stylebox(state, "CheckBox", StyleBoxEmpty.new())
	# Bigger drop-down menus for touch.
	t.set_font_size("font_size", "PopupMenu", 26)
	t.set_constant("v_separation", "PopupMenu", 18)
	return t
