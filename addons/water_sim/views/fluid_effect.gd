@tool
class_name WaterSimFluidEffect
extends CompositorEffect
## Draws a simulation's particles as water, in the camera's picture: every particle is a sphere drawn into a depth buffer and a
## thickness buffer, the depth is smoothed (so the spheres' bumps go and edges stay), and the water is shaded from it: its
## colour from how thick it is (light where shallow, deep where deep, each substance its own), the picture behind it bent by its
## surface, the sky at glancing angles and the sun on it. Everything is the camera's own picture, so water is hidden by what is
## in front of it, water in front of water needs no sorting, and there is no mesh.
##
## Don't make one by hand: a [WaterSimFluidView] makes it, feeds it the particles and puts it on the camera (as a compositor
## effect; needs the Forward+ or Mobile renderer). It runs on the render thread.

const CONTEXT := &"water_sim_fluid"
const FLOATS_BEFORE_COLORS := 48 + 44
const FLOATS_IN_PARAMS := FLOATS_BEFORE_COLORS + 128 * 4

# What the view sets (read on the render thread: single values, so no lock).
var particle_radius := 0.14
var cell_size := 0.25
var extent := Vector3.ONE
var far_limit := 400.0
## The surface waves: how high (m), the longest one's length (m), the time they have run (s), and where the solver's origin is in x and
## z of the world (see [method WaterSim.surface_wave_at]).
var wave_height := 0.0
var wave_length := 1.0
var wave_time := 0.0
var wave_origin := Vector2.ZERO
## Both the sphere passes in one (the nearest front kept by a minimum blend instead of a depth buffer).
var single_pass := false
## Experimental, on by default: the smoothing works out the nearer of the two depths (the hardware pass's and the compute
## rasterizer's) as it reads them, instead of a resolve pass writing it at full size first. The same picture. May change between frames.
var fuse_resolve := true
## Each particle's triangle the smallest one round the circle (equilateral) instead of the right-angled one.
var equilateral := true
## The thickness targets are this many times smaller than the picture, on each side (1, 2, 4).
var thickness_shrink := 2
## A test: read each particle and draw nothing.
var vertex_only := false
## Opaque, lit water (Liquid Crystal's way) instead of the translucent screen-space fluid: the near particles drawn as spheres in a
## depth pass, the small far ones rasterized by a compute pass (no triangles for them), the nearer of the two smoothed and lit.
## No thickness pass and no refraction. May change between frames.
var opaque := true
## With [member opaque]: see-through anyway, the water's depth taken from the scene behind it (no thickness pass, no copy, no
## refraction). May change between frames.
var clear := false
## Particles smaller on screen than this many pixels (radius) go to the compute rasterizer; the bigger ones are listed for the
## triangle passes, which draw only those (an indirect draw). Every style but the translucent one's single pass.
var small_pixels := 1.5
## Time each stage on the card (a running mean in ms, in [member timings]).
var profile := false
var timings := {}
var filter_radius := 0.45
var depth_sigma := 0.3
# Passes of depth smoothing (each along x then y); 0: none, the shading reads the particles' depth as drawn.
var smoothing_passes := 3
var depth_scale := 1.0
var opacity := 1.6
var refraction := 0.08
var specular := 0.5
var shininess := 80.0
var fresnel := 0.55
var sun_direction := Vector3(0.4, 0.8, 0.3)
var sun_color := Color(1.0, 0.97, 0.9)
var sun_strength := 1.0
var sky_color := Color(0.65, 0.8, 0.95)
## Each particle drawn as a sphere (0), a cube along the solver's axes (1) or a flat disc lying along the water's surface (2; the
## points must carry its way: see [method WaterSimSolver.set_point_request]'s orient), each with a sphere's volume.
var shape := 0
## Discs turn about the vertical to face the camera, keeping how upright they are (their flow's way is dropped).
var discs_face_camera := true
# Where each particle is drawn: -1 a radius down (its bottom), 0 on its point, 1 a radius up (its top).
var anchor := 0
var deep_colors := PackedColorArray()
var shallow_colors := PackedColorArray()

