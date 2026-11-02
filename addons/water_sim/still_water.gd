@tool
@icon("icon.svg")
class_name WaterSimStillWater
extends Node3D
## Resting liquid at almost no cost: a grid of columns, each holding a volume of water on
## top of its bottom height, drawn as one surface. Lakes, ponds and rivers live here while
## nothing disturbs them. When a [WaterSim] box wakes over it, the columns inside the box
## become particles; when the box settles, they come back. Floating, raycasts and density
## queries ([method WaterSim.sample_density_at]) see it like simulated water.
##
## Bodies with a [WaterSimCollider] moving through it make waves on it (a heightfield over the
## columns, see [member waves]) without waking a box: only a splash faster than the box's
## wake speed turns it into particles.
##
## Place it at the water's level: the columns are a [member size] rectangle centred on the
## node in x and z. With [member fill_on_start] each column fills from the ground below up
## to the node's height. The grid follows the node's position only (not its rotation or
## scale).

const GROUP := &"water_sim_still_waters"

## The rectangle the water can cover (x and z), in metres.
@export var size := Vector2(10, 10):
	set(value):
		size = value.max(Vector2.ONE * 0.5)
		if is_node_ready():
			_resize()
## Column width. Match the boxes' cell size (or a multiple of it) so water goes back and
## forth without gaps.
@export_range(0.05, 4.0, 0.01, "or_greater") var cell_size := 0.25:
	set(value):
		cell_size = value
		if is_node_ready():
			_resize()
## What the water is. Boxes settle only this substance into it.
@export var substance: WaterSimSubstance
## Fill every column from the ground below (the first static surface a ray down meets,
## within [member max_depth]) up to this node's height, when the game starts. Columns whose
## top is inside something solid (a wall, a rock) stay dry.
@export var fill_on_start := true
@export var max_depth := 20.0
@export var surface_material: Material:
	set(value):
		surface_material = value
		if _view != null:
			_view.material_override = value
## Physics layers the ground is found on.
@export_flags_3d_physics var ground_mask := 1

@export_group("Waves")
## Waves on the surface from bodies moving through it (and [method disturb]). They cost
## nothing once they have died out.
@export var waves := true
## How fast waves die out (1/s).
@export_range(0.0, 10.0, 0.01) var wave_damping := 0.8
## How hard a moving body pushes the surface: the share of its speed (m/s) given to the
## water round it each second.
@export_range(0.0, 10.0, 0.01) var wave_push := 1.5

# Per column (x fastest): bottom height above this node's origin, and the volume of water
# on it (m^3; dry at 0). Volume rather than a top height, so water going into particles
# and back comes out the same amount.
var _bottoms := PackedFloat32Array()
var _volumes := PackedFloat32Array()
var _nx := 0
var _nz := 0
var _view: MeshInstance3D
var _lines: MeshInstance3D
# The columns changed (the waves and the surface follow), and the surface is to be drawn again.
var _dirty := false
var _redraw := false
var _waves: WaterSimWaves
# Where each collider's body was last tick (for its speed through the water).
var _bodies_at: Dictionary[Node3D, Vector3] = {}


func _ready() -> void:
	add_to_group(GROUP)
	_resize()
	if Engine.is_editor_hint():
		_draw_outline()
		return
	_view = MeshInstance3D.new()
	_view.material_override = surface_material
	add_child(_view, false, Node.INTERNAL_MODE_BACK)
	if fill_on_start:
		# The ground's shapes are in the physics world after the first physics frame.
		_fill_from_ground.call_deferred()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_sync()
	if _redraw:
		_redraw = false
		_rebuild_view()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not waves or _waves == null:
		return
	_sync()
	_push_from_bodies(delta)
	if _waves.is_active():
		_waves.step(delta, 9.8, wave_damping)
		_redraw = true


## Pushes the surface round a global point within radius: speed (m/s) added to its rise, most
## in the middle (negative pushes it down). For footsteps, small splashes, a spell's touch.
func disturb(point: Vector3, radius: float, speed: float) -> void:
	if _waves == null or not waves:
		return
	_sync()
	var local := point - get_grid_origin()
	_waves.disturb(local.x, local.z, radius, speed)


