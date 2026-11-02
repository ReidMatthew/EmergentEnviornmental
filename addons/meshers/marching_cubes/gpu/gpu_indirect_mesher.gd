@tool
class_name MarchingCubesGpuIndirectMesher
extends Mesher
## Marching cubes whose triangles never leave the GPU. A compute shader writes each grid's
## triangles into a slot of a shared triangle pool texture and sets the draw count of an
## indirect MultiMesh; a vertex shader (pull.gdshaderinc) pulls the triangles back out
## when drawing. Nothing is read back, so nothing waits on the GPU.
##
## Because there is no CPU copy of the mesh, callers that need one (collision, raycasts)
## must use another mesher. [method polygonize] and [method polygonize_batch] do exactly
## that, through [method get_fallback_mesher].
##
## Usage, main thread only:
## [codeblock]
## var target := mesher.acquire_target(chunk_bounds)   # null when the pool is full
## mesher.submit(grids, targets)                        # queues the GPU work, returns at once
## [/codeblock]
## then draw [member MesherIndirectTarget.multimesh] as that class describes.
##
## Runs on the main RenderingDevice (the pool must be visible to materials), with all
## device work queued through RenderingServer.call_on_render_thread(). Needs Forward+ or
## Mobile; see [method is_gpu_resident].

## Triangles per chunk slot. A chunk that produces more is cut off and reported by
## [method take_overflowed]; the terrain then draws it from a CPU mesh instead. Pool
## memory is slot_triangles x 3 vertices x 16 bytes x [member max_slots] (75 MB at the
## defaults).
@export_range(64, 65536, 64) var slot_triangles := 6144:
	set(value):
		slot_triangles = maxi(64, value - value % 64)
		_settings_changed()
## Chunks that can be on the GPU at once. Further chunks are drawn from CPU meshes.
@export_range(1, 4096) var max_slots := 256:
	set(value):
		max_slots = value
		_settings_changed()
## Grids meshed per GPU submission; the terrain hands this many to each job.
@export_range(1, 64) var max_batch := 16

var _mutex := Mutex.new()
var _state: _State
var _fallback: Mesher


## True when triangles can stay on the GPU (a RenderingDevice exists). When false, use
## this like any other mesher; it meshes through [method get_fallback_mesher].
func is_gpu_resident() -> bool:
	return RenderingServer.get_rendering_device() != null


func polygonize(grid: MesherGrid) -> MeshData:
	return get_fallback_mesher().polygonize(grid)


func polygonize_batch(grids: Array[MesherGrid]) -> Array[MeshData]:
	return get_fallback_mesher().polygonize_batch(grids)


func get_batch_size() -> int:
	return max_batch


## Creates the triangle pool and pipeline (on the render thread: about 17 ms, once).
func warm_up() -> void:
	if is_gpu_resident():
		_get_state()
	get_fallback_mesher().warm_up()


## The mesher used when a CPU mesh is needed: [MarchingCubesGpuMesher], which itself falls back to
## the CPU without a RenderingDevice.
func get_fallback_mesher() -> Mesher:
	if _fallback == null:
		_fallback = MarchingCubesGpuMesher.new()
	return _fallback


## Reserves a pool slot and an indirect MultiMesh. [param bounds] is the culling box of
## the triangles in the caller's local space. Returns null when every slot is taken.
func acquire_target(bounds: AABB) -> MesherIndirectTarget:
	return _get_state().acquire(bounds)


## Returns a target's slot and MultiMesh for reuse. Stop drawing it first.
func release_target(target: MesherIndirectTarget) -> void:
	var state: _State = target._owner
	if state != null:
		state.release(target)


## Queues marching cubes for each grid into the matching target. Returns immediately; the
## work runs on the render thread before the next frame is drawn. Main thread only.
func submit(grids: Array[MesherGrid], targets: Array[MesherIndirectTarget]) -> void:
	assert(grids.size() == targets.size())
	if grids.is_empty():
		return
	_get_state().submit(grids, targets)


## The triangle pool, for the ms_triangle_pool uniform of materials using pull.gdshaderinc.
func get_pool_texture() -> Texture2DRD:
	return _get_state().pool_texture


## Targets whose latest mesh had more triangles than a slot holds, since the last call.
func take_overflowed() -> Array[MesherIndirectTarget]:
	_mutex.lock()
	var state := _state
	_mutex.unlock()
	return state.take_overflowed() if state != null else ([] as Array[MesherIndirectTarget])


