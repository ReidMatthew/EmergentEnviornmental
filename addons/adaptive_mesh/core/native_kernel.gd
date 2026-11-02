@tool
class_name NativeKernel
extends RefCounted
## The heaviest geometry in native code, when the adaptive_mesh_native add-on is installed
## and its library loads on this platform: clean-up ([method MeshCleanup.clean]), surfaces
## ([method Solid.build_surfaces]), welding, islands, seam faces and joining parts. Each
## gives exactly what the GDScript gives (the add-on's tests check it), many times faster,
## so nothing else changes. Found by class name, so this add-on doesn't need that one;
## without it, the GDScript runs.

## The native class (from adaptive_mesh_native).
const CLASS := &"AdaptiveMeshKernel"

## Off: always run the GDScript (to compare the two, or to rule the native code out).
static var enabled := true

static var _available := -1  # -1: not looked yet


## True if the native code runs: [member enabled] and the library loaded.
static func on() -> bool:
	if not enabled:
		return false
	if _available < 0:
		_available = 1 if ClassDB.class_exists(CLASS) else 0
	return _available == 1


## True if a piece's whole edit can run as one native call ([method edit_job]): the native
## core is on, [param backend] is adaptive_mesh_native's Manifold backend with its library
## loaded, and [param cleanup] is none or a plain [MeshCleanup] (a subclass may clean up
## its own way).
static func can_fuse(backend: BooleanBackend, cleanup: MeshCleanup) -> bool:
	return on() and backend != null and backend.has_method(&"combine_native") and backend.is_thread_safe() \
			and (cleanup == null or cleanup.get_script() == MeshCleanup)


## A worker job doing what [code]AdaptivePiece._edit_job[/code] does (boolean, clean-up,
## surfaces, collision data, seam faces) in one native call. Returns the same
## [code][result, [surfaces, collision], seam faces][/code], or empty if the boolean failed.
## [param build] and [param border] are what the piece's build and border settings are:
## [code][crease, hidden tags, collide, extra normal faces, convex, hulls][/code] and
## [code][on, cell, cut axes, cap tag, cells][/code].
static func edit_job(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int, bounds_walls: int,
		cleanup: MeshCleanup, build: Array, border: Array) -> Callable:
	var steps := []
	for op in ops:
		var operation := 1 if op.operation == BooleanOp.Operation.SUBTRACT \
				else (2 if op.operation == BooleanOp.Operation.INTERSECT else 0)
		steps.append([op.shape.positions, op.shape.indices, op.shape.tags, op.shape.uvs, op.transform, operation])
	var settings := PackedFloat64Array()
	if cleanup != null:
		settings = PackedFloat64Array([cleanup.min_edge_length, cleanup.sliver_angle, cleanup.max_error,
				cleanup.feature_angle, cleanup.max_normal_change, cleanup.unlock_rings, cleanup.passes])
	var cut: Array[bool] = border[2]
	var mask := (1 if cut[0] else 0) | (2 if cut[1] else 0) | (4 if cut[2] else 0)
	var native_border := [border[0], border[1], mask, border[3], border[4]]
	return func() -> Array:
		var started := StageProfile.begin()
		var out: Array = ClassDB.class_call_static(CLASS, &"edit_piece", target.positions, target.indices,
				target.tags, target.uvs, steps, bounds, bounds_tag, bounds_walls, settings, build, native_border)
		StageProfile.end(&"native edit", started)
		if out.is_empty():
			return []
		return [to_solid(out[0]), [AdaptivePiece.job_mesh(out[1]), out[2]], out[3]]


## A solid from [code][positions, indices, tags, uvs][/code] as the native calls return them.
static func to_solid(arrays: Array) -> Solid:
	var solid := Solid.new()
	solid.positions = arrays[0]
	solid.indices = arrays[1]
	solid.tags = arrays[2]
	solid.uvs = arrays[3]
	return solid
