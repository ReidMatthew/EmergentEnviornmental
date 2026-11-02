extends Node3D
## The tool sandbox: a 20 x 20 m pool of two million particles at 1/8 m cells (0.1 to 5 million, chosen on the menu's Scene
## panel), and every kind of tool the tool kit makes ([WaterSimTool], [WaterSimToolBelt]): pour, blast, gather into a ball, tornado,
## whirlpool, geyser, draw a floating river, freeze, a water jet, a gust, summon water out of the pool, vanish it, rain. Each tool is
## only an arrangement of components under a [WaterSimTool] node in the scene; the menu's Tools tab ([ or ]) picks one and shows its
## settings.
##
## 1 to 0, Q and E pick a tool, left mouse uses it, Shift / Ctrl / Alt + wheel change its reach, power and height, C clears what the
## tools left. Right mouse turns the camera.

const STONE := preload("res://addons/water_sim/demo/materials/stone.tres")
const MENU_PANEL := "res://addons/menus/menu_panel.gd"

## How many particles the pool is filled with (it is as deep as it takes).
@export_range(100000, 5000000, 100000) var water_amount := 2000000
## How far the rim round the pool stands over the water (the box's walls hold the water; this is what is seen).
@export var rim_over_water := 0.45
## Show the stone rim round the pool. Off, the box's walls are invisible and the sides of the water can be seen.
@export var show_rim := false
## Room left in the simulation for what the tools add, over the pool's particles.
@export var headroom := 400000

## Fine particles a cubic metre of the pool fills with at 1/8 m cells (eight a cell, less the edges; measured).
const FILLED_PER_CUBIC_METRE := 3290.0

@onready var tools: WaterSimToolBelt = $Tools
var sim: WaterSim
var pool: WaterSimEmitter

var _rim: Array[MeshInstance3D] = []


# Before the children are ready: the pool fills on start, so it has its depth by then.
func _enter_tree() -> void:
	sim = $WaterSim
	pool = $Pool
	_shape_pool()


func _ready() -> void:
	_build_rim(_depth() + rim_over_water)
	_add_menu()


## Fills the pool again with [param amount] particles (clears the water and what the tools left).
func set_water_amount(amount: int) -> void:
	water_amount = clampi(amount, 100000, 5000000)
	tools.clear()
	sim.clear()
	_shape_pool()
	_build_rim(_depth() + rim_over_water)
	# (Now, not with the simulation's next inputs: a slow frame can run two physics ticks before it steps.)
	sim.get_solver().set_max_particles(sim.max_particles)
	pool.fill()


# The pool's shape and fill limit for water_amount, and the room in the simulation that goes with it. The shape is a little deeper
# than the water and fill_limit stops it at the amount (the edges and the top layer hold fewer, more so in a shallow pool).
func _shape_pool() -> void:
	var depth := minf(_depth() + 0.25, sim.size.y * 0.6)
	pool.size = Vector3(sim.size.x, depth, sim.size.z)
	pool.position.y = depth * 0.5
	pool.fill_limit = water_amount
	sim.max_particles = water_amount + headroom


# About how deep water_amount stands in the pool.
func _depth() -> float:
	var scale := pow(0.125 / sim.cell_size, 3)
	return water_amount / (FILLED_PER_CUBIC_METRE * scale * sim.size.x * sim.size.z)


func _build_rim(height: float) -> void:
	for wall in _rim:
		wall.queue_free()
	_rim.clear()
	if not show_rim:
		return
	var half := sim.size.x * 0.5
	var thick := 0.5
	for side in 4:
		var along_x := side < 2
		var out := (half + thick * 0.5) * (1.0 if side % 2 == 0 else -1.0)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(sim.size.x + thick * 2.0, height, thick) if along_x else Vector3(thick, height, sim.size.z)
		mesh.material = STONE
		var wall := MeshInstance3D.new()
		wall.mesh = mesh
		wall.position = Vector3(0, height * 0.5, out) if along_x else Vector3(out, height * 0.5, 0)
		add_child(wall)
		_rim.append(wall)


# A Scene panel on the menu, when the menus add-on is in the project (found by path and group: the demo needs neither). The HUD,
# a child, has put the host in by now.
func _add_menu() -> void:
	var host := get_tree().get_first_node_in_group(&"menus_host")
	if host == null or not ResourceLoader.exists(MENU_PANEL):
		return
	var p: Node = load(MENU_PANEL).new()
	p.set("title", "Scene")
	p.set("order", 10)
	host.call("add_panel", p)
	p.call("tab", "Scene")
	p.call("section", "Water")
	p.call("slider", "Water (particles)", 0.1, 5.0, 0.1, water_amount / 1000000.0, Callable(),
			func(v: float) -> String: return "%.1f million" % v if v >= 1.0 else "%dk" % roundi(v * 1000.0),
			func(v: float) -> void: set_water_amount(roundi(v * 1000000.0)))
	p.call("label", "Let go of the slider to fill the pool again (it gets deeper). Past about 3 million it runs slower than real time.")
	p.call("button", "Refill", func() -> void: set_water_amount(water_amount))
