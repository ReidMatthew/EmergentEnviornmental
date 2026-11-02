@tool
class_name AdaptivePiece
extends Node3D
## One piece of an [AdaptiveMesh]: a solid it edits with booleans, the mesh drawing it
## and its collision. Made and configured by the mesh; you don't add these yourself.
##
## Edits are queued and applied in batches: every edit queued while one batch runs goes
## into the next. [signal edited] fires when a batch is drawn, normally the frame after the
## edit: the boolean runs right away (on the main thread for backends that need it, within
## [member frame_budget]), and everything after it runs as one job on a worker thread.

## Emitted on the main thread after a batch of edits is applied and drawn.
signal edited
## Emitted on the main thread whenever a new mesh is drawn: after edits, and after
## [method request_redraw].
signal drawn
## Emitted on the main thread after a batch with digs, when [member debris] is on: per dig,
## the material it took out ([param removed], this node's space; faces where the piece met
## its neighbours get [param cut_tag], the dig's own tag).
signal broke_off(removed: Solid, cut_tag: int)
## Emitted on the main thread when a run of batches or a redraw is over and nothing is
## queued or running (after [signal edited] or [signal drawn], which can come before the
## work for debris or follow-up hulls is done).
signal finished

## The current shape, edits included.
var solid: Solid = Solid.new()
## A mesh to show at first instead of building one (from [member AdaptiveMeshData.meshes]).
var initial_mesh: ArrayMesh
var backend: BooleanBackend
var cleanup: MeshCleanup
## Material per tag (index = tag); null entries draw with Godot's default.
var materials: Array[Material] = []
var crease_angle := 40.0
var cast_shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
## [GeometryInstance3D] properties to give the drawn mesh (a component copies its target's
## look this way), applied over [member cast_shadow].
var render_settings := {}
var collision := true
var collision_layer := 1
var collision_mask := 1
## Moving mode: collide as the hull of this piece, added to this body (as a shape owner
## the piece owns), instead of as a trimesh on a [StaticBody3D] of its own. Set before the
## piece enters the tree.
var moving_body: CollisionObject3D
## Moving mode: how many convex hulls this piece collides as (see
## [method ConvexCells.hull_sets]).
var hulls_per_piece := 1
## Moving mode: the hulls' point sets for [member solid] if already known (with
## [member initial_mesh]), so they aren't worked out again on the main thread.
var initial_hulls: Array[PackedVector3Array] = []
## If it has a size, unions never add anything outside this box (this node's space). Faces
## the box cuts get [member bounds_tag] on the sides in [member bounds_walls], and the
## shape's tag elsewhere (see [method BooleanBackend.combine]).
var bounds := AABB()
var bounds_tag := 1
var bounds_walls := 63
## Triangles with these tags are neither drawn nor collided with (the faces that close a
## piece off where it meets a neighbour).
var hidden_tags := PackedInt32Array()
## Triangles of neighbouring pieces (three positions each, in this node's space). They
## aren't drawn or collided with, but vertices this piece shares with them average their
## normals too, so shading carries across the seam. Call [method request_redraw] after
## changing it.
var normal_faces := PackedVector3Array()
## When set, enabled and its [member MeshDebris.fragments] are on, each batch with digs
## also works out what they removed (see [signal broke_off]).
var debris: MeshDebris
## Shares main-thread time with the other pieces (see [FrameBudget]). Null: no limit.
var frame_budget: FrameBudget
## The neighbouring cells (key -> box) whose seams this piece's border faces are sorted for.
## Replace the whole dictionary to change it (edits in flight keep the one they started
## with, see [member border_parts_cells]).
var border_cells := {}
## When on, each batch also finds the faces each neighbour needs for its seam normals
## (see [method AdaptiveMesh._border_parts], with [member border_cell], [member border_cut]
## and [member border_cap]); they're in [member border_parts] when [signal edited] fires.
var find_borders := false
var border_cell := AABB()
var border_cut: Array[bool] = [false, false, false]
var border_cap := -1
## The faces found for the current solid (key -> faces), and the [member border_cells]
## they were sorted for.
var border_parts := {}
var border_parts_cells := {}
## The box (this piece's space) the last batch of edits could have changed: their shapes'
## boxes, a little grown (clean-up moves nearby points too).
var edited_box := AABB()

