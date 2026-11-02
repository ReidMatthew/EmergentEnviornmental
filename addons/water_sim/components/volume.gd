@tool
class_name WaterSimVolume
extends WaterSimComponent
## A component that acts inside a shape centred on itself: emitters, converters, drains
## and force fields. The shape is drawn in the editor.

@export var shape := WaterSim.Shape.SPHERE:
	set(value):
		shape = value
		notify_property_list_changed()
		_redraw()
## Full size, for a box.
@export var size := Vector3.ONE:
	set(value):
		size = value
		_redraw()
@export var radius := 0.5:
	set(value):
		radius = value
		_redraw()
## Full height (including the caps, for a capsule).
@export var height := 1.0:
	set(value):
		height = value
		_redraw()
## Draw the shape in game too.
@export var show_shape := false:
	set(value):
		show_shape = value
		_redraw()

var _lines: MeshInstance3D


func _ready() -> void:
	_redraw()


func _validate_property(property: Dictionary) -> void:
	var name: String = property.name
	var hidden := (name == "size" and shape != WaterSim.Shape.BOX) \
			or (name == "radius" and shape == WaterSim.Shape.BOX) \
			or (name == "height" and (shape == WaterSim.Shape.BOX or shape == WaterSim.Shape.SPHERE))
	if hidden:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## What the solver calls the shape's size (see [method WaterSim.get_extents]).
func get_extents() -> Vector3:
	return WaterSim.get_extents(shape, size, radius, height)


## Whether a global point is inside the shape.
func has_point(point: Vector3) -> bool:
	var p := global_transform.affine_inverse() * point
	match shape:
		WaterSim.Shape.SPHERE:
			return p.length() <= radius
		WaterSim.Shape.CAPSULE:
			var half := maxf(height * 0.5 - radius, 0.0)
			return (p - Vector3(0, clampf(p.y, -half, half), 0)).length() <= radius
		WaterSim.Shape.CYLINDER:
			return Vector2(p.x, p.z).length() <= radius and absf(p.y) <= height * 0.5
	return absf(p.x) <= size.x * 0.5 and absf(p.y) <= size.y * 0.5 and absf(p.z) <= size.z * 0.5


## The shape's global bounds.
func get_global_box() -> AABB:
	var e := get_extents()
	var half := e
	match shape:
		WaterSim.Shape.SPHERE:
			half = Vector3.ONE * radius
		WaterSim.Shape.CAPSULE, WaterSim.Shape.CYLINDER:
			half = Vector3(radius, height * 0.5, radius)
	var t := global_transform
	return t * AABB(-half, half * 2.0)


## The colour the shape is drawn in.
func _get_shape_color() -> Color:
	return Color(0.4, 0.8, 1.0)


func _redraw() -> void:
	if not is_inside_tree():
		return
	if not (Engine.is_editor_hint() or show_shape):
		if _lines != null:
			_lines.queue_free()
			_lines = null
		return
	if _lines == null:
		_lines = preload("../shape_lines.gd").new()
		add_child(_lines, false, Node.INTERNAL_MODE_BACK)
	var drawn := size if shape == WaterSim.Shape.BOX else Vector3(radius, height, radius)
	_lines.draw(shape, drawn, _get_shape_color())
