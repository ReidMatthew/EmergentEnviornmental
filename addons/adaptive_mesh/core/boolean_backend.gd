@tool
@abstract
class_name BooleanBackend
extends Resource
## Runs mesh booleans. Subclass this to add a backend (Godot's CSG nodes, a Manifold
## GDExtension, ...); anything holding an BooleanBackend can use any of them.


## Applies [param ops] to [param target] in order and returns the result, or null if the
## backend failed (the caller keeps the old solid). [param target] is not modified. It may
## be empty (unions then build from nothing), and so may the result (everything dug out).
##
## If [param bounds] has a size, a union never adds anything outside it: the shape is cut
## to the box first. Faces the cut makes on the box's sides in [param bounds_walls] get
## [param bounds_tag]; on its other sides they get the shape's own tag. Use the walls for
## sides shared with a neighbouring piece (whose faces are hidden), the rest for real outer
## limits (whose faces must show). Bits: 1 = -x, 2 = +x, 4 = -y, 8 = +y, 16 = -z, 32 = +z;
## see [method side_bit].
##
## May be a coroutine (await it): backends that need the scene tree finish on a later
## frame. Called from worker threads when [method is_thread_safe] is true.
@abstract func combine(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Solid


## [method combine] in two parts, for backends that must use the main thread
## ([method is_thread_safe] false): this part runs on the main thread and does only what
## has to happen there, returning whatever [method combine_finish] needs; that part runs
## on a worker thread. By default this is all of [method combine] and the finish passes
## the result through. May be a coroutine.
func combine_main(target: Solid, ops: Array[BooleanOp], bounds: AABB, bounds_tag: int,
		bounds_walls: int = 63) -> Variant:
	return await combine(target, ops, bounds, bounds_tag, bounds_walls)


## Turns what [method combine_main] returned into the result (or null if the backend
## failed). Called from worker threads.
func combine_finish(main_result: Variant) -> Solid:
	return main_result


## The bit for side [param axis] (0-2), [param positive] or negative, in a sides mask.
static func side_bit(axis: int, positive: bool) -> int:
	return 1 << (axis * 2 + (1 if positive else 0))


## Return false if [method combine] has to run on the main thread.
func is_thread_safe() -> bool:
	return true
