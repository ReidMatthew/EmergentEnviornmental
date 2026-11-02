extends Node
## Demo tool: dig into whatever adaptive mesh is under the mouse with the left button, build
## with Shift held, hold still to go deeper or higher, Ctrl + wheel for the brush size. This
## is the part to copy into a game and adapt: it turns mouse rays into a [BrushStroke],
## finding what it hit with [method AdaptiveMesh.find] (anything else is left alone).
##
## X cycles the modes (see [member mode]). Cutting: drag a line across a mesh (starting
## beside it is fine) and let go, and the first adaptive mesh the drag passed over is cut
## along that line, away from the camera, [member cut_depth] of the way through (Ctrl +
## wheel), with [method AdaptiveMesh.cut]. All the way through divides it. Dismantling:
## click a mesh and it's cut into cubes [member cube_size] across (Ctrl + wheel) with
## [method AdaptiveMesh.dismantle].
##
## Strokes follow the surface as it was when they began: at the start of each stroke the
## pieces' collision shapes are put on [member snapshot_layer] (see
## [method AdaptiveMesh.get_collision_shapes]) and rays hit those, so a dig doesn't dive
## into the trench it is making.

## Emitted when the tool queues an edit on [member target].
signal edit_queued

## Only edit this mesh. Empty: whichever adaptive mesh the ray hits.
@export var mesh: AdaptiveMesh
## The brush. A sphere's radius changes with Ctrl + wheel.
@export var brush: SolidShape = SolidSphere.new()
## Physics layers the first ray of a stroke hits (the pieces' collision layer).
@export_flags_3d_physics var surface_layers := 1
## A physics layer of its own for the stroke's snapshot of the surface.
@export_flags_3d_physics var snapshot_layer := 2
## How far the brush moves between edits, as a fraction of its size.
@export_range(0.1, 4.0, 0.05) var spacing := 1.0
## Sweep the brush between edits (one smooth trench) instead of stamping it.
@export var sweep := true
## How fast (units per second) holding still digs in or builds out. 0 turns it off.
@export var hold_speed := 3.0
## Ctrl + wheel limits for a sphere brush's radius.
@export var min_radius := 0.3
@export var max_radius := 6.0
@export var ray_length := 500.0
## What the left button does; X cycles through them.
@export var mode := Mode.DIG
## How far cuts go into the mesh, as a fraction of its depth along the cut (its box's,
## from the front): 1 is all the way through. Ctrl + wheel changes it in cut mode.
@export_range(0.05, 1.0, 0.05) var cut_depth := 1.0
## Dismantle mode: how big the cubes are (world units). Ctrl + wheel changes it.
@export_range(0.01, 100.0, 0.01, "or_greater") var cube_size := 1.0
## Ctrl + wheel limits for [member cube_size].
@export var min_cube_size := 0.1
@export var max_cube_size := 20.0

enum Mode {
	## Dig (or build, with Shift) along a stroke.
	DIG,
	## Drag a line to cut along it.
	CUT,
	## Click a mesh to cut it into cubes.
	DISMANTLE,
}

var stroke := BrushStroke.new()
## The adaptive mesh the current (or last) stroke edits.
var target: AdaptiveMesh
var _snapshot: StaticBody3D
var _live := false  # this stroke rays the live surface (no snapshot to ray)
var _cutting := false  # a cut is being dragged
var _cut_start := Vector2.ZERO  # where it started on screen
var _cut_distance := -1.0  # how far from the camera the line is (the first mesh the drag met)
var _cut_line: MeshInstance3D  # shows the cut while it's dragged
var _pressed := false  # dismantle mode: the button was down last frame


func _ready() -> void:
	_snapshot = StaticBody3D.new()
	_snapshot.collision_layer = snapshot_layer
	_snapshot.collision_mask = 0
	add_child(_snapshot)
	_cut_line = MeshInstance3D.new()
	_cut_line.mesh = ImmediateMesh.new()
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.no_depth_test = true
	line_material.albedo_color = Color(1.0, 0.85, 0.2)
	_cut_line.material_override = line_material
	_cut_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cut_line.top_level = true
	add_child(_cut_line)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_X:
		mode = ((mode + 1) % Mode.size()) as Mode
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.ctrl_pressed and mode == Mode.DISMANTLE:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			cube_size = clampf(cube_size * 1.15, min_cube_size, max_cube_size)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cube_size = clampf(cube_size / 1.15, min_cube_size, max_cube_size)
		return
	if button != null and button.pressed and button.ctrl_pressed and mode == Mode.CUT:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			cut_depth = minf(cut_depth + 0.05, 1.0)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cut_depth = maxf(cut_depth - 0.05, 0.05)
		return
	var sphere := brush as SolidSphere
	if button != null and button.pressed and button.ctrl_pressed and sphere != null:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			sphere.radius = clampf(sphere.radius * 1.15, min_radius, max_radius)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			sphere.radius = clampf(sphere.radius / 1.15, min_radius, max_radius)


