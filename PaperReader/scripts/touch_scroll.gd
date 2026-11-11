extends RefCounted
## Lets a ScrollContainer be dragged up/down with a finger, also when the drag
## starts on one of its buttons, without that drag counting as a tap.

const DRAG_DISTANCE := 16.0


static func setup(scroll: ScrollContainer) -> void:
	scroll.set_meta("dragged", false)
	scroll.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			scroll.set_meta("press_pos", e.global_position)
			scroll.set_meta("press_scroll", scroll.scroll_vertical)
			scroll.set_meta("dragged", false)
		elif e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
			var start: Vector2 = scroll.get_meta("press_pos", e.global_position)
			var dy: float = e.global_position.y - start.y
			if absf(dy) > DRAG_DISTANCE:
				scroll.set_meta("dragged", true)
			if scroll.get_meta("dragged", false):
				# Move the list with the finger.
				scroll.scroll_vertical = int(scroll.get_meta("press_scroll", 0)) - int(dy)
				scroll.accept_event())


## Adds a button whose tap is ignored if it was the start of a drag.
static func connect_button(scroll: ScrollContainer, button: BaseButton, on_tap: Callable) -> void:
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	button.pressed.connect(func():
		if not scroll.get_meta("dragged", false):
			on_tap.call())
