@tool
@icon("icon.svg")
class_name WaterSim
extends Node3D
## A box of simulated liquid: water and slime (MLS-MPM, run in C++ on worker
## threads). The box sits on this node: centred in x and z, from the node up in y.
##
## Built from components. Put them anywhere (they find the [WaterSim] above them, or the one
## whose box they're in): [WaterSimEmitter] adds matter, [WaterSimCollider] makes a physics
## body block it, [WaterSimVortex] and friends push it, [WaterSimConverter] turns it into
## something else (water into slime, say), [WaterSimDrain] takes it away, [WaterSimTransmuter]
## turns a mesh into it, [WaterSimBuoyancy] floats a body on it, and [WaterSimParticleView]
## draws it.
##
## A box can rest: [method sleep] (called by the game, never by the box itself) puts its
## liquids into the [WaterSimStillWater] under them and stops simulating. A box starting asleep over still water
## wakes when a component acts in it or a body moves fast in it, taking the still water
## inside it back into particles. A [WaterSimWorld] starts boxes wherever something happens
## and none is awake.
##
## Everything here takes and returns global positions. The node may move and turn (the
## matter doesn't move with it), but not scale. The outermost cells are the box's walls
## (matter can't be in them), so put its floor at least a cell below the ground.

signal stepped
## The box went to sleep: its matter settled and it stopped simulating.
signal fell_asleep
## The box woke up.
signal woke

enum Shape { BOX, SPHERE, CAPSULE, CYLINDER }
const GROUP := &"water_sims"
# As in ms_wave (fluid_shape.glslinc).
const SURFACE_WAVE_DIR: Array[Vector2] = [Vector2(0.7648, 0.6442), Vector2(-0.9991, 0.0416), Vector2(0.7087, -0.7055), Vector2(-0.0492, 0.9988), Vector2(-0.637, -0.771)]

## Size of the box, in metres.
@export var size := Vector3(12, 6, 12):
	set(value):
		size = value.max(Vector3.ONE * 0.5)
		_reconfigure()
## Grid cell size. Particles are a half cell apart, so this sets how fine the matter is,
## and the cost: halving it is eight times the particles for the same volume. The default (1/8 m) is water at a person's scale,
## with one substep a frame. The bounded pressure holds water up in proportion to 1 / (a substep's length) squared, so a finer cell
## (or deeper water) wants more substeps or a higher [member bounded_gain].
@export_range(0.05, 2.0, 0.01, "or_greater") var cell_size := 0.125:
	set(value):
		cell_size = value
		_reconfigure()
## Substances registered up front. Others are added when a component first uses them.
@export var substances: Array[WaterSimSubstance] = []
@export var gravity := Vector3(0, -19.6, 0)
## Particles beyond this are not added.
@export var max_particles := 60000
## Substeps in every step, always exactly this many (the bounded pressure holds water up in proportion to the substep's length squared).
## A step is shortened (the water runs slower than real time) when something moves faster than a cell a substep. 1 is the default; at
## the default 1/8 m cells, 2 holds a pond up better (see the README).
@export_range(1, 64) var max_substeps := 1
## The length of every step, in seconds (Liquid Crystal's fixed step a frame): the water does the same on a fast machine and a
## slow one, which only runs it slower. At most one step a rendered frame. 0: each step covers the time since the last (up to a
## tenth of a second).
@export_range(0.0, 0.1, 0.0001) var fixed_step := 1.0 / 60.0
@export var simulating := true

