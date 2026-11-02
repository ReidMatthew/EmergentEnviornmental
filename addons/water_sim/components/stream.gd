@tool
@icon("../icon.svg")
class_name WaterSimStream
extends WaterSimComponent
## A river in the air: carries matter along a path and holds it there against gravity. Built from a chain of [WaterSimVortex] fields
## laid along a [Curve3D], each turned so its axis runs along the path: a vortex's lift carries matter along its axis and cancels gravity
## inside it, its pull holds matter to the axis, so the chain is a pipe for the water to ride. The speed grows along the path
## ([member speed_start] to [member speed_end]), so the water is drawn on harder the farther it has come; over the last
## [member release] of the path the pull lets go, and past its end the water flies on and falls.
##
## The path is [member curve], or the curve of a [Path3D] parent when that is empty (in the parent's space). Changing the curve or any
## setting lays the fields out again.

## The path, in this node's space. Empty: the parent [Path3D]'s.
@export var curve: Curve3D:
	set(value):
		if curve != null and curve.changed.is_connected(_queue_rebuild):
			curve.changed.disconnect(_queue_rebuild)
		curve = value
		if curve != null:
			curve.changed.connect(_queue_rebuild)
		_queue_rebuild()
@export var enabled := true:
	set(value):
		enabled = value
		for field in _fields:
			field.enabled = value
## Radius of the stream (m).
@export var radius := 0.8:
	set(value):
		radius = maxf(value, 0.05)
		_queue_rebuild()
## The mouth, at the first point, is this many times wider, narrowing to the stream over [member mouth_length]: it gathers water.
@export var mouth_scale := 2.0:
	set(value):
		mouth_scale = value
		_queue_rebuild()
## Share of the path the mouth narrows over.
@export_range(0.0, 1.0) var mouth_length := 0.15:
	set(value):
		mouth_length = value
		_queue_rebuild()
## Speed along the path at its start and at its end (m/s). At 4 m/s or more a segment cancels gravity entirely.
@export var speed_start := 4.0:
	set(value):
		speed_start = value
		_queue_rebuild()
@export var speed_end := 11.0:
	set(value):
		speed_end = value
		_queue_rebuild()
## How the speed grows: 1 evenly, above 1 it holds low and rises late, below 1 it rises early.
@export_range(0.1, 5.0) var ramp := 1.0:
	set(value):
		ramp = value
		_queue_rebuild()
## Speed towards the path's axis (m/s): what keeps the water in the stream.
@export var pull := 3.0:
	set(value):
		pull = value
		_queue_rebuild()
## Turning about the path (m/s), which twists the stream.
@export var swirl := 1.0:
	set(value):
		swirl = value
		_queue_rebuild()
## How quickly matter takes up the stream's velocity (1/s).
@export_range(0.0, 60.0, 0.1, "or_greater") var strength := 20.0:
	set(value):
		strength = value
		_queue_rebuild()
@export_range(0.0, 1.0) var falloff := 0.25:
	set(value):
		falloff = value
		_queue_rebuild()
## Share of the path, at its end, over which the pull lets go, so the water leaves the stream as a jet rather than piling at its end.
@export_range(0.0, 1.0) var release := 0.15:
	set(value):
		release = value
		_queue_rebuild()
## Draw the segments in game too (they are always drawn in the editor).
@export var show_shape := false:
	set(value):
		show_shape = value
		for field in _fields:
			field.show_shape = value

var _fields: Array[WaterSimVortex] = []
var _queued := false
var _watched: Curve3D


func _ready() -> void:
	_rebuild_now()


func _notification(what: int) -> void:
	# (A Path3D parent's curve can be swapped: follow it.)
	if what == NOTIFICATION_PARENTED:
		_queue_rebuild()


## The path in use: [member curve], else the parent [Path3D]'s.
func get_curve() -> Curve3D:
	if curve != null:
		return curve
	var path := get_parent() as Path3D
	return path.curve if path != null else null


## Lays the fields out along the path again at the end of the frame (changing a setting does this).
func rebuild() -> void:
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _queued or not is_inside_tree():
		return
	_queued = true
	_rebuild_now.call_deferred()


func _rebuild_now() -> void:
	_queued = false
	if not is_inside_tree():
		return
	var path := get_curve()
	_watch(path)
	for field in _fields:
		field.queue_free()
	_fields.clear()
	if path == null or path.point_count < 2:
		return
	var length := path.get_baked_length()
	if length <= 0.0:
		return
	# The curve is in its owner's space: this node's, or the parent path's.
	var to_here := Transform3D() if curve != null else transform.affine_inverse()
	# Segments are a radius apart and twice that long, so each point is in two.
	var spacing := radius
	var count := maxi(int(length / spacing), 1)
	var on := get_sim() if not Engine.is_editor_hint() else null
	for i in count:
		var offset := (float(i) + 0.5) / count * length
		var u := float(i) / maxf(count - 1, 1)
		var here := to_here * path.sample_baked(offset)
		var along := to_here.basis * (path.sample_baked(minf(offset + 0.05, length)) - path.sample_baked(maxf(offset - 0.05, 0.0)))
		along = along.normalized() if along.length() > 1e-5 else Vector3.UP
		var field := WaterSimVortex.new()
		field.sim = on
		field.shape = WaterSim.Shape.CYLINDER
		field.radius = radius * lerpf(mouth_scale, 1.0, clampf(u / maxf(mouth_length, 0.001), 0.0, 1.0))
		field.height = spacing * 2.4
		field.lift_speed = lerpf(speed_start, speed_end, pow(u, ramp))
		var letting_go := clampf((1.0 - u) / maxf(release, 0.001), 0.0, 1.0) if release > 0.0 else 1.0
		field.pull_speed = pull * letting_go
		field.swirl_speed = swirl * letting_go
		field.strength = strength
		field.falloff = falloff
		field.enabled = enabled
		field.show_shape = show_shape
		# Its up axis along the path.
		var side := along.cross(Vector3.RIGHT if absf(along.x) < 0.9 else Vector3.FORWARD).normalized()
		field.transform = Transform3D(Basis(side, along, side.cross(along)), here)
		add_child(field, false, Node.INTERNAL_MODE_BACK)
		_fields.append(field)


# Rebuilds when the curve in use changes (a Path3D parent's is edited in place).
func _watch(path: Curve3D) -> void:
	if _watched == path:
		return
	if _watched != null and _watched.changed.is_connected(_queue_rebuild):
		_watched.changed.disconnect(_queue_rebuild)
	_watched = path
	if path != null and not path.changed.is_connected(_queue_rebuild):
		path.changed.connect(_queue_rebuild)
