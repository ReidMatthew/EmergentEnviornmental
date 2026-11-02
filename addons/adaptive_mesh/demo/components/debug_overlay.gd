extends CanvasLayer
## Demo diagnostics for the adaptive mesh being dug and the dig tool digging it: the
## controls and stats on screen, and keys to look inside. Delete it and the demo still works.
##
## F wireframe, E brush detail (matched to the surface, or keys 1-4 for fixed levels),
## T sweep, C cleanup, K chunks on/off (bakes again), B debris on/off and L separation
## on/off (if the mesh has those settings), R reset.

## The mesh to show. Empty: whichever one the dig tool last edited.
@export var mesh: AdaptiveMesh
## The dig tool (demo/components/dig_tool.gd) whose brush and stroke the keys change.
@export var dig_tool: Node

var _label: Label
var _wireframe: MeshInstance3D
var _edge_length := 0.0  # the brush's matched detail, for E to switch back to
var _current: AdaptiveMesh  # the mesh shown now
var _cleanup: MeshCleanup
var _chunking: Chunking
var _source_triangles := 0
var _edit_started := 0
var _last_edit_ms := 0.0


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(12, 12)
	add_child(_label)
	_wireframe = MeshInstance3D.new()
	_wireframe.material_override = _wireframe_material()
	_wireframe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wireframe.visible = false
	# The overlay's own, following the shown mesh: under the mesh, it was freed with it (a
	# part dug away or made plain), and the overlay then broke on it.
	add_child(_wireframe)
	var sphere := _brush() as SolidSphere
	if sphere != null:
		_edge_length = sphere.edge_length
	dig_tool.edit_queued.connect(func() -> void: _edit_started = Time.get_ticks_usec())


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if not is_instance_valid(_current):
		_current = null
	var sphere := _brush() as SolidSphere
	match key.keycode:
		KEY_F:
			_wireframe.visible = not _wireframe.visible
			_update_wireframe()
		KEY_E:
			if sphere != null:
				sphere.edge_length = 0.0 if sphere.edge_length > 0.0 else _edge_length
		KEY_1, KEY_2, KEY_3, KEY_4:
			if sphere != null:
				sphere.subdivisions = key.keycode - KEY_1
				sphere.edge_length = 0.0  # fixed levels instead of matching the surface
		KEY_T:
			dig_tool.sweep = not dig_tool.sweep
		KEY_C:
			if _current != null:
				_current.cleanup = null if _current.cleanup != null else _cleanup
				for piece: AdaptivePiece in _current.get_pieces().values():
					piece.cleanup = _current.cleanup
		KEY_B:
			if _current != null and _current.debris != null:
				_current.debris.enabled = not _current.debris.enabled
		KEY_L:
			if _current != null and _current.separation != null:
				_current.separation.enabled = not _current.separation.enabled
		KEY_K:
			if _current != null:
				_current.chunking = null if _current.chunking != null else _chunking  # bakes again
		KEY_R:
			if mesh != null:
				mesh.reset()
			else:
				for each in AdaptiveMesh.get_all(get_tree()):
					each.reset()


