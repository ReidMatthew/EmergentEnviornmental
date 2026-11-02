@tool
class_name MeshData
extends RefCounted
## Indexed triangle mesh produced by a mesher. Plain arrays, so it can be built on a worker
## thread and turned into an ArrayMesh or collision shape on the main thread.

var vertices := PackedVector3Array()
var normals := PackedVector3Array()
## Material id per vertex in the red channel ([code]id / 255[/code]).
var colors := PackedColorArray()
var indices := PackedInt32Array()


func is_empty() -> bool:
	return indices.is_empty()


func get_triangle_count() -> int:
	return indices.size() / 3


func get_surface_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	if colors.size() == vertices.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Writes this data into [param mesh] (reused when given) and returns it. Returns an empty
## mesh when there are no triangles.
func to_array_mesh(mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	if not is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, get_surface_arrays())
	return mesh


## Unindexed triangle soup, the format ConcavePolygonShape3D wants.
func get_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = vertices[indices[i]]
	return faces
