extends "test_suite.gd"
## Quick micro-benchmarks (printed, not checked).


func run(has_gpu: bool) -> void:
	_benchmark(MarchingCubesGpuMesher.new() if has_gpu else null)


func _benchmark(gpu: MarchingCubesGpuMesher) -> void:
	print("benchmark (32^3 noise chunk, average of 10)")
	var grid := _noise_grid()
	var meshers: Array[Mesher] = [MarchingCubesCpuMesher.new(), DualContouringCpuMesher.new()]
	if gpu != null:
		meshers.append(gpu)
		gpu.polygonize(grid)  # warm up: buffer allocation
	for mesher in meshers:
		var start := Time.get_ticks_usec()
		var mesh: MeshData
		for i in 10:
			mesh = mesher.polygonize(grid)
		print("  %s: %.2f ms, %d triangles" % [mesher.get_script().get_global_name(),
				(Time.get_ticks_usec() - start) / 10000.0, mesh.get_triangle_count()])
