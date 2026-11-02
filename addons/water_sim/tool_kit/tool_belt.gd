@icon("../icon.svg")
class_name WaterSimToolBelt
extends Node3D
## Holds [WaterSimTool]s (its children) and works the selected one with the mouse: the tool follows the point under the mouse (the
## nearest of the physics world and the water) and the left button uses it. Keys:
## - 1 to 9 and 0 pick one of the first ten, Q and E step through all of them;
## - Shift + wheel changes the tool's reach, Ctrl + wheel its power, Alt + wheel its height or distance;
## - C clears what the tools left behind (placed copies, drawn streams, toggled tools).
## Writes the tool list into [member help], if set. A menu can list the tools ([method get_tools]), follow [signal selected] and
## call [method select].

signal selected(index: int)

@export var camera: Camera3D
## Shows the tool list and the keys.
@export var help: Label
## Number keys, Q and E pick tools.
@export var keys := true
## Shift, Ctrl and Alt with the wheel change the selected tool.
@export var wheel := true
## Clears what the tools left (0: no key).
@export var clear_key := KEY_C
## Farthest the mouse's ray looks (m).
@export var ray_length := 300.0

var _tools: Array[Node3D] = []
var _selected := 0


func _ready() -> void:
	_gather()
	select.call_deferred(0)


## The tools, in their order.
func get_tools() -> Array[Node3D]:
	# (A menu made before this belt was ready asks first.)
	_gather()
	return _tools


func _gather() -> void:
	if not _tools.is_empty():
		return
	for child in get_children():
		if child.has_method(&"aim"):
			_tools.append(child)
			if child.has_signal(&"settings_changed"):
				child.settings_changed.connect(_write_help)


func get_selected() -> int:
	return _selected


## Puts the selected tool away and takes up another.
func select(index: int) -> void:
	if _tools.is_empty():
		return
	index = posmod(index, _tools.size())
	_tools[_selected].release()
	_selected = index
	# The selected tool's shapes show where it acts.
	for i in _tools.size():
		if _tools[i].has_method(&"show_shapes"):
			_tools[i].show_shapes(i == _selected)
	_write_help()
	selected.emit(index)


## Clears what every tool left behind.
func clear() -> void:
	for tool in _tools:
		if tool.has_method(&"clear_placed"):
			tool.clear_placed()


func _physics_process(_delta: float) -> void:
	if _tools.is_empty() or camera == null:
		return
	var mouse := get_viewport().get_mouse_position()
	_aim(_tools[_selected], camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))


func _unhandled_input(event: InputEvent) -> void:
	if _tools.is_empty():
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		_key(key)
		return
	var button := event as InputEventMouseButton
	if button == null:
		return
	var tool := _tools[_selected]
	if button.button_index == MOUSE_BUTTON_LEFT and camera != null:
		if button.pressed:
			var hit := _aim(tool, camera.project_ray_origin(button.position), camera.project_ray_normal(button.position))
			tool.press(hit.collider)
		else:
			tool.release()
	elif wheel and button.pressed and (button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		var step := 1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if button.shift_pressed and &"reach" in tool:
			tool.reach = snappedf(tool.reach * pow(1.1, step), 0.01)
		elif button.ctrl_pressed and &"power" in tool:
			tool.power = snappedf(tool.power * pow(1.1, step), 0.01)
		elif button.alt_pressed and &"aim_mode" in tool:
			if tool.aim_mode == WaterSimTool.Aim.SURFACE:
				tool.height += step * 0.25
			else:
				tool.distance += step * 0.5
		else:
			return
		get_viewport().set_input_as_handled()


func _key(key: InputEventKey) -> void:
	if not keys:
		return
	# (The number keys hide and show levels while the LOD debug mode is on.)
	for panel: CanvasItem in get_tree().get_nodes_in_group(&"water_sim_lod_debug"):
		if panel.visible:
			return
	var index := -1
	if key.keycode >= KEY_0 and key.keycode <= KEY_9:
		# 1 to 9, then 0 for a tenth.
		index = 9 if key.keycode == KEY_0 else key.keycode - KEY_1
	elif key.keycode == KEY_Q:
		index = posmod(_selected - 1, _tools.size())
	elif key.keycode == KEY_E:
		index = posmod(_selected + 1, _tools.size())
	elif clear_key != 0 and key.keycode == clear_key:
		clear()
		get_viewport().set_input_as_handled()
		return
	if index >= 0 and index < _tools.size():
		select(index)
		get_viewport().set_input_as_handled()


# Points a tool along a ray: what it hits, its normal, and the ray itself.
func _aim(tool: Node3D, from: Vector3, direction: Vector3) -> Dictionary:
	var hit := _cast(from, direction)
	if &"ray_origin" in tool:
		tool.ray_origin = from
		tool.ray_direction = direction
		tool.surface_normal = hit.normal
	tool.aim(hit.point, hit.collider)
	return hit


# The nearest of the physics world and the matter along a ray.
func _cast(from: Vector3, direction: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * ray_length)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var point: Vector3 = result.position if not result.is_empty() else from + direction * 30.0
	var normal: Vector3 = result.normal if not result.is_empty() else Vector3.UP
	var collider: Object = result.get("collider")
	# Matter (in a box or still water) in front of the ground counts as a surface to aim at.
	var wet: Variant = WaterSim.raycast_at(get_tree(), from, direction, from.distance_to(point), 400.0)
	if wet != null:
		return { "point": wet, "normal": Vector3.UP, "collider": null }
	return { "point": point, "normal": normal, "collider": collider }


func _write_help() -> void:
	if help == null or _tools.is_empty():
		return
	var lines := PackedStringArray()
	for i in _tools.size():
		var tool := _tools[i]
		var key_name := str((i + 1) % 10) if i < 10 else " "
		var line := "%s %s  %s" % [">" if i == _selected else " ", key_name, tool.label]
		if i == _selected:
			if tool.hint != "":
				line += "  -  " + tool.hint
			if &"power" in tool:
				line += "   (power %.2f, reach %.2f)" % [tool.power, tool.reach]
		lines.append(line)
	lines.append("")
	var keys_line := "Left mouse: use    Q / E: next tool    Shift / Ctrl / Alt + wheel: reach / power / height"
	if clear_key != 0:
		keys_line += "    %s: clear" % OS.get_keycode_string(clear_key)
	lines.append(keys_line)
	lines.append("Right mouse / arrows: orbit    Wheel: zoom")
	help.text = "\n".join(lines)
