@tool
class_name WaterSimForceField
extends WaterSimVolume
## Base for nodes that push matter around inside their shape. They steer velocities
## towards a target rather than adding raw force, so they stay stable at any strength:
## [member strength] is how quickly matter takes up the target (per second).

@export var enabled := true
## How quickly matter takes up the field's velocity (1/s). Above about 60 it's immediate.
@export_range(0.0, 60.0, 0.1, "or_greater") var strength := 4.0
## The outer fraction of the shape over which the field fades out.
@export_range(0.0, 1.0) var falloff := 0.4

@export_group("Spray")
## The water it holds sheds spray from its surface, flung outwards: a gathered ball steams, a tornado throws off mist. Drawn by a
## [WaterSimSprayView] (none: nothing is shed); substances with no [member WaterSimSubstance.spray] (slime) never shed.
@export var spray := false
## The chance a step that a particle at the surface of the water in it sheds spray. The ones shed in a step are capped by the spray
## view's [member WaterSimSprayView.max_per_step].
@export_range(0.0, 1.0, 0.005) var spray_amount := 0.03
## How fast (m/s) the spray leaves, outwards from its middle (a vortex's: from its axis), on top of the water's own speed.
@export_range(0.0, 10.0, 0.1) var spray_speed := 1.5


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not enabled:
		return
	# Keeps its box awake (or starts one).
	_activity()


func _attach(on: WaterSim) -> void:
	on._register_field(self)


func _detach(from: WaterSim) -> void:
	from._unregister_field(self)


## The solver dictionary (see [method WaterSimSolver.set_fields]).
func get_solver_field(on: WaterSim) -> Dictionary:
	var field := {
		"shape": shape,
		"transform": on.to_solver(global_transform),
		"extents": get_extents(),
		"strength": strength,
		"falloff": falloff,
		"spray": spray_amount if spray else 0.0,
		"spray_speed": spray_speed,
	}
	field.merge(_get_settings(), true)
	return field


## The field's own settings: type and its speeds.
func _get_settings() -> Dictionary:
	return {}


func _get_shape_color() -> Color:
	return Color(0.9, 0.9, 0.5) if enabled else Color(0.5, 0.5, 0.4)