var _rd: RenderingDevice
var _mutex := Mutex.new()
var _incoming := PackedByteArray()
var _incoming_count := 0
var _incoming_count_taken := 0
var _incoming_to_world := Transform3D.IDENTITY
var _fresh := false
var _count := 0
var _to_world := Transform3D.IDENTITY
var _ready_to_draw := false
var _depth_shader: RID
var _thickness_shader: RID
var _smooth_shader: RID
var _shade_shader: RID
var _copy_shader: RID
var _copy_pipeline: RID
var _smooth_pipeline: RID
# The depth to half size for the smoothing and back (fluid_smooth_down.glsl, fluid_smooth_up.glsl).
var _smooth_down_shader: RID
var _smooth_down_pipeline: RID
var _smooth_up_shader: RID
var _smooth_up_pipeline: RID
var _shade_pipeline: RID
var _splat_shader: RID
var _splat_pipeline: RID
var _depth_pipeline: RID
var _thickness_pipeline: RID
var _sampler_nearest: RID
var _sampler_linear: RID
var _points_buffer: RID
var _points_capacity := 0
var _params_buffer: RID
# The same with the picture's size that of the opaque look's particle targets, half of it.
var _params_half_buffer: RID
var _opaque_scene_depth_shader: RID
var _empty_vertex_array: RID
var _opaque_depth_shader: RID
var _opaque_depth_pipeline: RID
var _raster_shader: RID
var _raster_pipeline_rid: RID
var _resolve_shader: RID
var _resolve_pipeline: RID
var _opaque_shade_shader: RID
var _opaque_shade_pipeline: RID
var _clear_shade_shader: RID
var _clear_shade_pipeline: RID
var _thickness_resolve_shader: RID
var _thickness_resolve_pipeline: RID
# The big particles (the hardware passes draw these, by an indirect draw whose arguments are in _draw_buffer), and the small
# ones' thickness sums (the translucent look; _no_sums stands in for them in the others).
var _big_buffer: RID
var _draw_buffer: RID
var _sums_buffer: RID
var _sums_size := 0
var _no_sums: RID
# The pass that writes the water into the scene's depth.
var _scene_depth_shader: RID
var _scene_depth_pipeline: RID
var _scene_depth_format := -1
var _scene_depth_reversed := true
var _scene_depth_opaque := false
var _head := PackedFloat32Array()
var _deep_sent := PackedColorArray()
var _shallow_sent := PackedColorArray()
var _colors_sent := false
# The opaque look's targets and uniform sets, kept from frame to frame (see _opaque_prepare), and what they were made for.
var _op_size := Vector2i.ZERO
var _op_color: RID
var _op_scene_depth: RID
var _op_points: RID
var _op_clear := false
var _op_passes := -1
var _op_near_small: RID
var _op_fb: RID
var _op_raster_set: RID
var _op_depth_set: RID
var _op_resolve_set: RID
var _op_smooth_sets: Array[RID] = []
var _op_smooth_pushes: Array[PackedByteArray] = []
var _op_shade_set: RID
var _op_scene_depth_set: RID
var _op_groups := Vector2i.ZERO
var _op_half_groups := Vector2i.ZERO
var _op_raster_push := PackedByteArray()
var _op_raster_groups := Vector2i.ZERO
var _op_raster_count := -1
var _draw_reset := PackedInt32Array([3, 0, 0, 0]).to_byte_array()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_motion_vectors = false
	needs_normal_roughness = false
	RenderingServer.call_on_render_thread(_initialize_render)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		# (Not a method of this object, which is going: what there is to free is handed over.)
		var rd := _rd
		var rids: Array[RID] = [_splat_pipeline, _depth_pipeline, _thickness_pipeline, _smooth_pipeline, _shade_pipeline, _copy_pipeline, _empty_vertex_array,
				_opaque_depth_pipeline, _raster_pipeline_rid, _resolve_pipeline, _opaque_shade_pipeline, _clear_shade_pipeline,
				_splat_shader, _depth_shader, _thickness_shader, _smooth_shader, _shade_shader, _copy_shader, _sampler_nearest, _sampler_linear, _points_buffer, _params_buffer,
				_opaque_depth_shader, _raster_shader, _resolve_shader, _opaque_shade_shader, _clear_shade_shader,
				_thickness_resolve_pipeline, _thickness_resolve_shader, _big_buffer, _draw_buffer, _sums_buffer, _no_sums,
				_scene_depth_pipeline, _scene_depth_shader, _smooth_down_pipeline, _smooth_down_shader, _smooth_up_pipeline, _smooth_up_shader,
				_opaque_scene_depth_shader, _params_half_buffer]
		RenderingServer.call_on_render_thread(func() -> void:
			for rid in rids:
				if rid.is_valid():
					rd.free_rid(rid))


## The particles to draw: four floats each (x, y, z in the solver's space, and the substance), and the transform from the solver's
## space to the world's. Called from the game's thread; drawn from the next frame.
func set_points(points: PackedByteArray, count: int, to_world: Transform3D) -> void:
	_mutex.lock()
	_incoming = points
	_incoming_count = count
	_incoming_to_world = to_world
	_fresh = true
	_mutex.unlock()


