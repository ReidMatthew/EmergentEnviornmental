extends Node3D
## The spline demo: can the force fields the tools use (push, pull, tornado) hold a river up in the air? A pool of water, and a
## [WaterSimStream]: a chain of vortex fields along a corkscrew path that draws the water up out of the pool, once round, and lets go
## of it at the top, where it falls back. The pull on the water grows along the path.
## T turns the stream on and off, P shows the path and its segments, R refills the pool. Right mouse button turns the camera.

## Height the corkscrew climbs to (m), its radius and the turns it makes.
@export var climb := 8.0
@export var coil_radius := 2.2
@export var turns := 1.0
## The stream's last stretch leaves the coil going up and out by this much (m).
@export var tail := 3.0

@onready var stream: WaterSimStream = $Stream
var _path_lines: MeshInstance3D


func _ready() -> void:
	stream.curve = _make_curve()
	_draw_path(stream.curve)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_T:
		stream.enabled = not stream.enabled
	elif key.keycode == KEY_P:
		_path_lines.visible = not _path_lines.visible
		stream.show_shape = _path_lines.visible
	elif key.keycode == KEY_R:
		$Pool.fill()


# From inside the pool, a rising turn of a helix, then straight on up and out so the water leaves with some height left.
func _make_curve() -> Curve3D:
	var curve := Curve3D.new()
	curve.bake_interval = 0.1
	var steps := 48
	var end := Vector3.ZERO
	for i in steps + 1:
		var t := float(i) / steps
		var angle := TAU * turns * t
		var lift := climb * t
		# (The first stretch goes mostly up, out of the pool, and the helix eases in.)
		var r := coil_radius * smoothstep(0.0, 0.2, t)
		end = Vector3(cos(angle) * r, 0.3 + lift, sin(angle) * r)
		curve.add_point(end)
	# The tail, along the helix's last direction, tilted up.
	var heading := Vector3(-sin(TAU * turns), 0, cos(TAU * turns))
	for i in 1 + int(tail):
		curve.add_point(end + (heading + Vector3.UP * 0.6).normalized() * (i + 1))
	return curve


func _draw_path(curve: Curve3D) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in curve.get_baked_points():
		mesh.surface_add_vertex(p)
	mesh.surface_end()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.8, 0.2)
	_path_lines = MeshInstance3D.new()
	_path_lines.mesh = mesh
	_path_lines.material_override = material
	_path_lines.visible = false
	add_child(_path_lines)
