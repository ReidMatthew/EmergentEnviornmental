@tool
class_name SolidSphere
extends SolidShape
## A sphere made from a subdivided icosahedron, so its triangles are all about the same
## size. Each subdivision has 4 times the triangles: 0 = 20, 1 = 80, 2 = 320, 3 = 1280,
## 4 = 5120.

## Average edge length of a unit sphere at each subdivision level (measured).
const _UNIT_EDGE: Array[float] = [1.0515, 0.5823, 0.2983, 0.1501, 0.0752]

@export_range(0.01, 100.0, 0.01, "or_greater") var radius := 1.0:
	set(value):
		radius = value
		emit_changed()
## Used when [member edge_length] is 0.
@export_range(0, 4) var subdivisions := 2:
	set(value):
		subdivisions = value
		emit_changed()
## Optional. Above 0, the sphere picks the subdivision level whose edges come closest to
## this length (in its own units), instead of using [member subdivisions]. Craters then
## stay about as dense as each other (and as the mesh around them, if you match its edge
## length) whatever the radius. 0 turns it off.
@export_range(0.0, 10.0, 0.01, "or_greater") var edge_length := 0.0:
	set(value):
		edge_length = value
		emit_changed()


## The subdivision level in use: [member subdivisions], or the one [member edge_length]
## picks.
func get_subdivisions() -> int:
	if edge_length <= 0.0:
		return subdivisions
	var best := 0
	for level in _UNIT_EDGE.size():
		# Compare in log space, so 2x too long and 2x too short count the same.
		if absf(log(_UNIT_EDGE[level] * radius / edge_length)) < absf(log(_UNIT_EDGE[best] * radius / edge_length)):
			best = level
	return best


## Average edge length of the sphere as built, for matching other geometry to it (such as
## [member BrushStroke.band_edge_length]).
func get_edge_length() -> float:
	return _UNIT_EDGE[get_subdivisions()] * radius


func _build_solid() -> Solid:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var points: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	# Counter-clockwise from outside; flipped to Godot's clockwise at the end.
	var faces := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	for i in get_subdivisions():
		var midpoints := {}
		var next := PackedInt32Array()
		for f in range(0, faces.size(), 3):
			var a := faces[f]
			var b := faces[f + 1]
			var c := faces[f + 2]
			var ab := _midpoint(points, midpoints, a, b)
			var bc := _midpoint(points, midpoints, b, c)
			var ca := _midpoint(points, midpoints, c, a)
			next.append_array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
		faces = next
	var solid := Solid.new()
	for p in points:
		solid.positions.append(p.normalized() * radius)
	for f in range(0, faces.size(), 3):
		solid.indices.append_array([faces[f], faces[f + 2], faces[f + 1]])
		solid.tags.append(0)
	return solid


static func _midpoint(points: Array[Vector3], cache: Dictionary, a: int, b: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if cache.has(key):
		return cache[key]
	points.append((points[a] + points[b]) * 0.5)
	cache[key] = points.size() - 1
	return points.size() - 1