func _shader(path: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null:
		push_error("WaterSimFluidEffect: can't load %s" % path)
		return RID()
	var spirv := file.get_spirv()
	for message in [spirv.compile_error_vertex, spirv.compile_error_fragment, spirv.compile_error_compute]:
		if message != "":
			push_error("WaterSimFluidEffect: %s: %s" % [path, message])
			return RID()
	return _rd.shader_create_from_spirv(spirv)


func _initialize_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var nearest := RDSamplerState.new()
	nearest.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_nearest = _rd.sampler_create(nearest)
	var linear := RDSamplerState.new()
	linear.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_linear = _rd.sampler_create(linear)
	var dir := "res://addons/water_sim/shaders/"
	_splat_shader = _shader(dir + "fluid_splat.glsl")
	_depth_shader = _shader(dir + "fluid_depth.glsl")
	_thickness_shader = _shader(dir + "fluid_thickness.glsl")
	_smooth_shader = _shader(dir + "fluid_smooth.glsl")
	_shade_shader = _shader(dir + "fluid_shade.glsl")
	_copy_shader = _shader(dir + "fluid_copy.glsl")
	_opaque_depth_shader = _shader(dir + "fluid_opaque_depth.glsl")
	_raster_shader = _shader(dir + "fluid_raster.glsl")
	_resolve_shader = _shader(dir + "fluid_resolve.glsl")
	_opaque_shade_shader = _shader(dir + "fluid_opaque_shade.glsl")
	_clear_shade_shader = _shader(dir + "fluid_clear_shade.glsl")
	_thickness_resolve_shader = _shader(dir + "fluid_thickness_resolve.glsl")
	_scene_depth_shader = _shader(dir + "fluid_scene_depth.glsl")
	_smooth_down_shader = _shader(dir + "fluid_smooth_down.glsl")
	_smooth_up_shader = _shader(dir + "fluid_smooth_up.glsl")
	_opaque_scene_depth_shader = _shader(dir + "fluid_opaque_scene_depth.glsl")
	if not (_splat_shader.is_valid() and _depth_shader.is_valid() and _thickness_shader.is_valid() and _smooth_shader.is_valid() and _shade_shader.is_valid() and _copy_shader.is_valid()):
		return
	if not (_opaque_depth_shader.is_valid() and _raster_shader.is_valid() and _resolve_shader.is_valid() and _opaque_shade_shader.is_valid() and _clear_shade_shader.is_valid() and _thickness_resolve_shader.is_valid()):
		return
	if not (_scene_depth_shader.is_valid() and _smooth_down_shader.is_valid() and _smooth_up_shader.is_valid()):
		return
	_smooth_down_pipeline = _rd.compute_pipeline_create(_smooth_down_shader)
	_smooth_up_pipeline = _rd.compute_pipeline_create(_smooth_up_shader)
	_raster_pipeline_rid = _rd.compute_pipeline_create(_raster_shader)
	_resolve_pipeline = _rd.compute_pipeline_create(_resolve_shader)
	_opaque_shade_pipeline = _rd.compute_pipeline_create(_opaque_shade_shader)
	_clear_shade_pipeline = _rd.compute_pipeline_create(_clear_shade_shader)
	_thickness_resolve_pipeline = _rd.compute_pipeline_create(_thickness_resolve_shader)
	var zeros := PackedByteArray()
	zeros.resize(16)
	_draw_buffer = _rd.storage_buffer_create(16, zeros, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_no_sums = _rd.storage_buffer_create(16, zeros)
	_smooth_pipeline = _rd.compute_pipeline_create(_smooth_shader)
	_shade_pipeline = _rd.compute_pipeline_create(_shade_shader)
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	_params_buffer = _rd.uniform_buffer_create(FLOATS_IN_PARAMS * 4)
	_params_half_buffer = _rd.uniform_buffer_create(FLOATS_IN_PARAMS * 4)
	_empty_vertex_array = _rd.vertex_array_create(0, _rd.vertex_format_create([]), [])
	_ready_to_draw = true


func _raster_pipeline(shader: RID, framebuffer: RID, color_attachments: int, with_depth: bool, min_last := false) -> RID:
	var raster := RDPipelineRasterizationState.new()
	var multisample := RDPipelineMultisampleState.new()
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = with_depth
	depth_stencil.enable_depth_write = with_depth
	depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_LESS
	var blend := RDPipelineColorBlendState.new()
	for i in color_attachments:
		var attachment := RDPipelineColorBlendStateAttachment.new()
		attachment.enable_blend = true
		attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
		attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
		if min_last and i == color_attachments - 1:
			attachment.color_blend_op = RenderingDevice.BLEND_OP_MINIMUM
			attachment.alpha_blend_op = RenderingDevice.BLEND_OP_MINIMUM
		blend.attachments.push_back(attachment)
	return _rd.render_pipeline_create(shader, _rd.framebuffer_get_format(framebuffer), _rd.vertex_format_create([]),
			RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, multisample, depth_stencil, blend)


func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


func _sampled(binding: int, texture: RID, sampler: RID) -> RDUniform:
	return _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, binding, [sampler, texture])


func _put(at: int, a: float, b: float, c: float, d: float) -> void:
	_head[at] = a
	_head[at + 1] = b
	_head[at + 2] = c
	_head[at + 3] = d


func _put_projection(at: int, p: Projection) -> void:
	_put(at, p.x.x, p.x.y, p.x.z, p.x.w)
	_put(at + 4, p.y.x, p.y.y, p.y.z, p.y.w)
	_put(at + 8, p.z.x, p.z.y, p.z.z, p.z.w)
	_put(at + 12, p.w.x, p.w.y, p.w.z, p.w.w)


# The parameters: all but the colours each frame, written in place (this runs on the render thread every frame); the colours when they change.
func _write_params(scene_data: RenderSceneData, size: Vector2i) -> void:
	var camera := scene_data.get_cam_transform()
	var projection := scene_data.get_cam_projection()
	if _head.size() != FLOATS_BEFORE_COLORS:
		_head.resize(FLOATS_BEFORE_COLORS)
	_put_projection(0, Projection(camera.affine_inverse() * _to_world))
	_put_projection(16, projection)
	_put_projection(32, projection.inverse())
	_put(48, size.x, size.y, 1.0 / size.x, 1.0 / size.y)
	_put(52, particle_radius, far_limit, filter_radius, depth_sigma)
	# A full block of particles, eight a cell, as thick as it is: the spheres cover only part of their space.
	var spacing := cell_size * 0.5
	var coverage := 4.0 / 3.0 * PI * pow(particle_radius, 3.0) / pow(spacing, 3.0)
	_put(56, 1.0 / maxf(coverage, 0.01), depth_scale, opacity, refraction)
	_put(60, specular, shininess, fresnel, 2.0 if equilateral else 1.0)
	var sun_view := (camera.basis.inverse() * sun_direction).normalized()
	_put(64, sun_view.x, sun_view.y, sun_view.z, sun_strength)
	_put(68, sun_color.r, sun_color.g, sun_color.b, float(anchor))
	_put(72, sky_color.r, sky_color.g, sky_color.b, 3.0 if shape == 2 and discs_face_camera else float(shape))
	_put(76, extent.x / 65535.0, extent.y / 65535.0, extent.z / 65535.0, 0.0)
	_put(80, 1.0 if single_pass else float(maxi(thickness_shrink, 1)), 1.0 if vertex_only else 0.0, 0.0 if single_pass and not opaque else small_pixels, 0.0)
	_put(84, wave_height, wave_length, wave_time, 0.0)
	_put(88, wave_origin.x, wave_origin.y, 0.0, 0.0)
	var bytes := _head.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)
	if opaque:
		var half := (size + Vector2i.ONE) / 2
		_put(48, half.x, half.y, 1.0 / half.x, 1.0 / half.y)
		bytes = _head.to_byte_array()
		_rd.buffer_update(_params_half_buffer, 0, bytes.size(), bytes)
	if not _colors_sent or deep_colors != _deep_sent or shallow_colors != _shallow_sent:
		var data := PackedFloat32Array()
		for colors in [deep_colors, shallow_colors]:
			for i in 64:
				var c: Color = colors[i] if i < colors.size() else Color(0.2, 0.5, 0.95)
				data.append_array(PackedFloat32Array([c.r, c.g, c.b, 1.0]))
		var color_bytes := data.to_byte_array()
		_rd.buffer_update(_params_buffer, FLOATS_BEFORE_COLORS * 4, color_bytes.size(), color_bytes)
		_deep_sent = deep_colors
		_shallow_sent = shallow_colors
		_colors_sent = true