# The waves take the columns as they are now.
func _sync() -> void:
	if _dirty and _waves != null:
		_dirty = false
		_waves.set_columns(_bottoms, _volumes)
		_redraw = true


# Each body with a collider in the water pushes the surface down round it by how fast it moves
# (a wake behind a wading body, rings where something bobs).
func _push_from_bodies(delta: float) -> void:
	var seen: Dictionary[Node3D, Vector3] = {}
	for node in get_tree().get_nodes_in_group(WaterSimCollider.GROUP):
		var collider := node as WaterSimCollider
		var body := collider.get_body() if collider != null else null
		if body == null:
			continue
		var at := body.global_position
		seen[body] = at
		# (Over the water and within a metre of its surface: wading, bobbing, swimming.)
		if not _bodies_at.has(body) or absf(at.y - _surface_at(at)) > 1.0:
			continue
		var speed := (at - _bodies_at[body]).length() / maxf(delta, 1e-4)
		# A body in the water reaches about its own size round it; its shapes' extent is not looked up (a metre at most).
		if speed > 0.05:
			disturb(at, clampf(cell_size * 2.0, 0.3, 1.0), -minf(speed, 4.0) * wave_push * delta)
	_bodies_at = seen


# The surface's height (global y) over a global point, or -INF where there is no water.
func _surface_at(point: Vector3) -> float:
	var local := point - get_grid_origin()
	var i := floori(local.x / cell_size)
	var k := floori(local.z / cell_size)
	if i < 0 or k < 0 or i >= _nx or k >= _nz or _volumes[k * _nx + i] <= 0.0:
		return -INF
	return get_grid_origin().y + _surface(k * _nx + i)


## Column count along x and z.
func get_grid_size() -> Vector2i:
	return Vector2i(_nx, _nz)


## The global position of column (i, k)'s first corner (lowest x and z, at this node's
## height).
func get_grid_origin() -> Vector3:
	return global_position - Vector3(_nx * cell_size * 0.5, 0, _nz * cell_size * 0.5)


## Sets column (i, k) to hold water from bottom to top (above the node); top <= bottom
## dries it.
func set_column(i: int, k: int, bottom: float, top: float) -> void:
	if i < 0 or k < 0 or i >= _nx or k >= _nz:
		return
	var c := k * _nx + i
	_bottoms[c] = bottom
	_volumes[c] = maxf(top - bottom, 0.0) * cell_size * cell_size
	_dirty = true


## Whether a global point is in the water.
func has_point(point: Vector3) -> bool:
	var local := point - get_grid_origin()
	var i := floori(local.x / cell_size)
	var k := floori(local.z / cell_size)
	if i < 0 or k < 0 or i >= _nx or k >= _nz:
		return false
	var c := k * _nx + i
	return _volumes[c] > 0.0 and local.y >= _bottoms[c] and local.y <= _surface(c)


## The substance's density inside the water, 0 outside, fading over the top half column
## width like simulated water's surface (so a body floating on it doesn't jolt when its
## water turns still).
func sample_density(point: Vector3) -> float:
	var local := point - get_grid_origin()
	var i := floori(local.x / cell_size)
	var k := floori(local.z / cell_size)
	if i < 0 or k < 0 or i >= _nx or k >= _nz:
		return 0.0
	var c := k * _nx + i
	if _volumes[c] <= 0.0 or local.y < _bottoms[c]:
		return 0.0
	var fade := clampf((_surface(c) - local.y) / (cell_size * 0.5) + 0.5, 0.0, 1.0)
	return (substance.density if substance != null else 1000.0) * fade


## Where a ray first meets the water's surface (or enters it from the side), or null.
func raycast(from: Vector3, direction: Vector3, max_distance: float) -> Variant:
	var dir := direction.normalized()
	var step := cell_size * 0.5
	var t := 0.0
	while t <= max_distance:
		var p := from + dir * t
		if has_point(p):
			return p
		t += step
	return null


## Whether the columns reach into a global box.
func overlaps(box: AABB) -> bool:
	var origin := get_grid_origin()
	var mine := AABB(origin + Vector3(0, -max_depth, 0), Vector3(_nx * cell_size, max_depth * 2.0, _nz * cell_size))
	return mine.intersects(box)


