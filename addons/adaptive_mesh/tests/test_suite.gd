extends RefCounted
## Base for the test groups: _check() and the helpers several groups share. Groups run inside
## the runner's SceneTree; [member root] and [member process_frame] forward to it so tests
## read like SceneTree scripts.

var tree: SceneTree
var failures := 0

var root: Window:
	get:
		return tree.root
var process_frame: Signal:
	get:
		return tree.process_frame


## Runs the group's tests.
func run() -> void:
	pass


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FAIL ", message)


# A 4 x 4 x 4 box centred on the origin, each face split into 4 x 4 quads (192 triangles).
func _box_mesh() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(4, 4, 4)
	box.subdivide_width = 3
	box.subdivide_height = 3
	box.subdivide_depth = 3
	return box


func _sphere(radius: float, subdivisions: int = 2) -> SolidSphere:
	var sphere := SolidSphere.new()
	sphere.radius = radius
	sphere.subdivisions = subdivisions
	return sphere


# Triangles of [param solid] (only those tagged [param tag] unless it is -1) as position
# triples rotated to start at the smallest corner, so equal keys mean the same winding.
func _triangle_keys(solid: Solid, tag: int = -1) -> Dictionary:
	var keys := {}
	for t in solid.get_triangle_count():
		if tag >= 0 and solid.tags[t] != tag:
			continue
		keys[_triangle_key(solid.positions[solid.indices[t * 3]], solid.positions[solid.indices[t * 3 + 1]],
				solid.positions[solid.indices[t * 3 + 2]])] = true
	return keys


func _triangle_key(a: Vector3, b: Vector3, c: Vector3) -> Array:
	var p: Array[Vector3] = [a, b, c]
	var first := 0
	for i in range(1, 3):
		if p[i] < p[first]:
			first = i
	return [p[first], p[(first + 1) % 3], p[(first + 2) % 3]]


func _count_tag(solid: Solid, tag: int) -> int:
	var n := 0
	for t in solid.tags:
		if t == tag:
			n += 1
	return n


# An AdaptiveMesh (one piece) made from [param mesh], not yet in the tree.
func _adaptive(mesh: Mesh, with_collision: bool = true) -> AdaptiveMesh:
	var node := AdaptiveMesh.new()
	node.source = MeshSource.new()
	(node.source as MeshSource).mesh = mesh
	if not with_collision:
		node.collision = PieceCollision.new()
		node.collision.enabled = false
	return node


# The solid of a one-piece AdaptiveMesh.
func _only_solid(node: AdaptiveMesh) -> Solid:
	var piece: AdaptivePiece = node.get_pieces().get(Vector4i.ZERO)
	return piece.solid if piece != null else Solid.new()


# Waits until [param node] has baked and finished its edits.
func _settle(node: AdaptiveMesh) -> void:
	await process_frame
	var frames := 0
	while not node.is_idle() and frames < 1200:
		await process_frame
		frames += 1
