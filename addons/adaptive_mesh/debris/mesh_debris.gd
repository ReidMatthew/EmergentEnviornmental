@tool
class_name MeshDebris
extends Resource
## What an [AdaptiveMesh]'s digs break off, as plain [RigidBody3D]s (fracturing, paused:
## parts that digs and cuts divide off are [member AdaptiveMesh.separation]'s, and stay
## adaptive). Give it to [member AdaptiveMesh.debris]; [member enabled] off (or an empty
## slot) turns it off at no cost.
##
## [b]Dig fragments[/b] ([member fragments], on): every dig (a subtract) also works out the
## material it removed and breaks it into fragments that fly apart and shrink away after
## [member lifetime]. They're the removed material cut by a random Voronoi split, each cell
## one fragment (and each part of a cell that doesn't touch the rest its own); the cuts
## are flat, so they're made by clipping on a worker thread, not with booleans. Where a dig
## crosses the pieces of a chunked mesh, the piece walls split it too. Cost: one more
## boolean per dig on each piece it reaches (about as much as the dig itself; with the CSG
## backend on the main thread, within [member AdaptiveMesh.main_thread_budget_ms]).
##
## Fragments start exactly where the material was and collide as a convex hull of their
## corners, a little smaller than themselves, which stays inside the hole for convex
## brushes (spheres, boxes, sweeps of them). The bodies then cost what rigid bodies cost in
## your physics engine: keep [member max_bodies] modest.
##
## Sizes and speeds are in world units. Override [method make_body] for your own bodies
## (sounds on impact, particles, pooled nodes), or connect to
## [signal AdaptiveMesh.debris_spawned].

## Turns all debris off without removing the settings.
@export var enabled := true

@export_group("Dig fragments")
## Break what each dig removes into fragments. Off: digs cost nothing extra.
@export var fragments := true
## About how wide fragments are: a dig that removes more breaks into more of them.
@export_range(0.01, 10.0, 0.01, "or_greater") var fragment_size := 0.6
## At most this many fragments from one dig on one piece, however big.
@export_range(1, 64) var max_fragments := 8
## How fast fragments fly apart from the middle of the dig (units per second).
@export_range(0.0, 50.0, 0.1, "or_greater") var scatter_speed := 1.5
## Seconds before a fragment shrinks away and is freed. 0 keeps it (until
## [member max_bodies] pushes it out).
@export_range(0.0, 600.0, 0.1, "or_greater") var lifetime := 10.0

@export_group("Bodies")
## Fragments smaller than about this across, or thinner than a sixth of it, are dropped
## instead (dust).
@export_range(0.0, 10.0, 0.001, "or_greater") var min_size := 0.1
## Mass per cubic unit.
@export_range(0.001, 100.0, 0.001, "or_greater") var density := 1.0
## Friction of the bodies (0 slides like ice, 1 is Godot's default).
@export_range(0.0, 1.0, 0.01) var friction := 0.3
## At most this many fragments per mesh at once; the oldest go first.
@export_range(1, 1000, 1, "or_greater") var max_bodies := 60
## Physics layers the bodies are on. Leave them off the layers your dig rays hit if
## digging shouldn't stop at debris.
@export_flags_3d_physics var layer := 1
## Physics layers the bodies collide with (include the mesh's pieces).
@export_flags_3d_physics var mask := 1

## Picks the fragments' cells and scatter. Seed it for repeatable debris.
var rng := RandomNumberGenerator.new()
var _physics_material: PhysicsMaterial  # shared by the bodies, for friction


## Breaks [param removed] (a closed solid) into fragments: clipped to Voronoi cells on a
## worker thread (the cut faces get [param cut_tag]; a cell whose cut has a hole is
## intersected with [param backend] instead, sharing main-thread time through
## [param budget] if given), split into parts that don't touch, without dust (see
## [member min_size]). A coroutine. Stops (no fragments) if [param owner] is freed meanwhile.
func break_up(removed: Solid, cut_tag: int, backend: BooleanBackend, budget: FrameBudget = null,
		owner: Object = null) -> Array[Solid]:
	var owned := owner != null
	var min_volume := min_size * min_size * min_size
	var volume := removed.get_volume()
	if volume <= min_volume:
		return [] as Array[Solid]
	var count := clampi(roundi(volume / (fragment_size * fragment_size * fragment_size)), 1, max_fragments)
	var seeds := _seeds(removed, count) if count > 1 else PackedVector3Array()
	# [parts, cells the clipping couldn't do]
	var clipped: Array = await run_on_worker(_clip_job(removed, seeds, cut_tag, min_volume), owner)
	if owned and not is_instance_valid(owner):
		return [] as Array[Solid]
	var parts: Array[Solid] = clipped[0]
	var box := removed.get_aabb().grow(0.01)
	for i: int in clipped[1]:
		# A cut with a hole in it: the cell takes a boolean instead.
		var ops: Array[BooleanOp] = [BooleanOp.create(voronoi_cell(box, seeds, i, cut_tag), Transform3D.IDENTITY,
				BooleanOp.Operation.INTERSECT)]
		var part: Solid
		if backend.is_thread_safe():
			part = await run_on_worker(func() -> Solid: return backend.combine(removed, ops, AABB(), cut_tag, 0), owner)
		else:
			if budget != null:
				await budget.wait_turn()
			var start := Time.get_ticks_usec()
			var main_result: Variant = await backend.combine_main(removed, ops, AABB(), cut_tag, 0)
			if budget != null:
				budget.spend(Time.get_ticks_usec() - start)
			part = await run_on_worker(func() -> Solid: return backend.combine_finish(main_result), owner)
		if owned and not is_instance_valid(owner):
			return [] as Array[Solid]
		if part != null and not part.is_empty():
			parts.append_array(await run_on_worker(_split_job(part, min_volume), owner))
		if owned and not is_instance_valid(owner):
			return [] as Array[Solid]
	return parts


