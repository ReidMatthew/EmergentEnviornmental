extends Node3D
## The big-world demo, after Grant Kot's test: a world of 256 x 256 x 128 cells (171 x 171 x 85 m at the default 2/3 m cells) with
## about a million particles, simulated on the CPU only, one step a frame (the sparse grid is what makes it possible: the empty space
## costs nothing), drawn as water. A wide shallow lake with islands, and a tall block of water dropped in the middle of it, whose wave
## runs out across the lake. Everything in the world is laid out for its size, so the scene is the same at any cell size.
## Press R to drop another block. Right mouse button turns the camera, the wheel zooms, [ or ] opens the menu.
##

const WATER := preload("res://addons/water_sim/substances/water.tres")
const GRAINS := preload("res://addons/water_sim/demo/materials/grains.tres")

const CELLS := Vector3i(256, 128, 256)
## Side of the lake as a share of the world's, and how deep it is (m).
@export var lake_fraction := 0.875
@export var lake_depth := 2.0
## Side of the lake in metres (0: lake_fraction of the world).
@export var lake_size := 0.0
## Particles the box may carry.
@export var max_particles := 1000000
@export var threads := 4
## Farther than this from the camera the water is simulated and drawn with particles that stand for eight (0: all fine).
@export var detail_distance := 10.0
@export var fill_water := true
## The simulation's cell size (m); the world is 256 x 128 x 256 of them, so it sets the world's size too (the cell slider refills
## the same world at another size).
@export var cell_size := 0.125
## Most substeps a frame (1: one step a frame).
@export var max_substeps := 1

# The world's size over the 64 m it was laid out for (islands, the dropped block, the camera).
var _scale := 1.0
## Drop a block of water into the lake at the start (R drops another).
@export var drop_block := true

var sim: WaterSim


func _ready() -> void:
	_scale = CELLS.x * cell_size / 64.0
	var camera := get_node_or_null("Camera") as Camera3D
	if camera != null:
		camera.far *= _scale
		camera.set("distance", camera.get("distance") * _scale)
		camera.set("max_distance", camera.get("max_distance") * _scale)
		camera.call("_place")
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.directional_shadow_max_distance *= _scale
	_build_ground()
	_build_islands()
	_build_sim()
	_build_hud()
	if fill_water:
		_fill.call_deferred()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		_drop()


func _build_ground() -> void:
	# Beyond the lake: land the water never reaches, so there is something to see the size against.
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(600, 600) * _scale
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.5, 0.3)
	material.roughness = 1.0
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = Vector3(0, -0.05, 0)
	add_child(instance)


func _build_islands() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 9:
		var body := StaticBody3D.new()
		body.name = "Island%d" % i
		var radius := rng.randf_range(1.5, 3.5) * _scale
		var height := rng.randf_range(1.2, 3.0)
		var angle := TAU * float(i) / 9.0 + rng.randf_range(-0.2, 0.2)
		var ring := rng.randf_range(9.0, 21.0) * _scale
		body.position = Vector3(cos(angle) * ring, height * 0.5, sin(angle) * ring)
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		body.add_child(WaterSimCollider.new())
		var mesh := CylinderMesh.new()
		mesh.top_radius = radius * 0.8
		mesh.bottom_radius = radius
		mesh.height = height
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.5, 0.46, 0.4)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		body.add_child(instance)
		add_child(body)


func _build_sim() -> void:
	sim = WaterSim.new()
	sim.name = "WaterSim"
	sim.size = Vector3(CELLS) * cell_size
	sim.cell_size = cell_size
	sim.detail_levels = 2
	sim.substances = [WATER]
	sim.max_particles = max_particles
	sim.max_substeps = max_substeps
	sim.threads = threads
	sim.adaptive = true
	sim.detail_distance = detail_distance
	add_child(sim)
	var fluid := WaterSimFluidView.new()
	fluid.name = "Fluid"
	fluid.substances = [WATER]
	fluid.far_distance = 400.0 * _scale
	fluid.location = WaterSimFluidView.Location.CENTER
	sim.add_child(fluid)
	var particles := WaterSimParticleView.new()
	particles.name = "Particles"
	particles.material_override = GRAINS
	particles.visible = false
	sim.add_child(particles)


func _fill() -> void:
	# The islands' shapes are in the solver after a physics frame or two.
	await get_tree().physics_frame
	await get_tree().physics_frame
	sim._update_inputs()
	var started := Time.get_ticks_msec()
	var half := (lake_size if lake_size > 0.0 else sim.size.x * lake_fraction) * 0.5
	var floor_y := sim.cell_size
	# (Depths are laid out for cells of 2/3 m, as the world is for its size.)
	var depth := lake_depth * cell_size / 0.667
	var total := sim.fill(WaterSim.Shape.BOX, Transform3D(Basis(), Vector3(0, floor_y + depth * 0.5, 0)), Vector3(half, depth * 0.5, half), WATER, Vector3.ZERO, true)
	if drop_block:
		total += _drop()
	print("kot demo: %d particles in %.1f s" % [total, (Time.get_ticks_msec() - started) / 1000.0])


# A tall block of water over the middle of the lake.
func _drop() -> int:
	return sim.fill(WaterSim.Shape.BOX, Transform3D(Basis(), Vector3(0, 8.0 * cell_size / 0.667, 0)), Vector3(6.0 * _scale, 2.5 * cell_size / 0.667, 6.0 * _scale), WATER, Vector3.ZERO, true)


func _build_hud() -> void:
	var hud: WaterSimDemoHud = (load("res://addons/water_sim/demo/ui/demo_hud.tscn") as PackedScene).instantiate()
	hud.name = "HUD"
	hud.sim = sim
	hud.help_text = "R: drop a block of water. Right mouse / arrows: turn, wheel: zoom, [ or ]: menu.
A world of %d x %d x %d cells on the CPU; only the cells with water in them cost anything." % [CELLS.x, CELLS.z, CELLS.y]
	# R drops a block here, and this script fills the world itself.
	hud.reset_key = 0
	hud.refill_emitters = false
	hud.cell_size_changed.connect(func(_size: float) -> void: _fill())
	add_child(hud)
