@tool
class_name MeshSeparation
extends Resource
## When digs and cuts divide an [AdaptiveMesh] (a cut right through, a part dug off all the
## way round), the parts that come away become adaptive meshes of their own, on
## [RigidBody3D]s: they fall, and they can be dug, cut and divided again. Give it to
## [member AdaptiveMesh.separation]; empty, or [member enabled] off, nothing is checked and
## nothing separates.
##
## A part keeps the pieces it was made of (the same chunk grid and keys, the shapes shared,
## no booleans), the mesh's settings, look and physics layers. What stays with the mesh is
## set by [member anchor]. Parts that were separate from the start (a floating island in
## the model) stay where they are.
##
## The check runs on a worker thread once the mesh is idle after edits, and only re-reads
## pieces that changed; working out the parts (seam shading, hulls, masses) does too, and
## parts are added within the frame budget.
##
## [b]Limits[/b]: parts smaller than [member min_adaptive_size] come away as plain rigid
## bodies (drawn and colliding, not editable), and at most [member max_parts] parts made
## with these settings stay adaptive at once ([member over_limit] says what happens to the
## oldest past that). A part at rest costs what its rigid body costs: nothing runs per frame.

## What stays with the mesh when it comes apart.
enum Anchor {
	## [constant GROUND] for a static mesh, [constant LARGEST] for a moving one.
	AUTO,
	## Parts reaching down to the mesh's bottom (its lowest point when it appeared, plus
	## [member anchor_margin], in its own space) stay; the rest separate. For anything
	## standing on the ground or closed off below: terrain, walls, rocks.
	GROUND,
	## The biggest part stays; the rest separate.
	LARGEST,
	## Nothing: once a static mesh is in two or more parts, they all separate (a hanging
	## rock that should come down when it breaks). A moving mesh keeps its biggest part (it's
	## moving already).
	NOTHING,
}

## Turns separating off without removing the settings.
@export var enabled := true
## What stays with the mesh.
@export var anchor := Anchor.AUTO
## [constant GROUND]: how far above the mesh's bottom a part may end and still count as
## standing on it (the mesh's units).
@export_range(0.0, 10.0, 0.001, "or_greater") var anchor_margin := 0.05
## Parts smaller than about this across (the mesh's units) are dropped instead (dust), and
## so are flakes (see [method is_flake]) of any size.
@export_range(0.0, 10.0, 0.001, "or_greater") var min_size := 0.05
## Mass per cubic unit for parts that come off a static mesh. Parts of a moving mesh keep
## its mass per volume.
@export_range(0.001, 100.0, 0.001, "or_greater") var density := 1.0
## Friction of the parts' bodies (0 slides like ice, 1 is Godot's default), so broken parts
## slide and topple off each other instead of sticking where they land. Parts of a moving
## mesh whose body has a [member RigidBody3D.physics_material_override] keep that instead.
@export_range(0.0, 1.0, 0.01) var friction := 0.3

@export_group("Limits")
## Parts smaller than about this across (the mesh's units) come away as plain rigid bodies
## instead: drawn and colliding as one hull, but not adaptive, so they cost no more than
## any rigid body. 0: every part (above [member min_size]) stays adaptive.
@export_range(0.0, 100.0, 0.001, "or_greater") var min_adaptive_size := 0.0
## At most this many adaptive parts made with these settings at once (every mesh using this
## resource counts); past that, the oldest is dealt with as [member over_limit] says. 0: no
## limit.
@export_range(0, 1000, 1, "or_greater") var max_parts := 0
## What happens to the oldest adaptive part past [member max_parts].
@export var over_limit := OverLimit.MAKE_PLAIN
## Seconds before a plain part (a small one, or one made plain past the limit) shrinks away
## and is freed. 0 keeps them.
@export_range(0.0, 600.0, 0.1, "or_greater") var plain_lifetime := 0.0

## What [member over_limit] does with the oldest adaptive part.
enum OverLimit {
	## It stays as it is, drawn and colliding, but stops being adaptive (see
	## [method AdaptiveMesh.make_plain]).
	MAKE_PLAIN,
	## It's freed, body and all.
	FREE,
}

var _parts: Array[WeakRef] = []  # adaptive parts made with these settings, oldest first
var _swept_at := 16  # how many there were after gone ones were last cleared out
var _physics_material: PhysicsMaterial  # shared by the parts, for friction


## The physics material for parts' bodies ([member friction]), shared by all of them.
func get_physics_material() -> PhysicsMaterial:
	if _physics_material == null or _physics_material.friction != friction:
		_physics_material = PhysicsMaterial.new()
		_physics_material.friction = friction
	return _physics_material


