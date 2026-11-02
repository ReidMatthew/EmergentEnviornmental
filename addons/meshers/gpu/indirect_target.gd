@tool
class_name MesherIndirectTarget
extends RefCounted
## Where [MarchingCubesGpuIndirectMesher] puts one chunk's triangles: a slot in its
## triangle pool and an indirect MultiMesh that draws exactly that slot. Get one with
## [method MarchingCubesGpuIndirectMesher.acquire_target] and give it back with
## [method MarchingCubesGpuIndirectMesher.release_target].
##
## To draw it: a RenderingServer instance with [member multimesh] as its base, a material
## that uses pull.gdshaderinc (with ms_triangle_pool set to the mesher's pool texture),
## and the instance shader parameter [code]ms_vertex_base[/code] set to [member vertex_base].

## Indirect MultiMesh whose draw count the GPU sets after every mesh.
var multimesh := RID()
## First pool vertex of this target's slot.
var vertex_base := 0
## Slot size in triangles. Anything beyond is cut off and reported as an overflow.
var capacity := 0
## Triangles the most recent mesh produced, read back asynchronously a frame or two after
## it is drawn. -1 until known. Larger than [member capacity] means it was cut off.
var triangle_count := -1
## Free for the caller, for example the chunk key. Overflow reports hand it back.
var user_data: Variant

# Bumped per mesh, so a late readback for an older mesh is ignored.
var _submission := 0
var _slot := -1
# The pool state this target belongs to, while acquired. Keeps that state (and so this
# target's MultiMesh) alive while a chunk still draws it, even if the mesher is gone.
var _owner: RefCounted
# RenderingDevice handle of the MultiMesh's command buffer, looked up on the render thread.
var _command_buffer := RID()