@export_group("Detail")
## Adaptive detail: liquid deep inside a body of liquid is simulated with particles that stand
## for eight fine ones each (a deep pond is a fraction of the particles), while the surface,
## the walls and anything near the focus stay fine. Needs [member cell_size] small enough that
## a cell has several particles, which it always does; costs well under a millisecond a step. On by default (as Liquid Crystal
## does: 8 particles a cell at the surface, coarser below); shallow water has no inside and stays fine.
@export var adaptive := true
## With adaptive detail: the width of each band of detail from the camera (or the nodes in [member focus]). Within it the
## liquid is LOD 1 (fine), within twice it LOD 2, three times LOD 3, and so on up to [member detail_levels]; liquid under the
## water all the way is a level coarser again (LOD 2 right by the camera). 0: distance doesn't matter (only the depth does).
@export_range(0.0, 500.0, 0.5, "or_greater") var detail_distance := 5.0
## With adaptive detail: how many levels of detail there are (LOD 1 to this). LOD 2 is a particle for eight fine ones; past
## that each level is eight times coarser again, and the grid there is coarse too (cells 2, then 4 fine cells across), so far
## or deep water costs a small fraction of the particles. Matter by a collider or the box's walls stays at LOD 2 at most.
@export_range(1, 4) var detail_levels := 4
## With adaptive detail: the particles the simulation should stay under (0: no limit). Over it, the water under the surface all the
## way goes a level coarser (and another if that is not enough), and back when the count is under half of it: coarse interior only when
## it is needed. The surface, and the water near the camera and the [member focus] nodes, are not touched.
@export var particle_budget := 0
## Where the detail matters besides the active camera (a player that the camera orbits, say).
@export var focus: Array[Node3D] = []
## With adaptive detail: water outside the camera's view is one level coarser than its distance gives, and water that is far from the
## camera and the [member focus] nodes as well is as coarse as it goes and sleeps sooner (the camera's view, widened by
## [member view_margin]; it gets fine again as soon as the view reaches it). Off: detail follows distance only, behind you as in front.
@export var detail_by_view := true
## How far (degrees, each side) the view is widened for that: room for the camera to turn without coarse water coming into view.
@export_range(0.0, 80.0, 1.0) var view_margin := 35.0

@export_group("Surface waves")
## Waves running over the water as it is drawn, so it never looks dead still, even asleep: how high they get (m, 0: none). Only the
## drawing and the queries here ([method sample_density], [method raycast], so floating bodies too) move: the simulation doesn't
## see them, they wake nothing and cost it nothing, and they don't carry anything along. Particles in the air move with them too.
@export_range(0.0, 2.0, 0.005, "or_greater") var surface_wave_height := 0.05
## The longest wave's length (m); four shorter ones go with it, each 0.62 as long and as high.
@export_range(0.25, 200.0, 0.05, "or_greater") var surface_wave_length := 3.0
## How fast they run: 1 is as gravity has them at that length.
@export_range(0.0, 4.0, 0.05) var surface_wave_speed := 1.0

@export_group("Performance")
## Liquid Crystal's pressure: each substep a particle pushes with a force capped at a fixed size, so a step stays stable at small
## cells whatever the depth. Water is a little less dense at depth (a 4 m pond stands at about 0.93 of its rest height). The
## gain is 3.5 at 0.25 m cells; deeper water at smaller cells needs more.
@export_range(0.0, 8.0, 0.1) var bounded_gain := 3.5
## Bounded pressure: how fast water slower than [member bounded_settle_speed] loses its leftover motion (1 / s).
@export_range(0.0, 100.0, 1.0) var bounded_settling := 48.0
## Bounded pressure: water slower than about this (m/s) is settled; faster water is left alone.
@export_range(0.05, 3.0, 0.05) var bounded_settle_speed := 0.5
## Bounded pressure: the share of [member bounded_settling] that the water's bulk velocity gets (its ripples get all of it). At 1 slow
## flow is frozen, so a pond with a slope or a spout at one side does not level; at 0 a deep pond rings. 0.2 levels a pond about as fast
## as the particle stress does and stays calm.
@export_range(0.0, 1.0, 0.05) var bounded_drift := 0.2
## Bounded pressure: the same share for a block of water that is moving back against the way it set off from rest (a pond ringing,
## where a slope levelling flows one way and stops). 1 settles that motion as hard as the ripples: a pond lies still sooner and its
## blocks sleep, and a slope still levels. At or under [member bounded_drift] it is off. Needs [member sleeping_blocks].
@export_range(0.0, 1.0, 0.05) var bounded_drift_swing := 1.0
## Blocks of liquid at rest (4 x 4 x 4 cells) are not simulated until something disturbs them: a wave reaching them, a body
## moving near, anything added or taken. A pond that is still costs next to nothing. Off while force fields are about.
@export var sleeping_blocks := true:
	set(value):
		sleeping_blocks = value
		if _solver != null:
			_solver.set_sleeping(value)
