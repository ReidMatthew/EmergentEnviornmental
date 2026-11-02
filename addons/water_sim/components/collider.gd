@tool
@icon("../icon.svg")
class_name WaterSimCollider
extends WaterSimComponent
## Makes a physics body block a [WaterSim]: add it as a child of a StaticBody3D,
## RigidBody3D, CharacterBody3D, AnimatableBody3D or Area3D, and the body's collision shapes
## push the matter out of the way. A moving body drags matter along with it, and one moving
## fast through [WaterSimStillWater] wakes it (with a [WaterSimWorld] in the scene).
##
## Box, sphere, capsule, cylinder, world boundary (plane), height map and concave
## (trimesh) shapes are used; convex ones are skipped (set [member mesh_instance] for those
## bodies). Concave shapes and meshes are baked once into a distance grid. One-way: the
## matter doesn't push the body (see [WaterSimBuoyancy]).

## How rough the body is: multiplies the friction of the substance sliding along it
## ([member WaterSimSubstance.friction]). 0 (the default): it slips freely; 1: as the substance says; below 1 slicker (an ice
## rink), above rougher.
@export_range(0.0, 4.0) var friction := 0.0
## Collide as this mesh (closed) instead of the body's collision shapes.
@export var mesh_instance: MeshInstance3D:
	set(value):
		mesh_instance = value
		refresh()

## Triangles to collide as, in [member mesh_instance]'s space, instead of its mesh (for
## meshes drawn some other way, such as an adaptive mesh's pieces). Call [method refresh]
## after changing them in place.
var faces_override := PackedVector3Array():
	set(value):
		faces_override = value
		refresh()

const GROUP := &"water_sim_colliders"

# Shapes' transforms this physics frame and last, for the speed of bodies that aren't
# rigid or character bodies.
var _now: Dictionary[Node3D, Transform3D] = {}
var _before: Dictionary[Node3D, Transform3D] = {}
var _frame := -1
# The mesh's distance grid, and what it was baked for.
var _mesh_sdf := {}


func _enter_tree() -> void:
	super()
	add_to_group(GROUP)


func _attach(on: WaterSim) -> void:
	on._register_collider(self)


func _detach(from: WaterSim) -> void:
	from._unregister_collider(self)


func _get_configuration_warnings() -> PackedStringArray:
	if not get_parent() is CollisionObject3D:
		return ["Add this as a child of a physics body (or Area3D); its collision shapes are used."]
	return []


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var on := get_sim()
	# Splashing into still water where no box is awake starts one.
	if (on == null or on.asleep) and get_speed() > (on.wake_speed if on != null else 1.0):
		var world := WaterSimWorld.find(get_tree())
		if world != null and on == null and WaterSim.sample_density_at(get_tree(), global_position + Vector3.DOWN * 0.3) > 0.0:
			world.ensure_box(global_position)


## The body this works for.
func get_body() -> CollisionObject3D:
	return get_parent() as CollisionObject3D


## How fast the body moves (m/s).
func get_speed() -> float:
	var body := get_body()
	if body is RigidBody3D:
		return body.linear_velocity.length()
	if body is CharacterBody3D:
		return body.velocity.length()
	if body != null and _before.has(body):
		return (body.global_position - _before[body].origin).length() / maxf(get_physics_process_delta_time(), 1e-4)
	return 0.0


## Forgets the baked mesh shape, so it's baked again (after the mesh changed).
func refresh() -> void:
	_mesh_sdf = {}


