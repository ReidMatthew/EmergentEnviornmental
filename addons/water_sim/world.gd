@tool
@icon("icon.svg")
class_name WaterSimWorld
extends Node3D
## Starts simulation boxes where something happens. In an open world, matter rests as
## [WaterSimStillWater] and bodies; when a component acts (a spell, an emitter, a tornado)
## or a body splashes into still water where no box is awake, this starts one from
## [member box_scene] around that spot, which takes in the still water there. A box it
## started frees itself when [method WaterSim.sleep] leaves it empty (boxes don't sleep by
## themselves: the game decides when). At most [member max_boxes] of its boxes exist at
## once; beyond that, nothing new starts until one goes.
##
## Add one to the scene. Boxes placed by hand (a [WaterSim] over a pond) work alongside it:
## a component inside one of those uses it.

const GROUP := &"water_sim_worlds"

## The box to start: a scene whose root is a [WaterSim], with its views and settings.
@export var box_scene: PackedScene
@export var max_boxes := 4
## How far below the spot the box's floor goes (the rest of its height is above).
@export var depth_below := 2.0
## Boxes are placed on a grid this fine (match the still water's cell size or a multiple).
@export var snap := 0.5

var _boxes: Array[WaterSim] = []


func _ready() -> void:
	add_to_group(GROUP)


## The world in the scene, or null.
static func find(tree: SceneTree) -> WaterSimWorld:
	return tree.get_first_node_in_group(GROUP) as WaterSimWorld if tree != null else null


## The box at a global point, awake: the one already there (woken), else a new one if the
## budget allows, else null.
func ensure_box(point: Vector3) -> WaterSim:
	for sim in get_tree().get_nodes_in_group(WaterSim.GROUP):
		if sim is WaterSim and not sim.is_queued_for_deletion() and sim.has_point(point):
			sim.wake()
			return sim
	if box_scene == null or get_boxes().size() >= max_boxes:
		return null
	var sim := box_scene.instantiate() as WaterSim
	if sim == null:
		push_error("WaterSimWorld: box_scene's root must be a WaterSim")
		return null
	sim.retire_when_empty = true
	# Asleep until placed, so waking takes in the still water where it lands.
	sim.start_asleep = true
	add_child(sim)
	var at := Vector3(point.x, point.y - depth_below, point.z)
	if snap > 0.0:
		at = (at / snap).round() * snap
	sim.global_position = at
	_boxes.append(sim)
	sim.wake()
	return sim


## Boxes this world started that are still around.
func get_boxes() -> Array[WaterSim]:
	# (Untyped: a freed box can't be passed as a WaterSim.)
	var alive: Array[WaterSim] = []
	for sim in _boxes:
		if is_instance_valid(sim) and not sim.is_queued_for_deletion():
			alive.append(sim)
	_boxes = alive
	return _boxes
