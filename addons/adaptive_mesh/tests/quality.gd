extends "test_suite.gd"
## Triangle quality of a dig stroke, the same drag done several ways (printed, not
## checked): a slow drag then a fast one across the demo hill, with a radius 1.5 sphere.
##
## - tiny: area under 0.005 square units (about a 0.1 x 0.1 right triangle)
## - slivers: smallest angle under 10 degrees
## - removed: volume dug out, to show every variant digs about the same trench

const RADIUS := 1.5
const FPS := 60.0


func run() -> void:
	var source: Mesh = load(get_script().resource_path.get_base_dir().path_join("../demo/models/hill.res"))
	var path := await _drag_path(source)
	print("stroke: %d frames, %.1f units long" % [path.size(), _length(path)])
	print("  %-44s %6s %6s %7s %6s %8s %8s %6s" % ["variant", "edits", "tris", "new", "tiny", "slivers", "removed", "ms"])
	var before := _sphere(RADIUS, 2)
	await _variant("before: stamp every 0.12 s", source, path, func(mesh: AdaptiveMesh) -> int:
		return await _stamp_by_time(mesh, path, before))
	for spacing in [0.75, 1.5]:
		await _variant("stamps spaced %.2f" % spacing, source, path, func(mesh: AdaptiveMesh) -> int:
			return await _stroke(mesh, path, _sphere(RADIUS, 2), false, 0.0, spacing))
		await _variant("swept, spaced %.2f" % spacing, source, path, func(mesh: AdaptiveMesh) -> int:
			return await _stroke(mesh, path, _sphere(RADIUS, 2), true, 0.3, spacing))
	var coarse := _sphere(RADIUS, 2)
	coarse.edge_length = 0.8
	await _variant("stamps 0.12 s + edge_length 0.8", source, path, func(mesh: AdaptiveMesh) -> int:
		return await _stamp_by_time(mesh, path, coarse))
	await _variant("swept 1.50 + edge_length 0.8", source, path, func(mesh: AdaptiveMesh) -> int:
		return await _stroke(mesh, path, coarse, true, 0.8, 1.5))
	# Cleanup after every edit: min edge a third of the brush's, 0.03 units of error.
	for rings in [0, 1]:
		var cleanup := MeshCleanup.new()
		cleanup.min_edge_length = 0.25
		cleanup.max_error = 0.03
		cleanup.unlock_rings = rings
		await _variant("before + cleanup (rings %d)" % rings, source, path, func(mesh: AdaptiveMesh) -> int:
			return await _stamp_by_time(mesh, path, before), cleanup)
		await _variant("swept 1.50 + edge 0.8 + cleanup (rings %d)" % rings, source, path, func(mesh: AdaptiveMesh) -> int:
			return await _stroke(mesh, path, coarse, true, 0.8, 1.5), cleanup)


func _variant(label: String, source: Mesh, path: PackedVector3Array, drive: Callable,
		cleanup: MeshCleanup = null) -> void:
	var mesh := _adaptive(source, false)
	mesh.cleanup = cleanup
	root.add_child(mesh)
	await _settle(mesh)
	var source_triangles := _only_solid(mesh).get_triangle_count()
	var source_volume := _volume(_only_solid(mesh))
	var start := Time.get_ticks_usec()
	var edits: int = await drive.call(mesh)
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	var solid := _only_solid(mesh)
	var tiny := 0
	var slivers := 0
	for t in solid.get_triangle_count():
		var a := solid.positions[solid.indices[t * 3]]
		var b := solid.positions[solid.indices[t * 3 + 1]]
		var c := solid.positions[solid.indices[t * 3 + 2]]
		if (b - a).cross(c - a).length() * 0.5 < 0.005:
			tiny += 1
		if _smallest_angle(a, b, c) < deg_to_rad(10.0):
			slivers += 1
	print("  %-44s %6d %6d %7d %6d %8d %8.1f %6.0f" % [label, edits, solid.get_triangle_count(),
			solid.get_triangle_count() - source_triangles, tiny, slivers, source_volume - _volume(solid), ms])
	_check(solid.count_open_edges() == 0, "%s: closed" % label)
	mesh.queue_free()
	await process_frame


# The old demo: a stamp every 0.12 s of drag, wherever the mouse is.
func _stamp_by_time(mesh: AdaptiveMesh, path: PackedVector3Array, shape: SolidShape) -> int:
	var every := roundi(0.12 * FPS)
	var edits := 0
	for i in range(0, path.size(), every):
		mesh.edit(shape, Transform3D(Basis(), path[i]), BooleanOp.Operation.SUBTRACT)
		edits += 1
		await _wait_idle(mesh)
	return edits


func _stroke(mesh: AdaptiveMesh, path: PackedVector3Array, shape: SolidShape, sweep: bool, band: float,
		spacing: float) -> int:
	var stroke := BrushStroke.new()
	stroke.shape = shape
	stroke.spacing = spacing
	stroke.sweep = sweep
	stroke.band_edge_length = band
	stroke.begin(mesh, path[0])
	var edits := 1
	await _wait_idle(mesh)
	for i in range(1, path.size()):
		if stroke.update(path[i]):
			edits += 1
			await _wait_idle(mesh)
	if not mesh.is_idle():
		await _wait_idle(mesh)
	var before_end := _only_solid(mesh).get_triangle_count()
	stroke.end()
	await _wait_idle(mesh)
	if _only_solid(mesh).get_triangle_count() != before_end:
		edits += 1
	return edits


# Points on the hill's surface along an S-curve, one per frame: 2 s at 3 units/s, then
# 1.2 s at 10 units/s.
func _drag_path(source: Mesh) -> PackedVector3Array:
	var probe := _adaptive(source)
	root.add_child(probe)
	await _settle(probe)
	await tree.physics_frame
	await tree.physics_frame
	var space := probe.get_world_3d().direct_space_state
	var path := PackedVector3Array()
	var distance := 0.0
	var frames := roundi(3.2 * FPS)
	for f in frames:
		var speed := 3.0 if f < 2.0 * FPS else 10.0
		var x := -9.0 + distance
		var z := 3.0 * sin(x * 0.35)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 30, z), Vector3(x, -30, z)))
		if not hit.is_empty():
			path.append(hit.position)
		distance += speed / FPS
	probe.queue_free()
	return path


func _wait_idle(mesh: AdaptiveMesh) -> void:
	while not mesh.is_idle():
		await process_frame


func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func _volume(solid: Solid) -> float:
	var v := 0.0
	for t in solid.get_triangle_count():
		var a := solid.positions[solid.indices[t * 3]]
		v += a.dot(solid.positions[solid.indices[t * 3 + 2]].cross(solid.positions[solid.indices[t * 3 + 1]])) / 6.0
	return v


func _smallest_angle(a: Vector3, b: Vector3, c: Vector3) -> float:
	var smallest := PI
	var corners := [[a, b, c], [b, c, a], [c, a, b]]
	for corner: Array in corners:
		var u: Vector3 = corner[1] - corner[0]
		var w: Vector3 = corner[2] - corner[0]
		if u.length_squared() == 0.0 or w.length_squared() == 0.0:
			return 0.0
		smallest = minf(smallest, u.angle_to(w))
	return smallest
