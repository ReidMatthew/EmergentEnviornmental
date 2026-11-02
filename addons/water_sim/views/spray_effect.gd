@tool
class_name WaterSimSprayEffect
extends CompositorEffect
## Moves and draws a simulation's spray, all on the graphics card: a fixed pool of particles (a ring: the newest write over the
## oldest), into which each frame's spawns go (spray_spawn.glsl), moved by gravity and air drag and landed against the scene's depth
## (spray_update.glsl), drawn as soft white quads after everything else (spray_draw.glsl). The simulation never sees them.
##
## Don't make one by hand: a [WaterSimSprayView] makes it, feeds it what the simulation shed and puts it on the camera (as a
## compositor effect; needs the Forward+ or Mobile renderer). It runs on the render thread.

const FLOATS_IN_PARAMS := 16 * 4 + 4 * 5 + 64 * 4
const SPRAY_BYTES := 48

# What the view sets (read on the render thread: single values, so no lock).
## How many spray particles there can be at once (set before the first frame).
var capacity := 65536
var particle_radius := 0.03
var opacity := 0.6
var stretch := 0.03
var lifetime := 1.2
var lifetime_spread := 0.4
var drag := 0.6
var land_band := 0.6
var land_grace := 0.08
var scatter := 0.05
var velocity_scatter := 0.15
var velocity_kick := 0.3
## How many spray particles each one the simulation sheds makes (each scattered its own way).
var per_particle := 1
var gravity := Vector3(0.0, -9.8, 0.0)
var colors := PackedColorArray()

var _rd: RenderingDevice
var _mutex := Mutex.new()
var _incoming := PackedFloat32Array()
var _incoming_to_world := Transform3D.IDENTITY
var _incoming_time := 0.0
var _to_world := Transform3D.IDENTITY
var _ready_to_draw := false
var _spawn_shader: RID
var _update_shader: RID
var _draw_shader: RID
var _spawn_pipeline: RID
var _update_pipeline: RID
var _draw_pipeline: RID
var _draw_format := -1
var _draw_reversed := true
var _sampler: RID
var _pool: RID
var _pool_capacity := 0
var _spawns: RID
var _spawns_capacity := 0
var _params: RID
var _empty_vertex_array: RID
var _head := 0
var _seed := 0
var _per := 1
# Time since the last spawn (s): once every particle must have died, nothing is moved or drawn.
var _quiet := INF


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_motion_vectors = false
	needs_normal_roughness = false
	RenderingServer.call_on_render_thread(_initialize_render)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		# (Not a method of this object, which is going: what there is to free is handed over.)
		var rd := _rd
		var rids: Array[RID] = [_spawn_pipeline, _update_pipeline, _draw_pipeline, _spawn_shader, _update_shader, _draw_shader, _sampler,
				_pool, _spawns, _params, _empty_vertex_array]
		RenderingServer.call_on_render_thread(func() -> void:
			for rid in rids:
				if rid.is_valid():
					rd.free_rid(rid))


## What the simulation shed (eight floats each: see [method WaterSimSolver.take_spray]) and the transform from the solver's space to
## the world's. Called from the game's thread; added at the next frame.
func add_spawns(spawns: PackedFloat32Array, to_world: Transform3D) -> void:
	_mutex.lock()
	# (More than the pool holds would only write over itself.)
	if _incoming.size() < capacity * 8:
		_incoming.append_array(spawns)
	_incoming_to_world = to_world
	_mutex.unlock()


## The game's time that passed (s), which the next frame moves the spray by.
func advance(delta: float) -> void:
	_mutex.lock()
	_incoming_time += delta
	_mutex.unlock()


func _shader(path: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null:
		push_error("WaterSimSprayEffect: can't load %s" % path)
		return RID()
	var spirv := file.get_spirv()
	for message in [spirv.compile_error_vertex, spirv.compile_error_fragment, spirv.compile_error_compute]:
		if message != "":
			push_error("WaterSimSprayEffect: %s: %s" % [path, message])
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
	_sampler = _rd.sampler_create(nearest)
	var dir := "res://addons/water_sim/shaders/"
	_spawn_shader = _shader(dir + "spray_spawn.glsl")
	_update_shader = _shader(dir + "spray_update.glsl")
	_draw_shader = _shader(dir + "spray_draw.glsl")
	if not (_spawn_shader.is_valid() and _update_shader.is_valid() and _draw_shader.is_valid()):
		return
	_spawn_pipeline = _rd.compute_pipeline_create(_spawn_shader)
	_update_pipeline = _rd.compute_pipeline_create(_update_shader)
	_params = _rd.uniform_buffer_create(FLOATS_IN_PARAMS * 4)
	_empty_vertex_array = _rd.vertex_array_create(0, _rd.vertex_format_create([]), [])
	_ready_to_draw = true


func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


func _projection_floats(p: Projection) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for column in [p.x, p.y, p.z, p.w]:
		out.append_array(PackedFloat32Array([column.x, column.y, column.z, column.w]))
	return out


func _write_params(scene_data: RenderSceneData, size: Vector2i, dt: float) -> void:
	var projection := scene_data.get_cam_projection()
	var data := PackedFloat32Array()
	data.append_array(_projection_floats(Projection(scene_data.get_cam_transform().affine_inverse())))
	data.append_array(_projection_floats(projection))
	data.append_array(_projection_floats(projection.inverse()))
	data.append_array(_projection_floats(Projection(_to_world)))
	data.append_array(PackedFloat32Array([size.x, size.y, 1.0 / size.x, 1.0 / size.y]))
	data.append_array(PackedFloat32Array([gravity.x, gravity.y, gravity.z, dt]))
	data.append_array(PackedFloat32Array([lifetime, lifetime_spread, drag, land_band]))
	data.append_array(PackedFloat32Array([particle_radius, opacity, stretch, land_grace]))
	data.append_array(PackedFloat32Array([scatter, velocity_scatter, float(_per), velocity_kick]))
	for i in 64:
		var c: Color = colors[i] if i < colors.size() else Color(0.92, 0.95, 1.0)
		data.append_array(PackedFloat32Array([c.r, c.g, c.b, 1.0]))
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params, 0, bytes.size(), bytes)


