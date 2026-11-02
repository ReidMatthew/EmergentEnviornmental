@tool
extends EditorPlugin

# Every class is a class_name script, available with the plugin on or off. The plugin only
# adds editor tools: a Bake button in AdaptiveMesh's inspector.

var _inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_inspector = preload("editor/bake_inspector.gd").new()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null
