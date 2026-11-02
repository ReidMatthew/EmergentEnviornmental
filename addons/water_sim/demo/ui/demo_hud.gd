class_name WaterSimDemoHud
extends CanvasLayer
## The information every demo shows, as one scene to put in any of them: where the frame's time goes (CPU, simulation step,
## GPU) and the particle counts at the top left, the help line at the bottom left, the settings menu on the right and the
## level-of-detail debug mode (L). Say which [WaterSim] it is for and it finds
## the rest: the box's fluid, particle, mesh and level-of-detail views are what the menu's switches and the keys F, P, M, B, N and L
## control, and its spray view S. A mesh view and a level-of-detail view the box doesn't have are added to it.
##
## The menu is the Water panel of the [code]menus[/code] and [code]water_sim_menu[/code] add-ons, put in when both are in the
## project (and a menu host is added when the scene has none); without them the demo has no settings, and nothing else changes.

## The simulation the demo shows.
@export var sim: WaterSim
## A pull tool ([code]demo/components/pull_tool.gd[/code]) for the menu's Tools tab; none: no tab.
@export var pull: Node
## A [WaterSimToolBelt] for the menu's Tools tab: pick a tool and change its settings there; none: no belt in the tab.
@export var tools: Node
## Takes the water back from the start (R, and a button on the menu); 0: no reset.
@export var reset_key := KEY_R
## Puts back what fills on start when the cell size changes. Off for a demo that fills the world itself (connect
## [signal cell_size_changed] to do it).
@export var refill_emitters := true
## What the demo's help line says (tools, mouse, keys). Left empty when the demo's own script writes it.
@export_multiline var help_text := ""

## The cell size was changed in the menu (the water has been cleared).
signal cell_size_changed(cell_size: float)

@onready var help: Label = $Help

const MENUS := "res://addons/menus/menus.tscn"
const WATER_MENU := "res://addons/water_sim_menu/water_menu.gd"


# Before the children are ready, as the views are there when the menu is made.
func _enter_tree() -> void:
	if sim == null:
		return
	var fluids: Array[Node] = _views(&"WaterSimFluidView")
	var particles: Array[Node] = _views(&"WaterSimParticleView")
	var lods: Array[Node] = _views(&"WaterSimLodView")
	var hidden: Array[Node] = []
	hidden.append_array(fluids)
	hidden.append_array(particles)
	if lods.is_empty():
		var lod := WaterSimLodView.new()
		lod.name = "LodView"
		lod.visible = false
		sim.add_child(lod)
		lods.append(lod)
	var debug := get_node("LodDebug")
	debug.set("lod_view", lods[0])
	debug.set("hide_while_on", hidden)
	get_node("Perf").set("sim", sim)


func _ready() -> void:
	if help_text != "":
		help.text = help_text
	_add_menu()


func _views(type: StringName) -> Array[Node]:
	return sim.find_children("*", type, true, false)


# The Water panel of the menu add-ons, when they are in the project (found by path and group: this demo needs neither).
func _add_menu() -> void:
	if sim == null or not ResourceLoader.exists(MENUS) or not ResourceLoader.exists(WATER_MENU):
		return
	if get_tree().get_first_node_in_group(&"menus_host") == null:
		add_child((load(MENUS) as PackedScene).instantiate())
	var menu := Node.new()
	menu.name = "WaterMenu"
	menu.set_script(load(WATER_MENU))
	menu.set("sim", sim)
	menu.set("pull", pull)
	menu.set("tools", tools)
	menu.set("reset_key", reset_key)
	menu.set("refill_emitters", refill_emitters)
	menu.connect("cell_size_changed", cell_size_changed.emit)
	add_child(menu)
