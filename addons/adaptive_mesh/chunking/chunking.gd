@tool
@abstract
class_name Chunking
extends Resource
## How an [AdaptiveMesh] is cut into pieces, so an edit only works on the pieces it
## touches. Cells are addressed by integers ([Vector3i]); [AdaptiveMeshData] adds a depth
## for cells split later. Leave the mesh's chunking empty for one piece (props, rocks); use
## [GridChunking] for anything big.

## Tag of the faces that close a piece off where it meets a neighbour. They're hidden; pick
## a tag no surface or shape uses.
@export var cap_tag := 1000
## A piece with more triangles than this is split in half along every axis this
## chunking cuts, once its edits are done: booleans cost about as much as the whole piece,
## so this keeps edits fast where many have piled up. 0 never splits.
@export_range(0, 100000, 1, "or_greater") var split_above := 2000
## How many times a cell may be split (each halves it along the cut axes).
@export_range(0, 8) var max_split_depth := 3


## The box of cell [param key]. [param extent] is how far cells reach along axes that
## aren't cut.
@abstract func get_cell(key: Vector3i, extent: AABB) -> AABB


## Cells overlapping [param box].
@abstract func keys_overlapping(box: AABB) -> Array[Vector3i]


## The cells next to [param key] (sharing a side, edge or corner).
@abstract func neighbour_keys(key: Vector3i) -> Array[Vector3i]


## True if cells are cut along [param axis] (0-2): neighbouring pieces then meet at walls
## across it, whose faces are hidden.
@abstract func cuts_axis(axis: int) -> bool


## Cuts [param source] into one solid per cell, by cell, with [member cap_tag] on the faces
## that close each piece off. Empty pieces are left out. [param extent] as in
## [method get_cell]. A coroutine (the backend may need frames).
@abstract func split(source: Solid, extent: AABB, backend: BooleanBackend) -> Dictionary