func _process(_delta: float) -> void:
	# (Meshes come and go: a part dug away, or made plain, is freed.)
	var wanted: Variant = mesh if is_instance_valid(mesh) else dig_tool.target
	var shown: AdaptiveMesh = wanted if is_instance_valid(wanted) and not (wanted as Node).is_queued_for_deletion() else null
	if not is_instance_valid(_current):
		_current = null
	if shown != _current:
		_show(shown)
	if _current != null:
		_wireframe.global_transform = _current.global_transform
	var sphere := _brush() as SolidSphere
	var detail := "keys 1-4"
	if sphere != null and sphere.edge_length > 0.0:
		detail = "matched, edge %.1f" % sphere.edge_length
	var lines := PackedStringArray()
	if dig_tool.mode == dig_tool.Mode.DISMANTLE:
		lines.append("DISMANTLE MODE (X: back to digging)    Left click: cut a mesh into cubes    Right drag: orbit    Wheel: zoom")
		lines.append("Ctrl + wheel: cube size (%.2f)" % dig_tool.cube_size)
	elif dig_tool.mode == dig_tool.Mode.CUT:
		lines.append("CUT MODE (X: dismantle mode)    Left drag: draw a cut, let go to cut    Right drag: orbit    Wheel: zoom")
		lines.append("Ctrl + wheel: cut depth (%d%%%s)" % [roundi(dig_tool.cut_depth * 100.0),
				", all the way through" if dig_tool.cut_depth >= 1.0 else ""])
	else:
		lines.append("Left drag: dig    Shift + left drag: build    Hold still: deeper / higher    X: cut mode    Right drag: orbit    Wheel: zoom")
		lines.append("Ctrl + wheel: brush size (%.1f)    E: brush detail (%s): %d triangles    T: sweep (%s)" % [
				sphere.radius if sphere != null else 0.0, detail, _brush().get_solid().get_triangle_count(),
				"on" if dig_tool.sweep else "off"])
	if _current == null:
		lines.append("F: wireframe (%s)    R: reset    Dig something adaptive to see its stats" % ["on" if _wireframe.visible else "off"])
	else:
		var debris := "none"
		var parts := "none"
		if _current.debris != null:
			debris = "%s, %d bodies" % ["on" if _current.debris.enabled else "off", _current.get_debris().size()]
		if _current.separation != null:
			parts = "on" if _current.separation.enabled else "off"
		lines.append("C: cleanup (%s)    K: chunks (%s)    B: debris (%s)    L: parts separate (%s)    F: wireframe (%s)    R: reset" % [
				"on" if _current.cleanup != null else "off",
				"%d" % _current.get_pieces().size() if _current.chunking != null else "off", debris, parts,
				"on" if _wireframe.visible else "off"])
		lines.append("%s: %d triangles (started with %d)    Last edit: %.0f ms" % [_current.get_parent().name
				if _current.is_component() else _current.name, _current.get_triangle_count(), _source_triangles,
				_last_edit_ms])
	lines.append("Adaptive meshes: %d (%d taken over)    FPS: %d" % [AdaptiveMesh.get_all(get_tree()).size(),
			AdaptiveMesh.get_all(get_tree()).filter(func(m: AdaptiveMesh) -> bool: return m.is_active()).size(),
			Engine.get_frames_per_second()])
	_label.text = "\n".join(lines)


func _brush() -> SolidShape:
	return dig_tool.brush


# Follows [param shown] instead of the last mesh: its signals, its settings for C and K, and
# the wireframe.
func _show(shown: AdaptiveMesh) -> void:
	if is_instance_valid(_current):
		_current.baked.disconnect(_count_source)
		_current.edited.disconnect(_on_edited)
	_current = shown
	_wireframe.mesh = null
	if _current == null:
		return
	_cleanup = _current.cleanup
	_chunking = _current.chunking
	_current.baked.connect(_count_source)
	_current.edited.connect(_on_edited)
	_count_source()


func _count_source() -> void:
	_source_triangles = _current.get_triangle_count()
	_update_wireframe()


func _on_edited() -> void:
	_last_edit_ms = (Time.get_ticks_usec() - _edit_started) / 1000.0
	_update_wireframe()


# Every visible triangle edge, once, as lines over the shaded mesh.
func _update_wireframe() -> void:
	if not _wireframe.visible or _current == null:
		return
	var faces := _current.get_faces()
	var seen := {}
	var lines := PackedVector3Array()
	for t in range(0, faces.size(), 3):
		for e in 3:
			var a := faces[t + e]
			var b := faces[t + (e + 1) % 3]
			var key := [a, b] if a < b else [b, a]
			if seen.has(key):
				continue
			seen[key] = true
			lines.append(a)
			lines.append(b)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var lines_mesh := ArrayMesh.new()
	if not lines.is_empty():
		lines_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_wireframe.mesh = lines_mesh


# Unshaded dark lines, pulled slightly towards the camera so they win the depth test
# against the faces they lie on.
static func _wireframe_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.xyz *= 0.995;  // towards the camera, by an amount that scales with distance
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	ALBEDO = vec3(0.08, 0.09, 0.1);
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	return material