func _upload_points(bytes: PackedByteArray, size: int) -> void:
	if size > _points_capacity:
		if _points_buffer.is_valid():
			_rd.free_rid(_points_buffer)
			_rd.free_rid(_big_buffer)
		_points_capacity = maxi(size * 3 / 2, 4096)
		_points_buffer = _rd.storage_buffer_create(_points_capacity)
		_big_buffer = _rd.storage_buffer_create(_points_capacity)
	_rd.buffer_update(_points_buffer, 0, size, bytes)


func _texture(buffers: RenderSceneBuffersRD, name: StringName, format: int, usage: int, size: Vector2i) -> RID:
	return buffers.create_texture(CONTEXT, name, format, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, false, false)


func _stamp(stage: String) -> void:
	if profile:
		_rd.capture_timestamp(stage)


# Each stage's time (ms, a running mean) from the timestamps the card has finished.
func _collect_timings() -> void:
	var last := -1.0
	for i in _rd.get_captured_timestamps_count():
		var stage := _rd.get_captured_timestamp_name(i)
		if not stage.begins_with("ws_"):
			continue
		var t := float(_rd.get_captured_timestamp_gpu_time(i)) * 1e-6
		if stage != "ws_start" and last >= 0.0:
			timings[stage] = lerpf(timings.get(stage, t - last), t - last, 0.05)
		last = t


# The raster pass's groups of 64 points. A dispatch holds at most 65535 groups along an axis (4.19M points), so past that they go in rows;
# the shader works out a point's place from its row, and is told how long a row is.
func _raster_groups() -> Vector2i:
	var groups := (_count + 63) / 64
	var rows := (groups + 65534) / 65535
	return Vector2i((groups + rows - 1) / rows, rows)


# Every particle once by compute: the small ones rasterized into near_small (and, given thickness_size, into the thickness sums),
# the big ones listed for the hardware passes' indirect draw (fluid_raster.glsl). Returns the list, as their points.
func _split(params: RDUniform, points: RDUniform, scene_depth_u: RDUniform, near_small: RID, thickness_size := Vector2i.ZERO) -> RDUniform:
	var with_thickness := thickness_size.x > 0
	if with_thickness:
		var sums_size := thickness_size.x * thickness_size.y * 4
		if sums_size != _sums_size:
			if _sums_buffer.is_valid():
				_rd.free_rid(_sums_buffer)
			# (Zero to start; the resolve sets back to zero what it reads.)
			_sums_buffer = _rd.storage_buffer_create(sums_size)
			_rd.buffer_clear(_sums_buffer, 0, sums_size)
			_sums_size = sums_size
	var arguments := PackedInt32Array([3, 0, 0, 0]).to_byte_array()
	_rd.buffer_update(_draw_buffer, 0, arguments.size(), arguments)
	_rd.texture_clear(near_small, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var set_raster := UniformSetCacheRD.get_cache(_raster_shader, 0, [points, params, scene_depth_u,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [near_small]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_big_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_draw_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [_sums_buffer if with_thickness else _no_sums])])
	var groups := _raster_groups()
	var push := PackedInt32Array([_count, 1 if with_thickness else 0, groups.x * 64, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _raster_pipeline_rid)
	_rd.compute_list_bind_uniform_set(list, set_raster, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()
	_stamp("ws_raster")
	return _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_big_buffer])


