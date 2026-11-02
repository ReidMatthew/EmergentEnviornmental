@tool
class_name BooleanOp
extends RefCounted
## One boolean step: combine [member shape], placed by [member transform], into a solid.

enum Operation {
	## Keep everything in either (add material).
	UNION,
	## Remove the shape from the solid (dig).
	SUBTRACT,
	## Keep only what is in both.
	INTERSECT,
}

var shape: Solid
## Where the shape goes, in the solid's space.
var transform := Transform3D.IDENTITY
var operation := Operation.SUBTRACT
## A subtract only: whether what it removes may become debris (see
## [member AdaptiveMesh.debris]). Off for cuts, whose thin slab is just discarded.
var debris := true


static func create(op_shape: Solid, op_transform: Transform3D, op_operation: Operation) -> BooleanOp:
	var op := BooleanOp.new()
	op.shape = op_shape
	op.transform = op_transform
	op.operation = op_operation
	return op
