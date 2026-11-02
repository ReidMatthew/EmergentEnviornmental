class_name MenuPanel
extends VBoxContainer
## One panel of a [MenuHost]: a page of controls (it scrolls on its own). Make one, fill it with
## [method section], [method check], [method slider], [method options], [method button],
## [method line] and [method number], and give it to the host with [method MenuHost.add_panel].
## It gets a notch of its own on the host, and can organise its controls into tabs with [method tab].
##
## The controls call back when the player changes them. Nothing here knows what it controls.

## The notch's label, and the pop-out window's title.
@export var title := "Panel"
## Where its notch goes: lowest first, then by title. Panels added in any order stack the same way.
@export var order := 0

# The controls by their text, as get_control finds them.
var _controls := {}
# What reads a control's value and what puts a saved one on it (UI and callback), by the control's text, and the texts of each tab.
var _readers := {}
var _appliers := {}
var _tab_controls := {}
var _tab := ""
# What shows a value that code set (a slider's label as well as its handle), by the control's text.
var _showers := {}
const PAD := 8

var _scroll: ScrollContainer
var _page: VBoxContainer
var _margin: MarginContainer
var _tabs: TabContainer
# Where the controls go: the page, or the current tab's box; and the box that [method end_group] returns to.
var _into: Control
var _base: Control


func _init() -> void:
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	# (The host's drawer has no padding of its own, so the tab bar can sit flush with its edges.)
	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.add_theme_constant_override(&"margin_left", PAD)
	_margin.add_theme_constant_override(&"margin_right", PAD)
	_margin.add_theme_constant_override(&"margin_top", PAD)
	_margin.add_theme_constant_override(&"margin_bottom", PAD)
	_scroll.add_child(_margin)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.add_child(_page)
	_into = _page
	_base = _page


## A control by its text ("Pause", "Threads"). Null if there isn't one.
func get_control(text: String) -> Control:
	return _controls.get(text)


## Shows [param value] on the control called [param text] without calling its callback.
func show_value(text: String, value: Variant) -> void:
	if _showers.has(text):
		_showers[text].call(value)


## Starts a tab: the controls made from here on go in it (the ones before the first tab stay above the tab bar).
## Each tab scrolls on its own.
func tab(text: String) -> void:
	if _tabs == null:
		# (Anything made before the first tab stays above the tab bar, with its padding; with none, there is nothing up there.)
		_scroll.visible = _page.get_child_count() > 0
		_scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_tabs = TabContainer.new()
		_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_tabs.tab_focus_mode = Control.FOCUS_NONE
		_tabs.add_theme_stylebox_override(&"panel", StyleBoxEmpty.new())
		# (The tab bar's own gap to the sides.)
		_tabs.add_theme_constant_override(&"side_margin", 0)
		_style_tabs(_tabs)
		add_child(_tabs)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, PAD)
	pad.add_child(box)
	scroll.add_child(pad)
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, text)
	_base = box
	_into = box
	_tab = text


# The selected tab is lit: a lighter back, bright text and a line of the heading colour under it; the others are dim.
func _style_tabs(tabs: TabContainer) -> void:
	var accent := Color(0.6, 0.8, 1.0)
	var looks := {
		&"tab_selected": [Color(0.17, 0.25, 0.36), true],
		&"tab_hovered": [Color(0.13, 0.17, 0.24), false],
		&"tab_unselected": [Color(0.09, 0.11, 0.15), false],
		&"tab_focus": [Color(0.17, 0.25, 0.36), true],
	}
	for look in looks:
		var box := StyleBoxFlat.new()
		box.bg_color = looks[look][0]
		box.content_margin_left = 10
		box.content_margin_right = 10
		box.content_margin_top = 5
		box.content_margin_bottom = 5
		if looks[look][1]:
			box.border_width_bottom = 2
			box.border_color = accent
		tabs.add_theme_stylebox_override(look, box)
	tabs.add_theme_color_override(&"font_selected_color", Color(1, 1, 1))
	tabs.add_theme_color_override(&"font_hovered_color", Color(0.85, 0.92, 1.0))
	tabs.add_theme_color_override(&"font_unselected_color", Color(0.55, 0.62, 0.72))


## The title of the tab showing ("" for a panel without tabs).
func current_tab() -> String:
	if _tabs == null or _tabs.get_tab_count() == 0:
		return ""
	return _tabs.get_tab_title(_tabs.current_tab)


## The tabs that have controls ("" for the controls outside any).
func tab_titles() -> Array:
	return _tab_controls.keys()


## The values of the controls of a tab ("" for the controls outside any), by the controls' text.
func read_tab(tab_title: String) -> Dictionary:
	var values := {}
	for text in _tab_controls.get(tab_title, []):
		values[text] = _readers[text].call()
	return values


## Puts saved values on the controls of a tab and calls their callbacks, as if the player had set them. Ones the tab does not have are skipped.
func apply_tab(tab_title: String, values: Dictionary) -> void:
	for text in _tab_controls.get(tab_title, []):
		if values.has(text):
			_appliers[text].call(values[text])


