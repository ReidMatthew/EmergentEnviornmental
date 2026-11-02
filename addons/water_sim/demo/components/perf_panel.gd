extends PanelContainer
## Where a demo's frame goes, in ms and as a share of it, averaged over the last two seconds: the frame, the game's thread (its
## scripts and physics, then the renderer's CPU work), the simulation's step (on threads of its own, beside the game's) and
## the GPU. The one near 100% is what holds the frame rate; with all of them well under it the frame is waiting for v-sync or
## the frame cap, and the V-Sync button turns that off so the frame rate shows the real cost. "Baseline" (or K) measures the
## numbers to compare with, averaged over five seconds: a column then shows each one's change since, green where it got faster.

## The box to report first (the others the scene has follow).
@export var sim: WaterSim
@export var baseline_key := KEY_K
## Seconds the numbers are averaged over (the last this many, so a change shows in full this long after it).
@export var window := 2.0
## Seconds between updates.
@export var refresh := 0.25
## Seconds the baseline is averaged over, from when it is asked for.
@export var baseline_seconds := 5.0

# Lanes (in the order shown): the name, and what its % is of (the sim's step has to be done by the next step, so its budget
# is the frame or the step interval, whichever is longer).
const _FRAME := 0
const _CPU := 1
const _MAIN := 2
const _RENDER := 3
const _SIM := 4
const _GPU := 5
const _NAMES := ["Frame", "CPU  game thread", "      scripts + physics", "      render", "CPU  sim step (own threads)",
		"GPU  render"]
const _GOOD := Color(0.5, 0.95, 0.55)
const _BAD := Color(1.0, 0.5, 0.45)
const _DIM := Color(1, 1, 1, 0.5)

# The interval being summed (refresh long), and the ones before it still in the window: {sums, frames, seconds}.
var _sums: Array[float] = []
var _frames := 0
var _elapsed := 0.0
var _intervals: Array[Dictionary] = []
var _last_usec := 0
var _shown: Array[float] = []
var _baseline: Array[float] = []
# A baseline being measured: the sums so far, over how many frames, and the seconds still to go (0: not measuring).
var _base_sums: Array[float] = []
var _base_frames := 0
var _base_left := 0.0
var _ms: Array[Label] = []
var _share: Array[Label] = []
var _change: Array[Label] = []
var _bound: Label
var _boxes: Label
var _vsync: Button
var _base_button: Button


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, 0.78)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override(&"panel", style)
	var box := VBoxContainer.new()
	add_child(box)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override(&"h_separation", 14)
	box.add_child(grid)
	# (The baseline column is emptied, not hidden, while there is none: a grid leaves hidden cells out and the rest move up.)
	for lane in _NAMES.size():
		var name_label := _cell(grid, _NAMES[lane], false)
		if lane == _MAIN or lane == _RENDER:
			name_label.modulate = Color(1, 1, 1, 0.75)
		_share.append(_cell(grid, "", true))
		_ms.append(_cell(grid, "", true))
		_change.append(_cell(grid, "", true))
	_bound = Label.new()
	box.add_child(_bound)
	_boxes = Label.new()
	_boxes.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_boxes)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_base_button = _button(buttons, "", _toggle_baseline)
	_update_base_text()
	_vsync = _button(buttons, "", _toggle_vsync)
	_vsync.toggle_mode = true
	_update_vsync_text()
	_sums.resize(_NAMES.size())
	_sums.fill(0.0)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_last_usec = Time.get_ticks_usec()


func _exit_tree() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)


func _cell(grid: GridContainer, text: String, right: bool) -> Label:
	var label := Label.new()
	label.text = text
	if right:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.custom_minimum_size.x = 52
	grid.add_child(label)
	return label


func _button(parent: Control, text: String, pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override(&"font_size", 11)
	button.pressed.connect(pressed)
	parent.add_child(button)
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == baseline_key:
		_toggle_baseline()
		get_viewport().set_input_as_handled()


# No baseline: measure one (over baseline_seconds); measuring or one kept: drop it.
func _toggle_baseline() -> void:
	if not _baseline.is_empty() or _base_left > 0.0:
		_baseline.clear()
		_base_left = 0.0
	else:
		_base_sums.resize(_NAMES.size())
		_base_sums.fill(0.0)
		_base_frames = 0
		_base_left = baseline_seconds
	for column in _change:
		column.text = ""
	_update_base_text()
	_show()


func _update_base_text() -> void:
	var key := OS.get_keycode_string(baseline_key)
	if _base_left > 0.0:
		_base_button.text = "Measuring baseline %.0f s (%s: cancel)" % [ceilf(_base_left), key]
	elif not _baseline.is_empty():
		_base_button.text = "Clear baseline (%s)" % key
	else:
		_base_button.text = "Baseline (%s)" % key


func _toggle_vsync() -> void:
	var on := DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if on else DisplayServer.VSYNC_ENABLED)
	_update_vsync_text()