var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _shape: CollisionShape3D
var _owner_id := -1  # moving mode: this piece's shape owner on moving_body
var _hulls: Array[ConvexPolygonShape3D] = []  # moving mode: the shapes on it now
var _pending: Array[BooleanOp] = []
var _busy := false
var _redraw_requested := false
var _collision_solid: Solid  # the solid the collision now there was made for

# In place of what to collide with: keep the collision there (it's for this solid).
const KEEP_COLLISION := "keep"


func _ready() -> void:
	if Engine.is_editor_hint():
		collision = false  # an editor preview needs no physics
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.cast_shadow = cast_shadow
	for property: StringName in render_settings:
		_mesh_instance.set(property, render_settings[property])
	add_child(_mesh_instance, false, Node.INTERNAL_MODE_FRONT)
	if initial_mesh != null:
		var collide: Variant = PackedVector3Array()
		var later := false  # several hulls, not worked out yet: one for now, the rest after
		if collision:
			if moving_body != null:
				later = initial_hulls.is_empty() and hulls_per_piece > 1
				collide = initial_hulls if not initial_hulls.is_empty() else ConvexCells.hull_sets(solid, 1)
			else:
				collide = solid.get_faces(hidden_tags)
		_show(initial_mesh, collide)
		_collision_solid = solid
		if later:
			_busy = true
			await _follow_up_hulls([null, null], solid)
			_busy = false
			if not _pending.is_empty():
				_process_edits()
			else:
				finished.emit()
	else:
		request_redraw()


## Queues [param shape] at [param local_transform] (this node's space) with
## [param operation]. With [param debris] off, what a subtract removes is discarded, never
## debris.
func edit_local(shape: Solid, local_transform: Transform3D, operation: BooleanOp.Operation, debris: bool = true) -> void:
	var op := BooleanOp.create(shape, local_transform, operation)
	op.debris = debris
	add_op(op)


## Queues [param op] (in this piece's space), as [method edit_local] does. Ops aren't changed
## once made, so one edit reaching several pieces can share one.
func add_op(op: BooleanOp) -> void:
	_pending.append(op)
	if not _busy:
		# Started at the end of the frame, so every edit this frame goes in one job.
		_busy = true
		_process_edits.call_deferred()


## True when no edits or redraws are queued or running.
func is_idle() -> bool:
	return not _busy and _pending.is_empty()


## The mesh drawn now.
func get_mesh() -> ArrayMesh:
	return _mesh_instance.mesh as ArrayMesh if _mesh_instance != null else null


## The collision shape now (null with collision off or nothing to collide with); the first
## hull for a moving mesh (see [method get_collision_shapes]). Rebuilds make a new shape
## instead of changing this one.
func get_collision_shape() -> Shape3D:
	var shapes := get_collision_shapes()
	return shapes[0] if not shapes.is_empty() else null


## Every collision shape now: the trimesh of a static piece, or the hulls of a moving one.
func get_collision_shapes() -> Array[Shape3D]:
	var out: Array[Shape3D] = []
	if moving_body != null:
		out.append_array(_hulls)
	elif _body != null and _shape != null and _shape.shape != null:
		out.append(_shape.shape)
	return out


## Rebuilds the drawn mesh (and collision) on a worker thread, for example after
## [member normal_faces] changed. If edits are running, their next build covers it.
func request_redraw() -> void:
	if _busy or not is_inside_tree():
		_redraw_requested = true
		return
	_redraw_requested = false
	_busy = true
	var drawn_solid := solid
	# A redraw of the solid the collision was made for (new seam shading, say) keeps that
	# collision: building a collision shape is the dearest part of showing a piece.
	var same_shape := is_same(drawn_solid, _collision_solid)
	var built: Array = await _run_on_worker(_build_job(crease_angle, hidden_tags, collision and not same_shape,
			normal_faces, moving_body != null, hulls_per_piece).bind(drawn_solid))
	if same_shape:
		built[1] = KEEP_COLLISION
	if frame_budget != null:
		await frame_budget.wait_turn(_priority())
	if solid == drawn_solid:
		var start := Time.get_ticks_usec()
		_apply(built)
		if frame_budget != null:
			frame_budget.spend(Time.get_ticks_usec() - start)
		if not same_shape:
			await _follow_up_hulls(built, drawn_solid)
	_busy = false
	if not _pending.is_empty():
		_process_edits()
	elif _redraw_requested:
		request_redraw()
	else:
		finished.emit()


