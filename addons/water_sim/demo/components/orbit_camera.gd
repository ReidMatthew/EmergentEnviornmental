extends Camera3D
## Demo camera: orbits [member target] with the right mouse button (or the arrow keys),
## zooms with the wheel.

@export var target := Vector3.ZERO
## Follows this node instead (the right mouse button still orbits around it).
@export var follow: Node3D
## Above [member follow]'s origin.
@export var follow_height := 1.4
@export var distance := 22.0
@export var min_distance := 4.0
@export var max_distance := 60.0
## Radians.
@export var yaw := 0.6
@export_range(-1.5, -0.05) var pitch := -0.6


func _ready() -> void:
	_place()


func _process(delta: float) -> void:
	if follow != null:
		# The interpolated spot, so the view doesn't stutter behind a physics body.
		target = follow.get_global_transform_interpolated().origin + Vector3.UP * follow_height
		_place()
	var turn := Input.get_axis(&"ui_left", &"ui_right")
	var tilt := Input.get_axis(&"ui_down", &"ui_up")
	if turn != 0.0 or tilt != 0.0:
		yaw -= turn * delta * 1.5
		pitch = clampf(pitch - tilt * delta * 1.0, -1.5, -0.05)
		_place()


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw -= motion.relative.x * 0.005
		pitch = clampf(pitch - motion.relative.y * 0.005, -1.5, -0.05)
		_place()
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance * 0.9, min_distance, max_distance)
			_place()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * 1.1, min_distance, max_distance)
			_place()


func _place() -> void:
	look_at_from_position(target + Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3(0, 0, distance), target)