func _update_vsync_text() -> void:
	var on := DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	_vsync.text = "V-Sync on" if on else "V-Sync off"
	_vsync.set_pressed_no_signal(on)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_usec) / 1000.0
	_last_usec = now
	var vp := get_viewport().get_viewport_rid()
	# (These monitors are in ms in 4.7, though the docs say seconds.)
	var main_ms := Performance.get_monitor(Performance.TIME_PROCESS) \
			+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var render_ms := RenderingServer.viewport_get_measured_render_time_cpu(vp)
	var sample: Array[float] = [frame_ms, main_ms + render_ms, main_ms, render_ms, _sim_ms(),
			RenderingServer.viewport_get_measured_render_time_gpu(vp)]
	for lane in _NAMES.size():
		_sums[lane] += sample[lane]
	_frames += 1
	_elapsed += frame_ms / 1000.0
	if _base_left > 0.0:
		for lane in _NAMES.size():
			_base_sums[lane] += sample[lane]
		_base_frames += 1
		_base_left -= frame_ms / 1000.0
		if _base_left <= 0.0:
			_baseline.resize(_NAMES.size())
			for lane in _NAMES.size():
				_baseline[lane] = _base_sums[lane] / _base_frames
		_update_base_text()
	if _elapsed < refresh:
		return
	# The interval just ended joins the ones kept, and those past the window drop out.
	_intervals.append({"sums": _sums.duplicate(), "frames": _frames, "seconds": _elapsed})
	var seconds := 0.0
	for i in range(_intervals.size() - 1, -1, -1):
		if seconds >= window:
			_intervals = _intervals.slice(i + 1)
			break
		seconds += _intervals[i].seconds
	var frames := 0
	_shown.resize(_NAMES.size())
	_shown.fill(0.0)
	for interval: Dictionary in _intervals:
		frames += interval.frames
		for lane in _NAMES.size():
			_shown[lane] += interval.sums[lane]
	for lane in _NAMES.size():
		_shown[lane] /= maxi(frames, 1)
	_sums.fill(0.0)
	_frames = 0
	_elapsed = 0.0
	_show()


# The step and the point build after it (both on the box's own thread) of every box that is awake, as of the last step done.
func _sim_ms() -> float:
	var total := 0.0
	for box: WaterSim in get_tree().get_nodes_in_group(WaterSim.GROUP):
		if box.asleep:
			continue
		var stats := box.get_stats()
		total += float(stats.get("step_msec", 0.0)) + float(stats.get("buffers_msec", 0.0))
	return total


func _show() -> void:
	if _shown.is_empty():
		return
	var frame := maxf(_shown[_FRAME], 0.001)
	var step_ms := frame
	if sim != null and sim.fixed_step > 0.0:
		step_ms = maxf(frame, sim.fixed_step * 1000.0)
	for lane in _NAMES.size():
		var ms := _shown[lane]
		_ms[lane].text = "%.2f" % ms
		if lane == _FRAME:
			_share[lane].text = "%d fps" % roundi(1000.0 / frame)
			_share[lane].modulate = Color.WHITE
		else:
			var share := ms / (step_ms if lane == _SIM else frame)
			_share[lane].text = "%d%%" % roundi(share * 100.0)
			_share[lane].modulate = _BAD if share > 0.9 else Color.WHITE
		if not _baseline.is_empty():
			# From the times as shown (to 0.01 ms), so a lane that rounds to the same time shows no change, and one under
			# 0.01 ms has no % (a few thousandths of a ms either way would be a swing of 100%).
			var before := snappedf(_baseline[lane], 0.01)
			var label := _change[lane]
			var change := snappedf(ms, 0.01) - before
			var relative := change / before if before > 0.0 else 0.0
			label.text = "%+.2f" % change
			if before > 0.0:
				label.text += " (%+d%%)" % roundi(relative * 100.0)
			label.modulate = _DIM if absf(relative) < 0.03 or absf(change) < 0.005 else (_GOOD if change < 0.0 else _BAD)
	_bound.text = "Bound by: %s" % _bottleneck(frame, step_ms)
	_boxes.text = _box_text()


func _bottleneck(frame: float, step_ms: float) -> String:
	var lanes := {"game thread (CPU)": _shown[_CPU] / frame, "sim step (CPU)": _shown[_SIM] / step_ms,
			"GPU": _shown[_GPU] / frame}
	var top := ""
	for lane: String in lanes:
		if top == "" or lanes[lane] > lanes[top]:
			top = lane
	if lanes[top] >= 0.85:
		return top
	var capped := DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED or Engine.max_fps > 0
	return "%s (busiest: %s, %d%%)" % ["v-sync / frame cap" if capped else "nothing measured", top,
			roundi(lanes[top] * 100.0)]


func _box_text() -> String:
	var parts := PackedStringArray()
	var boxes: Array = get_tree().get_nodes_in_group(WaterSim.GROUP)
	if sim != null and sim in boxes:
		boxes.erase(sim)
		boxes.push_front(sim)
	for box: WaterSim in boxes:
		if box.asleep:
			parts.append("%s: asleep (%s particles)" % [box.name, _thousands(box.get_fine_particle_count())])
			continue
		var stats := box.get_stats()
		if stats.is_empty():
			continue
		# Fine-equivalent count: what the water amounts to, not what the levels of detail carry.
		parts.append("%s: %s particles, %d of %d threads" % [box.name, _thousands(box.get_fine_particle_count()), int(stats.get("threads_used", 1)), box.get_solver().get_threads()])
	return "\n".join(parts)


func _thousands(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return ("-" if n < 0 else "") + digits + out
