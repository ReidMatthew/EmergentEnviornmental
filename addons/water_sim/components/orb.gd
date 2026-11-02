@tool
@icon("../icon.svg")
class_name WaterSimOrb
extends WaterSimComponent
## Gathers matter into a ball round this node and holds it there, in the air if need be: a gathering or levitation spell, a water
## shield. A [WaterSimPush] pulls in at one speed everywhere in its sphere, so matter at its centre overshoots and sloshes; this is
## [member layers] of them, nested, each pulling more gently than the one round it, so the pull grows with the distance from the centre
## like a spring and the matter settles into a ball. Strong enough ([member strength]), it holds the ball against gravity.
##
## An orb over a pool that reaches into it only piles the pool up into a mound. With [member feed_length], a column under it (a
## [WaterSimVortex] lifting along it) draws matter up into it from that far below until the ball is full (the matter a little over its
## centre is [member full_density]), then stops, so the ball parts from what is below and hangs on its own; when it thins, the column
## starts again.

@export var enabled := true:
	set(value):
		enabled = value
		for field in _fields:
			field.enabled = value
## How far out matter is gathered from (m).
@export var radius := 2.5:
	set(value):
		radius = maxf(value, 0.1)
		_queue_rebuild()
## Speed of the pull at the outside (m/s); it falls to nothing at the centre.
@export var speed := 5.0:
	set(value):
		speed = value
		_queue_rebuild()
## How quickly matter takes up the pull (1/s). Times [member speed] it is how hard matter is drawn in (m/s^2). What is already
## full is held, not squeezed (see [WaterSimPush]), so more draws the ball together faster without crushing it.
@export_range(0.0, 120.0, 0.1, "or_greater") var strength := 8.0:
	set(value):
		strength = value
		_queue_rebuild()
## The nested pulls. More is a smoother spring.
@export_range(1, 8) var layers := 4:
	set(value):
		layers = clampi(value, 1, 8)
		_queue_rebuild()
## Length of the column under the orb that draws matter up into it (m; 0: none).
@export var feed_length := 0.0:
	set(value):
		feed_length = maxf(value, 0.0)
		_queue_rebuild()
## Speed up the column (m/s).
@export var feed_speed := 7.0:
	set(value):
		feed_speed = value
		_queue_rebuild()
## The column stops once the matter a little over the centre is this dense (kg/m^3).
@export var full_density := 600.0
@export_group("Spray")
## The ball sheds spray from its surface, flung outwards (see [member WaterSimForceField.spray]).
@export var spray := false:
	set(value):
		spray = value
		_apply_spray()
## The chance a step that a particle at the ball's surface sheds spray.
@export_range(0.0, 1.0, 0.005) var spray_amount := 0.03:
	set(value):
		spray_amount = value
		_apply_spray()
## How fast (m/s) the spray leaves the ball, outwards, on top of the water's own speed.
@export_range(0.0, 10.0, 0.1) var spray_speed := 1.5:
	set(value):
		spray_speed = value
		_apply_spray()
@export_group("")

## Draw the spheres in game too (they are always drawn in the editor).
@export var show_shape := false:
	set(value):
		show_shape = value
		for field in _fields:
			field.show_shape = value
		if _feed != null:
			_feed.show_shape = value

var _fields: Array[WaterSimPush] = []
var _feed: WaterSimVortex
var _queued := false


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _feed == null:
		return
	var on := get_sim()
	if on != null and on.is_stepping():
		return
	_feed.enabled = enabled and on != null and on.sample_density(global_position + global_basis.y * radius * 0.3) < full_density


func _ready() -> void:
	_rebuild_now()


func _queue_rebuild() -> void:
	if _queued or not is_inside_tree():
		return
	_queued = true
	_rebuild_now.call_deferred()


func _rebuild_now() -> void:
	_queued = false
	if not is_inside_tree():
		return
	for field in _fields:
		field.queue_free()
	_fields.clear()
	if _feed != null:
		_feed.queue_free()
		_feed = null
	var on := get_sim() if not Engine.is_editor_hint() else null
	if feed_length > 0.0:
		# From feed_length under the orb up into its lower half (the lift tapers off over the column's top, where the orb takes over).
		_feed = WaterSimVortex.new()
		_feed.sim = on
		_feed.shape = WaterSim.Shape.CYLINDER
		_feed.radius = radius * 0.75
		_feed.height = feed_length + radius * 0.5
		_feed.position = Vector3.DOWN * (feed_length - radius * 0.5) * 0.5
		_feed.swirl_speed = 1.5
		_feed.pull_speed = 2.0
		_feed.lift_speed = feed_speed
		_feed.strength = 12.0
		_feed.falloff = 0.3
		_feed.enabled = enabled
		_feed.show_shape = show_shape
		add_child(_feed, false, Node.INTERNAL_MODE_BACK)
	# Outermost first: the fields act in the order they were added, so each inner one has the last word inside it.
	# The innermost share has no field: steering overrides the pressure, so a pull (or a hold still) reaching all the way in crushes
	# the matter into a point; left free, the pressure holds the ball's middle up against the pull round it.
	for i in range(layers, 1, -1):
		var field := WaterSimPush.new()
		field.sim = on
		field.radius = radius * float(i) / layers
		field.speed = -speed * float(i - 1) / maxf(layers - 1, 1)
		field.strength = strength
		field.falloff = 0.3 if i == layers else 0.0
		field.enabled = enabled
		field.show_shape = show_shape and i == layers
		add_child(field, false, Node.INTERNAL_MODE_BACK)
		_fields.append(field)
	_apply_spray()


# The outermost pull sprays for the ball: it holds all of it, so the inner ones need not.
func _apply_spray() -> void:
	if _fields.is_empty():
		return
	var outer := _fields[0]
	outer.spray = spray
	outer.spray_amount = spray_amount
	outer.spray_speed = spray_speed