## For a worker job: the [ArrayMesh] for [param surfaces] (see [method make_mesh]) when
## meshes can be made off the main thread, so the main thread only shows it; otherwise the
## surfaces as they are, for [method as_mesh] to make on the main thread. Real renderers
## keep meshes in thread-safe storage (threaded resource loading makes meshes too); the
## dummy one a headless run uses (tests, dedicated servers) doesn't, and crashes.
static func job_mesh(surfaces: Array) -> Variant:
	if _meshes_on_workers < 0:
		_meshes_on_workers = 0 if DisplayServer.get_name() == "headless" else 1
	return make_mesh(surfaces) if _meshes_on_workers == 1 else surfaces


## What [method job_mesh] gave, as a mesh (made now if it's still surfaces). Main thread.
static func as_mesh(made: Variant) -> ArrayMesh:
	return made if made is ArrayMesh else make_mesh(made)


static var _meshes_on_workers := -1


## An [ArrayMesh] from [method Solid.build_surfaces] output, one surface per tag named
## [code]tag_<n>[/code] (so materials can be set by tag later).
static func make_mesh(surfaces: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for entry: Array in surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, entry[1])
		mesh.surface_set_name(mesh.get_surface_count() - 1, "tag_%d" % entry[0])
	return mesh


static func _ops_box(ops: Array[BooleanOp]) -> AABB:
	var box := AABB()
	for i in ops.size():
		var op_box := ops[i].transform * ops[i].shape.get_aabb()
		box = op_box if i == 0 else box.merge(op_box)
	return box.grow(box.get_longest_axis_size() * 0.25 + 1e-3)


func _process_edits() -> void:
	_busy = true
	while not _pending.is_empty() and is_inside_tree():
		var ops := _pending.duplicate()
		_pending.clear()
		var target := solid
		var b := backend
		var fused := NativeKernel.can_fuse(b, cleanup)
		var combined: Callable
		if fused:
			pass  # the whole edit is one native job (below)
		elif b.is_thread_safe():
			combined = _combine_job(b, target, ops, bounds, bounds_tag, bounds_walls)
		else:
			if frame_budget != null:
				await frame_budget.wait_turn(_priority())
			var start := Time.get_ticks_usec()
			var main_result: Variant = await b.combine_main(target, ops, bounds, bounds_tag, bounds_walls)
			if StageProfile.enabled:
				StageProfile.end(&"main: boolean", start)
			if frame_budget != null:
				frame_budget.spend(Time.get_ticks_usec() - start)
			combined = _finish_job(b, main_result)
		_redraw_requested = false  # this build includes whatever the request was for
		# What the digs removed, for debris: its booleans run while the edit's job does.
		var removal := []
		var removing := [false]
		if debris != null and debris.enabled and debris.fragments 				and ops.any(func(op: BooleanOp) -> bool: return op.operation == BooleanOp.Operation.SUBTRACT and op.debris):
			removing[0] = true
			_start_removal(b, target, ops, removal, removing)
		var cells := border_cells
		var job: Callable
		if fused:
			job = NativeKernel.edit_job(target, ops, bounds, bounds_tag, bounds_walls, cleanup,
					[crease_angle, hidden_tags, collision, normal_faces, moving_body != null, hulls_per_piece],
					[find_borders, border_cell, border_cut, border_cap, cells])
		var outcome: Array = await _run_on_worker(job if fused else _edit_job(combined, target, cleanup, bounds,
				_build_job(crease_angle, hidden_tags, collision, normal_faces, moving_body != null, hulls_per_piece),
				[find_borders, border_cell, border_cut, border_cap, cells]))
		if outcome.is_empty():
			push_warning("AdaptivePiece: the boolean backend failed; %d edits dropped." % ops.size())
			continue
		# Putting the result in the scene (mesh, collision) takes main-thread time too: it
		# shares the frame budget, so many pieces finishing at once (a fast backend, a big
		# cut) spread over frames instead of landing in one.
		if frame_budget != null:
			await frame_budget.wait_turn(_priority())
		var applying := Time.get_ticks_usec()
		solid = outcome[0]
		border_parts = outcome[2]
		edited_box = _ops_box(ops)
		border_parts_cells = cells
		_apply(outcome[1])
		if frame_budget != null:
			frame_budget.spend(Time.get_ticks_usec() - applying)
		edited.emit()
		await _follow_up_hulls(outcome[1], solid)
		if removing[0] or not removal.is_empty():
			while removing[0]:
				await get_tree().process_frame
			for entry: Array in await _run_on_worker(_removed_job(removal, hidden_tags)):
				broke_off.emit(entry[0], entry[1])
	_busy = false
	if _redraw_requested:
		request_redraw()
	finished.emit()


