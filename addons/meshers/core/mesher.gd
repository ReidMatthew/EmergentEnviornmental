@tool
@abstract
class_name Mesher
extends Resource
## Turns a [MesherGrid] into triangles. Subclass this to add a backend (GDScript, compute
## shader, GDExtension); anything that holds an Mesher can use any of them.


## Polygonises [param grid]. Called from worker threads when [method is_thread_safe] is true,
## so implementations must not touch the scene tree or mutate shared state.
@abstract func polygonize(grid: MesherGrid) -> MeshData


## Polygonises several grids, results in the same order. Override when meshing grids
## together is cheaper than one at a time (for example, one GPU submission for all of them).
func polygonize_batch(grids: Array[MesherGrid]) -> Array[MeshData]:
	var results: Array[MeshData] = []
	for grid in grids:
		results.append(polygonize(grid))
	return results


## How many grids callers should pass to [method polygonize_batch] at once. 1 means one at
## a time, which lets a caller spread grids across threads instead.
func get_batch_size() -> int:
	return 1


## Called on the main thread when the mesher starts being used, before any meshing.
## Start slow setup here (GPU devices, pipelines) so it doesn't happen mid-stream.
func warm_up() -> void:
	pass


## True when this mesher's triangles stay on the GPU instead of coming back as
## [MeshData] (see [MarchingCubesGpuIndirectMesher]). Callers then draw them through targets
## and get CPU meshes, when they need them, from another mesher.
func is_gpu_resident() -> bool:
	return false


## Return false if this mesher has to run on the main thread.
func is_thread_safe() -> bool:
	return true
