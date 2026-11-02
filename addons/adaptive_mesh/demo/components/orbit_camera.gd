extends Camera3D
## Demo camera: orbits [member target] with the right mouse button, zooms with the wheel
## (the wheel with Ctrl held is left for the dig tool's brush size).

@export var target := Vector3.ZERO
@export var distance := 24.0
@export var min_distance := 5.0
@export var max_distance := 80.0
## Radians.
@export var yaw := 0.6
@export_range(-1.5, -0.05) var pitch := -0.6


func _ready() -> void:
	_place()


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw -= motion.relative.x * 0.005
		pitch = clampf(pitch - motion.relative.y * 0.005, -1.5, -0.05)
		_place()
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and not button.ctrl_pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance * 0.9, min_distance, max_distance)
			_place()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * 1.1, min_distance, max_distance)
			_place()


func _place() -> void:
	look_at_from_position(target + Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3(0, 0, distance), target)