## Counts [param part] (a new adaptive part) against [member max_parts], dealing with the
## oldest past it.
func add_part(part: AdaptiveMesh) -> void:
	_parts.append(weakref(part))
	if max_parts <= 0 or _parts.size() <= max_parts:
		# Gone parts are cleared out now and then, not on every add (a dismantle adds a
		# thousand at once).
		if _parts.size() >= _swept_at * 2:
			_sweep()
		return
	_sweep()
	while _parts.size() > max_parts:
		var oldest: AdaptiveMesh = _parts.pop_front().get_ref()
		if over_limit == OverLimit.FREE:
			oldest.get_body().queue_free()
		else:
			oldest.make_plain(plain_lifetime)


# Drops parts that are gone (freed, or on their way out) from the list.
func _sweep() -> void:
	_parts = _parts.filter(func(ref: WeakRef) -> bool: return is_instance_valid(ref.get_ref()) and not (ref.get_ref() as Node).is_queued_for_deletion())
	_swept_at = maxi(_parts.size(), 16)


## The adaptive parts made with these settings that are still adaptive, oldest first.
func get_parts() -> Array[AdaptiveMesh]:
	var out: Array[AdaptiveMesh] = []
	for ref in _parts:
		var part: AdaptiveMesh = ref.get_ref()
		if is_instance_valid(part) and not part.is_queued_for_deletion():
			out.append(part)
	return out


## True if [param solid] is a flake: thinner than [param thickness] all over (a slab's
## thickness is about twice its volume over its area). Physics can't make a hull of one,
## so a flake that separates is always dropped, whatever [member min_size] is.
static func is_flake(solid: Solid, thickness: float) -> bool:
	var area := 0.0
	for t in solid.indices.size() / 3:
		var a := solid.positions[solid.indices[t * 3]]
		area += (solid.positions[solid.indices[t * 3 + 1]] - a).cross(solid.positions[solid.indices[t * 3 + 2]] - a).length()
	return solid.get_volume() * 2.0 < area * 0.5 * thickness


## The anchor rule [param anchor] stands for on a mesh that is [param moving] or not.
static func resolve(anchor: Anchor, moving: bool) -> Anchor:
	if moving:
		return Anchor.LARGEST if anchor != Anchor.GROUND else Anchor.GROUND
	return Anchor.GROUND if anchor == Anchor.AUTO else anchor


## The parts of [param solid] that don't touch, each as
## [code][part, volume, lowest y, corners on hidden (cap) faces][/code]. A part's corners on
## the walls between pieces are where it carries on in the neighbour.
static func part_infos(solid: Solid, cap: int) -> Array:
	var started := StageProfile.begin()
	var out := _part_infos_work(solid, cap)
	StageProfile.end(&"separation: islands", started)
	return out


static func _part_infos_work(solid: Solid, cap: int) -> Array:
	var out := []
	if solid.is_empty():
		return out
	for part in _with_hollows(solid.get_islands()):
		if NativeKernel.on():
			var info: Array = ClassDB.class_call_static(NativeKernel.CLASS, &"part_info", part.positions, part.indices,
					part.tags, cap)
			out.append([part, info[0], info[1], info[2]])
			continue
		var lowest := INF
		for p in part.positions:
			lowest = minf(lowest, p.y)
		var walls := PackedVector3Array()
		var seen := {}
		for t in part.tags.size():
			if part.tags[t] != cap:
				continue
			for c in 3:
				var v := part.indices[t * 3 + c]
				if not seen.has(v):
					seen[v] = true
					walls.append(part.positions[v])
		out.append([part, part.get_volume(), lowest, walls])
	return out


# [param islands] with every hollow (an island enclosing negative volume: the inside of a
# dig that didn't break the surface) joined to the island around it: a hollow is part of
# what surrounds it, not a part of its own.
static func _with_hollows(islands: Array[Solid]) -> Array[Solid]:
	if islands.size() < 2:
		return islands
	var shells: Array[Solid] = []
	var hollows: Array[Solid] = []
	for island in islands:
		(shells if island.get_volume() > 0.0 else hollows).append(island)
	if hollows.is_empty():
		return islands
	var joined := {}  # shell index -> its hollows
	var out: Array[Solid] = []
	for hollow in hollows:
		var around := -1
		for i in shells.size():
			if shells[i].get_aabb().grow(1e-4).encloses(hollow.get_aabb()) and shells[i].encloses(hollow.positions[0]):
				around = i
				break
		if around < 0:
			out.append(hollow)  # not inside anything here: leave it be
			continue
		if not joined.has(around):
			joined[around] = []
		(joined[around] as Array).append(hollow)
	for i in shells.size():
		if not joined.has(i):
			out.append(shells[i])
			continue
		var together: Array[Solid] = [shells[i]]
		together.append_array(joined[i])
		out.append(merge_solids(together))
	return out