## Blocks go to sleep by how the block moves as a whole, not by its fastest node. Water that has been merged into coarse particles
## (the levels of detail, about a particle a cell) shakes its nodes at random by tenths of a metre a second, so by the fastest node
## it never sleeps and costs its full step; by its motion as a whole it does (a pool of the Tool Sandbox's step: 10 to 5.5 ms). What
## sleeps keeps the holes in the surface it had when it fell asleep, so it looks a little rougher. On by default (at one substep the water
## is never still enough to sleep by its fastest node: a 24 m pond had 3,185 of 19,371 blocks asleep, now 6,623).
@export var sleep_by_motion := true:
	set(value):
		sleep_by_motion = value
		if _solver != null:
			_solver.set_sleep_by_motion(value)
## How long (s) after it was last disturbed a block may sleep. A pond levels more slowly than a block reads as calm, so what sleeps
## sooner keeps the humps it had; a longer wait costs a full step on that water for longer after each splash.
@export_range(0.0, 30.0, 0.1) var sleep_after := 8.0:
	set(value):
		sleep_after = value
		if _solver != null:
			_solver.set_sleep_after(value)
## Experimental, on by default. A block of water that is awake but slower than [member drowsy_speed] (its fastest node) moves its particles every
## other step, twice as far, and on the step between adds what it added the step before, as a sleeping block does; half of such
## blocks skip each step. It costs some accuracy: the block's neighbours feel its pressure a step late.
@export var drowsy_blocks := true:
	set(value):
		drowsy_blocks = value
		if _solver != null:
			_solver.set_drowsy(drowsy_blocks, drowsy_speed)
## Experimental. The speed (m/s) under which a block may be drowsy (see [member drowsy_blocks]).
@export_range(0.0, 4.0, 0.05) var drowsy_speed := 1.0:
	set(value):
		drowsy_speed = value
		if _solver != null:
			_solver.set_drowsy(drowsy_blocks, drowsy_speed)
## Threads the simulation may use: 1 is one core (the default: predictable, and leaves the
## rest of the CPU to the game), 0 is every core. See [member step_budget_ms] for how many of them it does use.
@export_range(0, 64) var threads := 1:
	set(value):
		threads = value
		if _solver != null:
			_solver.set_threads(threads)
## With more than one of [member threads]: the longest a step in the background should take (ms). It uses as few of them as keep it
## under this and the others sleep, more at once in a splash: a step only has to fit its tick, and fewer threads do the same work for
## less of the machine (the water is the same on any number). 0: always all of them. Without [member step_in_background] the frame
## waits for the step, so it gets them all.
@export_range(0.0, 33.0, 0.5) var step_budget_ms := 8.0:
	set(value):
		step_budget_ms = value
		if _solver != null:
			_solver.set_step_budget(step_budget_ms)
## Run each step on a thread of its own while the game goes on, and use it a frame later,
## instead of making the frame wait for it. Off: the step runs in the physics tick.
@export var step_in_background := true
## With a step in the background that takes longer than a frame: off, the frame goes on with
## the water as it was (a stale frame) and the step after starts when that one is done, so the
## water runs slower but the game does not stutter; on, the frame waits for the step (the water
## keeps its pace, the frame rate drops). Tools that count frames as steps turn it on.
@export var wait_for_step := false
## Draw the box in game (it's always drawn in the editor).
@export var show_bounds := false:
	set(value):
		show_bounds = value
		_update_bounds()

@export_group("Sleep")
## Start asleep: the still water already there stays as it is until something wakes the box.
@export var start_asleep := false
## A body with a [WaterSimCollider] moving faster than this (m/s) in the box wakes it
## (floating bodies bob slower than this; something thrown in is faster).
@export var wake_speed := 1.0
## Free the box when [method sleep] leaves it with nothing in it (for boxes a
## [WaterSimWorld] starts).
@export var retire_when_empty := false

## Whether the box is asleep (see the class description).
var asleep := false

var _solver: WaterSimSolver
# Time not yet simulated, and the rendered frame last stepped in.
var _pending := 0.0
var _stepped_frame := -1
var _ids: Dictionary[WaterSimSubstance, int] = {}
var _colliders: Array[WaterSimCollider] = []
var _fields: Array[WaterSimForceField] = []
var _bounds: MeshInstance3D
# A step running in the background, and the time it covers.
var _in_flight := false
# The solver's grid size, kept here: asking the solver for it waits for the step in flight (WaterSimSolver::finish).
var _dims := Vector3i.ZERO
var _in_flight_delta := 0.0
# A step held back because the one before was still running (see _advance).
var _owed := false
var _surface_wave_time := 0.0
# When the box last fell asleep (seconds): bodies floating on its still water are still
# finding their feet for a moment, and shouldn't wake it straight away.
var _slept_at := -1000.0


