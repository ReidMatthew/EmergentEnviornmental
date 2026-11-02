class_name BrushStroke
extends RefCounted
## Turns a continuous edit (a held mouse button, a drill, a burning fuse) into edits on an
## [AdaptiveMesh], with as few overlapping cuts as possible.
##
## The brush sits at the input point, pushed [member advance_direction] by however far it
## has advanced. It advances at [member advance_speed] while the input moves slower than
## that (or always, with [member advance_while_moving]), so holding still digs into the
## surface or builds out of it, and dragging digs along it.
##
## A new edit happens once the brush has moved [member spacing], and never while the mesh
## is still busy with the last one (the movement in between goes into the next edit). With
## [member sweep], each edit is the shape swept from the last brush position to the new
## one, so a stroke is one continuous trench, bore or pillar rather than a pile of
## overlapping stamps.
##
## [codeblock]
## # on press:   stroke.begin(mesh, hit_position)
## # each frame: stroke.update(hit_position, delta)
## # on release: stroke.end()
## [/codeblock]
##
## Pick the points on the surface as it was when the stroke began (the demo raycasts a
## snapshot of it). Raycasting the live mesh makes a dig stroke hit the trench it just
## made and zigzag down into it, cutting far more triangles.

## The shape to stamp or sweep. Sweeping needs a convex one (sphere, box).
var shape: SolidShape
var operation := BooleanOp.Operation.SUBTRACT
## How far (world units) the brush must move before the next edit.
var spacing := 1.0
## Sweep the shape from the last edit to the new brush position. Off stamps the shape at
## the new position only.
var sweep := true
## Sweep only: about how long (world units) the band's triangles are along the stroke.
## 0 makes the band one row, however long the segment.
var band_edge_length := 0.0
## Which way the brush advances (global; normalised when used). For example into the
## surface for digging, out of it for building. Zero turns advancing off.
var advance_direction := Vector3.ZERO
## How fast (world units per second) the brush advances. 0 turns advancing off.
var advance_speed := 0.0
## Advance even while the input moves faster than [member advance_speed] (a drag that
## also goes deeper the longer it lasts).
var advance_while_moving := false
## How far the brush may advance in one stroke. 0 is no limit.
var max_advance := 0.0

var _mesh: AdaptiveMesh
var _last := Vector3.ZERO  # brush position at the last edit
var _input := Vector3.ZERO  # latest input point
var _advanced := 0.0


## Starts a stroke on [param mesh] at [param at] (global), with an edit right there.
func begin(mesh: AdaptiveMesh, at: Vector3) -> void:
	_mesh = mesh
	_input = at
	_advanced = 0.0
	_last = at
	mesh.edit(shape, Transform3D(Basis(), at), operation)


## Moves the input to [param to] (global; pass the same point to hold still) after
## [param delta] seconds. Returns true if that queued an edit.
func update(to: Vector3, delta: float = 0.0) -> bool:
	if not is_active():
		_mesh = null  # (freed during the stroke: a part dug away, say)
		return false
	if delta > 0.0 and advance_speed > 0.0 and not advance_direction.is_zero_approx():
		var input_speed := _input.distance_to(to) / delta
		if advance_while_moving or input_speed < advance_speed:
			_advanced += advance_speed * delta
			if max_advance > 0.0:
				_advanced = minf(_advanced, max_advance)
	_input = to
	var target := get_brush_position()
	if not _mesh.is_idle() or _last.distance_to(target) < spacing:
		return false
	_edit_to(target)
	return true


## Ends the stroke, first covering whatever the brush moved since the last edit.
func end() -> void:
	if is_active():
		var target := get_brush_position()
		if _last.distance_to(target) > spacing * 0.25:
			_edit_to(target)
	_mesh = null


func is_active() -> bool:
	return is_instance_valid(_mesh) and not _mesh.is_queued_for_deletion()


## Where the brush is now: the input point, pushed by however far it has advanced.
func get_brush_position() -> Vector3:
	if advance_direction.is_zero_approx():
		return _input
	return _input + advance_direction.normalized() * _advanced


## How far the brush has advanced this stroke.
func get_advanced() -> float:
	return _advanced


func _edit_to(to: Vector3) -> void:
	if not sweep:
		_mesh.edit(shape, Transform3D(Basis(), to), operation)
	else:
		var offset := to - _last
		var rows := 1 if band_edge_length <= 0.0 else maxi(1, roundi(offset.length() / band_edge_length))
		_mesh.edit_solid(shape.get_solid().swept(offset, rows), Transform3D(Basis(), _last), operation)
	_last = to
