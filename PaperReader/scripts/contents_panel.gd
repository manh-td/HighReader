extends Control
## Contents drawer on the right edge. Opens with a right-to-left swipe (handled by
## the reader), closes with a left-to-right swipe, a tap outside, or picking an entry.

signal picked(index: int)

const TouchScroll := preload("res://scripts/touch_scroll.gd")

const SWIPE_CLOSE := 90.0

var _backdrop: ColorRect
var _drawer: PanelContainer
var _list: VBoxContainer
var _scroll: ScrollContainer
var _tween: Tween
var _press_pos := Vector2.ZERO
var _pressing := false
var is_open := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.45)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.gui_input.connect(_on_input)
	add_child(_backdrop)

	_drawer = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.15)
	sb.set_content_margin_all(18)
	_drawer.add_theme_stylebox_override("panel", sb)
	add_child(_drawer)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_drawer.add_child(col)
	var title := Label.new()
	title.text = "Contents"
	title.add_theme_font_size_override("font_size", 28)
	col.add_child(title)
	var hint := Label.new()
	hint.text = "Swipe right to close"
	hint.modulate = Color(1, 1, 1, 0.5)
	col.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_scroll = scroll
	TouchScroll.setup(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	resized.connect(_layout)


## entries: [{"t": text}] ; current: index to mark.
func set_entries(entries: Array, current: int) -> void:
	for c in _list.get_children():
		c.queue_free()
	if entries.is_empty():
		var none := Label.new()
		none.text = "No headings found in this paper."
		none.modulate = Color(1, 1, 1, 0.6)
		_list.add_child(none)
	for i in entries.size():
		var b := Button.new()
		b.text = String(entries[i]["t"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size.y = 52
		if i == current:
			b.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		TouchScroll.connect_button(_scroll, b, func():
			picked.emit(i)
			close())
		_list.add_child(b)


func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	_layout()
	_drawer.position.x = size.x
	_animate(size.x - _drawer.size.x, 0.45)


func close() -> void:
	if not is_open:
		return
	is_open = false
	_animate(size.x, 0.0)
	_tween.finished.connect(func():
		if not is_open:
			visible = false)


func _layout() -> void:
	var w: float = clamp(size.x * 0.8, 280.0, 520.0)
	_drawer.size = Vector2(w, size.y)
	_drawer.position = Vector2(size.x - w if is_open else size.x, 0)


func _animate(x: float, backdrop_alpha: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_drawer, "position:x", x, 0.25)
	_tween.tween_property(_backdrop, "color:a", backdrop_alpha, 0.25)


func _on_input(event: InputEvent) -> void:
	# Tap on the dimmed area outside the drawer closes it.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if (event.global_position - _press_pos).length() < 18:
			close()


func _input(event: InputEvent) -> void:
	# Swipe left-to-right anywhere (also over the list) closes the drawer.
	if not is_open or not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_pressing = true
		_press_pos = event.global_position
	elif _pressing:
		_pressing = false
		var d: Vector2 = event.global_position - _press_pos
		if d.x > SWIPE_CLOSE and absf(d.x) > absf(d.y) * 1.5:
			close()
			get_viewport().set_input_as_handled()