# The nearer of the hardware pass's depth and the compute-rasterized one, into depth_out (fluid_resolve.glsl).
func _resolve_depth(params: RDUniform, near_big: RID, near_small: RID, depth_out: RID, groups: Vector2i) -> void:
	var set_resolve := UniformSetCacheRD.get_cache(_resolve_shader, 0, [_sampled(0, near_big, _sampler_nearest), params,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [depth_out]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [near_small])])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _resolve_pipeline)
	_rd.compute_list_bind_uniform_set(list, set_resolve, 0)
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()
	_stamp("ws_resolve")


func _near_small(buffers: RenderSceneBuffersRD, size: Vector2i) -> RID:
	return _texture(buffers, &"near_small", RenderingDevice.DATA_FORMAT_R32_UINT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT, size)


# Whether the smoothing resolves the depth itself (fuse_resolve, and there is smoothing to do): then there's no resolve pass.
# (Not the translucent single pass: its splat writes the nearest depth already, and there are no two depths to resolve.)
func _fused() -> bool:
	return fuse_resolve and smoothing_passes > 0 and (opaque or not single_pass)


# The depth smoothed: taken to half size, smoothed there along x then along y a few times (a quarter of the pixels: the passes
# cost by the pixel more than by the tap), and brought back to full size into a (not `particles`, which is left as it is and
# guides it). Returns the smoothed depth. With _fused(), particles is the near pass's depth buffer, resolved against near_small
# where it is read.
func _smooth_depth(buffers: RenderSceneBuffersRD, size: Vector2i, params: RDUniform, particles: RID, a: RID, near_small: RID) -> RID:
	var passes := maxi(smoothing_passes, 0)
	if passes == 0:
		return particles
	var half := (size + Vector2i.ONE) / 2
	var storage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var half_a := _texture(buffers, &"smooth_half_a", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, half)
	var half_b := _texture(buffers, &"smooth_half_b", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, half)
	var half_groups := Vector2i((half.x + 7) / 8, (half.y + 7) / 8)
	var fused := PackedInt32Array([1 if _fused() else 0, 0, 0, 0]).to_byte_array()
	_compute(_smooth_down_pipeline, _smooth_down_shader, [_sampled(0, particles, _sampler_nearest), params,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [half_a]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [near_small])],
			half_groups, fused)
	var source := half_a
	var targets: Array[RID] = [half_b, half_a]
	for pass_index in passes * 2:
		var target := targets[pass_index % 2]
		var horizontal := pass_index % 2 == 0
		var push := PackedFloat32Array([1.0 if horizontal else 0.0, 0.0 if horizontal else 1.0, 4.0 if pass_index >= passes * 2 - 2 else 0.0, 0.0])
		_compute(_smooth_pipeline, _smooth_shader, [_sampled(0, source, _sampler_nearest), params,
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [target])], half_groups, push.to_byte_array())
		source = target
	_compute(_smooth_up_pipeline, _smooth_up_shader, [_sampled(0, source, _sampler_nearest), params,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [a]), _sampled(3, particles, _sampler_nearest),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 4, [near_small])], Vector2i((size.x + 7) / 8, (size.y + 7) / 8), fused)
	_stamp("ws_smooth")
	return a


# One compute dispatch of the pipeline over groups, with the uniforms as set 0 (and a push constant, if any).
func _compute(pipeline: RID, shader: RID, uniforms: Array, groups: Vector2i, push := PackedByteArray()) -> void:
	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, uniforms)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	if not push.is_empty():
		_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()


