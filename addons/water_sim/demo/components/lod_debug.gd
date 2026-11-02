extends PanelContainer
## A level-of-detail debug mode for a demo: a key turns it on and off, which shows a [WaterSimLodView] (each particle coloured
## by its level, see-through) in place of the water's other views, and lists how many particles each level has. The keypad's
## number keys (or the number row's, or a click on a level) hide and show a level, to see what is under it. With the sleeping
## particles grey, - hides and shows them.

## The view to show (it is hidden until the mode is on).
@export var lod_view: WaterSimLodView
## Views hidden while the mode is on (put back as they were after).
@export var hide_while_on: Array[Node] = []
@export var toggle_key := KEY_L

# Keypad 0-4 (matched by where the key is, so with Num Lock off too) and the number row's 0-4.
const _KEYPAD: Array[Key] = [KEY_KP_0, KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4]
const _NUMBERS: Array[Key] = [KEY_0, KEY_1, KEY_2, KEY_3, KEY_4]

var _rows: Array[Button] = []
var _title: Label
var _total: Label
var _was_visible: Array[bool] = []
var _shown := 0.0


## The group the panel is in, so the demo's tools can leave the number keys to it while it is on.
const GROUP := &"water_sim_lod_debug"


func _ready() -> void:
	add_to_group(GROUP)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, 0.78)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override(&"panel", style)
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	_title.text = _title_text()
	box.add_child(_title)
	for level in WaterSimLodView.LEVELS:
		var row := Button.new()
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.icon = _swatch(level)
		row.pressed.connect(_toggle_level.bind(level))
		box.add_child(row)
		_rows.append(row)
	_total = Label.new()
	box.add_child(_total)
	if lod_view != null:
		lod_view.visible = false
	visible = false


func _title_text() -> String:
	var grey := lod_view != null and lod_view.grey_asleep
	var next := "off" if grey else "grey the sleeping"
	var minus := "; -: %s the grey" % ("show" if lod_view.hide_asleep else "hide") if grey else ""
	return "LOD debug  (%s: %s)\nkeypad or 0-4, or click: hide a level%s" % [OS.get_keycode_string(toggle_key), next, minus]


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or lod_view == null:
		return
	if key.keycode == toggle_key:
		# Off, then levels, then levels with the sleeping particles grey, then off.
		if not lod_view.visible:
			_set_on(true)
		elif not lod_view.grey_asleep:
			lod_view.grey_asleep = true
			_title.text = _title_text()
			_shown = 0.0
		else:
			lod_view.grey_asleep = false
			lod_view.hide_asleep = false
			_set_on(false)
		get_viewport().set_input_as_handled()
		return
	if not lod_view.visible:
		return
	if lod_view.grey_asleep and (key.keycode == KEY_MINUS or key.physical_keycode == KEY_KP_SUBTRACT \
			or key.keycode == KEY_KP_SUBTRACT):
		lod_view.hide_asleep = not lod_view.hide_asleep
		_title.text = _title_text()
		_shown = 0.0
		get_viewport().set_input_as_handled()
		return
	var level := _KEYPAD.find(key.physical_keycode)
	if level < 0:
		level = _KEYPAD.find(key.keycode)
	if level < 0:
		level = _NUMBERS.find(key.keycode)
	if level >= 0:
		_toggle_level(level)
		get_viewport().set_input_as_handled()


func _toggle_level(level: int) -> void:
	lod_view.set_level_shown(level, not lod_view.is_level_shown(level))
	_shown = 0.0


func _set_on(on: bool) -> void:
	lod_view.visible = on
	visible = on
	_title.text = _title_text()
	if on:
		_was_visible.clear()
		for node in hide_while_on:
			_was_visible.append(node.visible)
			node.visible = false
	else:
		for i in mini(hide_while_on.size(), _was_visible.size()):
			hide_while_on[i].visible = _was_visible[i]
	_shown = 0.0


func _process(delta: float) -> void:
	if not visible:
		return
	_shown -= delta
	if _shown > 0.0:
		return
	_shown = 0.25
	var counts := lod_view.get_level_counts()
	var total := 0
	for level in WaterSimLodView.LEVELS:
		var count := counts[level] if level < counts.size() else 0
		total += count
		var shown := lod_view.is_level_shown(level)
		var row := _rows[level]
		# (Levels the water doesn't have are left out, unless hidden.)
		row.visible = count > 0 or not shown
		row.text = "LOD %d  %s   %s%s" % [level, WaterSimLodView.LEVEL_NAMES[level], _thousands(count), "" if shown else "   (hidden)"]
		row.modulate = Color.WHITE if shown else Color(1.0, 0.55, 0.55)
	var asleep := lod_view.get_asleep_count()
	_total.text = "total %s" % _thousands(total + asleep)
	if lod_view.grey_asleep:
		_total.text += "   (%s asleep, %s, not counted above)" % [_thousands(asleep), "hidden" if lod_view.hide_asleep else "grey"]


# A square of the level's colour (on a light border, so black shows on the dark panel).
func _swatch(level: int) -> Texture2D:
	var color := lod_view.colors[level] if lod_view != null and level < lod_view.colors.size() else Color.WHITE
	var image := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 0.6))
	image.fill_rect(Rect2i(2, 2, 10, 10), Color(color, 1.0))
	return ImageTexture.create_from_image(image)


func _thousands(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return ("-" if n < 0 else "") + digits + out
