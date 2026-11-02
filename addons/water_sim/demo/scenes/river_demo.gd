extends Node3D
## The rivers demo: a big land (360 x 300 m) with no walls the water meets, one box on the CPU, with adaptive detail.
## A tall waterfall pools in a medium pond; a river circles it and leads to a large pond; another
## winds down to a small whirlpool whose pit takes the water and puts it back at the top of the
## waterfall. Everything is built here from [RiverCourse].
##
## Right mouse button turns the camera, the wheel zooms, the arrow keys turn it too.

const WATER := preload("res://addons/water_sim/substances/water.tres")
const GRAINS := preload("res://addons/water_sim/demo/materials/grains.tres")

## The size of a simulation cell (m); the land is laid out for cells of 2/3 m and shrinks with them (as the big world's does).
@export var cell_size := 0.125
@export var max_particles := 1000000
## Start the water in the ponds and rivers (off: only what the waterfall brings).
@export var fill_water := true

var course := RiverCourse.new()
var sim: WaterSim
var terrain: StaticBody3D
# The land's size over what it was laid out for.
var _scale := 1.0


func _ready() -> void:
	_scale = cell_size / 0.667
	var camera := get_node_or_null("Camera") as Camera3D
	if camera != null:
		camera.far *= _scale
		camera.set("distance", camera.get("distance") * _scale)
		camera.set("min_distance", camera.get("min_distance") * _scale)
		camera.set("max_distance", camera.get("max_distance") * _scale)
		camera.set("target", camera.get("target") * _scale)
		camera.call("_place")
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.directional_shadow_max_distance *= _scale
	_build_terrain()
	_build_sim()
	_build_components()
	_build_hud()
	if fill_water:
		_fill.call_deferred()


func _build_terrain() -> void:
	var spacing := 0.5
	var heights := course.build_heights(spacing)
	var nx := int(round(RiverCourse.SIZE.x / spacing)) + 1
	var nz := int(round(RiverCourse.SIZE.y / spacing)) + 1
	terrain = StaticBody3D.new()
	terrain.name = "Land"
	add_child(terrain)
	var shape := HeightMapShape3D.new()
	shape.map_width = nx
	shape.map_depth = nz
	var scaled := heights.duplicate()
	for i in scaled.size():
		scaled[i] *= _scale
	shape.map_data = scaled
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.scale = Vector3(spacing, 1.0, spacing) * _scale
	terrain.add_child(collision)
	var collider := WaterSimCollider.new()
	terrain.add_child(collider)
	# The same land drawn, a vertex to each sample.
	var stride := 1
	var mx := (nx - 1) / stride + 1
	var mz := (nz - 1) / stride + 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(mx * mz)
	normals.resize(mx * mz)
	colors.resize(mx * mz)
	var half := Vector3(RiverCourse.SIZE.x * 0.5, 0.0, RiverCourse.SIZE.y * 0.5)
	for j in mz:
		for i in mx:
			var si := mini(i * stride, nx - 1)
			var sj := mini(j * stride, nz - 1)
			var h := heights[sj * nx + si]
			var hx0 := heights[sj * nx + maxi(si - stride, 0)]
			var hx1 := heights[sj * nx + mini(si + stride, nx - 1)]
			var hz0 := heights[maxi(sj - stride, 0) * nx + si]
			var hz1 := heights[mini(sj + stride, nz - 1) * nx + si]
			var normal := Vector3(hx0 - hx1, 2.0 * stride * spacing, hz0 - hz1).normalized()
			var at := j * mx + i
			vertices[at] = (Vector3(si * spacing, h, sj * spacing) - half) * _scale
			normals[at] = normal
			var steep := clampf((0.85 - normal.y) * 5.0, 0.0, 1.0)
			var grass := Color(0.30, 0.46, 0.22).lerp(Color(0.40, 0.52, 0.28), clampf(h / 40.0, 0.0, 1.0))
			var bed := Color(0.62, 0.56, 0.42)
			var rock := Color(0.45, 0.43, 0.42)
			var low := clampf(1.0 - (h - 0.5) / 14.0, 0.0, 1.0) * 0.35
			colors[at] = grass.lerp(bed, low).lerp(rock, steep)
	var indices := PackedInt32Array()
	indices.resize((mx - 1) * (mz - 1) * 6)
	var k := 0
	for j in mz - 1:
		for i in mx - 1:
			var a := j * mx + i
			indices[k] = a
			indices[k + 1] = a + 1
			indices[k + 2] = a + mx
			indices[k + 3] = a + 1
			indices[k + 4] = a + mx + 1
			indices[k + 5] = a + mx
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	terrain.add_child(instance)