# The water's smoothed surface into the scene's depth (fluid_scene_depth.glsl), nearest wins, so the transparent pass after it (glass, other effects) is hidden behind the water.
func _write_scene_depth(scene_data: RenderSceneData, scene_depth: RID, set_depth: RID) -> void:
	var fb := FramebufferCacheRD.get_cache_multipass([scene_depth], [], 1)
	var format := _rd.framebuffer_get_format(fb)
	# (Godot draws depth reversed, 1 near: checked from the projection rather than assumed.)
	var projection := scene_data.get_cam_projection()
	var near := projection * Vector4(0.0, 0.0, -1.0, 1.0)
	var far := projection * Vector4(0.0, 0.0, -10.0, 1.0)
	var reversed := near.z / near.w > far.z / far.w
	if not _scene_depth_pipeline.is_valid() or format != _scene_depth_format or reversed != _scene_depth_reversed or opaque != _scene_depth_opaque:
		if _scene_depth_pipeline.is_valid():
			_rd.free_rid(_scene_depth_pipeline)
		var depth_stencil := RDPipelineDepthStencilState.new()
		depth_stencil.enable_depth_test = true
		depth_stencil.enable_depth_write = true
		depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER if reversed else RenderingDevice.COMPARE_OP_LESS
		_scene_depth_pipeline = _rd.render_pipeline_create(_opaque_scene_depth_shader if opaque else _scene_depth_shader, format, _rd.vertex_format_create([]),
				RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(), depth_stencil,
				RDPipelineColorBlendState.new())
		_scene_depth_format = format
		_scene_depth_reversed = reversed
		_scene_depth_opaque = opaque
	var draw := _rd.draw_list_begin(fb, RenderingDevice.DRAW_DEFAULT_ALL)
	_rd.draw_list_bind_render_pipeline(draw, _scene_depth_pipeline)
	_rd.draw_list_bind_uniform_set(draw, set_depth, 0)
	_rd.draw_list_bind_vertex_array(draw, _empty_vertex_array)
	_rd.draw_list_draw(draw, false, 1, 3)
	_rd.draw_list_end()
	_stamp("ws_scene_depth")


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	if not _ready_to_draw or _rd == null:
		return
	if profile:
		_collect_timings()
	_mutex.lock()
	var incoming := PackedByteArray()
	if _fresh:
		incoming = _incoming
		_to_world = _incoming_to_world
		_incoming_count_taken = _incoming_count
		_incoming = PackedByteArray()
		_fresh = false
		_count = _incoming_count_taken
	_mutex.unlock()
	if _count > 0 and incoming.size() > 0:
		_upload_points(incoming, _count * 8)
	if _count == 0 or not _points_buffer.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color := buffers.get_color_layer(0)
	var scene_depth := buffers.get_depth_layer(0)
	_write_params(scene_data, size)
	if opaque:
		_render_opaque(buffers, scene_data, size, color, scene_depth)
		return

	var sampled := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var attach := RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | sampled
	# (The one-pass drawing keeps its targets the picture's size.)
	var shrink := 1 if single_pass else maxi(thickness_shrink, 1)
	var thickness_size := (size + Vector2i(shrink - 1, shrink - 1)) / shrink
	var storage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | sampled
	# (Storage too: the small particles' thickness is added to them.)
	var deep_tex := _texture(buffers, StringName("deep_%d" % shrink), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, attach | storage, thickness_size)
	var shallow_tex := _texture(buffers, StringName("shallow_%d" % shrink), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, attach | storage, thickness_size)
	var smooth_a := _texture(buffers, &"smooth_a", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, size)
	var smooth_b := _texture(buffers, &"smooth_b", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, size)
	var scene_copy := _texture(buffers, &"scene_copy", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, storage, size)

	var params := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [_params_buffer])
	var points := _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_points_buffer])
	var scene_depth_u := _sampled(2, scene_depth, _sampler_nearest)

	_stamp("ws_start")
	var nearest_tex: RID
	# (Bound for the smoothing even where it isn't drawn into: see _smooth_depth.)
	var near_small := _near_small(buffers, size)
	if single_pass:
		# Every sphere once: its chord and colours added up, its front kept by a minimum.
		nearest_tex = _texture(buffers, &"nearest", RenderingDevice.DATA_FORMAT_R32_SFLOAT, attach, size)
		var splat_fb := FramebufferCacheRD.get_cache_multipass([deep_tex, shallow_tex, nearest_tex], [], 1)
		if not _splat_pipeline.is_valid():
			_splat_pipeline = _raster_pipeline(_splat_shader, splat_fb, 3, false, true)
		var set_splat := UniformSetCacheRD.get_cache(_splat_shader, 0, [points, params, scene_depth_u])
		var splat := _rd.draw_list_begin(splat_fb, RenderingDevice.DRAW_CLEAR_ALL, PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(1, 1, 1, 1)]), 1.0)
		_rd.draw_list_bind_render_pipeline(splat, _splat_pipeline)
		_rd.draw_list_bind_uniform_set(splat, set_splat, 0)
		_rd.draw_list_bind_vertex_array(splat, _empty_vertex_array)
		_rd.draw_list_draw(splat, false, _count, 3)
		_rd.draw_list_end()
	else:
		# The small particles by compute, the big ones listed for the two passes below.
		var big := _split(params, points, scene_depth_u, near_small, thickness_size)
		var depth_tex := _texture(buffers, &"depth", RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | sampled, size)
		# The big spheres' fronts, nearest wins (a depth buffer of our own, written with the distance).
		var depth_fb := FramebufferCacheRD.get_cache_multipass([depth_tex], [], 1)
		if not _depth_pipeline.is_valid():
			_depth_pipeline = _raster_pipeline(_depth_shader, depth_fb, 0, true)
		var set_depth := UniformSetCacheRD.get_cache(_depth_shader, 0, [big, params, scene_depth_u])
		var draw := _rd.draw_list_begin(depth_fb, RenderingDevice.DRAW_CLEAR_ALL, PackedColorArray(), 1.0)
		_rd.draw_list_bind_render_pipeline(draw, _depth_pipeline)
		_rd.draw_list_bind_uniform_set(draw, set_depth, 0)
		_rd.draw_list_bind_vertex_array(draw, _empty_vertex_array)
		_rd.draw_list_draw_indirect(draw, false, _draw_buffer, 0, 1, 0)
		_rd.draw_list_end()
		_stamp("ws_depth")
		# The nearer of the two, for the smoothing (or the smoothing works it out as it reads them).
		if _fused():
			nearest_tex = depth_tex
		else:
			nearest_tex = smooth_b
			_resolve_depth(params, depth_tex, near_small, smooth_b, Vector2i((size.x + 7) / 8, (size.y + 7) / 8))

		# Every big sphere's chord, added up, with its colours; then the small ones' sums added in.
		var thickness_fb := FramebufferCacheRD.get_cache_multipass([deep_tex, shallow_tex], [], 1)
		if not _thickness_pipeline.is_valid():
			_thickness_pipeline = _raster_pipeline(_thickness_shader, thickness_fb, 2, false)
		var set_thickness := UniformSetCacheRD.get_cache(_thickness_shader, 0, [big, params, scene_depth_u])
		draw = _rd.draw_list_begin(thickness_fb, RenderingDevice.DRAW_CLEAR_ALL, PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0)]), 1.0)
		_rd.draw_list_bind_render_pipeline(draw, _thickness_pipeline)
		_rd.draw_list_bind_uniform_set(draw, set_thickness, 0)
		_rd.draw_list_bind_vertex_array(draw, _empty_vertex_array)
		_rd.draw_list_draw_indirect(draw, false, _draw_buffer, 0, 1, 0)
		_rd.draw_list_end()
		var set_sums := UniformSetCacheRD.get_cache(_thickness_resolve_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_sums_buffer]), params,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [deep_tex]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [shallow_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 4, [near_small])])
		var sums := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(sums, _thickness_resolve_pipeline)
		_rd.compute_list_bind_uniform_set(sums, set_sums, 0)
		_rd.compute_list_dispatch(sums, (thickness_size.x + 7) / 8, (thickness_size.y + 7) / 8, 1)
		_rd.compute_list_end()
		_stamp("ws_thickness")

	# The depth smoothed (the first pass reads our depth buffer).
	var groups := Vector2i((size.x + 7) / 8, (size.y + 7) / 8)
	var source := _smooth_depth(buffers, size, params, nearest_tex, smooth_a, near_small)

	# The picture as it is, to see through the water; then the water over it.
	var set_copy := UniformSetCacheRD.get_cache(_copy_shader, 0, [
		_sampled(0, color, _sampler_nearest), params, _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [scene_copy])])
	var copy := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(copy, _copy_pipeline)
	_rd.compute_list_bind_uniform_set(copy, set_copy, 0)
	_rd.compute_list_dispatch(copy, groups.x, groups.y, 1)
	_rd.compute_list_end()
	_stamp("ws_copy")
	var set_shade := UniformSetCacheRD.get_cache(_shade_shader, 0, [
		_sampled(0, source, _sampler_nearest), params, _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [color]),
		_sampled(3, deep_tex, _sampler_nearest), _sampled(4, shallow_tex, _sampler_nearest),
		_sampled(5, scene_copy, _sampler_linear), _sampled(6, scene_depth, _sampler_nearest)])
	var shade := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(shade, _shade_pipeline)
	_rd.compute_list_bind_uniform_set(shade, set_shade, 0)
	_rd.compute_list_dispatch(shade, groups.x, groups.y, 1)
	_rd.compute_list_end()
	_stamp("ws_shade")
	_write_scene_depth(scene_data, scene_depth, UniformSetCacheRD.get_cache(_scene_depth_shader, 0, [_sampled(0, source, _sampler_nearest), params]))


