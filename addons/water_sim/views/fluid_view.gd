@tool
@icon("../icon.svg")
class_name WaterSimFluidView
extends Node3D
## Draws a [WaterSim]'s water as water: no mesh, no triangles, the particles themselves shaded as a fluid in the camera's picture
## (see [WaterSimFluidEffect]). Light and shallow where the water is thin, deep where it is thick, each substance its own colour, the
## picture behind bent by the surface, the sky at glancing angles, the sun on it. It makes a compositor effect and puts it on the
## camera that is looking (so the game needs no setup beyond this node); needs the Forward+ or Mobile renderer.
##
## Put it anywhere; it draws in the simulation's space wherever it is. The particles are handed over after each step, a step late.

## The simulation to draw. Empty: the nearest above, else the one whose box this is in.
@export var sim: WaterSim
## Which substances to draw. Empty: all.
@export var substances: Array[WaterSimSubstance] = []
enum Style {
	## Lit, solid-looking water, as Liquid Crystal draws it: near particles as spheres, small far ones rasterized by a compute
	## pass (no triangles for them), the surface smoothed and lit. Cheaper: no thickness pass, no refraction.
	OPAQUE,
	## See-through water: depth, an additive thickness pass, refraction of what is behind it, shallow and deep colour. Small far
	## particles go to the compute pass here too, for their depth and thickness.
	TRANSLUCENT,
	## See-through water at the opaque style's cost: how deep it is comes from the scene behind it (surface to floor), so there is
	## no thickness pass and no copy of the picture. Given up for that: refraction, and water in the air reads as thick as the gap
	## to whatever is behind it (a splash against the far sky is all deep colour).
	CLEAR,
}
## How the water is drawn (may change at any time).
@export var style := Style.CLEAR:
	set(value):
		style = value
		if _effect != null:
			_effect.opaque = style != Style.TRANSLUCENT
			_effect.clear = style == Style.CLEAR
enum Shape {
	## Round particles.
	SPHERE,
	## Cubes, their sides along the simulation's axes.
	CUBE,
	## Flat discs (a fifth as thick as they are wide): flat however fast the water runs across, turning upright as it moves up or
	## down (all the way at 4 m/s) to face along its flow, so a falling sheet stands up.
	DISC,
}
## The shape each particle is drawn as, each with a sphere's volume (may change at any time). The depth smoothing rounds shapes off:
## less [member smoothing] keeps them.
@export var shape := Shape.SPHERE:
	set(value):
		shape = value
		if _effect != null:
			_effect.shape = int(shape)
## Discs turn about the vertical to face the camera, as upright as the flow stood them (instead of facing along it): a fall reads
## as full from every side rather than a sheet edge-on (may change at any time).
@export var discs_face_camera := true:
	set(value):
		discs_face_camera = value
		if _effect != null:
			_effect.discs_face_camera = discs_face_camera
enum Location {
	## Each particle's shape centred a radius above its point: at the top of the particle.
	TOP,
	## Centred on its point.
	CENTER,
	## Centred a radius below its point: at the bottom of the particle (the water sits lower, on the floor rather than over it).
	BOTTOM,
}
## Where on each particle its shape is drawn (may change at any time). Each particle moves by its own radius, so coarse
## (adaptive detail) ones move more.
@export var location := Location.BOTTOM:
	set(value):
		location = value
		if _effect != null:
			_effect.anchor = _anchor()
## Particles smaller on screen than this many pixels (radius) go to the compute rasterizer instead of being drawn as triangles
## (the triangle passes never see them). Not with single_pass.
@export_range(0.5, 8.0, 0.1) var small_pixels := 1.5
## The radius (m) of the sphere each particle is drawn as. 0: a little over a quarter of a cell (the spheres overlap, and the depth
## is smoothed over them).
@export var particle_radius := 0.0
## Draw every particle once, depth and thickness together (the nearest front kept by a minimum blend). Off (faster, measured): the two passes with a depth buffer. Set before the first frame.
@export var single_pass := false
## Experimental, on by default. The smoothing works out the water's nearest depth as it reads it, instead of a pass writing it
## first at full size (the same picture; may change at any time). Not with no smoothing, nor with [member single_pass] in the
## translucent style.
@export var fuse_resolve := true:
	set(value):
		fuse_resolve = value
		if _effect != null:
			_effect.fuse_resolve = fuse_resolve
## Leave out the particles in blocks the camera can't see (they are not sent to the graphics card or drawn).
@export var cull_to_camera := true
## Water this deep inside the water (this many blocks of 4 cells, and this many cells: a cell whose neighbours within that many cells are all full) draws one particle in eight, bigger, into the thickness only: deep water costs less to draw and the surface is untouched. 0 is off. Not with single_pass.
@export_range(0, 8) var thin_interior := 1
## The farthest the water is drawn (m): depth is kept as a fraction of this, so a huge world wants it bigger.
@export_range(50.0, 5000.0, 10.0, "or_greater") var far_distance := 400.0
## Smooth the surface's depth (off: each particle's shape is lit as it is drawn, bumps and all; no smoothing passes).
@export var smooth := true
## How far (m) the surface is smoothed: more is smoother water that rounds off small waves.
@export_range(0.05, 2.0, 0.01) var smoothing := 0.45
## Passes of smoothing (each along x and along y): more is smoother and costs more.
@export_range(1, 6) var smoothing_passes := 3
## How thick (m) the water must be to be all its deep colour.
@export_range(0.1, 8.0, 0.05) var deep_at := 1.0
## How thick the water must be to hide what is behind it (opacity grows with thickness; bigger is more see-through).
@export_range(0.1, 8.0, 0.05) var opacity := 1.6
## In the clear style, how deep (m) you see into the water: at this depth what is behind is almost hidden.
@export_range(0.1, 50.0, 0.1, "or_greater") var see_depth := 3.0
## How far the water bends what is behind it.
@export_range(0.0, 0.5, 0.005) var refraction := 0.08
## The sun's glint on it, how tight it is, and how much of the sky it reflects at a glancing angle.
@export_range(0.0, 2.0, 0.01) var specular := 0.5
@export_range(4.0, 400.0, 1.0) var shininess := 80.0
@export_range(0.0, 1.0, 0.01) var sky_reflection := 0.55
## The colour of the sky it reflects.
@export var sky_color := Color(0.65, 0.8, 0.95)

