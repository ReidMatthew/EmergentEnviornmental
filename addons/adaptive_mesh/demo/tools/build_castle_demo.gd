extends SceneTree
## Builds castle_demo.tscn: a rolling field, the castle from castle_layout.gd (a copy of
## toon_shading's demo castle) and rocks, each an ordinary model made adaptive by a
## component, with their bakes saved so the demo starts with every piece ready.
##
##   godot --headless --path . --script res://addons/adaptive_mesh/demo/tools/build_castle_demo.gd
##
## Name steps after `--` to run only those (field, castle, scene); default all. The scene
## step places the rocks on the field's surface, so run it after changing the field.
##
## What it makes:
## - models/field.*, field.tscn: a closed slab of grass 256 x 256 units, flat where the
##   castle stands, cut into 24-unit columns.
## - models/castle.*, castle.tscn: the castle's few hundred overlapping primitives merged
##   into one closed mesh with a boolean union, cut into 16-unit cells.
## - castle_demo.tscn: the two, rocks (rock.tscn) around the field, the camera, the dig
##   tool and the overlay.

const DIR := "res://addons/adaptive_mesh/demo/"
const CastleLayout := preload("castle_layout.gd")

## The brush's tag: each mesh draws what's dug or built with it with its material at this
## slot (soil in the field, fresh-cut stone in the castle, the inside of a rock).
const DIG_TAG := 10

const FIELD_SIZE := 256.0
const FIELD_STEP := 4.0
const FIELD_DEPTH := 16.0
## Flat within this radius of the castle's centre, rolling from FLAT_TO on.
const FLAT_RADIUS := 54.0
const FLAT_TO := 76.0
## How far the castle is sunk into the field, so its base doesn't show a seam.
const CASTLE_SINK := 0.4

var _noise := FastNoiseLite.new()


func _initialize() -> void:
	_noise.seed = 3
	_noise.frequency = 0.01
	_noise.fractal_octaves = 3
	_run.call_deferred()


func _run() -> void:
	var steps := OS.get_cmdline_user_args()
	if steps.is_empty():
		steps = PackedStringArray(["field", "castle", "scene"])
	var started := Time.get_ticks_msec()
	if "field" in steps:
		await _build_field()
	if "castle" in steps:
		await _build_castle()
	if "scene" in steps:
		_build_scene()
	print("Done in %.1f s." % ((Time.get_ticks_msec() - started) / 1000.0))
	quit()


# --- Field ---------------------------------------------------------------------------

## Height of the field's surface: flat round the castle, rolling hills further out, rising
## towards the edges.
func field_height(x: float, z: float) -> float:
	var away := Vector2(x, z).length()
	var hills := _noise.get_noise_2d(x, z) * 9.0 + 2.0
	var rim := smoothstep(FIELD_SIZE * 0.32, FIELD_SIZE * 0.5, away) * 14.0
	return (hills + rim) * smoothstep(FLAT_RADIUS, FLAT_TO, away)