func _ready() -> void:
	# The step starts after every other node's physics tick: emitters, drains and colliders call into the solver
	# (spray, remove, colliders), and each call waits for the step in flight, so a step started first stalled the
	# game's thread for its whole length and left nothing for it to overlap.
	process_physics_priority = 1000
	add_to_group(GROUP)
	_update_bounds()
	if Engine.is_editor_hint():
		return
	_reconfigure()
	for substance in substances:
		get_substance_id(substance)
	asleep = start_asleep


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not simulating or _solver == null:
		return
	if asleep:
		if _disturbed():
			wake()
		else:
			return
	_advance(delta)


func _process(delta: float) -> void:
	_surface_wave_time += delta * surface_wave_speed
	# A step held back on a tick because the last one was still running starts as soon as that one is done, not at the next
	# tick (which would leave the solver idle for up to a tick each time).
	if _owed and simulating and not asleep and _solver != null and not _solver.is_stepping():
		_advance(0.0)


# The time of a tick (or none) on to the simulation, and a step started when there is one to take.
func _advance(delta: float) -> void:
	# Last frame's background step still running (it took longer than a frame): the frame goes on with the water as it was
	# (one stale frame instead of a frame that waits for it); the time is kept, and the step starts when that one is done.
	if _in_flight and not wait_for_step and _solver.is_stepping():
		_pending = minf(_pending + delta, fixed_step * 2.0 if fixed_step > 0.0 else 0.1)
		_owed = true
		return
	_owed = false
	# At most one step per rendered frame. When a frame runs long the engine catches up with
	# several physics ticks in the next one; stepping in each would make that frame longer still.
	var frame := Engine.get_process_frames()
	if fixed_step > 0.0:
		# Steps of exactly fixed_step: time builds up until there is a step's worth (physics ticking faster than the step), and
		# past two steps behind (a machine that can't keep up) the water slows down instead.
		_pending = minf(_pending + delta, fixed_step * 2.0)
		if frame == _stepped_frame or _pending < fixed_step * 0.999:
			return
		_stepped_frame = frame
		delta = fixed_step
		_pending = maxf(_pending - fixed_step, 0.0)
	else:
		# The ticks' time goes into one step (and past a tenth of a second, the simulation falls
		# behind rather than taking ever bigger steps).
		_pending = minf(_pending + delta, 0.1)
		if frame == _stepped_frame or _pending <= 0.0:
			return
		_stepped_frame = frame
		delta = _pending
		_pending = 0.0
	# Last frame's background step is done by now. The next one starts before the views take
	# what it built, so the simulation works while the game's thread updates them.
	var shown := _in_flight
	var shown_delta := _in_flight_delta
	_in_flight = false
	_update_inputs()
	if step_in_background:
		_solver.step_async(delta)
		_in_flight = true
		_in_flight_delta = delta
		if shown:
			_after_step(shown_delta)
	else:
		_solver.step(delta)
		_after_step(delta)


func _after_step(_delta: float) -> void:
	stepped.emit()


## Wakes the box if it's asleep, taking the still water inside it back into particles.
## Components call this whenever they act.
func wake() -> void:
	if not asleep or _solver == null:
		return
	asleep = false
	_update_inputs()
	for still in _still_waters():
		still.wake_into(self)
	_solver.rebuild_grid()
	woke.emit()


## Settles the box and stops simulating: liquids go into the still water under them. Boxes
## never do this by themselves: call it when the game wants a box to rest (the player has
## left the area, a spell is long over). What can't settle (a liquid with no still water
## under it, or substances set to stay) stays as particles, waiting. With
## [member retire_when_empty], an empty box frees itself.
func sleep() -> void:
	if asleep or _solver == null:
		return
	asleep = true
	_in_flight = false
	_slept_at = Time.get_ticks_msec() * 0.001
	for still in _still_waters():
		still.settle_from(self)
	_solver.rebuild_grid()
	stepped.emit()
	fell_asleep.emit()
	if retire_when_empty and get_particle_count() == 0:
		queue_free()


# Whether something should wake the box: a body moving fast in it.
func _disturbed() -> bool:
	if Time.get_ticks_msec() * 0.001 - _slept_at < 1.0:
		return false
	for collider in _colliders:
		if collider.get_speed() > wake_speed and has_point(collider.global_position):
			return true
	return false