## A rigid body for [param fragment] (centred on its origin), drawn with [param mesh] (made from it, surfaces named by tag) and
## [param materials] by tag, colliding as the convex
## hull of [param hull] (see [method get_hull_points]), with mass from its volume. Override
## to make your own; the caller places it, sets its velocity and frees it later.
func make_body(fragment: Solid, mesh: ArrayMesh, hull: PackedVector3Array, materials: Array[Material]) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = layer
	body.collision_mask = mask
	body.mass = maxf(fragment.get_volume() * density, 0.001)
	if _physics_material == null or _physics_material.friction != friction:
		_physics_material = PhysicsMaterial.new()
		_physics_material.friction = friction
	body.physics_material_override = _physics_material
	var view := MeshInstance3D.new()
	view.mesh = mesh
	AdaptivePiece.set_materials(view, materials)
	body.add_child(view)
	var convex := ConvexPolygonShape3D.new()
	convex.points = hull
	var shape := CollisionShape3D.new()
	shape.shape = convex
	body.add_child(shape)
	return body


## [method Solid.get_hull_points], shrunk a little by default, so a fragment doesn't start
## touching the walls of the hole it came out of.
static func get_hull_points(solid: Solid, shrink: float = 0.95) -> PackedVector3Array:
	return solid.get_hull_points(shrink)


## Runs [param job] on a worker thread and returns what it returned, checking each frame
## whether it's done. A coroutine. The job must not touch nodes (they may be freed by the
## time it runs). [param owner] waits for it if freed first (see [WorkerJobs]).
static func run_on_worker(job: Callable, owner: Variant = null) -> Variant:
	# (Untyped: an owner freed while its caller awaited is still passed, as nothing.)
	return await WorkerJobs.run(job, owner if is_instance_valid(owner) else null)


## The Voronoi cells of [param seeds] inside [param box] (see [method ConvexCells.voronoi_cells]).
static func voronoi_cells(box: AABB, seeds: PackedVector3Array, tag: int) -> Array[Solid]:
	return ConvexCells.voronoi_cells(box, seeds, tag)


## See [method ConvexCells.voronoi_cell].
static func voronoi_cell(box: AABB, seeds: PackedVector3Array, index: int, tag: int) -> Solid:
	return ConvexCells.voronoi_cell(box, seeds, index, tag)


## See [method ConvexCells.clip].
static func clip(solid: Solid, plane: Plane, tag: int, tolerance: float = 1e-6) -> Solid:
	return ConvexCells.clip(solid, plane, tag, tolerance)


## See [method ConvexCells.convex_solid].
static func convex_solid(planes: Array[Plane], tag: int, tolerance: float = 1e-5) -> Solid:
	return ConvexCells.convex_solid(planes, tag, tolerance)


## See [method ConvexCells.triangulate].
static func triangulate(points: PackedVector2Array) -> Array:
	return ConvexCells.triangulate(points)


## Where [param solid]'s volume is centred (see [method Solid.get_centre]).
static func get_centre(solid: Solid) -> Vector3:
	return solid.get_centre()


# [removed] split by the Voronoi cells of [param seeds] (none: whole) into parts that don't
# touch, without those under [param min_volume]: [parts, indices of cells the clipping
# couldn't do].
static func _clip_job(removed: Solid, seeds: PackedVector3Array, tag: int, min_volume: float) -> Callable:
	return func() -> Array:
		var parts: Array[Solid] = []
		var failed := PackedInt32Array()
		if seeds.is_empty():
			parts.append_array(MeshDebris._split_job(removed, min_volume).call())
			return [parts, failed]
		for i in seeds.size():
			var planes := ConvexCells._bisectors(seeds, i)
			# Nearest seeds first: their cuts shrink the part most.
			planes.sort_custom(func(p: Plane, q: Plane) -> bool:
				return absf(p.distance_to(seeds[i])) < absf(q.distance_to(seeds[i])))
			var part := removed
			for plane in planes:
				part = ConvexCells.clip(part, plane, tag)
				if part == null or part.is_empty():
					break
			if part == null:
				failed.append(i)
			elif not part.is_empty():
				parts.append_array(MeshDebris._split_job(part, min_volume).call())
		return [parts, failed]


# The parts of [param cut] that don't touch, without those under [param min_volume] or
# thinner than a sixth of its side (a slab's thickness is about twice its volume over its
# area; physics can't make a hull of a flake either).
static func _split_job(cut: Solid, min_volume: float) -> Callable:
	return func() -> Array[Solid]:
		var out: Array[Solid] = []
		var min_thickness := pow(min_volume, 1.0 / 3.0) / 6.0
		for part in cut.get_islands():
			var volume := part.get_volume()
			if volume >= min_volume and volume * 2.0 >= MeshDebris._area(part) * min_thickness:
				out.append(part)
		return out


static func _area(solid: Solid) -> float:
	var area := 0.0
	for t in solid.indices.size() / 3:
		var a := solid.positions[solid.indices[t * 3]]
		area += (solid.positions[solid.indices[t * 3 + 1]] - a).cross(solid.positions[solid.indices[t * 3 + 2]] - a).length()
	return area * 0.5


# Seeds for [param count] cells, spread through the solid: between its middle and random
# corners of it, so few land outside it.
func _seeds(solid: Solid, count: int) -> PackedVector3Array:
	var middle := get_centre(solid)
	var seeds := PackedVector3Array()
	for i in count:
		var corner := solid.positions[rng.randi_range(0, solid.positions.size() - 1)]
		seeds.append(middle.lerp(corner, rng.randf_range(0.25, 0.9)))
	return seeds