## Targets whose latest mesh turned out to have no triangles, since the last call. Their
## slots are wasted until released; the CPU can't know a mesh is empty before this.
func take_empty() -> Array[MesherIndirectTarget]:
	_mutex.lock()
	var state := _state
	_mutex.unlock()
	return state.take_empty() if state != null else ([] as Array[MesherIndirectTarget])


## True while triangle counts are still being read back.
func has_pending_readbacks() -> bool:
	_mutex.lock()
	var state := _state
	_mutex.unlock()
	return state != null and state.pending_readbacks() > 0


## True while reports are waiting to be taken ([method take_overflowed], [method take_empty]).
func has_unread_reports() -> bool:
	_mutex.lock()
	var state := _state
	_mutex.unlock()
	return state != null and state.unread_reports() > 0


## Debug and tests: copies a target's triangles back into an unindexed [MeshData].
## Stalls the GPU and reads the whole pool texture, so keep the pool small when using it.
## A coroutine: call it with await.
func read_target(target: MesherIndirectTarget) -> MeshData:
	var state := _get_state()
	var result := [PackedByteArray()]
	var done := [false]
	_on_render_thread(func() -> void:
		result[0] = state.read_pool()
		done[0] = true)
	var tree := Engine.get_main_loop() as SceneTree
	while not done[0]:
		await tree.process_frame
	return state.decode_target(result[0], target)


## Runs [param fn] on the render thread: right away when already on it (the default,
## single-threaded rendering), otherwise queued. Running right away also lets teardown
## happen during engine shutdown, when queued calls never run.
static func _on_render_thread(fn: Callable) -> void:
	if RenderingServer.is_on_render_thread():
		fn.call()
	else:
		RenderingServer.call_on_render_thread(fn)


func _get_state() -> _State:
	_mutex.lock()
	if _state == null or (_state.stale and _state.live_targets() == 0):
		_state = _State.new(slot_triangles, max_slots)
	var state := _state
	_mutex.unlock()
	return state


func _settings_changed() -> void:
	_mutex.lock()
	if _state != null:
		_state.stale = true
	_mutex.unlock()
	emit_changed()


