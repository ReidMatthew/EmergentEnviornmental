@tool
extends EditorInspectorPlugin
## Adds a Bake button to [AdaptiveMesh]'s inspector: bakes [member AdaptiveMesh.data]
## from the source and saves it (compressed binary) so the game starts without baking.
## The first bake asks where to save, suggesting a file next to the source model; later
## bakes overwrite that file.

var _dialog: EditorFileDialog
var _target: AdaptiveMesh


func _can_handle(object: Object) -> bool:
	return object is AdaptiveMesh


func _parse_begin(object: Object) -> void:
	var node := object as AdaptiveMesh
	var box := VBoxContainer.new()
	var button := Button.new()
	button.text = "Bake" if _saved_path(node).is_empty() else "Bake (overwrites %s)" % _saved_path(node).get_file()
	button.tooltip_text = "Bakes the source into pieces and meshes and saves them, so the game starts without baking."
	button.disabled = node.get_bake_source() == null
	var status := Label.new()
	status.add_theme_color_override(&"font_color", Color(0.6, 0.6, 0.6))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = _describe(node)
	button.pressed.connect(_on_bake_pressed.bind(node, button, status))
	box.add_child(button)
	box.add_child(status)
	add_custom_control(box)


func _on_bake_pressed(node: AdaptiveMesh, button: Button, status: Label) -> void:
	var path := _saved_path(node)
	if not path.is_empty():
		_bake_to(node, path, button, status)
		return
	_target = node
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_dialog.add_filter("*.res", "Adaptive mesh data")
		_dialog.title = "Save baked adaptive mesh data"
		EditorInterface.get_base_control().add_child(_dialog)
	if _dialog.file_selected.is_connected(_on_file_selected):
		_dialog.file_selected.disconnect(_on_file_selected)
	_dialog.file_selected.connect(_on_file_selected.bind(button, status), CONNECT_ONE_SHOT)
	_dialog.current_path = _suggested_path(node)
	_dialog.popup_file_dialog()


func _on_file_selected(path: String, button: Button, status: Label) -> void:
	if is_instance_valid(_target):
		_bake_to(_target, path, button, status)


func _bake_to(node: AdaptiveMesh, path: String, button: Button, status: Label) -> void:
	if is_instance_valid(button):
		button.disabled = true
	if is_instance_valid(status):
		status.text = "Baking..."
	var start := Time.get_ticks_msec()
	var old_data := node.data
	await node.bake()
	var made := node.data
	var error := ResourceSaver.save(made, path, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		push_error("AdaptiveMesh: couldn't save the baked data to %s (%s)." % [path, error_string(error)])
		if is_instance_valid(status):
			status.text = "Saving failed: %s" % error_string(error)
		if is_instance_valid(button):
			button.disabled = false
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	var saved := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as AdaptiveMeshData
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Bake adaptive mesh", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_property(node, &"data", saved)
	undo.add_undo_property(node, &"data", old_data)
	undo.commit_action()
	print("AdaptiveMesh: baked %d pieces in %d ms, saved to %s" % [saved.pieces.size(),
			Time.get_ticks_msec() - start, path])
	if is_instance_valid(button):
		button.disabled = false
		button.text = "Bake (overwrites %s)" % path.get_file()
	if is_instance_valid(status):
		status.text = _describe(node)


# The file the node's data was saved to, if it's a file of its own (not inside a scene).
static func _saved_path(node: AdaptiveMesh) -> String:
	if node.data == null:
		return ""
	var path := node.data.resource_path
	return "" if path.is_empty() or path.contains("::") else path


# Next to the source model (or the target's mesh, for a component) when there is one,
# otherwise next to the scene.
static func _suggested_path(node: AdaptiveMesh) -> String:
	var path := node.get_data_path()
	if path.is_empty():
		var root := EditorInterface.get_edited_scene_root()
		var from := root.scene_file_path if root != null and not root.scene_file_path.is_empty() else "res://adaptive_mesh.tscn"
		path = from.get_base_dir().path_join("%s.adaptive.res" % from.get_file().get_basename())
	return path


static func _describe(node: AdaptiveMesh) -> String:
	if node.get_bake_source() == null:
		return "Set a source, or put this node under a MeshInstance3D (or set a target), to bake."
	var text := _bake_state(node)
	text += "

Reads: %s
Collision: %s" % [node.get_reads_description(), node.get_collision_description()]
	var note := node.get_collision_note()
	if not note.is_empty():
		text += "

Note: " + note
	return text


static func _bake_state(node: AdaptiveMesh) -> String:
	var data := node.data
	if node.is_auto_baking():
		return "Baking by itself..."
	if data == null or not data.is_baked():
		if node.auto_bake:
			return "Not baked yet: it bakes by itself in a moment."
		return ("Not baked: the first edit bakes it." if node.is_component()
				else "Not baked: the game bakes the source when it starts.")
	var triangles := 0
	for solid: Solid in data.pieces.values():
		triangles += solid.get_triangle_count()
	var where := _saved_path(node)
	var text := "%d pieces, %d triangles%s." % [data.pieces.size(), triangles,
			(", saved in " + where.get_file()) if not where.is_empty() else " (inside the scene)"]
	text += (" Bakes again by itself when the mesh, source, chunking or bounds change." if node.auto_bake
			else " Auto-bake is off: press Bake after changing the mesh, source, chunking or bounds.")
	return text
