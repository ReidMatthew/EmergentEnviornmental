@tool
@icon("../icon.svg")
class_name WaterSimParticleView
extends MultiMeshInstance3D
## Draws a [WaterSim]'s particles as small meshes coloured by substance (each substance's
## [member WaterSimSubstance.color]). Cheap and clear: good for grainy matter (sand, snow,
## rubble) and for seeing what the simulation is doing.
##
## Put it anywhere; it draws in the simulation's space wherever it is.

## The simulation to draw. Empty: the nearest above, else the one whose box this is in.
@export var sim: WaterSim
## Which substances to draw. Empty: all.
@export var substances: Array[WaterSimSubstance] = []
## Size of each particle's mesh. 0: about a third of a cell.
@export var particle_radius := 0.0
## The mesh drawn per particle (radius 1). Empty: a low sphere.
@export var particle_mesh: Mesh
## Draw only particles where the matter is thinner than this (kg/m^3): spray, drops and
## streams too thin for a [WaterSimSurfaceView] to wrap. 0: draw them all.
@export var max_density := 0.0

var _sim: WaterSim


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	top_level = true
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	if particle_mesh == null:
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 8
		sphere.rings = 4
		particle_mesh = sphere
	multimesh.mesh = particle_mesh
	if material_override == null:
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material_override = material
	_connect.call_deferred()


func _connect() -> void:
	_sim = sim if sim != null else WaterSim.find_for(self)
	if _sim != null:
		_sim.stepped.connect(_redraw)


func _exit_tree() -> void:
	if _sim != null and _sim.get_solver() != null:
		_sim.get_solver().clear_buffer_request(get_instance_id() & 0x3fffffff)


func _redraw() -> void:
	var solver := _sim.get_solver()
	# Hidden views cost nothing.
	var key := get_instance_id() & 0x3fffffff
	if solver == null or not is_visible_in_tree():
		if solver != null:
			solver.clear_buffer_request(key)
		return
	global_transform = _sim.get_solver_transform()
	var colors := PackedColorArray()
	for substance in _sim.get_substances():
		colors.append(substance.color)
	var radius := particle_radius if particle_radius > 0.0 else _sim.cell_size * 0.35
	# Built after each step on the thread that stepped, shown a step later.
	solver.set_particle_request(key, _sim.get_mask(substances), radius, colors, max_density)
	var taken: Variant = solver.take_buffer(key)
	if taken == null:
		return
	var buffer: PackedFloat32Array = taken
	var count := buffer.size() / 16
	if multimesh.instance_count != count:
		multimesh.instance_count = count
	if count > 0:
		RenderingServer.multimesh_set_buffer(multimesh.get_rid(), buffer)
	# The particles can be anywhere in the box.
	custom_aabb = AABB(Vector3.ZERO, _sim.size)