func _build_field() -> void:
	print("Field...")
	var cells := int(FIELD_SIZE / FIELD_STEP)
	var low := -FIELD_SIZE * 0.5
	var sheet := Solid.new()
	for r in cells + 1:
		for c in cells + 1:
			var x := low + c * FIELD_STEP
			var z := low + r * FIELD_STEP
			sheet.positions.append(Vector3(x, field_height(x, z), z))
	for r in cells:
		for c in cells:
			var a := r * (cells + 1) + c
			var b := a + 1
			var d := a + cells + 1
			var e := d + 1
			# Clockwise seen from above (Godot's front faces), alternating the diagonal.
			if (r + c) % 2 == 0:
				sheet.indices.append_array([a, b, e, a, e, d])
			else:
				sheet.indices.append_array([a, b, d, b, e, d])
			sheet.tags.append_array([0, 0])
	if not sheet.close_to_floor(-FIELD_DEPTH, 1):
		push_error("Field: couldn't close the sheet to a floor.")
		return
	_check_closed(sheet, "field")
	var materials := [_material("field_grass", Color(0.5, 0.64, 0.36)), _material("field_bedrock", Color(0.47, 0.42, 0.36))]
	var mesh := _save(_to_mesh(sheet, 40.0, materials), "models/field.res") as ArrayMesh
	var shape := _save(mesh.create_trimesh_shape(), "models/field_shape.res") as Shape3D

	var root_node := _mesh_node("Field", mesh)
	_add_collision(root_node, shape)
	var adaptive := _adaptive(root_node, _material("field_soil", Color(0.55, 0.42, 0.3)), 40.0)
	var chunking := GridChunking.new()
	chunking.cell_size = Vector3(24, 0, 24)
	adaptive.chunking = chunking
	adaptive.cleanup = _cleanup(0.5, 0.05)
	adaptive.separation = _separation(0.3)
	adaptive.activation = AdaptiveMesh.Activation.AT_START  # see _build_castle
	await _bake_and_pack(root_node, adaptive, "models/field.adaptive.res", "field.tscn")


# --- Castle --------------------------------------------------------------------------

func _build_castle() -> void:
	print("Castle: merging its primitives...")
	var unit_solids := {}  # [unit, tag] -> welded solid
	var ops: Array[BooleanOp] = []
	for part: Array in CastleLayout.new().build():
		var key := [part[0], part[1]]
		if not unit_solids.has(key):
			var solid := Solid.from_mesh(CastleLayout.unit_mesh(part[0]))
			solid.uvs = PackedVector2Array()  # weld by position only, so UV seams close
			solid.weld()
			solid.tags.fill(part[1])
			_check_closed(solid, "castle %s" % part[0])
			unit_solids[key] = solid
		ops.append(BooleanOp.create(unit_solids[key], part[2], BooleanOp.Operation.UNION))
	print("  %d primitives" % ops.size())
	var started := Time.get_ticks_msec()
	var merged: Solid = await CsgBooleanBackend.new().combine(Solid.new(), ops, AABB(), 0)
	if merged == null:
		push_error("Castle: the union failed.")
		return
	print("  merged into %d triangles in %.1f s" % [merged.get_triangle_count(),
			(Time.get_ticks_msec() - started) / 1000.0])
	_check_closed(merged, "castle")
	var materials := [
		_material("castle_stone", Color(0.82, 0.8, 0.72)),
		_material("castle_roof", Color(0.36, 0.5, 0.56)),
		_material("castle_window", Color(0.2, 0.18, 0.2)),
		_material("castle_banner", Color(0.66, 0.27, 0.25)),
		_material("castle_wood", Color(0.36, 0.23, 0.16)),
	]
	var mesh := _save(_to_mesh(merged, 30.0, materials), "models/castle.res") as ArrayMesh
	var shape := _save(mesh.create_trimesh_shape(), "models/castle_shape.res") as Shape3D

	var castle := _mesh_node("Castle", mesh)
	_add_collision(castle, shape)
	var adaptive := _adaptive(castle, _material("castle_stone_cut", Color(0.66, 0.63, 0.56)), 30.0)
	var chunking := GridChunking.new()
	chunking.cell_size = Vector3(16, 16, 16)
	chunking.offset = Vector3(4.5, 0, 4.5)  # walls off the castle's centre lines
	adaptive.chunking = chunking
	adaptive.cleanup = _cleanup(0.2, 0.03)
	adaptive.separation = _separation(0.12)
	# Takes over while the scene loads: putting out its pieces' collision takes about 100 ms,
	# a hitch mid-game on the first dig.
	adaptive.activation = AdaptiveMesh.Activation.AT_START
	await _bake_and_pack(castle, adaptive, "models/castle.adaptive.res", "castle.tscn")


# --- Scene ---------------------------------------------------------------------------