func _build_sim() -> void:
	sim = WaterSim.new()
	sim.name = "WaterSim"
	sim.size = Vector3(RiverCourse.SIZE.x, 64.0, RiverCourse.SIZE.y) * _scale
	sim.cell_size = cell_size
	sim.max_substeps = 1
	sim.substances = [WATER]
	sim.max_particles = max_particles
	sim.adaptive = true
	sim.threads = 4
	sim.detail_levels = 2
	sim.detail_distance = 10.0
	add_child(sim)
	# The water drawn as water (a pass on the camera), the particles for looking.
	var fluid := WaterSimFluidView.new()
	fluid.name = "Fluid"
	fluid.substances = [WATER]
	fluid.location = WaterSimFluidView.Location.CENTER
	sim.add_child(fluid)
	var everything := WaterSimParticleView.new()
	everything.name = "AllParticles"
	everything.material_override = GRAINS
	everything.visible = false
	sim.add_child(everything)


func _build_components() -> void:
	# Where the whirlpool's water comes back: the back of the shelf, moving towards the cliff.
	var inlet := WaterSimEmitter.new()
	inlet.name = "Inlet"
	inlet.substance = WATER
	inlet.shape = WaterSim.Shape.BOX
	inlet.size = Vector3(10.0, 0.8, 2.0) * _scale
	inlet.velocity = Vector3(0, 0, 3.0)
	inlet.position = RiverCourse.to_world(course.inlet) * _scale
	add_child(inlet)
	var drain := WaterSimRecycler.new()
	drain.name = "Drain"
	drain.shape = WaterSim.Shape.CYLINDER
	drain.radius = 2.3 * _scale
	drain.height = 1.4 * _scale
	drain.inlet = inlet
	drain.recycle_bodies = false
	drain.position = RiverCourse.to_world(course.drain) * _scale
	add_child(drain)
	var whirl := WaterSimVortex.new()
	whirl.name = "Whirlpool"
	whirl.shape = WaterSim.Shape.CYLINDER
	whirl.radius = 8.5 * _scale
	whirl.height = 3.6 * _scale
	whirl.swirl_speed = 4.5
	whirl.pull_speed = 1.2
	whirl.lift_speed = 0.0
	whirl.strength = 3.0
	whirl.position = RiverCourse.to_world(Vector3(250, 2.9, 275)) * _scale
	add_child(whirl)


func _fill() -> void:
	# The land's shapes are in the solver after a physics frame or two.
	await get_tree().physics_frame
	await get_tree().physics_frame
	sim._update_inputs()
	var total := 0
	for entry in course.water_shapes():
		var t: Transform3D = entry.transform
		t.origin = RiverCourse.to_world(t.origin) * _scale
		total += sim.fill(entry.shape, t, entry.extents * _scale, WATER, Vector3.ZERO, true)
	print("rivers: %d particles" % total)


func _build_hud() -> void:
	var hud: WaterSimDemoHud = (load("res://addons/water_sim/demo/ui/demo_hud.tscn") as PackedScene).instantiate()
	hud.name = "HUD"
	hud.sim = sim
	hud.help_text = "Right mouse / arrows: turn, wheel: zoom, [ or ]: menu.
The whirlpool at the far end takes the water back to the top of the waterfall."
	# The land's water is filled by this script, so reset and refill are its own: a new cell size clears the water, the land's goes back in.
	hud.reset_key = 0
	hud.refill_emitters = false
	hud.cell_size_changed.connect(func(_size: float) -> void: _fill())
	add_child(hud)