## Turns the water in the columns inside a box into particles, and dries those columns.
## Returns how many particles were made.
func wake_into(sim: WaterSim) -> int:
	if substance == null:
		return 0
	var made := 0
	var origin := get_grid_origin()
	var basis := Basis()
	var particle := pow(sim.cell_size * 0.5, 3)
	# Columns rarely hold a whole number of particles: what each rounds off is carried to the
	# next, so the total comes out right.
	var carried := 0.0
	for k in _nz:
		for i in _nx:
			var c := k * _nx + i
			if _volumes[c] <= 0.0:
				continue
			var depth := _top(c) - _bottoms[c]
			# Only columns that fit inside the box (its outermost cells are walls) wake; the
			# rest stay still beside it.
			var footprint := AABB(origin + Vector3(i * cell_size, _bottoms[c], k * cell_size), Vector3(cell_size, depth, cell_size))
			if not sim.fits(footprint):
				continue
			# The column's volume in particles, from the bottom up around anything solid in
			# it, up to its surface. What a floating body or a rock in the way leaves no room
			# for is carried on to the next columns rather than stacked on top of it.
			var exact := _volumes[c] / particle + carried
			var count := roundi(exact)
			var room := depth + sim.cell_size * 0.5
			var half := Vector3(cell_size * 0.5, room * 0.5, cell_size * 0.5)
			var at := origin + Vector3((i + 0.5) * cell_size, _bottoms[c] + room * 0.5, (k + 0.5) * cell_size)
			var placed := sim.fill(WaterSim.Shape.BOX, Transform3D(basis, at), half, substance, Vector3.ZERO,
					true, count)
			made += placed
			carried = exact - placed
			_volumes[c] = 0.0
	_dirty = true
	return made


## Takes the box's particles of this water's substance that are over the columns back into
## the columns, and removes them. Returns how many particles it took.
func settle_from(sim: WaterSim) -> int:
	if substance == null or sim.get_solver() == null:
		return 0
	var solver := sim.get_solver()
	var to_grid := sim.get_solver_transform().affine_inverse() * Transform3D(Basis(), get_grid_origin())
	var mask := 1 << sim.get_substance_id(substance)
	var stats := solver.gather_columns(to_grid, cell_size, _nx, _nz, mask)
	# Particles sit half a lattice step above the water's bottom; each is a lattice step
	# cubed of water.
	var half_step := sim.cell_size * 0.25
	var particle := pow(sim.cell_size * 0.5, 3)
	var taken := 0
	for c in _nx * _nz:
		var count := int(stats[c * 3])
		if count == 0:
			continue
		taken += count
		var bottom := stats[c * 3 + 1] - half_step
		if _volumes[c] > 0.0:
			bottom = minf(bottom, _bottoms[c])
		_bottoms[c] = bottom
		_volumes[c] += count * particle
	if taken > 0:
		level_out()
		# Only particles over the grid: the rest stay in the box.
		var origin := get_grid_origin()
		var centre := origin + Vector3(_nx * cell_size * 0.5, 0, _nz * cell_size * 0.5)
		var extents := Vector3(_nx * cell_size * 0.5, max_depth, _nz * cell_size * 0.5)
		sim.remove(WaterSim.Shape.BOX, Transform3D(Basis(), centre), extents, [substance] as Array[WaterSimSubstance])
		_dirty = true
	return taken


