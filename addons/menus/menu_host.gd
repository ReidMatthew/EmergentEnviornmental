class_name MenuHost
extends CanvasLayer
## A menu that slides out from the right of the screen (the [ or ] key opens and closes it). Panels
## ([MenuPanel]) are added to it by whatever wants a control panel; each one gets its own
## notch (labelled with its title) on the edge of the screen, and a click on it opens that panel.
##
## Drop [code]menus.tscn[/code] into a scene. No plugin and no autoload: whatever has a panel finds the
## host with [method find] and skips its panel when there is none.
##
## [codeblock]
## var host := MenuHost.find(get_tree())
## if host != null:
##     var panel := MenuPanel.new()
##     panel.title = "Water"
##     panel.slider("Gravity", 1, 40, 0.1, 9.8, func(v): sim.gravity.y = -v)
##     host.add_panel(panel)
## [/codeblock]

## The keys that open and close the menu: [ or ] (none: no key).
@export var toggle_keys: Array[Key] = [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]
## How wide the menu is.
@export var width := 340.0
@export var open_on_start := false
## The notches at the top right, one per panel (without them, only the keys open the menu).
@export var show_button := true
## The file the settings are saved to and loaded from (none: no saving, and no Save button). Each tab of each panel has a section
## of its own, "Panel / Tab"; the Save button at the bottom right writes the section of the tab showing and nothing else.
@export_global_file("*.cfg") var config_path := "user://menus.cfg"
## How the menu looks; none: the project's theme.
@export var look: Theme

## The menu slid open or shut.
signal toggled(open: bool)

const GROUP := &"menus_host"
const MARGIN := 0.0
# A notch's size and the gap between them; they ride along on the drawer's edge.
const NOTCH_HEIGHT := 24.0
const NOTCH_FONT := 11
const NOTCH_PAD := 3.0
const NOTCH_GAP := 4.0

var _drawer: PanelContainer
var _notches: VBoxContainer
var _tabs: Control  # holds the panels, one visible at a time
var _current: MenuPanel
var _save: Button
var _saved: Label
var _saved_fade: Tween
var _notch_width := 20.0  # the widest title, plus a little
var _empty: Label
var _open := false
var _mouse_before := Input.MOUSE_MODE_VISIBLE
var _slide: Tween


## The menu of this scene tree; null if there is none.
static func find(tree: SceneTree) -> MenuHost:
	return tree.get_first_node_in_group(GROUP) as MenuHost


func _enter_tree() -> void:
	add_to_group(GROUP)
	layer = 100


func _ready() -> void:
	_build()
	if open_on_start:
		set_open(true)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and toggle_keys.has(key.keycode):
		set_open(not _open)
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _open


## Gives the menu a panel: a notch of its own. A panel with the same title is not added twice.
func add_panel(panel: MenuPanel) -> void:
	_build()
	for other in get_panels():
		if other.title == panel.title:
			push_warning("MenuHost: there is a panel called '%s' already." % panel.title)
			return
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tabs.add_child(panel)
	# (Sorted by order, then title, so the notches stack the same whatever order the add-ons came in.)
	var sorted := get_panels()
	sorted.sort_custom(func(a: MenuPanel, b: MenuPanel) -> bool:
		return a.order < b.order or (a.order == b.order and a.title.naturalnocasecmp_to(b.title) < 0))
	for i in sorted.size():
		_tabs.move_child(sorted[i], i)
	_refresh()
	# (Its controls are made right after this call, so they are there when this runs.)
	_load_panel.call_deferred(panel)


func remove_panel(panel: MenuPanel) -> void:
	panel.queue_free()
	_refresh.call_deferred()


## Every panel.
func get_panels() -> Array[MenuPanel]:
	var found: Array[MenuPanel] = []
	if _tabs != null:
		for child in _tabs.get_children():
			if child is MenuPanel and not child.is_queued_for_deletion():
				found.append(child)
	return found


## Opens the menu on this panel; a click on the notch of the panel already showing shuts it.
func show_panel(panel: MenuPanel) -> void:
	if _open and panel == _current:
		set_open(false)
		return
	_current = panel
	set_open(true)
	_refresh()


func set_open(open: bool) -> void:
	if open == _open:
		return
	_open = open
	# A game that holds the mouse gets it back to click with, and has it taken again on closing.
	if open:
		_mouse_before = Input.mouse_mode
		if _mouse_before == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_drawer.visible = true
	elif _mouse_before == Input.MOUSE_MODE_CAPTURED and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _slide != null:
		_slide.kill()
	_slide = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide.tween_property(_drawer, "offset_left", _left(open), 0.2)
	_slide.tween_property(_drawer, "offset_right", _right(open), 0.2)
	if _notches != null:
		_slide.tween_property(_notches, "offset_left", _left(open) - _notch_width, 0.2)
		_slide.tween_property(_notches, "offset_right", _left(open), 0.2)
	if not open:
		_slide.chain().tween_callback(func() -> void: _drawer.visible = false)
	_refresh()
	toggled.emit(open)