func _build_scene() -> void:
	print("Scene...")
	var scene := Node3D.new()
	scene.name = "CastleDemo"

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.7, 0.85)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.45, 0.45, 0.5)
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.62, 0.74, 0.86)
	environment.fog_density = 0.002
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = environment
	_own(scene, world)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.transform = Transform3D(Basis.from_euler(Vector3(-0.9, 0.5, 0.0)), Vector3.ZERO)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	_own(scene, sun)

	var field := (load(DIR + "field.tscn") as PackedScene).instantiate() as Node3D
	_own(scene, field)
	var castle := (load(DIR + "castle.tscn") as PackedScene).instantiate() as Node3D
	castle.position = Vector3(0, -CASTLE_SINK, 0)
	_own(scene, castle)
	_scatter_rocks(scene)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.far = 2000.0
	camera.set_script(load(DIR + "components/orbit_camera.gd"))
	camera.set(&"target", Vector3(0, 14, 0))
	camera.set(&"distance", 170.0)
	camera.set(&"min_distance", 8.0)
	camera.set(&"max_distance", 420.0)
	camera.set(&"yaw", 0.35)
	camera.set(&"pitch", -0.4)
	_own(scene, camera)

	var brush := SolidSphere.new()
	brush.radius = 3.0
	brush.tag = DIG_TAG
	var dig := Node.new()
	dig.name = "DigTool"
	dig.set_script(load(DIR + "components/dig_tool.gd"))
	dig.set(&"brush", brush)
	dig.set(&"hold_speed", 6.0)
	dig.set(&"min_radius", 0.5)
	dig.set(&"max_radius", 24.0)
	dig.set(&"ray_length", 2000.0)
	dig.set(&"cube_size", 5.0)
	_own(scene, dig)

	var overlay := CanvasLayer.new()
	overlay.name = "DebugOverlay"
	overlay.set_script(load(DIR + "components/debug_overlay.gd"))
	overlay.set(&"dig_tool", dig)
	_own(scene, overlay)

	_pack(scene, "castle_demo.tscn")
	scene.free()


## Rocks on the field outside the castle's plateau, mostly small, some boulders, a few
## piled against the walls.
func _scatter_rocks(scene: Node3D) -> void:
	var prefab := load(DIR + "rock.tscn") as PackedScene
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var rocks := Node3D.new()
	rocks.name = "Rocks"
	_own(scene, rocks)
	var placed: Array[Vector3] = []  # x, z, radius
	var attempts := 0
	var limit := FIELD_SIZE * 0.5 - 8.0
	while placed.size() < 40 and attempts < 5000:
		attempts += 1
		var spot := Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))
		var size := rng.randf_range(2.0, 4.5) if rng.randf() < 0.75 else rng.randf_range(6.0, 10.0)
		var radius := size * 0.55
		var away := spot.length()
		# Beside the walls (outside the towers) or out past the plateau, not in the courtyard.
		if away < 49.0 + radius or (away < FLAT_TO and rng.randf() < 0.7):
			continue
		if placed.any(func(p: Vector3) -> bool: return Vector2(p.x, p.y).distance_to(spot) < p.z + radius):
			continue
		placed.append(Vector3(spot.x, spot.y, radius))
		var rock := prefab.instantiate() as Node3D
		rock.name = "Rock%d" % placed.size()
		var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3.ONE * size)
		rock.transform = Transform3D(basis, Vector3(spot.x, field_height(spot.x, spot.y) + 0.12 * size, spot.y))
		rocks.add_child(rock)
		rock.owner = scene
	print("  %d rocks" % placed.size())


# --- Helpers -------------------------------------------------------------------------

## A plain material saved in materials/ (made the first time, kept after that so it can be
## tuned in the editor).
func _material(name: String, color: Color) -> Material:
	var path := DIR + "materials/%s.tres" % name
	if ResourceLoader.exists(path):
		return load(path)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	var err := ResourceSaver.save(material, path)
	if err != OK:
		push_error("Couldn't save %s (%s)." % [path, error_string(err)])
	material.take_over_path(path)
	return material


