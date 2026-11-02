@tool
@icon("../icon.svg")
class_name WaterSimBuoyancy
extends WaterSimComponent
## Floats a RigidBody3D on a [WaterSim] and lets the current carry it: add it as a child of
## the body. Each of a few points on the body pushes up with the weight of the matter it
## displaces and drags the body along with the flow there. Pair it with a
## [WaterSimCollider] so the body also pushes the water.
##
## The body's collider keeps matter out of the body, so the matter at a point is read just
## outside the body, level with it (four samples around it): how deep the point would be.

## Points to sample, in the body's space. Empty: the eight corners of half the body's
## collision box (good enough for most rough shapes).
@export var points: PackedVector3Array = []
## The body's volume in m^3, shared by the points. 0: from the collision shapes' boxes.
@export var volume := 0.0
## How strongly the flow drags the body along (per second, scaled by how deep it is).
@export var drag := 3.0
## How strongly the flow damps the body's spin.
@export var angular_drag := 1.0

## Group every buoyancy joins (see [WaterSimRecycler]).
const GROUP := &"water_sim_floaters"

var _points: PackedVector3Array = []
var _volume := 0.0
var _reach := 0.0
# The last samples, density and flow a point (reused while the box's step runs).
var _sampled: Array = []


func _get_configuration_warnings() -> PackedStringArray:
	if not get_parent() is RigidBody3D:
		return ["Add this as a child of a RigidBody3D."]
	return []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	_setup.call_deferred()


func _physics_process(_delta: float) -> void:
	var body := get_parent() as RigidBody3D
	if Engine.is_editor_hint() or body == null or _points.is_empty():
		return
	var on := get_sim()
	var g := on.gravity if on != null else Vector3(0, -9.8, 0)
	var tree := get_tree()
	var share := _volume / _points.size()
	var submerged := 0.0
	# While the box's step is still running (sampling would make the frame wait for it), the water is as it was last tick.
	var fresh := on == null or not on.is_stepping() or _sampled.size() != _points.size() * 2
	if fresh:
		_sampled.resize(_points.size() * 2)
	for i in _points.size():
		var point := body.global_transform * _points[i]
		var density := 0.0
		var flow := Vector3.ZERO
		if fresh:
			for side in [Vector3(_reach, 0, 0), Vector3(-_reach, 0, 0), Vector3(0, 0, _reach), Vector3(0, 0, -_reach)]:
				density += WaterSim.sample_density_at(tree, point + side) * 0.25
				flow += WaterSim.sample_velocity_at(tree, point + side) * 0.25
			_sampled[i * 2] = density
			_sampled[i * 2 + 1] = flow
		else:
			density = _sampled[i * 2]
			flow = _sampled[i * 2 + 1]
		if density <= 1.0:
			continue
		var depth := clampf(density / 1000.0, 0.0, 1.0)
		submerged += depth / _points.size()
		var offset := point - body.global_position
		body.apply_force(-g * density * share, offset)
		var here := body.linear_velocity + body.angular_velocity.cross(offset)
		body.apply_force((flow - here) * (body.mass / _points.size()) * drag * depth, offset)
	if submerged > 0.0:
		body.apply_torque(-body.angular_velocity * body.mass * angular_drag * submerged)


func _setup() -> void:
	var body := get_parent() as RigidBody3D
	if body == null:
		return
	var box := AABB()
	var first := true
	for child in body.get_children():
		var node := child as CollisionShape3D
		if node == null or node.shape == null:
			continue
		var shape_box: AABB = node.transform * node.shape.get_debug_mesh().get_aabb()
		box = shape_box if first else box.merge(shape_box)
		first = false
	_points = points
	if _points.is_empty():
		var centre := box.get_center()
		var quarter := box.size * 0.25
		for i in 8:
			_points.append(centre + Vector3(quarter.x if i & 1 else -quarter.x,
					quarter.y if i & 2 else -quarter.y, quarter.z if i & 4 else -quarter.z))
	_volume = volume if volume > 0.0 else box.size.x * box.size.y * box.size.z
	_reach = maxf(box.size.x, box.size.z) * 0.5 + 0.5