# The opaque style's targets and uniform sets (its particles' at half size, see _render_opaque): looked up once and kept while what they were made for stays the same. (This runs every
# frame on the render thread, and a look-up builds uniform objects from script: about 30 of them a frame.)
func _opaque_prepare(buffers: RenderSceneBuffersRD, size: Vector2i, color: RID, scene_depth: RID) -> void:
	if size == _op_size and color == _op_color and scene_depth == _op_scene_depth and _points_buffer == _op_points and clear == _op_clear and smoothing_passes == _op_passes and _rd.uniform_set_is_valid(_op_raster_set) and _rd.uniform_set_is_valid(_op_shade_set):
		return
	_op_size = size
	_op_color = color
	_op_scene_depth = scene_depth
	_op_points = _points_buffer
	_op_clear = clear
	_op_passes = smoothing_passes
	_op_groups = Vector2i((size.x + 7) / 8, (size.y + 7) / 8)
	var sampled := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var storage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | sampled
	var half := (size + Vector2i.ONE) / 2
	_op_half_groups = Vector2i((half.x + 7) / 8, (half.y + 7) / 8)
	_op_near_small = _near_small(buffers, half)
	var depth_tex := _texture(buffers, &"depth_half", RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | sampled, half)
	var half_a := _texture(buffers, &"smooth_half_a", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, half)
	var half_b := _texture(buffers, &"smooth_half_b", RenderingDevice.DATA_FORMAT_R32_SFLOAT, storage, half)
	_op_fb = FramebufferCacheRD.get_cache_multipass([depth_tex], [], 1)
	var params := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [_params_buffer])
	var params_half := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [_params_half_buffer])
	var points := _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_points_buffer])
	var scene_depth_u := _sampled(2, scene_depth, _sampler_nearest)
	var near_small_3 := _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [_op_near_small])
	var near_small_4 := _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 4, [_op_near_small])
	var big := _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_big_buffer])
	_op_raster_set = UniformSetCacheRD.get_cache(_raster_shader, 0, [points, params_half, scene_depth_u, near_small_3,
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_big_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_draw_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [_no_sums])])
	_op_depth_set = UniformSetCacheRD.get_cache(_opaque_depth_shader, 0, [big, params_half, scene_depth_u])
	_op_resolve_set = UniformSetCacheRD.get_cache(_resolve_shader, 0, [_sampled(0, depth_tex, _sampler_nearest), params_half,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [half_a]), near_small_3])
	_op_smooth_sets.clear()
	_op_smooth_pushes.clear()
	var passes := maxi(smoothing_passes, 0)
	var from := half_a
	var targets: Array[RID] = [half_b, half_a]
	for pass_index in passes * 2:
		var target := targets[pass_index % 2]
		var horizontal := pass_index % 2 == 0
		_op_smooth_pushes.append(PackedFloat32Array([1.0 if horizontal else 0.0, 0.0 if horizontal else 1.0, 4.0 if pass_index >= passes * 2 - 2 else 0.0, 0.0]).to_byte_array())
		_op_smooth_sets.append(UniformSetCacheRD.get_cache(_smooth_shader, 0, [_sampled(0, from, _sampler_nearest), params_half,
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [target])]))
		from = target
	_op_shade_set = UniformSetCacheRD.get_cache(_clear_shade_shader if clear else _opaque_shade_shader, 0, [_sampled(0, from, _sampler_nearest), params,
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [color]), _sampled(3, depth_tex, _sampler_nearest), near_small_4, _sampled(5, scene_depth, _sampler_nearest)])
	_op_scene_depth_set = UniformSetCacheRD.get_cache(_opaque_scene_depth_shader, 0, [_sampled(0, from, _sampler_nearest), params])


