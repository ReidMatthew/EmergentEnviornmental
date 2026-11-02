@tool
@icon("../icon.svg")
class_name WaterSimRecycler
extends WaterSimVolume
## Takes the matter that reaches its shape and puts it back somewhere else: the same
## amount of the same substances, appearing in an [WaterSimEmitter]'s shape (in this box or
## another) with that emitter's velocity. Bodies with a [WaterSimBuoyancy] that float into
## the shape are moved to [member return_point] and stop moving there.
##
## For flowing water that runs in a loop: a stream, a waterfall or a river runs off the end
## of its course into a recycler, and comes back at the start. Nothing is lost or made, so
## the amount of water stays the same however long it runs. The emitter doesn't have to
## emit by itself: its shape and velocity only say where and how matter comes back.

## Matter that is recycled, and bodies that are moved, appear here: matter anywhere in the
## shape, with the emitter's velocity.
@export var inlet: WaterSimEmitter
## Where bodies reappear. Empty: at the inlet.
@export var return_point: Node3D
@export var active := true
## How much of what's in the shape is taken each second (a fraction, like a drain's rate).
## 0: everything that reaches it, at once (the end of a course). More than 0 makes a pump:
## it moves water from a pool to the start of the course at a rate that follows the level.
@export_range(0.0, 20.0, 0.1, "or_greater") var rate := 0.0
## Also move floating bodies.
@export var recycle_bodies := true

## Particles put back in the last physics frame, and the total.
signal recycled(count: int)
signal body_returned(body: RigidBody3D)

var total_recycled := 0
var total_bodies := 0


func _get_configuration_warnings() -> PackedStringArray:
	if inlet == null:
		return ["Set the inlet: an emitter where recycled matter reappears."]
	return []


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not active or inlet == null:
		return
	var from := get_sim()
	if from == null or from.asleep or not from.simulating:
		return
	var into := inlet.get_sim()
	if into == null or into.is_stepping():
		return
	delta = _tick_time(delta)
	if delta <= 0.0:
		return
	var count := 0
	var fraction := 1.0 if rate <= 0.0 else 1.0 - exp(-rate * delta)
	for substance in from.get_substances():
		var taken := from.remove(shape, global_transform, get_extents(), [substance] as Array[WaterSimSubstance], fraction)
		if taken > 0:
			into.wake()
			count += into.spray(inlet.shape, inlet.global_transform, inlet.get_extents(), taken, substance,
					inlet.global_transform.basis.orthonormalized() * inlet.velocity)
	if count > 0:
		total_recycled += count
		recycled.emit(count)
	if recycle_bodies:
		_return_bodies()


func _return_bodies() -> void:
	for node in get_tree().get_nodes_in_group(WaterSimBuoyancy.GROUP):
		var body := node.get_parent() as RigidBody3D
		if body == null or not has_point(body.global_position):
			continue
		var at := (return_point if return_point != null else inlet).global_position
		var t := body.global_transform
		t.origin = at
		# Straight to the physics server: setting the transform of a body in the middle of a
		# physics frame is overridden by the engine's own step.
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t)
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		total_bodies += 1
		body_returned.emit(body)


func _get_shape_color() -> Color:
	return Color(0.9, 0.6, 0.2)