## Everything on the GPU for one pool size. Render-thread callables capture it, so it lives
## until the last queued call has run, and its teardown is itself queued on the render thread.
class _State:
	extends RefCounted

	const _SHADER := preload("./indirect.glsl")
	const _GROUP := 4
	const _POOL_WIDTH := 4096
	const _TRIANGLES_PER_INSTANCE := 64
	const _MAX_SUBMIT := 64

	## Set when the mesher's settings change; replaced once no targets are out.
	var stale := false
	var pool_texture := Texture2DRD.new()

	var _slot_triangles := 0
	var _max_slots := 0
	var _mutex := Mutex.new()
	var _free_slots: Array[int] = []
	var _live := 0
	var _spare_targets: Array[MesherIndirectTarget] = []
	# Every MultiMesh created, for teardown. RIDs only: holding the targets would make a
	# cycle with acquired targets, which reference this state.
	var _all_multimeshes: Array[RID] = []
	var _base_mesh := ArrayMesh.new()
	var _identity: PackedFloat32Array
	var _overflowed: Array[MesherIndirectTarget] = []
	var _empty: Array[MesherIndirectTarget] = []
	var _pending := 0

	# Render thread only.
	var _rd: RenderingDevice
	var _gpu_ready := false
	var _shader := RID()
	var _pipeline := RID()
	var _pool := RID()
	var _tri_table := RID()
	var _transition_cases := RID()
	var _triangle_counts := RID()
	var _draw_counts := RID()
	var _scratch: Array[_Scratch] = []

	func _init(slot_triangles: int, max_slots: int) -> void:
		_slot_triangles = slot_triangles
		_max_slots = max_slots
		for i in max_slots:
			_free_slots.append(max_slots - 1 - i)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var corners := PackedVector3Array()
		corners.resize(_TRIANGLES_PER_INSTANCE * 3)
		arrays[Mesh.ARRAY_VERTEX] = corners
		_base_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var instances := slot_triangles / _TRIANGLES_PER_INSTANCE
		_identity.resize(instances * 12)
		for i in instances:
			_identity[i * 12] = 1.0
			_identity[i * 12 + 5] = 1.0
			_identity[i * 12 + 10] = 1.0
		var state := self
		MarchingCubesGpuIndirectMesher._on_render_thread(func() -> void: state._init_gpu())

	func live_targets() -> int:
		_mutex.lock()
		var live := _live
		_mutex.unlock()
		return live

	func pending_readbacks() -> int:
		_mutex.lock()
		var pending := _pending
		_mutex.unlock()
		return pending

	func unread_reports() -> int:
		_mutex.lock()
		var unread := _overflowed.size() + _empty.size()
		_mutex.unlock()
		return unread

	func acquire(bounds: AABB) -> MesherIndirectTarget:
		_mutex.lock()
		if _free_slots.is_empty():
			_mutex.unlock()
			return null
		var slot: int = _free_slots.pop_back()
		var target: MesherIndirectTarget = null if _spare_targets.is_empty() else _spare_targets.pop_back()
		_live += 1
		_mutex.unlock()
		if target == null:
			target = MesherIndirectTarget.new()
			# Order matters: Godot creates the command buffer in multimesh_set_mesh, and only
			# if the multimesh is already allocated as indirect.
			target.multimesh = RenderingServer.multimesh_create()
			RenderingServer.multimesh_allocate_data(target.multimesh, _slot_triangles / _TRIANGLES_PER_INSTANCE,
					RenderingServer.MULTIMESH_TRANSFORM_3D, false, false, true)
			RenderingServer.multimesh_set_mesh(target.multimesh, _base_mesh.get_rid())
			RenderingServer.multimesh_set_buffer(target.multimesh, _identity)
			_mutex.lock()
			_all_multimeshes.append(target.multimesh)
			_mutex.unlock()
		RenderingServer.multimesh_set_custom_aabb(target.multimesh, bounds)
		target._slot = slot
		target._owner = self
		target.vertex_base = slot * _slot_triangles * 3
		target.capacity = _slot_triangles
		target.triangle_count = -1
		target.user_data = null
		target._submission += 1
		return target

	func release(target: MesherIndirectTarget) -> void:
		_mutex.lock()
		if target._slot >= 0:
			_free_slots.append(target._slot)
			target._slot = -1
			target._submission += 1
			target._owner = null
			_live -= 1
			_spare_targets.append(target)
		_mutex.unlock()

	func take_overflowed() -> Array[MesherIndirectTarget]:
		_mutex.lock()
		var out := _overflowed
		_overflowed = []
		_mutex.unlock()
		return out

	func take_empty() -> Array[MesherIndirectTarget]:
		_mutex.lock()
		var out := _empty
		_empty = []
		_mutex.unlock()
		return out

	func submit(grids: Array[MesherGrid], targets: Array[MesherIndirectTarget]) -> void:
		var submissions := PackedInt32Array()
		for target in targets:
			target._submission += 1
			target.triangle_count = -1
			submissions.append(target._submission)
		_mutex.lock()
		_pending += 1
		_mutex.unlock()
		var state := self
		var grids_copy := grids.duplicate()
		var targets_copy := targets.duplicate()
		MarchingCubesGpuIndirectMesher._on_render_thread(func() -> void:
			state._run(grids_copy, targets_copy, submissions))

	# --- Render thread ------------------------------------------------------------------

	func _init_gpu() -> void:
		_rd = RenderingServer.get_rendering_device()
		_shader = _rd.shader_create_from_spirv(_SHADER.get_spirv())
		_pipeline = _rd.compute_pipeline_create(_shader)
		var table := MarchingCubesTables.tri_table.to_byte_array()
		_tri_table = _rd.storage_buffer_create(table.size(), table)
		var cases := TransvoxelTables.cases.to_byte_array()
		_transition_cases = _rd.storage_buffer_create(cases.size(), cases)
		_triangle_counts = _rd.storage_buffer_create(_MAX_SUBMIT * 4)
		_draw_counts = _rd.storage_buffer_create(_MAX_SUBMIT * 4)
		var fmt := RDTextureFormat.new()
		fmt.width = _POOL_WIDTH
		fmt.height = maxi(1, ceili(float(_max_slots * _slot_triangles * 3) / _POOL_WIDTH))
		fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_pool = _rd.texture_create(fmt, RDTextureView.new())
		_gpu_ready = true
		var texture := pool_texture
		var pool := _pool
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			texture.texture_rd_rid = pool
		else:
			(func() -> void: texture.texture_rd_rid = pool).call_deferred()

	func _run(grids: Array, targets: Array, submissions: PackedInt32Array) -> void:
		var count := mini(grids.size(), _MAX_SUBMIT)
		var jobs: Array[_Entry] = []
		for i in count:
			var grid: MesherGrid = grids[i]
			var target: MesherIndirectTarget = targets[i]
			if target._submission != submissions[i]:
				continue  # released or resubmitted since; skip stale work
			if not target._command_buffer.is_valid():
				target._command_buffer = RenderingServer.multimesh_get_command_buffer_rd_rid(target.multimesh)
			var entry := _Entry.new()
			entry.grid = grid
			entry.target = target
			entry.submission = submissions[i]
			entry.index = jobs.size()
			entry.end = grid.get_cell_end()
			entry.cells = entry.end - grid.cell_begin
			var samples := grid.size.x * grid.size.y * grid.size.z
			if samples == 0 or entry.cells.x <= 0 or entry.cells.y <= 0 or entry.cells.z <= 0:
				continue
			while _scratch.size() <= entry.index:
				_scratch.append(_Scratch.new())
			entry.scratch = _scratch[entry.index]
			entry.has_materials = grid.materials.size() == samples
			var side := maxi(grid.size.x, maxi(grid.size.y, grid.size.z))
			if samples > entry.scratch.capacity or side > entry.scratch.side_capacity:
				entry.scratch.allocate(_rd, samples, side, _shader,
						[_tri_table, _triangle_counts, _draw_counts, _pool, _transition_cases])
			var values := grid.get_gpu_samples()
			_rd.buffer_update(entry.scratch.values, 0, values.size(), values)
			if entry.has_materials:
				var materials := grid.materials.duplicate()
				materials.resize(ceili(samples / 4.0) * 4)
				_rd.buffer_update(entry.scratch.materials, 0, materials.size(), materials)
			if not grid.transitions.is_empty():
				var data := MesherTransition.gpu_data(grid)
				_rd.buffer_update(entry.scratch.transition_data, 0, data.size(), data)
			jobs.append(entry)
		if jobs.is_empty():
			_finish_readback()
			return
		_rd.buffer_clear(_triangle_counts, 0, jobs.size() * 4)

		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		# Edges, then cells and transition cells (independent of each other), then finalize.
		for pass_index: int in [0, 1, 3, 2]:
			if pass_index == 1 or pass_index == 2:
				_rd.compute_list_add_barrier(list)
			for entry in jobs:
				if pass_index == 3 and entry.grid.transitions.is_empty():
					continue
				var params := _params(entry, pass_index)
				_rd.compute_list_bind_uniform_set(list, entry.scratch.uniform_set, 0)
				_rd.compute_list_set_push_constant(list, params, params.size())
				if pass_index == 2:
					_rd.compute_list_dispatch(list, 1, 1, 1)
				elif pass_index == 3:
					var most := maxi(entry.cells.x, maxi(entry.cells.y, entry.cells.z))
					_rd.compute_list_dispatch(list, _groups(most), _groups(most), _groups(6))
				else:
					var size := entry.cells + (Vector3i.ONE if pass_index == 0 else Vector3i.ZERO)
					_rd.compute_list_dispatch(list, _groups(size.x), _groups(size.y), _groups(size.z))
		_rd.compute_list_end()

		# The instance count is the second integer of the MultiMesh's draw command.
		for entry in jobs:
			_rd.buffer_copy(_draw_counts, entry.target._command_buffer, entry.index * 4, 4, 4)
		var state := self
		_rd.buffer_get_data_async(_triangle_counts, func(data: PackedByteArray) -> void:
			state._on_counts(data, jobs), 0, jobs.size() * 4)

	func _on_counts(data: PackedByteArray, jobs: Array[_Entry]) -> void:
		var counts := data.to_int32_array()
		_mutex.lock()
		for entry in jobs:
			var target := entry.target
			if target._submission != entry.submission:
				continue
			target.triangle_count = counts[entry.index]
			if target.triangle_count > target.capacity:
				_overflowed.append(target)
			elif target.triangle_count == 0:
				_empty.append(target)
		_mutex.unlock()
		_finish_readback()

	func _finish_readback() -> void:
		_mutex.lock()
		_pending -= 1
		_mutex.unlock()

	func read_pool() -> PackedByteArray:
		return _rd.texture_get_data(_pool, 0) if _gpu_ready else PackedByteArray()

	func decode_target(pool: PackedByteArray, target: MesherIndirectTarget) -> MeshData:
		var out := MeshData.new()
		var count := mini(maxi(target.triangle_count, 0), target.capacity)
		var texels := pool.slice(target.vertex_base * 16, (target.vertex_base + count * 3) * 16).to_float32_array()
		for v in count * 3:
			var o := v * 4
			out.vertices.append(Vector3(texels[o], texels[o + 1], texels[o + 2]))
			var w := int(texels[o + 3])
			var e := Vector2(w & 255, (w >> 8) & 255) / 255.0 * 2.0 - Vector2.ONE
			var n := Vector3(e.x, e.y, 1.0 - absf(e.x) - absf(e.y))
			var t := maxf(-n.z, 0.0)
			n.x += -t if n.x >= 0.0 else t
			n.y += -t if n.y >= 0.0 else t
			out.normals.append(n.normalized())
			out.colors.append(Color8((w >> 16) & 255, 0, 0))
			out.indices.append(v)
		return out

	func _params(entry: _Entry, pass_index: int) -> PackedByteArray:
		var grid := entry.grid
		var b := grid.cell_begin
		var e := entry.end
		var ints := PackedInt32Array([
			grid.size.x, grid.size.y, grid.size.z, 1 if entry.has_materials else 0,
			b.x, b.y, b.z, pass_index,
			e.x, e.y, e.z, 1 if MarchingCubesTables.FLIP_WINDING else 0,
		])
		var floats := PackedFloat32Array([
			grid.origin.x, grid.origin.y, grid.origin.z, grid.spacing,
			grid.iso, 1.0 if grid.uses_bytes() else 0.0, grid.byte_center, grid.byte_scale,
		])
		var slot := PackedInt32Array([entry.index, entry.target.vertex_base, entry.target.capacity, _POOL_WIDTH])
		var skirt := PackedFloat32Array([grid.skirt_depth, 0.0, 0.0, 0.0])
		var transition := grid.get_gpu_transition_params()
		transition.append_array(PackedInt32Array([0, 0]))
		return ints.to_byte_array() + floats.to_byte_array() + slot.to_byte_array() + skirt.to_byte_array() \
				+ transition.to_byte_array()

	func _groups(count: int) -> int:
		return ceili(float(count) / _GROUP)

	func _notification(what: int) -> void:
		if what != NOTIFICATION_PREDELETE:
			return
		# Materials may still hold the pool texture; detach it before the pool goes.
		if pool_texture.texture_rd_rid.is_valid():
			pool_texture.texture_rd_rid = RID()
		var multimeshes := _all_multimeshes.duplicate()
		var rids: Array[RID] = []
		for scratch in _scratch:
			rids.append_array(scratch.rids())
		rids.append_array([_pool, _draw_counts, _triangle_counts, _transition_cases, _tri_table, _pipeline, _shader])
		var rd := _rd
		MarchingCubesGpuIndirectMesher._on_render_thread(func() -> void:
			if rd == null:
				return
			for multimesh: RID in multimeshes:
				# Godot 4.7 never frees an indirect MultiMesh's command buffer (multimesh_free
				# drops the RID without freeing it), so free it here.
				var command := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
				if command.is_valid():
					rd.free_rid(command)
			for rid: RID in rids:
				if rid.is_valid():
					rd.free_rid(rid))
		for multimesh in multimeshes:
			RenderingServer.free_rid(multimesh)


	## One grid of a submission.
	class _Entry:
		extends RefCounted

		var grid: MesherGrid
		var target: MesherIndirectTarget
		var submission := 0
		var index := 0
		var end := Vector3i.ZERO
		var cells := Vector3i.ZERO
		var has_materials := false
		var scratch: _Scratch


	## Per-grid working buffers, sized for the largest grid seen in that batch position.
	class _Scratch:
		extends RefCounted

		var values := RID()
		var materials := RID()
		var vertices := RID()
		var transition_data := RID()
		var uniform_set := RID()
		var capacity := 0
		var side_capacity := 0

		## shared: tri_table, triangle_counts, draw_counts, pool, transition_cases.
		func allocate(rd: RenderingDevice, samples: int, side: int, shader: RID, shared: Array) -> void:
			for rid in rids():
				if rid.is_valid():
					rd.free_rid(rid)
			capacity = samples
			side_capacity = side
			transition_data = rd.storage_buffer_create(MesherTransition.gpu_data_capacity(side))
			values = rd.storage_buffer_create(samples * 4)
			materials = rd.storage_buffer_create(ceili(samples / 4.0) * 4)
			vertices = rd.storage_buffer_create(samples * 3 * 16)
			var uniforms: Array[RDUniform] = []
			var bound: Array[RID] = [values, materials, shared[0], vertices, shared[1], shared[2]]
			for binding in bound.size():
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u.binding = binding
				u.add_id(bound[binding])
				uniforms.append(u)
			var image := RDUniform.new()
			image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			image.binding = 6
			image.add_id(shared[3])
			uniforms.append(image)
			for binding in [7, 8]:
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u.binding = binding
				u.add_id(shared[4] if binding == 7 else transition_data)
				uniforms.append(u)
			uniform_set = rd.uniform_set_create(uniforms, shader, 0)

		## Uniform set first: freeing a buffer it uses would free it implicitly.
		func rids() -> Array[RID]:
			return [uniform_set, values, materials, vertices, transition_data]