# One compute dispatch with a set already made.
func _dispatch(pipeline: RID, uniform_set: RID, groups: Vector2i, push := PackedByteArray()) -> void:
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	if not push.is_empty():
		_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()


# The opaque style: near spheres by the hardware, small ones by a compute rasterizer, both at half the picture's size (the depth pass
# costs by the pixel); the nearer of the two smoothed there, and lit at full size from that (fluid_opaque_surface.glslinc).
func _render_opaque(buffers: RenderSceneBuffersRD, scene_data: RenderSceneData, size: Vector2i, color: RID, scene_depth: RID) -> void:
	_opaque_prepare(buffers, size, color, scene_depth)
	_stamp("ws_start")
	# The small ones by compute, the near ones listed for the hardware.
	_rd.buffer_update(_draw_buffer, 0, _draw_reset.size(), _draw_reset)
	_rd.texture_clear(_op_near_small, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if _op_raster_count != _count:
		_op_raster_count = _count
		_op_raster_groups = _raster_groups()
		_op_raster_push = PackedInt32Array([_count, 0, _op_raster_groups.x * 64, 0]).to_byte_array()
	_dispatch(_raster_pipeline_rid, _op_raster_set, _op_raster_groups, _op_raster_push)
	_stamp("ws_raster")
	# The near particles: spheres, depth-tested, the nearest one's depth and substance kept.
	if not _opaque_depth_pipeline.is_valid():
		var depth_stencil := RDPipelineDepthStencilState.new()
		depth_stencil.enable_depth_test = true
		depth_stencil.enable_depth_write = true
		depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_LESS
		var blend := RDPipelineColorBlendState.new()
		_opaque_depth_pipeline = _rd.render_pipeline_create(_opaque_depth_shader, _rd.framebuffer_get_format(_op_fb), _rd.vertex_format_create([]),
				RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(), depth_stencil, blend)
	var draw := _rd.draw_list_begin(_op_fb, RenderingDevice.DRAW_CLEAR_ALL, PackedColorArray(), 1.0)
	_rd.draw_list_bind_render_pipeline(draw, _opaque_depth_pipeline)
	_rd.draw_list_bind_uniform_set(draw, _op_depth_set, 0)
	_rd.draw_list_bind_vertex_array(draw, _empty_vertex_array)
	_rd.draw_list_draw_indirect(draw, false, _draw_buffer, 0, 1, 0)
	_rd.draw_list_end()
	_stamp("ws_depth")
	# The nearer of the two, as depth for the smoothing.
	_dispatch(_resolve_pipeline, _op_resolve_set, _op_half_groups)
	_stamp("ws_resolve")
	for i in _op_smooth_sets.size():
		_dispatch(_smooth_pipeline, _op_smooth_sets[i], _op_half_groups, _op_smooth_pushes[i])
	_stamp("ws_smooth")
	_dispatch(_clear_shade_pipeline if clear else _opaque_shade_pipeline, _op_shade_set, _op_groups)
	_stamp("ws_shade")
	_write_scene_depth(scene_data, scene_depth, _op_scene_depth_set)