func _update_inputs() -> void:
	_solver.set_gravity(_solver_basis().inverse() * gravity)
	_solver.set_max_substeps(max_substeps)
	_solver.set_bounded_pressure(bounded_gain, bounded_settling, bounded_settle_speed, bounded_drift, bounded_drift_swing)
	_solver.set_max_particles(max_particles)
	_solver.set_adaptive(adaptive, detail_levels - 1, detail_distance, particle_budget)
	if adaptive and detail_distance > 0.0:
		_solver.set_focus(_focus_points())
		_solver.set_view(_view_planes() if detail_by_view else PackedFloat32Array(), _keep_points())
	var colliders := []
	for collider in _colliders:
		colliders.append_array(collider.get_solver_shapes(self))
	_solver.set_colliders(colliders)
	var fields := []
	for field in _fields:
		if field.enabled:
			fields.append(field.get_solver_field(self))
	_solver.set_fields(fields)


# The points detail is kept near, in the solver's space: the camera and the focus nodes.
func _focus_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	var to_box := get_solver_transform().affine_inverse()
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		points.append(to_box * camera.global_position)
	for node in focus:
		if is_instance_valid(node):
			points.append(to_box * node.global_position)
	return points


# The points that keep detail near them wherever the camera looks: the focus nodes (not the camera), in the solver's space.
func _keep_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	var to_box := get_solver_transform().affine_inverse()
	for node in focus:
		if is_instance_valid(node):
			points.append(to_box * node.global_position)
	return points


# What the camera sees, widened by view_margin on every side, as four planes through the eye (nx, ny, nz, d: inside where
# n.p + d >= 0) in the solver's space. None (empty) when there is no perspective camera.
func _view_planes() -> PackedFloat32Array:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var out := PackedFloat32Array()
	if camera == null or camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return out
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var half := deg_to_rad(camera.fov) * 0.5
	var half_x := half if camera.keep_aspect == Camera3D.KEEP_WIDTH else atan(tan(half) * aspect)
	var half_y := atan(tan(half) / aspect) if camera.keep_aspect == Camera3D.KEEP_WIDTH else half
	var limit := deg_to_rad(85.0)
	half_x = minf(half_x + deg_to_rad(view_margin), limit)
	half_y = minf(half_y + deg_to_rad(view_margin), limit)
	var basis := camera.global_transform.basis
	var right := basis.x
	var up := basis.y
	var forward := -basis.z
	var eye := camera.global_position
	var to_box := get_solver_transform().affine_inverse()
	var inside := to_box * (eye + forward)
	var normals: Array[Vector3] = [
		forward * sin(half_x) - right * cos(half_x),
		forward * sin(half_x) + right * cos(half_x),
		forward * sin(half_y) - up * cos(half_y),
		forward * sin(half_y) + up * cos(half_y),
	]
	for n in normals:
		var plane: Plane = to_box * Plane(n, eye)
		if plane.distance_to(inside) < 0.0:
			plane = -plane
		out.append_array(PackedFloat32Array([plane.normal.x, plane.normal.y, plane.normal.z, -plane.d]))
	return out


func _still_waters() -> Array[WaterSimStillWater]:
	var list: Array[WaterSimStillWater] = []
	var box := get_global_box()
	for node in get_tree().get_nodes_in_group(WaterSimStillWater.GROUP):
		if node is WaterSimStillWater and node.overlaps(box):
			list.append(node)
	return list


## The box in global space (axis-aligned around it if the node is turned).
## Whether the box's background step is still running: a call into the box now would wait for
## it. Components hold their work for a tick then (see [method WaterSimComponent._tick_time]).
func is_stepping() -> bool:
	return _in_flight and not wait_for_step and _solver != null and _solver.is_stepping()


## The solver's grid size in cells, without waiting for the step in flight.
func get_dims() -> Vector3i:
	return _dims


func get_global_box() -> AABB:
	return get_solver_transform() * AABB(Vector3.ZERO, size)


## Whether a global box fits in the part of the box matter can be in: inside its side
## walls (a cell at the low end, two at the high end) and under its top. Its bottom may
## reach into the floor (matter there settles on the floor).
func fits(box: AABB) -> bool:
	if _solver == null:
		return false
	var local := get_solver_transform().affine_inverse() * box
	var high := Vector3(_solver.get_dims() - Vector3i(2, 2, 2)) * cell_size + Vector3.ONE * 0.001
	var low := cell_size - 0.001
	return local.position.x >= low and local.position.z >= low and local.end.x <= high.x 			and local.end.z <= high.z and local.position.y >= -0.001 and local.end.y <= high.y


