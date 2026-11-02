@tool
@icon("../icon.svg")
class_name WaterSimSprayView
extends Node3D
## Draws spray: whitish particles the water sheds where it is thin (crests, streams, splashes) that fly on gravity and air drag and
## fade when they land or grow old. Purely visual: the simulation never sees them, and they cost it a few comparisons a particle on
## its last substep. They are moved and drawn on the graphics card ([WaterSimSprayEffect]), from a fixed pool, after the water.
##
## How much each substance sheds is its [member WaterSimSubstance.spray]. Put it anywhere; it draws in the simulation's space
## wherever it is. Hidden or off, nothing is shed.

## The simulation to draw. Empty: the nearest above, else the one whose box this is in.
@export var sim: WaterSim
## Shed and draw spray at all.
@export var enabled := true

@export_group("Shed")
## Fast water in a thin place sheds spray: wave crests, the face of a fall.
@export var from_fast := true
## Water flying free (almost alone in its cell) sheds spray: thin streams, drops.
@export var from_free := true
## Water whose velocity changed sharply in a step sheds spray: hitting a collider, the floor or other water.
@export var from_impacts := true
## Water held in a force field or orb that sprays ([member WaterSimForceField.spray]) sheds spray from its surface.
@export var from_fields := true
## How fast (m/s) water must be to shed as fast water.
@export_range(0.0, 20.0, 0.1) var fast_speed := 3.0
## How fast (m/s) free water must be to shed.
@export_range(0.0, 20.0, 0.1) var free_speed := 1.0
## How much its velocity must change in a step (m/s) to shed as an impact.
@export_range(0.0, 20.0, 0.1) var impact_speed := 2.5
## How full (of a cell) the place round a particle may be for it to shed at all: the surface, not the body.
@export_range(0.0, 1.0, 0.01) var surface_full := 0.6
## How full the place round it may be for it to count as flying free.
@export_range(0.0, 1.0, 0.01) var free_full := 0.2
## The most spray shed in a step.
@export_range(0, 16384) var max_per_step := 1024

## How many spray particles each water particle that sheds makes, each scattered its own way. Made on the graphics card: more
## costs the simulation nothing, only pool room (see [member capacity]).
@export_range(1, 16) var per_particle := 1

@export_group("Look")
## The radius (m) of each spray particle.
@export_range(0.005, 0.5, 0.005) var size := 0.03
## How opaque one is.
@export_range(0.0, 1.0, 0.01) var opacity := 0.6
## How long one lives (s), and how much that varies (a fraction).
@export_range(0.1, 10.0, 0.05) var lifetime := 1.2
@export_range(0.0, 1.0, 0.01) var lifetime_spread := 0.4
## How far each is stretched back along its motion (s of travel): streaks. 0: round.
@export_range(0.0, 0.2, 0.001) var stretch := 0.03
## How much the air slows them (1/s).
@export_range(0.0, 10.0, 0.05) var drag := 0.6
## How white they are: 0 their substance's colour, 1 white.
@export_range(0.0, 1.0, 0.01) var whiteness := 0.85
## How far (m) a spawn is scattered from the water it came off, and its velocity (a fraction of its speed, plus kick m/s).
@export_range(0.0, 1.0, 0.005) var scatter := 0.05
@export_range(0.0, 1.0, 0.01) var velocity_scatter := 0.15
@export_range(0.0, 5.0, 0.05) var kick := 0.3
## How many spray particles there can be at once (the oldest go first). Set before the first frame.
@export_range(1024, 1048576) var capacity := 65536

var _sim: WaterSim
var _effect: WaterSimSprayEffect
var _camera: Camera3D
# What was last sent to the solver (set_spray waits for a step in flight, so only on a change).
var _sent: Array = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_effect = WaterSimSprayEffect.new()
	_effect.capacity = capacity
	_connect.call_deferred()


func _exit_tree() -> void:
	if _effect != null:
		_detach()
	if _sim != null and is_instance_valid(_sim) and _sim.get_solver() != null and not _sent.is_empty() and _sent[0] != 0:
		_sim.get_solver().set_spray(0)
	_sent = []


func _connect() -> void:
	_sim = sim if sim != null else WaterSim.find_for(self)
	if _sim != null:
		_sim.stepped.connect(_take)


func _on() -> bool:
	return enabled and is_visible_in_tree()


func _take() -> void:
	var solver := _sim.get_solver()
	if solver == null:
		return
	var triggers := (1 if from_fast else 0) | (2 if from_free else 0) | (4 if from_impacts else 0) | (8 if from_fields else 0) if _on() else 0
	var wanted := [triggers, surface_full, fast_speed, free_full, free_speed, impact_speed, max_per_step]
	if wanted != _sent:
		_sent = wanted
		solver.callv("set_spray", wanted)
	if triggers != 0:
		var shed := solver.take_spray()
		if shed.size() > 0:
			_effect.add_spawns(shed, _sim.get_solver_transform())


func _process(delta: float) -> void:
	if _effect == null or Engine.is_editor_hint():
		return
	_effect.enabled = _on()
	_effect.advance(delta)
	var camera := get_viewport().get_camera_3d()
	if camera != _camera:
		if _camera != null:
			_detach()
		_camera = camera
	if _camera != null:
		_attach()
	_update_look()


func _attach() -> void:
	var compositor := _camera.compositor
	if compositor == null:
		compositor = Compositor.new()
		_camera.compositor = compositor
	var effects := compositor.compositor_effects
	if not _effect in effects:
		effects.append(_effect)
		compositor.compositor_effects = effects


func _detach() -> void:
	if _camera != null and is_instance_valid(_camera) and _camera.compositor != null:
		var effects := _camera.compositor.compositor_effects
		effects.erase(_effect)
		_camera.compositor.compositor_effects = effects


func _update_look() -> void:
	_effect.particle_radius = size
	_effect.opacity = opacity
	_effect.lifetime = lifetime
	_effect.lifetime_spread = lifetime_spread
	_effect.stretch = stretch
	_effect.drag = drag
	_effect.scatter = scatter
	_effect.velocity_scatter = velocity_scatter
	_effect.velocity_kick = kick
	_effect.per_particle = per_particle
	if _sim != null:
		_effect.gravity = _sim.gravity
		var colors := PackedColorArray()
		for substance in _sim.get_substances():
			colors.append(substance.color.lerp(Color.WHITE, whiteness))
		_effect.colors = colors