# Starts working out what each dig in [param ops] took out of [param target] (the solid
# before them): the target inside the dig's shape, minus whatever earlier digs in the batch
# took. Fills [param removal] with [finish job, the dig's tag] per dig (see
# [method _removed_job]) and sets [param removing] false when done. The main-thread parts
# start the frame after the edit's, within the frame budget.
func _start_removal(b: BooleanBackend, target: Solid, ops: Array[BooleanOp], removal: Array, removing: Array) -> void:
	await get_tree().process_frame
	var earlier: Array[BooleanOp] = []
	for op in ops:
		if op.operation != BooleanOp.Operation.SUBTRACT:
			continue
		if not op.debris:
			earlier.append(op)  # (discarded, but later digs in the batch don't get it either)
			continue
		var steps: Array[BooleanOp] = [BooleanOp.create(op.shape, op.transform, BooleanOp.Operation.INTERSECT)]
		steps.append_array(earlier)
		earlier.append(op)
		var tag: int = op.shape.tags[0] if not op.shape.tags.is_empty() else 1
		if b.is_thread_safe():
			removal.append([_combine_job(b, target, steps, AABB(), 0, 0), tag])
			continue
		if frame_budget != null:
			await frame_budget.wait_turn(_priority())
		if not is_inside_tree():
			break
		var start := Time.get_ticks_usec()
		var main_result: Variant = await b.combine_main(target, steps, AABB(), 0, 0)
		if frame_budget != null:
			frame_budget.spend(Time.get_ticks_usec() - start)
		removal.append([_finish_job(b, main_result), tag])
	removing[0] = false


## Gives [param instance]'s surfaces (named [code]tag_<n>[/code], see [method make_mesh])
## the material for their tag from [param by_tag] (none past its end).
static func set_materials(instance: MeshInstance3D, by_tag: Array[Material]) -> void:
	var mesh := instance.mesh as ArrayMesh
	for s in mesh.get_surface_count():
		var tag := mesh.surface_get_name(s).trim_prefix("tag_").to_int()
		instance.set_surface_override_material(s, by_tag[tag] if tag >= 0 and tag < by_tag.size() else null)


# Worker jobs are made by static functions out of plain values, so they never call into a
# node: a piece (or its mesh) can then wait for one before it's freed without deadlocking.

# Everything after the boolean's main-thread part: finish the boolean, clean up, build
# surfaces and collision faces, find border faces. Returns [result, built, border parts], or
# empty if the backend failed. [param build] is a [method _build_job] whose solid is
# replaced by the result; [param border] is [enabled, cell, cut axes, cap tag, cells].
static func _edit_job(combined: Callable, before: Solid, tidy: MeshCleanup, bounds: AABB, build: Callable,
		border: Array) -> Callable:
	return func() -> Array:
		var result: Solid = combined.call()
		if result == null:
			return []
		if tidy != null:
			result = tidy.clean(result, before, bounds)
		var built: Array = build.call(result)
		var parts := AdaptiveMesh._border_parts(result, border[1], border[2], border[3], border[4]) if border[0] else {}
		return [result, built, parts]


# The mesh (made here, on the worker) and what to collide with for the solid it's called
# with: its faces, or with [param convex] (moving mode) [param hulls] hulls' point sets.
# Several hulls take a while, so they're left out (null) and worked out after the mesh is
# shown (see [method _follow_up_hulls]). With [param collide] off, nothing to collide with.
static func _build_job(crease: float, hidden: PackedInt32Array, collide: bool,
		extra_normal_faces: PackedVector3Array, convex: bool, hulls: int) -> Callable:
	return func(solid: Solid) -> Array:
		var surfaces := solid.build_surfaces(crease, hidden, extra_normal_faces)
		var shape: Variant = PackedVector3Array()
		if collide:
			if not convex:
				shape = solid.get_faces(hidden)
			elif hulls <= 1:
				shape = ConvexCells.hull_sets(solid, 1)
			else:
				shape = null
		return [AdaptivePiece.job_mesh(surfaces), shape]


# Finishes what [method _start_removal] started: [removed solid, tag] per dig that removed
# something. Faces where the piece met its neighbours ([param hidden] tags) get the dig's tag.
static func _removed_job(removal: Array, hidden: PackedInt32Array) -> Callable:
	return func() -> Array:
		var out := []
		for entry: Array in removal:
			var removed: Solid = (entry[0] as Callable).call()
			if removed == null or removed.is_empty():
				continue
			for t in removed.tags.size():
				if hidden.has(removed.tags[t]):
					removed.tags[t] = entry[1]
			out.append([removed, entry[1]])
		return out