func _ensure_pool() -> void:
	var want := maxi(capacity, 64)
	if want == _pool_capacity:
		return
	if _pool.is_valid():
		_rd.free_rid(_pool)
	# (All zero: every particle dead.)
	var zeros := PackedByteArray()
	zeros.resize(want * SPRAY_BYTES)
	_pool = _rd.storage_buffer_create(zeros.size(), zeros)
	_pool_capacity = want
	_head = 0


func _push(count: int) -> PackedByteArray:
	return PackedInt32Array([count, _head, _pool_capacity, _seed]).to_byte_array()


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	if not _ready_to_draw or _rd == null:
		return
	_mutex.lock()
	var incoming := _incoming
	_incoming = PackedFloat32Array()
	var dt := minf(_incoming_time, 0.1)
	_incoming_time = 0.0
	if incoming.size() > 0:
		_to_world = _incoming_to_world
	_mutex.unlock()
	_ensure_pool()
	# (Read once a frame, so the spawn pass and its count agree.)
	_per = maxi(per_particle, 1)
	var shed := incoming.size() / 8
	var count := mini(shed * _per, _pool_capacity)
	if count > 0:
		_quiet = 0.0
	else:
		_quiet += dt
	if _quiet > lifetime * (1.0 + lifetime_spread) + 0.2:
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
	_write_params(scene_data, size, dt)
	var params := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [_params])
	var pool := _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_pool])

	if count > 0:
		var bytes := incoming.slice(0, ceili(float(count) / _per) * 8).to_byte_array()
		if bytes.size() > _spawns_capacity:
			if _spawns.is_valid():
				_rd.free_rid(_spawns)
			_spawns_capacity = maxi(bytes.size() * 3 / 2, 32 * 1024)
			_spawns = _rd.storage_buffer_create(_spawns_capacity)
		_rd.buffer_update(_spawns, 0, bytes.size(), bytes)
		_seed = (_seed + 0x9E3779B1) & 0x7fffffff
		var set_spawn := UniformSetCacheRD.get_cache(_spawn_shader, 0, [pool, params, _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [_spawns])])
		var push := _push(count)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _spawn_pipeline)
		_rd.compute_list_bind_uniform_set(list, set_spawn, 0)
		_rd.compute_list_set_push_constant(list, push, push.size())
		_rd.compute_list_dispatch(list, (count + 63) / 64, 1, 1)
		_rd.compute_list_end()
		_head = (_head + count) % _pool_capacity

	var set_update := UniformSetCacheRD.get_cache(_update_shader, 0, [pool, params,
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_sampler, scene_depth])])
	var push := _push(0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _update_pipeline)
	_rd.compute_list_bind_uniform_set(list, set_update, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, (_pool_capacity + 63) / 64, 1, 1)
	_rd.compute_list_end()

	# Over the picture, hidden by the scene and the water in front (their depth, not written).
	var fb := FramebufferCacheRD.get_cache_multipass([color, scene_depth], [], 1)
	var format := _rd.framebuffer_get_format(fb)
	# (Godot draws depth reversed, 1 near: checked from the projection rather than assumed.)
	var projection := scene_data.get_cam_projection()
	var near := projection * Vector4(0.0, 0.0, -1.0, 1.0)
	var far := projection * Vector4(0.0, 0.0, -10.0, 1.0)
	var reversed := near.z / near.w > far.z / far.w
	if not _draw_pipeline.is_valid() or format != _draw_format or reversed != _draw_reversed:
		if _draw_pipeline.is_valid():
			_rd.free_rid(_draw_pipeline)
		var depth_stencil := RDPipelineDepthStencilState.new()
		depth_stencil.enable_depth_test = true
		depth_stencil.enable_depth_write = false
		depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER if reversed else RenderingDevice.COMPARE_OP_LESS
		var blend := RDPipelineColorBlendState.new()
		var attachment := RDPipelineColorBlendStateAttachment.new()
		# (Premultiplied: the colour is already times its alpha.)
		attachment.enable_blend = true
		attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
		attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
		attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
		blend.attachments.push_back(attachment)
		_draw_pipeline = _rd.render_pipeline_create(_draw_shader, format, _rd.vertex_format_create([]), RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
				RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(), depth_stencil, blend)
		_draw_format = format
		_draw_reversed = reversed
	var set_draw := UniformSetCacheRD.get_cache(_draw_shader, 0, [pool, params])
	var draw := _rd.draw_list_begin(fb, RenderingDevice.DRAW_DEFAULT_ALL)
	_rd.draw_list_bind_render_pipeline(draw, _draw_pipeline)
	_rd.draw_list_bind_uniform_set(draw, set_draw, 0)
	_rd.draw_list_bind_vertex_array(draw, _empty_vertex_array)
	_rd.draw_list_set_push_constant(draw, push, push.size())
	_rd.draw_list_draw(draw, false, _pool_capacity, 6)
	_rd.draw_list_end()
