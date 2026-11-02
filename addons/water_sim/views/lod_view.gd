@tool
@icon("../icon.svg")
class_name WaterSimLodView
extends MultiMeshInstance3D
## Draws a [WaterSim]'s particles as see-through discs coloured by their level of detail, to see what the simulation is made of
## where: level 0 the simulation's fine particles (blue), 1 the particles that stand for eight fine
## ones (red, adaptive detail), 2 and 3 coarser still (yellow, black). Each level can be hidden, to see
## what is under it. For debugging: every particle is drawn, none culled or thinned, so it costs much more than a fluid view.
##
## Put it anywhere; it draws in the simulation's space wherever it is. Hidden, it costs nothing.

const LEVELS := 4
const LEVEL_NAMES: PackedStringArray = ["fine", "coarse x8", "coarse x64", "coarse x512"]

## The simulation to draw. Empty: the nearest above, else the one whose box this is in.
@export var sim: WaterSim
## The colour of each level (its alpha is how see-through it is).
@export var colors: PackedColorArray = [Color(0.15, 0.35, 1.0, 0.35), Color(1.0, 0.1, 0.1, 0.35),
		Color(1.0, 0.9, 0.1, 0.35), Color(0.0, 0.0, 0.0, 0.5)]:
	set(value):
		colors = value
		_update_material()
## The discs' size as a multiple of the size each particle is drawn at by a fluid view (smaller shows them apart).
@export_range(0.05, 2.0, 0.05) var size_scale := 0.6:
	set(value):
		size_scale = value
		_update_material()
## Bit n set: level n is not drawn.
@export_flags("Fine", "Coarse x8", "Coarse x64", "Coarse x512") var hidden_levels := 0:
	set(value):
		hidden_levels = value
		_update_material()

const _WIDTH := 4096

var _sim: WaterSim
var _material: ShaderMaterial
var _texture: ImageTexture
var _rows := 0
var _counts := PackedInt64Array()
var _asleep := 0
var _counted := 0.0
var _grey_asleep := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	multimesh = MultiMesh.new()
	# (The shader places each disc from the buffer; the instances only count them.)
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	multimesh.mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = preload("../shaders/lod_view.gdshader")
	material_override = _material
	_counts.resize(LEVELS)
	_update_material()
	_connect.call_deferred()


func _connect() -> void:
	_sim = sim if sim != null else WaterSim.find_for(self)
	if _sim != null:
		_sim.stepped.connect(_redraw)


func _exit_tree() -> void:
	if _sim != null and is_instance_valid(_sim) and _sim.get_solver() != null:
		_sim.get_solver().clear_buffer_request(_key())


## The simulation drawn (null until found).
func get_sim() -> WaterSim:
	return _sim


## How many particles each level has (fine, then coarser), as of the last count (a few times a second while shown).
func get_level_counts() -> PackedInt64Array:
	return _counts


## Draws the particles in sleeping blocks grey, and leaves them out of [method get_level_counts].
var grey_asleep: bool:
	get:
		return _grey_asleep
	set(value):
		_grey_asleep = value
		_counted = 0.0
		_update_material()


## With [member grey_asleep], leaves the sleeping particles out instead of drawing them grey.
var hide_asleep := false:
	set(value):
		hide_asleep = value
		_update_material()


## How many particles are in sleeping blocks, as of the last count (see [member grey_asleep]; 0 while that is off).
func get_asleep_count() -> int:
	return _asleep


## Whether a level is drawn.
func is_level_shown(level: int) -> bool:
	return hidden_levels >> level & 1 == 0


func set_level_shown(level: int, shown: bool) -> void:
	hidden_levels = hidden_levels & ~(1 << level) if shown else hidden_levels | (1 << level)


func _key() -> int:
	return (get_instance_id() & 0x3ffffffe)


func _redraw() -> void:
	var solver := _sim.get_solver()
	# Hidden views cost nothing.
	if solver == null or not is_visible_in_tree():
		if solver != null:
			solver.clear_buffer_request(_key())
		return
	global_transform = _sim.get_solver_transform()
	var mask := _sim.get_mask([])
	# (The blocks come nearest the camera first and the shader draws them last to first, so what is nearest is on top: the discs
	# are see-through and write no depth, so in any other order the colours show the order, not the water.)
	var camera := get_viewport().get_camera_3d()
	var eye := _sim.get_solver_transform().affine_inverse() * camera.global_position if camera != null else Vector3.ZERO
	solver.set_point_request(_key(), mask, PackedFloat32Array(), 0, false, _grey_asleep, eye)
	var taken: Variant = solver.take_buffer(_key())
	if taken == null:
		return
	var count := solver.get_buffer_point_count(_key())
	_upload(taken, count)
	_material.set_shader_parameter(&"count", count)
	_material.set_shader_parameter(&"extent", Vector3(_sim.get_dims()) * _sim.cell_size)
	_material.set_shader_parameter(&"to_world", Projection(global_transform))
	_material.set_shader_parameter(&"radius", _sim.cell_size * 0.56)
	custom_aabb = AABB(Vector3.ZERO, Vector3(_sim.get_dims()) * _sim.cell_size)
	_count_levels(solver)


func _upload(bytes: PackedByteArray, count: int) -> void:
	# Kept at a whole number of rows, grown by half again, so most frames update the texture in place.
	var rows := maxi(1, ceili(float(count) / _WIDTH))
	if rows > _rows or _texture == null:
		_rows = maxi(rows, _rows * 3 / 2)
		_texture = null
		multimesh.instance_count = _rows * _WIDTH
	bytes.resize(_rows * _WIDTH * 8)
	var image := Image.create_from_data(_WIDTH, _rows, false, Image.FORMAT_RGBA16, bytes)
	if _texture == null:
		_texture = ImageTexture.create_from_image(image)
		_material.set_shader_parameter(&"points", _texture)
		_material.set_shader_parameter(&"width", _WIDTH)
	else:
		_texture.update(image)
	multimesh.visible_instance_count = count


func _count_levels(solver: WaterSimSolver) -> void:
	# (The levels are read after the step under way finishes: a stall, so only a few times a second.)
	var now := Time.get_ticks_msec() / 1000.0
	if now - _counted < 0.5:
		return
	_counted = now
	var levels := solver.get_levels()
	for level in LEVELS:
		_counts[level] = levels.count(level)
	_asleep = 0
	if _grey_asleep:
		var asleep := solver.get_asleep_levels()
		_asleep = asleep.size()
		for level in LEVELS:
			_counts[level] -= asleep.count(level)


func _update_material() -> void:
	if _material == null:
		return
	var padded := colors.duplicate()
	padded.resize(LEVELS)
	_material.set_shader_parameter(&"colors", padded)
	_material.set_shader_parameter(&"size_scale", size_scale)
	_material.set_shader_parameter(&"hidden_levels", hidden_levels)
	_material.set_shader_parameter(&"grey_asleep", _grey_asleep)
	_material.set_shader_parameter(&"hide_asleep", hide_asleep)