## The solver dictionaries for the body's shapes (see [method WaterSimSolver.set_colliders]).
func get_solver_shapes(on: WaterSim) -> Array:
	var body := get_body()
	var list := []
	if body == null:
		return list
	var frame := Engine.get_physics_frames()
	if frame != _frame:
		_frame = frame
		_before = _now
		_now = {}
		_now[body] = body.global_transform
	var parts: Array[Node3D] = []
	if mesh_instance != null:
		parts.append(mesh_instance)
	else:
		for child in body.get_children():
			var node := child as CollisionShape3D
			if node != null and not node.disabled and node.shape != null:
				parts.append(node)
	var to_solver := on.get_solver_transform().affine_inverse()
	var solver_basis := on.get_solver_transform().basis.inverse()
	for node in parts:
		var transform := node.global_transform
		var scale := transform.basis.get_scale()
		var entry := _describe_mesh(on, scale) if node == mesh_instance else _describe(on, (node as CollisionShape3D).shape, scale)
		if entry.is_empty():
			continue
		var placed := Transform3D(transform.basis.orthonormalized(), transform.origin)
		if entry.has("local"):
			placed = placed * (entry.local as Transform3D)
			entry.erase("local")
		entry.transform = to_solver * placed
		entry.friction = friction
		var linear := Vector3.ZERO
		var angular := Vector3.ZERO
		if body is RigidBody3D:
			linear = body.linear_velocity + body.angular_velocity.cross(transform.origin - body.global_position)
			angular = body.angular_velocity
		elif body is CharacterBody3D:
			linear = body.velocity
		elif _before.has(node):
			var delta := get_physics_process_delta_time()
			var before: Transform3D = _before[node]
			linear = (transform.origin - before.origin) / delta
			var turn := (transform.basis.orthonormalized() * before.basis.orthonormalized().inverse()).get_rotation_quaternion()
			angular = turn.get_axis() * turn.get_angle() / delta if turn.get_angle() > 1e-5 else Vector3.ZERO
		_now[node] = transform
		entry.linear_velocity = solver_basis * linear
		entry.angular_velocity = solver_basis * angular
		list.append(entry)
	return list


func _describe(on: WaterSim, shape: Shape3D, scale: Vector3) -> Dictionary:
	if shape is BoxShape3D:
		return { "shape": 0, "extents": shape.size * scale * 0.5 }
	if shape is SphereShape3D:
		return { "shape": 1, "extents": Vector3.ONE * shape.radius * scale.x }
	if shape is CapsuleShape3D:
		var r: float = shape.radius * scale.x
		return { "shape": 2, "extents": Vector3(r, maxf(shape.height * scale.y * 0.5 - r, 0.0), r) }
	if shape is CylinderShape3D:
		return { "shape": 3, "extents": Vector3(shape.radius * scale.x, shape.height * scale.y * 0.5, 0) }
	if shape is WorldBoundaryShape3D:
		var plane: Plane = shape.plane
		var basis := Basis(Quaternion(Vector3.UP, plane.normal.normalized()))
		return { "shape": 4, "local": Transform3D(basis, plane.normal * plane.d) }
	if shape is HeightMapShape3D:
		var heights: PackedFloat32Array = shape.map_data
		if not is_equal_approx(scale.y, 1.0):
			heights = heights.duplicate()
			for i in heights.size():
				heights[i] *= scale.y
		return { "shape": 5, "heights": heights, "heights_width": shape.map_width,
				"heights_depth": shape.map_depth, "heights_spacing": scale.x }
	if shape is ConcavePolygonShape3D:
		# Baked once per shape and scale, and kept on the shape for every collider using it.
		var key := "water_sim_sdf_%s_%s" % [scale, on.cell_size]
		if not shape.has_meta(key):
			shape.set_meta(key, _bake(on, shape.get_faces(), scale))
		return (shape.get_meta(key) as Dictionary).duplicate()
	return {}


func _describe_mesh(on: WaterSim, scale: Vector3) -> Dictionary:
	var key := [scale, on.cell_size]
	if _mesh_sdf.get("key") != key:
		var faces := faces_override
		if faces.is_empty() and mesh_instance.mesh != null:
			faces = mesh_instance.mesh.get_faces()
		_mesh_sdf = { "key": key, "entry": _bake(on, faces, scale) }
	return (_mesh_sdf.entry as Dictionary).duplicate()


func _bake(on: WaterSim, faces: PackedVector3Array, scale: Vector3) -> Dictionary:
	if faces.is_empty():
		return {}
	var scaled := faces
	if not scale.is_equal_approx(Vector3.ONE):
		scaled = faces.duplicate()
		for i in scaled.size():
			scaled[i] *= scale
	var entry := on.get_solver().bake_sdf(scaled, on.cell_size * 0.5, 48)
	entry.shape = 6
	return entry
