@tool
@icon("../icon.svg")
class_name WaterSimTransmuter
extends WaterSimComponent
## Turns an object into matter: call [method transmute] and its mesh's volume is filled
## with particles and the object goes. A rock that becomes water, a wall that becomes slime.
##
## Add it under the object (or point [member target] at it). The mesh should be closed.

signal transmuted(count: int)

## The object that turns into matter. Empty: this node's parent.
@export var target: Node3D
## The mesh whose inside is filled. Empty: the first MeshInstance3D in the target
## (the target itself if it is one).
@export var mesh_instance: MeshInstance3D
@export var substance: WaterSimSubstance
## Free the target once transmuted (else it's hidden and its collision turned off).
@export var free_target := true



func _get_configuration_warnings() -> PackedStringArray:
	if _find_mesh() == null:
		return ["Needs a MeshInstance3D in the target (or set mesh_instance)."]
	return []


## Fills the mesh with matter and removes the target. Returns how many particles were made.
func transmute() -> int:
	var on := _activity()
	var source := _find_mesh()
	if on == null or source == null or source.mesh == null:
		return 0
	var velocity := Vector3.ZERO
	var body := _get_target() as RigidBody3D
	if body != null:
		velocity = body.linear_velocity
	var count := on.fill_mesh(source.mesh, source.global_transform, substance, velocity)
	_remove_target()
	transmuted.emit(count)
	return count


func _get_target() -> Node3D:
	return target if target != null else get_parent() as Node3D


func _find_mesh() -> MeshInstance3D:
	if mesh_instance != null:
		return mesh_instance
	var root := _get_target()
	if root == null:
		return null
	if root is MeshInstance3D:
		return root
	return root.find_children("*", "MeshInstance3D", true, false).front() if root.find_children("*", "MeshInstance3D", true, false).size() > 0 else null


func _remove_target() -> void:
	var root := _get_target()
	if root == null:
		return
	if free_target:
		# Not this frame: the caller may still be using it.
		root.queue_free()
		return
	root.visible = false
	for node in [root] + root.find_children("*", "CollisionObject3D", true, false):
		if node is CollisionObject3D:
			node.process_mode = Node.PROCESS_MODE_DISABLED
			node.collision_layer = 0
