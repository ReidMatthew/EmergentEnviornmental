@tool
class_name MarchingCubesGpuMesher
extends Mesher
## Marching cubes in a compute shader, read back into a [MeshData]. Produces the same
## mesh as [MarchingCubesCpuMesher] (vertex order differs), so the two are interchangeable and
## collision still works.
##
## Needs the Forward+ or Mobile renderer. Without a RenderingDevice (Compatibility, or
## --headless) it falls back to [MarchingCubesCpuMesher] and warns once.
##
## Runs on its own [GpuThread], which merges concurrent requests into batches of up to
## [member max_batch]. Reading a buffer back stalls until the GPU is idle, and while the
## game is rendering each stall costs several milliseconds. So a batch reads back exactly
## twice, whatever its size: once for every grid's vertex and index counts (shared
## counters buffer), then once for all the triangles, after the GPU has copied them into
## one contiguous buffer.

## Most grids meshed in one GPU submission. Each slot keeps its own buffers (about 7 MB
## for a padded 32^3 chunk), so this also caps GPU memory use.
@export_range(1, 64) var max_batch := 16:
	set(value):
		max_batch = value
		_mutex.lock()
		if _gpu != null:
			_gpu.max_batch = value
		_mutex.unlock()

var _mutex := Mutex.new()
var _gpu: GpuThread
var _fallback := MarchingCubesCpuMesher.new()


func polygonize(grid: MesherGrid) -> MeshData:
	return polygonize_batch([grid])[0]


## Runs on worker threads. The first call may wait for the GPU thread to finish starting.
func polygonize_batch(grids: Array[MesherGrid]) -> Array[MeshData]:
	if not _start().wait_until_ready():
		_warn_unavailable()
		return _fallback.polygonize_batch(grids)
	var results: Array[MeshData] = []
	results.assign(_gpu.run(grids))
	# Skirts are added here, on the calling worker, rather than in the shader.
	for i in grids.size():
		MesherSkirts.add(results[i], grids[i])
	return results


## Starts the GPU thread in the background.
func warm_up() -> void:
	_start()


## The terrain hands this many chunks to each call, so each GPU batch is full. Never
## blocks: it starts the GPU thread in the background on first use.
func get_batch_size() -> int:
	var gpu := _start()
	return 1 if gpu.is_ready() and not gpu.available else max_batch


## False when there is no RenderingDevice and the CPU fallback is used. Waits for the GPU
## thread to finish starting (about 60 ms the first time), so avoid calling it every frame
## on the main thread.
func is_gpu_available() -> bool:
	var available := _start().wait_until_ready()
	if not available:
		_warn_unavailable()
	return available


# Starts the GPU thread if it isn't running. Returns immediately.
func _start() -> GpuThread:
	_mutex.lock()
	if _gpu == null:
		_gpu = GpuThread.new(_Kernel.new(), mini(max_batch, _Kernel.MAX_BATCH))
	var gpu := _gpu
	_mutex.unlock()
	return gpu


var _warned := false


func _warn_unavailable() -> void:
	if not _warned:
		_warned = true
		push_warning("MarchingCubesGpuMesher: no RenderingDevice (Compatibility renderer or "
				+ "headless); using the CPU mesher.")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _gpu != null:
		_gpu.stop()