static func _combine_job(b: BooleanBackend, target: Solid, ops: Array[BooleanOp], bounds: AABB, tag: int,
		walls: int) -> Callable:
	return func() -> Solid:
		var started := StageProfile.begin()
		var out: Solid = b.combine(target, ops, bounds, tag, walls)
		StageProfile.end(&"boolean", started)
		return out


static func _finish_job(b: BooleanBackend, main_result: Variant) -> Callable:
	return func() -> Solid:
		var started := StageProfile.begin()
		var out := b.combine_finish(main_result)
		StageProfile.end(&"boolean", started)
		return out


# This piece's place in the frame budget's queue: its distance from the camera, so the
# pieces nearest the player are shown first.
func _priority() -> float:
	if not is_inside_tree():
		return 0.0
	var centre := bounds.get_center() if bounds.has_volume() else Vector3.ZERO
	return FrameBudget.camera_distance(get_viewport(), global_transform * centre)


# Runs [param job] on a worker thread and waits for it frame by frame.
func _run_on_worker(job: Callable) -> Variant:
	return await WorkerJobs.run(job, self)


func _exit_tree() -> void:
	if _owner_id >= 0 and is_instance_valid(moving_body):
		moving_body.remove_shape_owner(_owner_id)
	_owner_id = -1
	_hulls.clear()


func _notification(what: int) -> void:
	# A job still running reads this piece: let it finish before the piece goes away (a
	# mesh freed mid-edit, a level unloading).
	if what == NOTIFICATION_PREDELETE:
		WorkerJobs.finish(self)


func _apply(built: Array) -> void:
	var started := StageProfile.begin()
	_apply_work(built)
	StageProfile.end(&"main: apply results", started)


func _apply_work(built: Array) -> void:
	_show(as_mesh(built[0]), built[1])
	if not (built[1] is String):
		_collision_solid = solid


func _show(mesh: ArrayMesh, faces: Variant) -> void:
	# Materials go on the instance, not the mesh: baked meshes are shared through the data.
	_mesh_instance.mesh = mesh
	set_materials(_mesh_instance, materials)
	drawn.emit.call_deferred()
	if faces is String:
		return  # KEEP_COLLISION: the collision there is for this solid already
	if moving_body != null:
		if faces is Array:
			_show_hulls(faces)  # (null: hulls to follow, the old ones stay meanwhile)
		return
	if not collision or faces.is_empty():
		if _body != null:
			_body.queue_free()
			_body = null
		return
	if _body == null:
		_body = StaticBody3D.new()
		_shape = CollisionShape3D.new()
		_body.add_child(_shape)
		add_child(_body, false, Node.INTERNAL_MODE_FRONT)
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	_shape.shape = shape


# Moving mode, several hulls: works out the hulls for [param drawn_solid] on a worker once
# its mesh is shown ([param built] left them out), and puts them on the body if the piece
# still has that solid. The piece stays busy until then.
func _follow_up_hulls(built: Array, drawn_solid: Solid) -> void:
	if moving_body == null or not collision or built[1] != null or not is_inside_tree():
		return
	var sets: Array = await _run_on_worker(_hulls_job(hulls_per_piece).bind(drawn_solid))
	if solid == drawn_solid:
		_show_hulls(sets)


static func _hulls_job(hulls: int) -> Callable:
	return func(of: Solid) -> Array: return ConvexCells.hull_sets(of, hulls)


# Moving mode: puts a hull per point set in [param sets] on [member moving_body] as this
# piece's shapes (none for sets of too few points), placed where the piece is relative to
# the body.
func _show_hulls(sets: Array) -> void:
	if not is_instance_valid(moving_body):
		return
	if _owner_id < 0:
		_owner_id = moving_body.create_shape_owner(self)
	moving_body.shape_owner_clear_shapes(_owner_id)
	_hulls.clear()
	if not collision:
		return
	for points: PackedVector3Array in sets:
		if points.size() < 4:
			continue
		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		moving_body.shape_owner_add_shape(_owner_id, hull)
		_hulls.append(hull)
	moving_body.shape_owner_set_transform(_owner_id, moving_body.global_transform.affine_inverse() * global_transform)