func _register(text: String, control: Control, reader: Callable, applier: Callable) -> void:
	_controls[text] = control
	_readers[text] = reader
	_appliers[text] = applier
	if not _tab_controls.has(_tab):
		_tab_controls[_tab] = []
	if not _tab_controls[_tab].has(text):
		_tab_controls[_tab].append(text)


## Starts a group: the controls made until [method end_group] go in the box this returns, to show or hide together.
func begin_group() -> VBoxContainer:
	var group := VBoxContainer.new()
	_into.add_child(group)
	_into = group
	return group


func end_group() -> void:
	if _into != _base:
		_into = _into.get_parent()


## A heading, with a little room above it (not above the first).
func section(text: String) -> Label:
	if _base.get_child_count() > 0:
		var space := Control.new()
		space.custom_minimum_size = Vector2(0, 8)
		_into.add_child(space)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override(&"font_color", Color(0.6, 0.8, 1.0))
	_into.add_child(label)
	_into.add_child(HSeparator.new())
	return label


func label(text: String) -> Label:
	var line := Label.new()
	line.text = text
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_into.add_child(line)
	return line


func check(text: String, value: bool, changed: Callable) -> CheckButton:
	var button := CheckButton.new()
	button.text = text
	button.button_pressed = value
	button.focus_mode = Control.FOCUS_NONE
	button.clip_text = true
	button.toggled.connect(changed)
	_into.add_child(button)
	_showers[text] = func(on: bool) -> void: button.set_pressed_no_signal(on)
	_register(text, button, func() -> bool: return button.button_pressed, func(on: bool) -> void:
		button.set_pressed_no_signal(on)
		changed.call(on))
	return button


## A slider with its value shown. [param format] turns the value into text (none: the number).
## [param on_release], if given, takes the place of [param changed]: called once when the slider is let go.
func slider(text: String, low: float, high: float, step: float, value: float, changed: Callable,
		format := Callable(), on_release := Callable()) -> HSlider:
	var caption := Label.new()
	# (Wrapped, so a long value doesn't widen the panel.)
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_into.add_child(caption)
	var bar := HSlider.new()
	bar.min_value = low
	bar.max_value = high
	bar.step = step
	bar.value = value
	bar.focus_mode = Control.FOCUS_NONE
	bar.custom_minimum_size = Vector2(0, 18)
	_into.add_child(bar)
	var show := func(v: float) -> void:
		caption.text = "%s: %s" % [text, format.call(v) if format.is_valid() else str(snappedf(v, step))]
	show.call(value)
	bar.value_changed.connect(func(v: float) -> void:
		show.call(v)
		if changed.is_valid() and not on_release.is_valid():
			changed.call(v))
	if on_release.is_valid():
		bar.drag_ended.connect(func(moved: bool) -> void:
			if moved:
				on_release.call(bar.value))
	_showers[text] = func(v: float) -> void:
		bar.set_value_no_signal(v)
		show.call(v)
	_register(text, bar, func() -> float: return bar.value, func(v: float) -> void:
		bar.set_value_no_signal(v)
		show.call(v)
		if on_release.is_valid():
			on_release.call(v)
		elif changed.is_valid():
			changed.call(v))
	return bar


## A drop-down of [param items] (strings), [param selected] is an index. [param changed] gets the index.
func options(text: String, items: Array, selected: int, changed: Callable) -> OptionButton:
	var pick := OptionButton.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.clip_text = true
	for item in items:
		pick.add_item(str(item))
	pick.select(selected)
	pick.item_selected.connect(changed)
	_into.add_child(pick)
	_showers[text] = func(index: int) -> void: pick.select(index)
	_register(text, pick, func() -> int: return pick.selected, func(index: int) -> void:
		if index >= 0 and index < pick.item_count:
			pick.select(index)
			changed.call(index))
	return pick


func button(text: String, pressed: Callable) -> Button:
	var push := Button.new()
	push.text = text
	push.focus_mode = Control.FOCUS_NONE
	push.clip_text = true
	push.pressed.connect(pressed)
	_into.add_child(push)
	_controls[text] = push
	return push


## A line of text to type; [param submitted] gets it when Enter is pressed or the field is left.
func line(text: String, value: String, submitted: Callable) -> LineEdit:
	var caption := Label.new()
	caption.text = text
	_into.add_child(caption)
	var edit := LineEdit.new()
	edit.text = value
	edit.text_submitted.connect(submitted)
	edit.focus_exited.connect(func() -> void: submitted.call(edit.text))
	_into.add_child(edit)
	_showers[text] = func(v: String) -> void: edit.text = v
	_register(text, edit, func() -> String: return edit.text, func(v: String) -> void:
		edit.text = v
		submitted.call(v))
	return edit


## A number to type (or step with the arrows).
func number(text: String, low: float, high: float, step: float, value: float, changed: Callable) -> SpinBox:
	var caption := Label.new()
	caption.text = text
	_into.add_child(caption)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.value = value
	spin.value_changed.connect(changed)
	_into.add_child(spin)
	_showers[text] = func(v: float) -> void: spin.set_value_no_signal(v)
	_register(text, spin, func() -> float: return spin.value, func(v: float) -> void:
		spin.set_value_no_signal(v)
		changed.call(v))
	return spin