## The native solver, for views and components. Its space is the box, from its corner.
func get_solver() -> WaterSimSolver:
	return _solver


## The solver's space in global space: the box's lowest corner, the node's rotation.
func get_solver_transform() -> Transform3D:
	return Transform3D(_solver_basis(), global_transform * Vector3(-size.x * 0.5, 0, -size.z * 0.5))


## A global transform in the solver's space, without scale.
func to_solver(transform: Transform3D) -> Transform3D:
	var t := get_solver_transform().affine_inverse() * transform
	t.basis = t.basis.orthonormalized()
	return t


## Whether a global point is inside the box.
func has_point(point: Vector3) -> bool:
	var p := get_solver_transform().affine_inverse() * point
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x <= size.x and p.y <= size.y and p.z <= size.z


## The substance's number in the solver, registering it if it's new (at most 64).
func get_substance_id(substance: WaterSimSubstance) -> int:
	if substance == null:
		return 0
	if _ids.has(substance):
		return _ids[substance]
	if _ids.size() >= 64:
		push_error("WaterSim: more than 64 substances")
		return 0
	var id := _ids.size()
	_ids[substance] = id
	if not substance.changed.is_connected(_on_substance_changed):
		substance.changed.connect(_on_substance_changed.bind(substance))
	_push_substance(substance)
	return id


## Registered substances, by number.
func get_substances() -> Array[WaterSimSubstance]:
	var list: Array[WaterSimSubstance] = []
	list.resize(_ids.size())
	for substance in _ids:
		list[_ids[substance]] = substance
	return list


## A mask with a bit for each substance; all of them when the list is empty.
func get_mask(list: Array[WaterSimSubstance]) -> int:
	if list.is_empty():
		return -1
	var mask := 0
	for substance in list:
		if substance != null:
			mask |= 1 << get_substance_id(substance)
	return mask


## The extents the solver wants for a shape (see [enum Shape]): half size for a box; radius
## and half height (of the middle, for a capsule) for the round ones.
static func get_extents(shape: Shape, box_size: Vector3, radius: float, height: float) -> Vector3:
	match shape:
		Shape.SPHERE:
			return Vector3(radius, radius, radius)
		Shape.CAPSULE:
			return Vector3(radius, maxf(height * 0.5 - radius, 0.0), radius)
		Shape.CYLINDER:
			return Vector3(radius, height * 0.5, radius)
	return box_size * 0.5


## Fills a shape (at a global transform) with a substance, eight particles a cell. With
## avoid_colliders, places inside colliders stay empty.
## With limit (0 or more), it stops after that many, filling from the bottom up. Returns how
## many were added.
func fill(shape: Shape, transform: Transform3D, extents: Vector3, substance: WaterSimSubstance,
		velocity := Vector3.ZERO, avoid_colliders := false, limit := -1) -> int:
	if _solver == null:
		return 0
	return _solver.fill(shape, to_solver(transform), extents, _solver_basis().inverse() * velocity,
			get_substance_id(substance), avoid_colliders, limit)


## Adds amount particles at random inside a shape.
func spray(shape: Shape, transform: Transform3D, extents: Vector3, amount: int, substance: WaterSimSubstance,
		velocity := Vector3.ZERO) -> int:
	if _solver == null:
		return 0
	return _solver.spray(shape, to_solver(transform), extents, amount, _solver_basis().inverse() * velocity,
			get_substance_id(substance))


## Fills the inside of a closed mesh placed at a global transform.
func fill_mesh(mesh: Mesh, transform: Transform3D, substance: WaterSimSubstance, velocity := Vector3.ZERO) -> int:
	if mesh == null:
		return 0
	var faces := mesh.get_faces()
	for i in faces.size():
		faces[i] = transform * faces[i]
	return fill_faces(faces, substance, velocity)


## Fills the inside of a closed surface given as global triangles (three vertices each).
func fill_faces(faces: PackedVector3Array, substance: WaterSimSubstance, velocity := Vector3.ZERO) -> int:
	if _solver == null or faces.is_empty():
		return 0
	var to := get_solver_transform().affine_inverse()
	var local := PackedVector3Array()
	local.resize(faces.size())
	for i in faces.size():
		local[i] = to * faces[i]
	return _solver.fill_triangles(local, _solver_basis().inverse() * velocity, get_substance_id(substance))


