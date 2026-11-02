@tool
class_name ManifoldBooleanBackend
extends BooleanBackend
## Mesh booleans with the Manifold library, called directly through this add-on's
## GDExtension instead of through Godot's CSG nodes: thread-safe, so edits run on worker
## threads and leave the main thread free. Put it in an [AdaptiveMesh]'s
## [member AdaptiveMesh.backend] slot; with this add-on installed, adaptive meshes with no
## backend set use it by themselves (see [method AdaptiveMesh.get_backend]).
##
## Where the library isn't built for the platform (see the README), it falls back to
## [CsgBooleanBackend], so a project still runs, only slower.

const NATIVE := &"ManifoldBoolean"

var _fallback: CsgBooleanBackend


## True if the native library loaded on this platform.
static func is_available() -> bool:
	return ClassDB.class_exists(NATIVE)


## The Manifold library's version, or empty if it isn't available.
static func get_manifold_version() -> String:
	return ClassDB.class_call_static(NATIVE, &"get_manifold_version") if is_available() else ""


func is_thread_safe() -> bool:
	return is_available()


func combine(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Solid:
	if not is_available():
		if _fallback == null:
			_fallback = CsgBooleanBackend.new()
		return await _fallback.combine(target, ops, bounds, bounds_tag, bounds_walls)
	return combine_native(target, ops, bounds, bounds_tag, bounds_walls)


## [method combine] with the native library only (no fallback): not a coroutine, so it can
## be called without [code]await[/code]. Only call it when [method is_available].
func combine_native(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Solid:
	if target.is_empty() and not ops.any(func(op: BooleanOp) -> bool: return op.operation == BooleanOp.Operation.UNION):
		return Solid.new()  # nothing to cut from, nothing added
	var steps := []
	for op in ops:
		steps.append([op.shape.positions, op.shape.indices, op.shape.tags, op.shape.uvs, op.transform,
				_native_operation(op.operation)])
	var result: Array = ClassDB.class_call_static(NATIVE, &"combine", target.positions, target.indices,
			target.tags, target.uvs, steps, bounds, bounds_tag, bounds_walls)
	if result.is_empty():
		return null
	var solid := Solid.new()
	solid.positions = result[0]
	solid.indices = result[1]
	solid.tags = result[2]
	solid.uvs = result[3]
	solid.weld()
	return solid


func combine_main(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Variant:
	if not is_available():
		if _fallback == null:
			_fallback = CsgBooleanBackend.new()
		return await _fallback.combine_main(target, ops, bounds, bounds_tag, bounds_walls)
	return await combine(target, ops, bounds, bounds_tag, bounds_walls)


func combine_finish(main_result: Variant) -> Solid:
	if not is_available() and _fallback != null:
		return _fallback.combine_finish(main_result)
	return main_result


static func _native_operation(operation: BooleanOp.Operation) -> int:
	match operation:
		BooleanOp.Operation.SUBTRACT:
			return 1
		BooleanOp.Operation.INTERSECT:
			return 2
	return 0
