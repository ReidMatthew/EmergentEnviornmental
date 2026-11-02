extends Node3D
## Pulls nearby water in while the left button is held: a [WaterSimPush] pulling inwards, put [member distance] metres from the
## camera along the ray through the mouse. The menu's Tools tab sets [member strength] and [member distance].

@export var sim: WaterSim
@export var camera: Camera3D
## How fast the water is pulled in (m/s).
@export_range(0.0, 30.0, 0.1) var strength := 8.0
## How far from the camera the pull is, along the ray through the mouse (m).
@export_range(0.5, 60.0, 0.1) var distance := 8.0
## How far round the pull point water is pulled (m).
@export var radius := 2.5

var _field: WaterSimPush


func _ready() -> void:
	_field = WaterSimPush.new()
	_field.sim = sim
	_field.radius = radius
	# (Quick to take up the pull, so it answers the mouse.)
	_field.strength = 10.0
	_field.enabled = false
	add_child(_field)


func _physics_process(_delta: float) -> void:
	if camera == null:
		return
	var mouse := get_viewport().get_mouse_position()
	global_position = camera.project_ray_origin(mouse) + camera.project_ray_normal(mouse) * distance
	_field.speed = -strength
	_field.radius = radius


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		_set_held(button.pressed)


func _notification(what: int) -> void:
	# (Let go when the window loses the mouse, or the release is never seen.)
	if what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_set_held(false)


func _set_held(on: bool) -> void:
	if _field == null:
		return
	_field.enabled = on
	# The sphere it pulls from, drawn while pulling.
	_field.show_shape = on