## Turns particles of the from substances (all when empty) inside a shape into to, each
## with chance fraction. Returns how many changed.
func convert(shape: Shape, transform: Transform3D, extents: Vector3, from: Array[WaterSimSubstance],
		to: WaterSimSubstance, fraction := 1.0) -> int:
	if _solver == null or to == null:
		return 0
	return _solver.convert(shape, to_solver(transform), extents, get_mask(from), get_substance_id(to), fraction)


## Removes particles of the from substances (all when empty) inside a shape, each with
## chance fraction. Returns how many went.
func remove(shape: Shape, transform: Transform3D, extents: Vector3, from: Array[WaterSimSubstance] = [],
		fraction := 1.0) -> int:
	if _solver == null:
		return 0
	return _solver.remove(shape, to_solver(transform), extents, get_mask(from), fraction)


func clear() -> void:
	if _solver != null:
		_solver.clear()


func get_particle_count() -> int:
	return _solver.get_particle_count() if _solver != null else 0


## The particles counted as fine ones: with adaptive detail a coarse particle is worth eight, so this
## is how much matter there is (what an emitter put in and a drain took out), where
## [method get_particle_count] is what the simulation has to carry.
func get_fine_particle_count() -> int:
	return _solver.get_fine_particle_count() if _solver != null else 0


func count_substance(substance: WaterSimSubstance) -> int:
	if _solver == null or not _ids.has(substance):
		return 0
	return _solver.count_substance(_ids[substance])


## kg/m^3 of matter at a global point (about a substance's density inside it, 0 outside),
## as of the last step.
func sample_density(point: Vector3) -> float:
	if _solver == null:
		return 0.0
	return _solver.sample_density(get_solver_transform().affine_inverse() * (point - Vector3.UP * surface_wave_at(point)))


## Velocity of the matter at a global point, as of the last step.
func sample_velocity(point: Vector3) -> Vector3:
	if _solver == null:
		return Vector3.ZERO
	return _solver_basis() * _solver.sample_velocity(get_solver_transform().affine_inverse() * (point - Vector3.UP * surface_wave_at(point)))


## Where a ray first meets matter at least threshold kg/m^3 dense, or null.
func raycast(from: Vector3, direction: Vector3, max_distance: float, threshold := 300.0) -> Variant:
	if _solver == null:
		return null
	var dir := direction.normalized()
	# (With the waves as they are over the hit, found from the ray with those at its start: near enough while they are low.)
	var t := _solver.raycast(get_solver_transform().affine_inverse() * (from - Vector3.UP * surface_wave_at(from)), _solver_basis().inverse() * dir,
			max_distance, threshold)
	if t < 0.0:
		return null
	var hit := from + dir * t
	return hit + Vector3.UP * (surface_wave_at(hit) - surface_wave_at(from))


## How far the surface waves lift the water at a global point just now (m; see [member surface_wave_height]). What the drawing does.
func surface_wave_at(point: Vector3) -> float:
	if surface_wave_height <= 0.0:
		return 0.0
	var origin := get_solver_transform().origin
	var solver_point := get_solver_transform().affine_inverse() * point
	var p := Vector2(solver_point.x + origin.x, solver_point.z + origin.z)
	var wave_len := surface_wave_length
	var amp := 1.0
	var sum := 0.0
	var total := 0.0
	for i in SURFACE_WAVE_DIR.size():
		var k := TAU / wave_len
		var phase := SURFACE_WAVE_DIR[i].dot(p) * k + sqrt(9.8 * k) * _surface_wave_time + i * 1.7
		sum += amp * sin(phase)
		total += amp
		p += SURFACE_WAVE_DIR[i] * cos(phase) * amp * wave_len * 0.04
		amp *= 0.62
		wave_len *= 0.62
	return surface_wave_height * sum / total


## The time the surface waves have run (s, at their speed): what the views draw them at.
func get_surface_wave_time() -> float:
	return _surface_wave_time


## substeps, step_msec, mean_speed, max_speed, active_blocks, particles, and the times of the phases.
func get_stats() -> Dictionary:
	return _solver.get_stats() if _solver != null else {}


