@icon("../icon.svg")
class_name WaterSimStreamTool
extends WaterSimTool
## Draws a river in the air: hold the button and drag across the water; let go and a [WaterSimStream] runs along the line drawn,
## drawing water up where the line began and rising to [member height] over the first [member rise] metres. The stream stays until
## cleared (the belt's C key); at most [member max_placed] at once, the oldest goes first. [member power] scales its speeds, [member
## reach] its radius.

## The stream's settings at power and reach 1.
@export var radius := 0.7
@export var speed_start := 5.0
@export var speed_end := 12.0
@export var pull := 3.0
@export var swirl := 1.0
@export var strength := 20.0
## How far along the line the stream takes to climb to [member height] (m).
@export var rise := 2.5
## Points of the line are at least this far apart (m).
@export var spacing := 0.4

var _points := PackedVector3Array()
var _line: MeshInstance3D
var _ground := PackedVector3Array()


func _init() -> void:
	label = "Draw stream"
	hint = "drag across the water, let go to make a floating river"
	height = 3.0
	use = Use.PLACE


func _ready() -> void:
	super._ready()
	_line = MeshInstance3D.new()
	_line.mesh = ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.85, 0.3)
	material.no_depth_test = true
	_line.material_override = material
	_line.top_level = true
	add_child(_line)


func aim(point: Vector3, _hit: Object) -> void:
	global_position = point
	if held and (_ground.is_empty() or _ground[-1].distance_to(point) >= spacing):
		_ground.append(point)
		_points = _lift(_ground)
		_draw()


func press(_hit: Object) -> void:
	held = true
	_ground.clear()
	_ground.append(global_position)
	_points = _lift(_ground)


func release() -> void:
	if held and _points.size() >= 3:
		_make_stream(_points)
	held = false
	_ground.clear()
	_points.clear()
	_draw()


func get_settings() -> Array[Dictionary]:
	return [
		{ "name": "Power", "property": "power", "min": 0.0, "max": 4.0, "step": 0.05, "format": "%.2f x" },
		{ "name": "Reach", "property": "reach", "min": 0.25, "max": 4.0, "step": 0.05, "format": "%.2f x" },
		{ "name": "Height", "property": "height", "min": 0.0, "max": 12.0, "step": 0.1, "format": "%.1f m" },
		{ "name": "Rise", "property": "rise", "min": 0.5, "max": 10.0, "step": 0.1, "format": "%.1f m" },
		{ "name": "Pull", "property": "pull", "min": 0.0, "max": 10.0, "step": 0.1, "format": "%.1f m/s" },
		{ "name": "Swirl", "property": "swirl", "min": -6.0, "max": 6.0, "step": 0.1, "format": "%.1f m/s" },
	]


func show_shapes(on: bool) -> void:
	for stream in _placed:
		if is_instance_valid(stream):
			stream.show_shape = on


# The line as drawn, lifted: from the water where it began up to the height over the rise.
func _lift(ground: PackedVector3Array) -> PackedVector3Array:
	var lifted := PackedVector3Array()
	var along := 0.0
	var base := ground[0].y
	for i in ground.size():
		if i > 0:
			along += Vector2(ground[i].x - ground[i - 1].x, ground[i].z - ground[i - 1].z).length()
		var up := height * smoothstep(0.0, maxf(rise, 0.01), along)
		lifted.append(Vector3(ground[i].x, base + up, ground[i].z))
	# (Start a little under the surface, so the mouth is in the water.)
	lifted[0] = lifted[0] + Vector3.DOWN * 0.3
	return lifted


func _make_stream(points: PackedVector3Array) -> void:
	var curve := Curve3D.new()
	curve.bake_interval = 0.1
	for p in points:
		curve.add_point(p)
	var stream := WaterSimStream.new()
	stream.name = "DrawnStream"
	stream.radius = radius * reach
	stream.speed_start = speed_start * power
	stream.speed_end = speed_end * power
	stream.pull = pull
	stream.swirl = swirl
	stream.strength = strength
	stream.curve = curve
	# (In global space: the belt's parent is where the scene is; the curve's points are global.)
	get_parent().add_child(stream)
	stream.global_transform = Transform3D()
	_placed.append(stream)
	while _placed.size() > max_placed:
		var oldest: Node3D = _placed.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


func _draw() -> void:
	var mesh := _line.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if _points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in _points:
		mesh.surface_add_vertex(p)
	mesh.surface_end()