func _process(delta: float) -> void:
	if mode == Mode.CUT or _cutting:
		_process_cut()
		return
	if mode == Mode.DISMANTLE:
		if stroke.is_active():
			stroke.end()
		_process_dismantle()
		return
	if brush == null:
		return
	var size := brush.get_solid().get_aabb().get_longest_axis_size() * 0.5
	stroke.shape = brush
	stroke.spacing = size * spacing
	stroke.sweep = sweep
	stroke.advance_speed = hold_speed
	var sphere := brush as SolidSphere
	stroke.band_edge_length = sphere.get_edge_length() if sphere != null else 0.0
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if stroke.is_active():
			stroke.end()
		return
	var hit := _raycast(snapshot_layer if stroke.is_active() and not _live else surface_layers)
	if hit.is_empty():
		return
	if not stroke.is_active():
		var hit_mesh := AdaptiveMesh.find(hit.collider)
		if hit_mesh == null or (mesh != null and hit_mesh != mesh):
			return  # not adaptive (or not the one we're limited to)
		target = hit_mesh
		target.activate()  # a dormant component takes over now, so there are shapes to snapshot
		_take_snapshot()
		var build := Input.is_key_pressed(KEY_SHIFT)
		stroke.operation = BooleanOp.Operation.UNION if build else BooleanOp.Operation.SUBTRACT
		stroke.advance_direction = hit.normal if build else -hit.normal
		stroke.begin(target, hit.position)
		edit_queued.emit()
	elif stroke.update(hit.position, delta):
		edit_queued.emit()


# Cut mode: a press starts a line on screen; the first adaptive mesh the mouse passes over
# while dragging is the one cut, and its distance from the camera places the line. Letting
# go cuts along it.
func _process_cut() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var mouse := get_viewport().get_mouse_position()
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if _cutting:
			_cutting = false
			_draw_cut_line(Vector3.ZERO, Vector3.ZERO)
			if _cut_distance > 0.0 and is_instance_valid(target) and not target.is_queued_for_deletion():
				_cut(camera, _on_ray(camera, _cut_start), _on_ray(camera, mouse))
		return
	if not _cutting:
		_cutting = true
		_cut_start = mouse
		_cut_distance = -1.0
	if _cut_distance < 0.0:
		var hit := _raycast(surface_layers)
		var hit_mesh := AdaptiveMesh.find(hit.collider) if not hit.is_empty() else null
		if hit_mesh != null and (mesh == null or hit_mesh == mesh):
			target = hit_mesh
			_cut_distance = camera.project_ray_origin(mouse).distance_to(hit.position)
	if _cut_distance > 0.0:
		_draw_cut_line(_on_ray(camera, _cut_start), _on_ray(camera, mouse))


# Dismantle mode: a click on an adaptive mesh cuts it into cubes.
func _process_dismantle() -> void:
	var pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var clicked := pressed and not _pressed
	_pressed = pressed
	if not clicked:
		return
	var hit := _raycast(surface_layers)
	var hit_mesh := AdaptiveMesh.find(hit.collider) if not hit.is_empty() else null
	if hit_mesh == null or (mesh != null and hit_mesh != mesh):
		return
	target = hit_mesh
	if target.dismantle(cube_size, 0.0, _cut_tag()) > 0:
		edit_queued.emit()


# The point under screen position [param at], [member _cut_distance] from the camera.
func _on_ray(camera: Camera3D, at: Vector2) -> Vector3:
	return camera.project_ray_origin(at) + camera.project_ray_normal(at) * _cut_distance


# Cuts [member target] along [param from] - [param to], away from [param camera]. The line
# is moved along the view to just in front of the mesh's box (where the drag met the mesh
# may be halfway back, at its silhouette), and the cut reaches [member cut_depth] of the
# box's depth from there.
func _cut(camera: Camera3D, from: Vector3, to: Vector3) -> void:
	if from.distance_to(to) < 1e-3:
		return
	var middle := (from + to) * 0.5
	var direction := (middle - camera.global_position).normalized()
	var box := target.global_transform * target.get_aabb()
	var near := INF
	var far := -INF
	for i in 8:
		var along := (box.get_endpoint(i) - middle).dot(direction)
		near = minf(near, along)
		far = maxf(far, along)
	var lead := box.size.length() * 0.02
	var shift := direction * (near - lead)
	target.cut(from + shift, to + shift, direction, (far - near) * cut_depth + lead, 0.0, _cut_tag())
	edit_queued.emit()


func _draw_cut_line(from: Vector3, to: Vector3) -> void:
	var line := _cut_line.mesh as ImmediateMesh
	line.clear_surfaces()
	if from == to:
		return
	line.surface_begin(Mesh.PRIMITIVE_LINES)
	line.surface_add_vertex(from)
	line.surface_add_vertex(to)
	line.surface_end()


# Points the snapshot body at the pieces' current collision shapes: pieces never change a
# shape they made, so this keeps the surface as it is now without copying it.
func _take_snapshot() -> void:
	var shapes := target.get_collision_shapes()
	_live = shapes.is_empty()  # still baking: ray the live surface this stroke
	var nodes := _snapshot.get_children()
	for i in maxi(shapes.size(), nodes.size()):
		var node: CollisionShape3D
		if i < nodes.size():
			node = nodes[i]
		else:
			node = CollisionShape3D.new()
			_snapshot.add_child(node)
		node.shape = shapes[i] if i < shapes.size() else null
		node.disabled = i >= shapes.size()
	_snapshot.global_transform = target.global_transform


func _raycast(mask: int) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var mouse := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var to := from + camera.project_ray_normal(mouse) * ray_length
	return camera.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask))


# Cuts make faces with the brush's tag, so they look like digs.
func _cut_tag() -> int:
	return brush.tag if brush != null else 1