## Levels the water: each connected body of wet columns gets one flat surface holding the
## same volume (columns whose bottom ends up above it go dry). Still water is level; this
## evens out the column-to-column scatter particles settle with.
func level_out() -> void:
	var seen := PackedByteArray()
	seen.resize(_nx * _nz)
	for start in _nx * _nz:
		if seen[start] or _volumes[start] <= 0.0:
			continue
		# The connected wet columns (sharing a side) around this one.
		var body := PackedInt32Array([start])
		seen[start] = 1
		var head := 0
		while head < body.size():
			var c := body[head]
			head += 1
			var i := c % _nx
			var k := c / _nx
			for n in [Vector2i(i - 1, k), Vector2i(i + 1, k), Vector2i(i, k - 1), Vector2i(i, k + 1)]:
				if n.x < 0 or n.y < 0 or n.x >= _nx or n.y >= _nz:
					continue
				var nc: int = n.y * _nx + n.x
				if not seen[nc] and _volumes[nc] > 0.0:
					seen[nc] = 1
					body.append(nc)
		var volume := 0.0
		var low := INF
		var high := -INF
		for c in body:
			volume += _volumes[c]
			low = minf(low, _bottoms[c])
			high = maxf(high, _top(c))
		# The level that holds the volume over these columns' bottoms.
		var area := cell_size * cell_size
		for step in 40:
			var level := (low + high) * 0.5
			var held := 0.0
			for c in body:
				held += maxf(level - _bottoms[c], 0.0) * area
			if held > volume:
				high = level
			else:
				low = level
		var level := (low + high) * 0.5
		for c in body:
			_volumes[c] = maxf(level - _bottoms[c], 0.0) * area
	_dirty = true


func _resize() -> void:
	_nx = maxi(1, ceili(size.x / cell_size))
	_nz = maxi(1, ceili(size.y / cell_size))
	if _waves == null:
		_waves = WaterSimWaves.new()
	_waves.configure(_nx, _nz, cell_size)
	_bottoms.resize(_nx * _nz)
	_volumes.resize(_nx * _nz)
	_bottoms.fill(0.0)
	_volumes.fill(0.0)
	_dirty = true
	if Engine.is_editor_hint():
		_draw_outline()


func _fill_from_ground() -> void:
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var origin := get_grid_origin()
	var point := PhysicsPointQueryParameters3D.new()
	point.collision_mask = ground_mask
	for k in _nz:
		for i in _nx:
			var top := origin + Vector3((i + 0.5) * cell_size, 0, (k + 0.5) * cell_size)
			# Dry where the water's surface would be inside something static (a wall, a rock).
			point.position = top + Vector3.DOWN * 0.01
			var inside := false
			for hit in space.intersect_point(point):
				if not (hit.collider is RigidBody3D or hit.collider is CharacterBody3D):
					inside = true
			if inside:
				continue
			var bottom := _ground_below(space, top)
			if bottom < 0.0:
				_bottoms[k * _nx + i] = bottom
				_volumes[k * _nx + i] = -bottom * cell_size * cell_size
	_dirty = true


# Height of the ground below a point, relative to it (negative), or 0 if there's none in
# reach. Moving bodies (crates) are looked through.
func _ground_below(space: PhysicsDirectSpaceState3D, from: Vector3) -> float:
	var exclude: Array[RID] = []
	for attempt in 8:
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * max_depth, ground_mask, exclude)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return 0.0
		if hit.collider is RigidBody3D or hit.collider is CharacterBody3D:
			exclude.append(hit.rid)
			continue
		return (hit.position as Vector3).y - from.y
	return 0.0


func _rebuild_view() -> void:
	if _view == null:
		return
	# A vertex a corner, at the mean surface of the wet columns around it; a quad per wet column (built natively: thousands
	# of columns, every frame while there are waves).
	var surface := _waves.build_surface(get_grid_origin() - global_position)
	var mesh := ArrayMesh.new()
	if not (surface[2] as PackedInt32Array).is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surface[0]
		arrays[Mesh.ARRAY_NORMAL] = surface[1]
		arrays[Mesh.ARRAY_INDEX] = surface[2]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_view.mesh = mesh


# Column c's top height (above the node).
func _top(c: int) -> float:
	return _bottoms[c] + _volumes[c] / (cell_size * cell_size)


# Column c's surface with its wave (above the node): what floats bodies and answers queries.
func _surface(c: int) -> float:
	return _top(c) + (_waves.get_height(c % _nx, c / _nx) if _waves != null else 0.0)


func _draw_outline() -> void:
	if not is_inside_tree():
		return
	if _lines == null:
		_lines = preload("shape_lines.gd").new()
		add_child(_lines, false, Node.INTERNAL_MODE_BACK)
	_lines.draw(WaterSim.Shape.BOX, Vector3(size.x, 0.0, size.y), Color(0.3, 0.6, 1.0))