var _sim: WaterSim
var _effect: WaterSimFluidEffect
var _camera: Camera3D
var _sun: DirectionalLight3D
var _sun_checked := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_effect = WaterSimFluidEffect.new()
	_effect.single_pass = single_pass
	_effect.fuse_resolve = fuse_resolve
	_effect.opaque = style != Style.TRANSLUCENT
	_effect.clear = style == Style.CLEAR
	_effect.shape = int(shape)
	_effect.discs_face_camera = discs_face_camera
	_effect.anchor = _anchor()
	_connect.call_deferred()


func _exit_tree() -> void:
	if _effect != null:
		_detach()
	if _sim != null and is_instance_valid(_sim) and _sim.get_solver() != null:
		_sim.get_solver().clear_buffer_request(get_instance_id() & 0x3fffffff)


func _connect() -> void:
	_sim = sim if sim != null else WaterSim.find_for(self)
	if _sim != null:
		_sim.stepped.connect(_redraw)


func _redraw() -> void:
	var solver := _sim.get_solver()
	var key := get_instance_id() & 0x3fffffff
	# Hidden views cost nothing.
	if solver == null or not is_visible_in_tree():
		if solver != null:
			solver.clear_buffer_request(key)
		_effect.set_points(PackedByteArray(), 0, Transform3D.IDENTITY)
		return
	# (The particles come nearest the camera first, so the depth test throws away the hidden ones before they are shaded.)
	var camera := get_viewport().get_camera_3d()
	var eye := _sim.get_solver_transform().affine_inverse() * camera.global_position if camera != null else Vector3.ZERO
	solver.set_point_request(key, _sim.get_mask(substances), _frustum_planes() if cull_to_camera else PackedFloat32Array(), 0 if single_pass else thin_interior,
			shape == Shape.DISC, false, eye)
	var taken: Variant = solver.take_buffer(key)
	if taken != null:
		_effect.set_points(taken, solver.get_buffer_point_count(key), _sim.get_solver_transform())


# What the camera sees, as planes (nx, ny, nz, d: inside where n.p + d >= 0) in the solver's space, for the solver to leave out
# the blocks wholly outside them.
func _frustum_planes() -> PackedFloat32Array:
	var camera := get_viewport().get_camera_3d()
	var out := PackedFloat32Array()
	if camera == null:
		return out
	var to_box := _sim.get_solver_transform().affine_inverse()
	var inside := to_box * (camera.global_position - camera.global_transform.basis.z * minf(camera.far * 0.5, 50.0))
	for plane: Plane in camera.get_frustum():
		var p := to_box * plane
		if p.distance_to(inside) < 0.0:
			p = -p
		# (Widened by how far the surface waves can lift a block into view.)
		out.append_array(PackedFloat32Array([p.normal.x, p.normal.y, p.normal.z, -p.d + _sim.surface_wave_height]))
	return out


func _process(_delta: float) -> void:
	if _effect == null or Engine.is_editor_hint():
		return
	_effect.enabled = is_visible_in_tree()
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
	var cell := _sim.cell_size if _sim != null else 0.25
	_effect.cell_size = cell
	var solver := _sim.get_solver() if _sim != null else null
	if solver != null:
		_effect.extent = Vector3(_sim.get_dims()) * cell
	_effect.far_limit = far_distance
	_effect.particle_radius = particle_radius if particle_radius > 0.0 else cell * 0.56
	_effect.filter_radius = smoothing
	_effect.depth_sigma = _effect.particle_radius * 2.2
	_effect.smoothing_passes = smoothing_passes if smooth else 0
	_effect.depth_scale = deep_at
	# (The clear style's depth is in metres, not the translucent style's particle chords.)
	_effect.opacity = 3.0 / maxf(see_depth, 0.01) if style == Style.CLEAR else opacity
	_effect.refraction = refraction
	_effect.specular = specular
	_effect.shininess = shininess
	_effect.fresnel = sky_reflection
	_effect.sky_color = sky_color
	_effect.small_pixels = small_pixels
	if not _sun_checked:
		_sun_checked = true
		var lights := get_tree().root.find_children("*", "DirectionalLight3D", true, false)
		_sun = lights[0] if not lights.is_empty() else null
	if _sun != null and is_instance_valid(_sun):
		_effect.sun_direction = _sun.global_transform.basis.z
		_effect.sun_color = _sun.light_color
		_effect.sun_strength = _sun.light_energy
	var deep := PackedColorArray()
	var shallow := PackedColorArray()
	if _sim != null:
		_effect.wave_height = _sim.surface_wave_height
		_effect.wave_length = _sim.surface_wave_length
		_effect.wave_time = _sim.get_surface_wave_time()
		var origin := _sim.get_solver_transform().origin
		_effect.wave_origin = Vector2(origin.x, origin.z)
		for substance in _sim.get_substances():
			deep.append(substance.color)
			shallow.append(substance.shallow_color)
	_effect.deep_colors = deep
	_effect.shallow_colors = shallow


# The effect's anchor for the location: up a radius (1), none, down (-1).
func _anchor() -> int:
	return 1 - int(location)