## GPU side, run by the GpuThread. Never references the mesher.
class _Kernel:
	extends RefCounted

	const MAX_BATCH := 64
	const _SHADER := preload("./polygonize.glsl")
	const _GROUP := 4

	enum _Binding {
		VALUES, MATERIALS, TRI_TABLE, EDGE_VERTEX, POSITIONS, NORMALS, COLORS, INDICES, COUNTERS,
		TRANSITION_CASES, TRANSITION_DATA,
	}

	var _rd: RenderingDevice
	var _shader := RID()
	var _pipeline := RID()
	var _tri_table := RID()
	var _transition_cases := RID()
	var _counters := RID()
	var _readback := RID()
	var _readback_size := 0
	var _slots: Array[_Slot] = []


	func setup(rd: RenderingDevice) -> void:
		_rd = rd
		_shader = rd.shader_create_from_spirv(_SHADER.get_spirv())
		_pipeline = rd.compute_pipeline_create(_shader)
		var table := MarchingCubesTables.tri_table.to_byte_array()
		_tri_table = rd.storage_buffer_create(table.size(), table)
		var cases := TransvoxelTables.cases.to_byte_array()
		_transition_cases = rd.storage_buffer_create(cases.size(), cases)
		_counters = rd.storage_buffer_create(MAX_BATCH * 8)


	func teardown(rd: RenderingDevice) -> void:
		for slot in _slots:
			slot.release(rd)
		if _readback.is_valid():
			rd.free_rid(_readback)
		for rid in [_counters, _transition_cases, _tri_table, _pipeline, _shader]:
			rd.free_rid(rid)


	func process(rd: RenderingDevice, grids: Array) -> Array:
		_rd = rd
		while _slots.size() < grids.size():
			_slots.append(_Slot.new())
		var results := []
		var jobs: Array[_Dispatch] = []
		for grid: MesherGrid in grids:
			var job := _Dispatch.new()
			job.grid = grid
			job.result = MeshData.new()
			results.append(job.result)
			job.samples = grid.size.x * grid.size.y * grid.size.z
			job.end = grid.get_cell_end()
			job.cells = job.end - grid.cell_begin
			if job.samples == 0 or job.cells.x <= 0 or job.cells.y <= 0 or job.cells.z <= 0:
				continue
			job.index = jobs.size()
			job.slot = _slots[job.index]
			job.has_materials = grid.materials.size() == job.samples
			_upload(job)
			jobs.append(job)
		if jobs.is_empty():
			return results
		_rd.buffer_clear(_counters, 0, jobs.size() * 8)

		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		for pass_index in 3:
			if pass_index == 1:
				_rd.compute_list_add_barrier(list)
			for job in jobs:
				if pass_index == 2 and job.grid.transitions.is_empty():
					continue
				var params := _params(job, pass_index)
				_rd.compute_list_bind_uniform_set(list, job.slot.uniform_set, 0)
				_rd.compute_list_set_push_constant(list, params, params.size())
				if pass_index == 2:
					# Transition cells: (cells along u, cells along v) per face.
					var most := maxi(job.cells.x, maxi(job.cells.y, job.cells.z))
					_rd.compute_list_dispatch(list, _groups(most), _groups(most), _groups(6))
				else:
					var size := job.cells + (Vector3i.ONE if pass_index == 0 else Vector3i.ZERO)
					_rd.compute_list_dispatch(list, _groups(size.x), _groups(size.y), _groups(size.z))
		_rd.compute_list_end()

		# Stall 1: counts. Reading flushes the recorded work and waits for it.
		var counts := _rd.buffer_get_data(_counters, 0, jobs.size() * 8).to_int32_array()
		var total := 0
		for job in jobs:
			job.vertex_count = counts[job.index * 2]
			job.index_count = counts[job.index * 2 + 1]
			if job.index_count == 0:
				continue
			job.offset = total
			total += job.vertex_count * (12 + 12 + 16) + job.index_count * 4
		if total == 0:
			return results

		# Stall 2: everything else, copied on the GPU into one contiguous buffer first.
		if total > _readback_size:
			if _readback.is_valid():
				_rd.free_rid(_readback)
			_readback_size = total
			_readback = _rd.storage_buffer_create(total)
		for job in jobs:
			if job.index_count == 0:
				continue
			var at := job.offset
			var buffers := job.slot.buffers
			var nv := job.vertex_count
			_rd.buffer_copy(buffers[_Binding.POSITIONS], _readback, 0, at, nv * 12)
			_rd.buffer_copy(buffers[_Binding.NORMALS], _readback, 0, at + nv * 12, nv * 12)
			_rd.buffer_copy(buffers[_Binding.COLORS], _readback, 0, at + nv * 24, nv * 16)
			_rd.buffer_copy(buffers[_Binding.INDICES], _readback, 0, at + nv * 40, job.index_count * 4)
		var data := _rd.buffer_get_data(_readback, 0, total)
		for job in jobs:
			if job.index_count == 0:
				continue
			var at := job.offset
			var nv := job.vertex_count
			var out := job.result
			out.vertices = data.slice(at, at + nv * 12).to_vector3_array()
			out.normals = data.slice(at + nv * 12, at + nv * 24).to_vector3_array()
			out.colors = data.slice(at + nv * 24, at + nv * 40).to_color_array()
			out.indices = data.slice(at + nv * 40, at + nv * 40 + job.index_count * 4).to_int32_array()
		return results


	func _upload(job: _Dispatch) -> void:
		var slot := job.slot
		var side := maxi(job.grid.size.x, maxi(job.grid.size.y, job.grid.size.z))
		if job.samples > slot.capacity or side > slot.side_capacity:
			slot.allocate(_rd, _shader, _tri_table, _transition_cases, _counters, job.samples, side)
		var values := job.grid.get_gpu_samples()
		_rd.buffer_update(slot.buffers[_Binding.VALUES], 0, values.size(), values)
		if job.has_materials:
			var materials := job.grid.materials.duplicate()
			materials.resize(ceili(job.samples / 4.0) * 4)
			_rd.buffer_update(slot.buffers[_Binding.MATERIALS], 0, materials.size(), materials)
		if not job.grid.transitions.is_empty():
			var data := MesherTransition.gpu_data(job.grid)
			_rd.buffer_update(slot.buffers[_Binding.TRANSITION_DATA], 0, data.size(), data)


	func _params(job: _Dispatch, pass_index: int) -> PackedByteArray:
		var grid := job.grid
		var b := grid.cell_begin
		var e := job.end
		var ints := PackedInt32Array([
			grid.size.x, grid.size.y, grid.size.z, 1 if job.has_materials else 0,
			b.x, b.y, b.z, pass_index,
			e.x, e.y, e.z, 1 if MarchingCubesTables.FLIP_WINDING else 0,
		])
		var floats := PackedFloat32Array([
			grid.origin.x, grid.origin.y, grid.origin.z, grid.spacing,
			grid.iso, 1.0 if grid.uses_bytes() else 0.0, grid.byte_center, grid.byte_scale,
		])
		var transition := grid.get_gpu_transition_params()
		var extra := PackedInt32Array([job.index, transition[0], transition[1], 0])
		return ints.to_byte_array() + floats.to_byte_array() + extra.to_byte_array()


	func _groups(count: int) -> int:
		return ceili(float(count) / _GROUP)


	## One batch entry: a grid, its result, and the slot it runs in.
	class _Dispatch:
		extends RefCounted

		var grid: MesherGrid
		var result: MeshData
		var slot: _Slot
		var samples := 0
		var end := Vector3i.ZERO
		var cells := Vector3i.ZERO
		var has_materials := false
		## Position in the batch: which counter pair the shader uses.
		var index := 0
		var vertex_count := 0
		var index_count := 0
		## Byte offset of this grid's output in the combined readback buffer.
		var offset := 0


	## Buffers for one grid in a batch (the shared tables and counters are bound, not owned),
	## sized for the largest grid it has seen. Worst cases:
	## a vertex on every grid edge (3 per sample) and 15 indices per cell (at most 15 per
	## sample).
	class _Slot:
		extends RefCounted

		var buffers: Dictionary[int, RID] = {}
		var uniform_set := RID()
		var capacity := 0
		var side_capacity := 0

		func allocate(rd: RenderingDevice, shader: RID, tri_table: RID, transition_cases: RID, counters: RID,
				samples: int, side: int) -> void:
			release(rd)
			capacity = samples
			side_capacity = side
			var max_vertices := samples * 3
			buffers[_Binding.VALUES] = rd.storage_buffer_create(samples * 4)
			buffers[_Binding.MATERIALS] = rd.storage_buffer_create(ceili(samples / 4.0) * 4)
			buffers[_Binding.EDGE_VERTEX] = rd.storage_buffer_create(samples * 3 * 4)
			buffers[_Binding.POSITIONS] = rd.storage_buffer_create(max_vertices * 12)
			buffers[_Binding.NORMALS] = rd.storage_buffer_create(max_vertices * 12)
			buffers[_Binding.COLORS] = rd.storage_buffer_create(max_vertices * 16)
			buffers[_Binding.INDICES] = rd.storage_buffer_create(samples * 15 * 4)
			buffers[_Binding.TRANSITION_DATA] = rd.storage_buffer_create(MesherTransition.gpu_data_capacity(side))
			var uniforms: Array[RDUniform] = []
			for binding: int in _Binding.values():
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u.binding = binding
				match binding:
					_Binding.TRI_TABLE:
						u.add_id(tri_table)
					_Binding.COUNTERS:
						u.add_id(counters)
					_Binding.TRANSITION_CASES:
						u.add_id(transition_cases)
					_:
						u.add_id(buffers[binding])
				uniforms.append(u)
			uniform_set = rd.uniform_set_create(uniforms, shader, 0)

		func release(rd: RenderingDevice) -> void:
			if uniform_set.is_valid() and rd.uniform_set_is_valid(uniform_set):
				rd.free_rid(uniform_set)
			uniform_set = RID()
			for rid in buffers.values():
				rd.free_rid(rid)
			buffers.clear()
			capacity = 0
			side_capacity = 0