## One surface per tag (in tag order), shaded smooth across edges bending less than
## [param crease] degrees, the same way the adaptive pieces draw.
func _to_mesh(solid: Solid, crease: float, materials: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for entry: Array in solid.build_surfaces(crease):
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, entry[1])
		var tag: int = entry[0]
		mesh.surface_set_material(mesh.get_surface_count() - 1, materials[tag] if tag < materials.size() else null)
	return mesh


func _check_closed(solid: Solid, label: String) -> void:
	var open := solid.count_open_edges()
	if open > 0:
		push_warning("%s has %d open edges; booleans will fail on it." % [label, open])


func _save(resource: Resource, path: String) -> Resource:
	var full := DIR + path
	var err := ResourceSaver.save(resource, full, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_error("Couldn't save %s (%s)." % [full, error_string(err)])
	resource.take_over_path(full)  # so scenes refer to the file instead of embedding a copy
	return resource


func _mesh_node(node_name: String, mesh: Mesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	return node


func _add_collision(node: MeshInstance3D, shape: Shape3D) -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	node.add_child(body)
	body.owner = node
	var collider := CollisionShape3D.new()
	collider.name = "Shape"
	collider.shape = shape
	body.add_child(collider)
	collider.owner = node


## An AdaptiveMesh component under [param node], drawing what the dig tool digs or builds
## with [param cut_material] (see [constant DIG_TAG]).
func _adaptive(node: MeshInstance3D, cut_material: Material, crease: float) -> AdaptiveMesh:
	var adaptive := AdaptiveMesh.new()
	adaptive.name = "Adaptive"
	adaptive.target = node
	# This script bakes them; an editor holding an older copy of a prefab would otherwise
	# bake that copy and save it over the new bake.
	adaptive.auto_bake = false
	var drawing := PieceDrawing.new()
	var materials: Array[Material] = []
	materials.resize(DIG_TAG + 1)
	materials[DIG_TAG] = cut_material
	drawing.materials = materials
	drawing.crease_angle = crease
	adaptive.drawing = drawing
	node.add_child(adaptive)
	adaptive.owner = node
	return adaptive


func _cleanup(min_edge: float, max_error: float) -> MeshCleanup:
	var cleanup := MeshCleanup.new()
	cleanup.min_edge_length = min_edge
	cleanup.max_error = max_error
	return cleanup


# Parts that digs and cuts free come away as adaptive meshes of their own (Ground anchor:
# what still stands on the ground stays).
func _separation(min_size: float) -> MeshSeparation:
	var separation := MeshSeparation.new()
	separation.min_size = min_size
	separation.density = 2.5
	return separation


func _bake_and_pack(node: MeshInstance3D, adaptive: AdaptiveMesh, data_path: String, scene_path: String) -> void:
	# Bake first, set how it takes over after: one taking over at start would bake by itself
	# as soon as it entered the tree.
	var activation := adaptive.activation
	adaptive.activation = AdaptiveMesh.Activation.ON_FIRST_EDIT
	root.add_child(node)
	var started := Time.get_ticks_msec()
	await adaptive.bake()
	adaptive.activation = activation
	print("  baked %d pieces in %.1f s" % [adaptive.data.pieces.size(), (Time.get_ticks_msec() - started) / 1000.0])
	_save(adaptive.data, data_path)
	root.remove_child(node)
	_pack(node, scene_path)  # the pieces the bake drew have no owner, so they aren't saved
	node.free()


func _own(scene: Node, node: Node) -> void:
	scene.add_child(node)
	node.owner = scene


func _pack(node: Node, path: String) -> void:
	var packed := PackedScene.new()
	var err := packed.pack(node)
	if err != OK:
		push_error("Couldn't pack %s (%s)." % [path, error_string(err)])
		return
	err = ResourceSaver.save(packed, DIR + path)
	if err != OK:
		push_error("Couldn't save %s (%s)." % [DIR + path, error_string(err)])