## kg/m^3 of matter at a global point from every box and still water there (the most of
## them): what floats bodies and answers "is this under water?".
static func sample_density_at(tree: SceneTree, point: Vector3) -> float:
	var density := 0.0
	for sim in tree.get_nodes_in_group(GROUP):
		if sim is WaterSim and sim.has_point(point):
			density = maxf(density, sim.sample_density(point))
	for still in tree.get_nodes_in_group(WaterSimStillWater.GROUP):
		if still is WaterSimStillWater:
			density = maxf(density, still.sample_density(point))
	return density


## Velocity of the matter at a global point (still water: none).
static func sample_velocity_at(tree: SceneTree, point: Vector3) -> Vector3:
	for sim in tree.get_nodes_in_group(GROUP):
		if sim is WaterSim and not sim.asleep and sim.has_point(point):
			return sim.sample_velocity(point)
	return Vector3.ZERO


## Where a ray first meets matter in any box or still water, or null.
static func raycast_at(tree: SceneTree, from: Vector3, direction: Vector3, max_distance: float,
		threshold := 300.0) -> Variant:
	var best: Variant = null
	var reach := max_distance
	for sim in tree.get_nodes_in_group(GROUP):
		if sim is WaterSim:
			var hit: Variant = sim.raycast(from, direction, reach, threshold)
			if hit != null:
				best = hit
				reach = from.distance_to(hit)
	for still in tree.get_nodes_in_group(WaterSimStillWater.GROUP):
		if still is WaterSimStillWater:
			var hit: Variant = still.raycast(from, direction, reach)
			if hit != null:
				best = hit
				reach = from.distance_to(hit)
	return best


## Finds the simulation a node belongs to: the nearest [WaterSim] above it, else the one
## whose box holds it, else (with no [WaterSimWorld] to start one) the first in the scene.
static func find_for(node: Node3D) -> WaterSim:
	var parent := node.get_parent()
	while parent != null:
		if parent is WaterSim:
			return parent
		parent = parent.get_parent()
	if not node.is_inside_tree():
		return null
	var first: WaterSim = null
	for sim in node.get_tree().get_nodes_in_group(GROUP):
		if sim is WaterSim and not sim.is_queued_for_deletion():
			if first == null:
				first = sim
			if sim.has_point(node.global_position):
				return sim
	if WaterSimWorld.find(node.get_tree()) != null:
		return null
	return first


func _register_collider(collider: WaterSimCollider) -> void:
	if not collider in _colliders:
		_colliders.append(collider)


func _unregister_collider(collider: WaterSimCollider) -> void:
	_colliders.erase(collider)


func _register_field(field: WaterSimForceField) -> void:
	if not field in _fields:
		_fields.append(field)


func _unregister_field(field: WaterSimForceField) -> void:
	_fields.erase(field)


func _solver_basis() -> Basis:
	return global_transform.basis.orthonormalized()


func _reconfigure() -> void:
	_update_bounds()
	if not is_node_ready() or Engine.is_editor_hint():
		return
	if _solver == null:
		_solver = WaterSimSolver.new()
		_solver.set_threads(threads)
		_solver.set_step_budget(step_budget_ms)
		_solver.set_sleep_by_motion(sleep_by_motion)
		_solver.set_sleep_after(sleep_after)
		_solver.set_drowsy(drowsy_blocks, drowsy_speed)
	_in_flight = false
	var dims := Vector3i((size / cell_size).ceil())
	_dims = dims
	_solver.configure(dims, cell_size)
	for substance in _ids.keys():
		_push_substance(substance)
	# The settings go now too, not only before each step: what is added before the first step (fill_on_start) is held to
	# max_particles, not to the solver's own default.
	_update_inputs()


func _on_substance_changed(substance: WaterSimSubstance) -> void:
	if _ids.has(substance):
		_push_substance(substance)


# Sends a substance's settings to the solver.
func _push_substance(substance: WaterSimSubstance) -> void:
	if _solver == null:
		return
	_solver.set_substance(_ids[substance], substance.to_settings())


func _update_bounds() -> void:
	if not is_inside_tree():
		return
	var visible_now := Engine.is_editor_hint() or show_bounds
	if not visible_now:
		if _bounds != null:
			_bounds.queue_free()
			_bounds = null
		return
	if _bounds == null:
		_bounds = preload("shape_lines.gd").new()
		add_child(_bounds, false, Node.INTERNAL_MODE_BACK)
	_bounds.draw(Shape.BOX, size, Color(0.3, 0.7, 1.0), Vector3(0, size.y * 0.5, 0))