func _build() -> void:
	if _drawer != null:
		return
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_drawer = PanelContainer.new()
	_drawer.theme = look
	_drawer.visible = false
	_drawer.anchor_left = 1.0
	_drawer.anchor_right = 1.0
	_drawer.anchor_top = 0.0
	_drawer.anchor_bottom = 1.0
	_drawer.offset_top = MARGIN
	_drawer.offset_bottom = -MARGIN
	_drawer.offset_left = _left(false)
	_drawer.offset_right = _right(false)
	_drawer.add_theme_stylebox_override(&"panel", _backing(0.85, 0))
	root.add_child(_drawer)
	if show_button:
		_notches = VBoxContainer.new()
		_notches.add_theme_constant_override(&"separation", int(NOTCH_GAP))
		_notches.anchor_left = 1.0
		_notches.anchor_right = 1.0
		_notches.offset_top = MARGIN + 12.0
		_notches.offset_left = -_notch_width
		_notches.offset_right = 0.0
		_notches.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(_notches)
	var column := VBoxContainer.new()
	_drawer.add_child(column)
	_empty = Label.new()
	_empty.text = " No panels."
	column.add_child(_empty)
	_tabs = Control.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_tabs)
	var pad := MarginContainer.new()
	pad.visible = config_path != ""
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 6)
	column.add_child(pad)
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	pad.add_child(bottom)
	_saved = Label.new()
	_saved.add_theme_font_size_override(&"font_size", 11)
	_saved.add_theme_color_override(&"font_color", Color(0.6, 0.8, 1.0))
	_saved.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saved.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_saved.clip_text = true
	bottom.add_child(_saved)
	_save = Button.new()
	_save.text = "Save"
	_save.focus_mode = Control.FOCUS_NONE
	_save.tooltip_text = "Saves the settings of the tab showing"
	_save.pressed.connect(save_tab)
	bottom.add_child(_save)


## Saves the settings of the tab showing (of the panel showing): its section of the config file, and no other.
func save_tab() -> void:
	if config_path == "" or _current == null:
		return
	var tab := _current.current_tab()
	var section := _section(_current, tab)
	var config := ConfigFile.new()
	config.load(config_path)
	if config.has_section(section):
		config.erase_section(section)
	var values := _current.read_tab(tab)
	for text in values:
		config.set_value(section, text, values[text])
	var failed := config.save(config_path) != OK
	_say("Could not save %s" % section if failed else "Saved %s" % section)


# A panel's saved settings go on its controls, tab by tab.
func _load_panel(panel: MenuPanel) -> void:
	if config_path == "" or not is_instance_valid(panel):
		return
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return
	for tab in panel.tab_titles():
		var section := _section(panel, tab)
		if not config.has_section(section):
			continue
		var values := {}
		for key in config.get_section_keys(section):
			values[key] = config.get_value(section, key)
		panel.apply_tab(tab, values)


func _section(panel: MenuPanel, tab: String) -> String:
	return panel.title if tab == "" else "%s / %s" % [panel.title, tab]


# A line next to the Save button, gone after a moment.
func _say(text: String) -> void:
	_saved.text = text
	if _saved_fade != null:
		_saved_fade.kill()
	_saved_fade = create_tween()
	_saved_fade.tween_interval(2.5)
	_saved_fade.tween_callback(func() -> void: _saved.text = "")


# One notch per panel, the current one lit; only the current panel shows.
func _refresh() -> void:
	if _tabs == null:
		return
	var panels := get_panels()
	if not panels.has(_current):
		_current = panels[0] if not panels.is_empty() else null
	_tabs.visible = _current != null
	_empty.visible = _current == null
	for panel in panels:
		panel.visible = panel == _current
	if _notches == null:
		return
	for child in _notches.get_children():
		_notches.remove_child(child)
		child.queue_free()
	var font := ThemeDB.fallback_font
	_notch_width = 0.0
	for panel in panels:
		_notch_width = maxf(_notch_width, font.get_string_size(panel.title, HORIZONTAL_ALIGNMENT_LEFT, -1, NOTCH_FONT).x)
	_notch_width += NOTCH_PAD * 2.0
	# (Where the notches rest: shut or open, the widest title decides how far left of the edge they start.)
	_notches.offset_left = _left(_open) - _notch_width
	for panel in panels:
		_notches.add_child(_notch(panel))


func _notch(panel: MenuPanel) -> Button:
	var notch := Button.new()
	notch.text = panel.title
	notch.custom_minimum_size = Vector2(0.0, NOTCH_HEIGHT)
	notch.add_theme_font_size_override(&"font_size", NOTCH_FONT)
	notch.focus_mode = Control.FOCUS_NONE
	var lit := _open and panel == _current
	for side in [&"normal", &"hover", &"pressed", &"focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.08, 0.1, 0.14, 0.85)
		if lit:
			box.bg_color = Color(0.18, 0.28, 0.42, 0.95)
		elif side == &"hover":
			box.bg_color = Color(0.14, 0.18, 0.25, 0.9)
		# (Round on the screen's side only: the right side joins the drawer.)
		box.corner_radius_top_left = 6
		box.corner_radius_bottom_left = 6
		box.content_margin_left = NOTCH_PAD
		box.content_margin_right = NOTCH_PAD
		box.content_margin_top = 0
		box.content_margin_bottom = 0
		notch.add_theme_stylebox_override(side, box)
	notch.pressed.connect(show_panel.bind(panel))
	return notch


func _left(open: bool) -> float:
	return -(width + MARGIN) if open else 0.0


func _right(open: bool) -> float:
	return -MARGIN if open else width + MARGIN


func _backing(alpha: float, corner: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, alpha)
	style.set_content_margin_all(0)
	style.set_corner_radius_all(corner)
	return style
