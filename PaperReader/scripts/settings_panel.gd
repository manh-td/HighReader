extends Control
## Full-screen overlay with reader settings. Emits `changed(key, value)`.

signal changed(key: String, value: Variant)

const TouchScroll := preload("res://scripts/touch_scroll.gd")

const SWATCHES := [
	Color(1.0, 0.80, 0.10),   # yellow
	Color(1.0, 0.55, 0.15),   # orange
	Color(0.40, 0.85, 0.35),  # green
	Color(0.30, 0.70, 1.0),   # blue
	Color(1.0, 0.45, 0.70),   # pink
	Color(0.70, 0.50, 1.0),   # purple
	Color(1.0, 0.30, 0.30),   # red
]
const FITS := ["text", "column", "page"]
const FIT_NAMES := ["Fit to text", "Fit column", "Fit page width"]
const STYLES := ["box", "fill", "outline", "underline"]
const STYLE_NAMES := ["Box (fill + border)", "Fill only", "Border only", "Underline"]

var _cfg: Dictionary
var _swatch_buttons: Array[Button] = []
var _value_labels := {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false


func open(cfg: Dictionary, storage_dir: String) -> void:
	_cfg = cfg
	for c in get_children():
		c.queue_free()
	_swatch_buttons.clear()
	_build(storage_dir)
	visible = true


func close() -> void:
	visible = false


func _build(storage_dir: String) -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(min(get_viewport_rect().size.x - 40, 620), 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.17)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = min(get_viewport_rect().size.y - 120, 900)
	panel.add_child(scroll)
	TouchScroll.setup(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 14)
	scroll.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var done := Button.new()
	done.text = "Done"
	done.pressed.connect(close)
	head.add_child(done)

	_section(col, "Zoom")
	_option(col, "fit", FITS, FIT_NAMES)

	_section(col, "Highlight color")
	var swatches := HBoxContainer.new()
	swatches.add_theme_constant_override("separation", 10)
	col.add_child(swatches)
	for c in SWATCHES:
		var b := Button.new()
		b.custom_minimum_size = Vector2(56, 56)
		TouchScroll.connect_button(scroll, b, func():
			_apply("color", c)
			_refresh_swatches())
		swatches.add_child(b)
		_swatch_buttons.append(b)
	_refresh_swatches()
	var by_kind := CheckBox.new()
	by_kind.text = "Use other colors for headings, figures and tables"
	by_kind.button_pressed = _cfg["color_by_kind"]
	by_kind.toggled.connect(func(on): _apply("color_by_kind", on))
	col.add_child(by_kind)

	_section(col, "Highlight style")
	_option(col, "style", STYLES, STYLE_NAMES)
	_slider(col, "fill", "Highlight strength", 0.05, 0.6, func(v): return "%d%%" % int(v * 100))

	_section(col, "Rest of the page")
	_slider(col, "dim", "Dim amount", 0.0, 0.85, func(v): return "Off" if v < 0.01 else "%d%%" % int(v * 100))

	_section(col, "Reading")
	var side := CheckBox.new()
	side.text = "Skip side columns (narrow margin columns of quotes or notes)"
	side.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.button_pressed = _cfg["skip_side"]
	side.toggled.connect(func(on): _apply("skip_side", on))
	col.add_child(side)

	_section(col, "Tapping")
	_slider(col, "back_zone", "Left area that goes back", 0.15, 0.5, func(v): return "%d%% of width" % int(v * 100))

	_section(col, "Files")
	var where := Label.new()
	where.text = "Papers and cache are stored in:\n" + storage_dir
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.modulate = Color(1, 1, 1, 0.7)
	col.add_child(where)


func _section(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.modulate = Color(0.75, 0.80, 1.0)
	parent.add_child(l)


func _option(parent: Control, key: String, values: Array, names: Array) -> void:
	var ob := OptionButton.new()
	for n in names:
		ob.add_item(n)
	ob.select(max(values.find(_cfg[key]), 0))
	ob.item_selected.connect(func(i): _apply(key, values[i]))
	parent.add_child(ob)


func _slider(parent: Control, key: String, text: String, lo: float, hi: float, fmt: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_l := Label.new()
	name_l.text = text
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_l)
	var value_l := Label.new()
	value_l.text = fmt.call(_cfg[key])
	row.add_child(value_l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.value = _cfg[key]
	s.custom_minimum_size.y = 40
	s.value_changed.connect(func(v):
		value_l.text = fmt.call(v)
		_apply(key, v))
	parent.add_child(s)


func _refresh_swatches() -> void:
	for i in _swatch_buttons.size():
		var sb := StyleBoxFlat.new()
		sb.bg_color = SWATCHES[i]
		sb.set_corner_radius_all(28)
		var selected: bool = SWATCHES[i].is_equal_approx(_cfg["color"])
		sb.set_border_width_all(5 if selected else 0)
		sb.border_color = Color.WHITE
		for state in ["normal", "hover", "pressed", "focus"]:
			_swatch_buttons[i].add_theme_stylebox_override(state, sb)


func _apply(key: String, value: Variant) -> void:
	_cfg[key] = value
	changed.emit(key, value)