## A worker job finding the mesh's parts (pieces' parts joined across the walls between
## them by shared corners, within [param snap]) and which separate under [param anchor]
## (already resolved). Plain values in, plain values out. With [param first], nothing
## separates: the parts that would are noted as separate from the start. Returns
## {cache, ground, authored, separating: [[[key, part index]...], the part's solids]...]}
## (merge each part's solids with [method merge_solids]; left to the caller, which can do
## it for many parts at once).
static func find_parts_job(solids: Dictionary, cache: Dictionary, dirty: Dictionary, cap: int, snap: float,
		anchor: Anchor, ground: float, margin: float, authored: Dictionary, first: bool) -> Callable:
	return func() -> Dictionary:
		var out_cache := {}
		var places := []  # [key, part index] per part
		var infos := []
		for key: Vector4i in solids:
			var entry: Array = cache.get(key, [])
			if entry.is_empty() or not is_same(entry[0], solids[key]):
				entry = [solids[key], MeshSeparation.part_infos(solids[key], cap)]
			out_cache[key] = entry
			for i in (entry[1] as Array).size():
				places.append([key, i])
				infos.append(entry[1][i])
		if is_nan(ground):
			ground = INF
			for info: Array in infos:
				ground = minf(ground, info[2])
		# Join parts that share a corner on a wall (within a snap or so): a group number
		# per part.
		var group_of := PackedInt32Array()
		if NativeKernel.on():
			var corner_sets := []
			for info: Array in infos:
				corner_sets.append(info[3])
			group_of = ClassDB.class_call_static(NativeKernel.CLASS, &"join_parts", corner_sets, snap)
		else:
			var parent := range(places.size())
			var root := func(i: int) -> int:
				while parent[i] != i:
					parent[i] = parent[parent[i]]
					i = parent[i]
				return i
			var grid := {}
			for i in places.size():
				for p: Vector3 in infos[i][3]:
					var home := Vector3i((p / snap).round())
					for o in 27:
						var other: int = grid.get(home + Vector3i(o % 3 - 1, (o / 3) % 3 - 1, o / 9 - 1), -1)
						if other >= 0:
							var a: int = root.call(i)
							var b: int = root.call(other)
							if a != b:
								parent[b] = a
					if not grid.has(home):
						grid[home] = i
			group_of.resize(places.size())
			for i in places.size():
				group_of[i] = root.call(i)
		var groups := {}  # group -> part indices
		for i in places.size():
			var r: int = group_of[i]
			if not groups.has(r):
				groups[r] = []
			(groups[r] as Array).append(i)
		var largest := -1
		var largest_volume := -INF
		for r: int in groups:
			var volume := 0.0
			for i: int in groups[r]:
				volume += infos[i][1]
			if volume > largest_volume:
				largest_volume = volume
				largest = r
		var new_authored := {}
		var separating := []
		for r: int in groups:
			var members: Array = groups[r]
			var stays := false
			match anchor:
				Anchor.GROUND:
					for i: int in members:
						stays = stays or infos[i][2] <= ground + margin
				Anchor.LARGEST:
					stays = r == largest
				Anchor.NOTHING:
					stays = groups.size() < 2
			if stays:
				continue
			if first:
				# Separate from the start: note some corners, so it's known later.
				for i: int in members:
					var corners: PackedVector3Array = (infos[i][0] as Solid).positions
					for k in mini(corners.size(), 16):
						new_authored[Vector3i((corners[k * corners.size() / mini(corners.size(), 16)] / snap).round())] = true
				continue
			var touched := false
			var was_separate := false
			for i: int in members:
				touched = touched or dirty.has(places[i][0])
				for corner in (infos[i][0] as Solid).positions:
					if authored.has(Vector3i((corner / snap).round())):
						was_separate = true
						break
			if not touched or was_separate:
				continue
			var parts: Array[Solid] = []
			var where := []
			for i: int in members:
				parts.append(infos[i][0])
				where.append(places[i])
			separating.append([where, parts])
		return {cache = out_cache, ground = ground, authored = new_authored, separating = separating}


## [param parts] as one solid (UVs only if they all have them).
static func merge_solids(parts: Array[Solid]) -> Solid:
	var started := StageProfile.begin()
	var out := _merge_solids_work(parts)
	StageProfile.end(&"merging", started)
	return out


static func _merge_solids_work(parts: Array[Solid]) -> Solid:
	if parts.size() == 1:
		return parts[0]
	if NativeKernel.on():
		var arrays := []
		for part in parts:
			arrays.append([part.positions, part.indices, part.tags, part.uvs])
		return NativeKernel.to_solid(ClassDB.class_call_static(NativeKernel.CLASS, &"merge", arrays))
	var out := Solid.new()
	var has_uv := parts.all(func(part: Solid) -> bool: return part.uvs.size() == part.positions.size())
	for part in parts:
		var base := out.positions.size()
		out.positions.append_array(part.positions)
		if has_uv:
			out.uvs.append_array(part.uvs)
		for i in part.indices:
			out.indices.append(base + i)
		out.tags.append_array(part.tags)
	return out
