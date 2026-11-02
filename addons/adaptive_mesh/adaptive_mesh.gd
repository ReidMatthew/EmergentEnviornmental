@tool
@icon("icon.svg")
class_name AdaptiveMesh
extends Node3D
## A mesh you can dig into and add to at runtime, with booleans. Untouched parts keep their
## exact triangles; new triangles only appear where a shape cut or joined the surface, at
## the shape's own density. The same node serves a rock or a whole terrain:
##
## - [member source] says what to start from ([MeshSource], [SceneSource]).
## - [member chunking] says whether to cut it into pieces, so an edit only works on the
##   pieces it touches. Empty is one piece (props); [GridChunking] for anything big.
##   Pieces that grow past [member Chunking.split_above] triangles are split in smaller
##   cells, so places edited over and over stay fast.
## - [member data] holds the result: the pieces' shapes and ready-to-draw meshes. It is
##   made by [method bake] (on its own when the node is ready and has no data), kept up to
##   date by edits, and can be saved and loaded so baking is skipped.
## - [member backend], [member cleanup], [member drawing] and [member collision] set how
##   pieces are edited, tidied, drawn and collided with; [member main_thread_budget_ms] how
##   much of each frame booleans may take.
## - [member separation] (optional) turns parts that digs and cuts divide off into adaptive
##   meshes of their own, on [RigidBody3D]s; [member debris] (optional) breaks what digs
##   remove into fragments that fall as plain rigid bodies.
##
## [b]As a component[/b] it makes an existing mesh adaptive: put it under a [MeshInstance3D]
## (with no [member source]), or point [member target] at any node with meshes under it.
## The target keeps drawing and colliding as authored until something edits it (or the game
## starts, see [member activation]); then its meshes are hidden, its collision is switched
## off, and this node's pieces take over with the same look and physics layers. Untouched
## objects cost nothing extra. [method find] tells which adaptive mesh a ray hit, whether it
## has taken over yet or not.
##
## [b]Moving[/b]: under a [RigidBody3D] (at any depth: a component on the body's mesh, or a
## node of its own under the body), the mesh moves with it. Its pieces collide as convex
## hulls on that body instead of as static trimeshes (taking over replaces the body's own
## shapes, as for a static target), the body's mass follows the volume as it's dug or
## built on (starting from the mass it has), and its centre of mass follows the shape.
## Edits are placed in the mesh's own space when they're made, so a cut lands where it was
## aimed even if the body moves before it's applied.
##
## In the editor it bakes by itself ([member auto_bake]): when it's added without data, and
## again a second after its target's meshes, source, chunking or bounds change. It saves
## the result next to the mesh or model ([method get_data_path]), so the game starts
## without baking. With auto-bake off, the plugin's Bake button does it; without saved
## data, the node bakes when the game starts (a component: on its first edit).
##
## [codeblock]
## var sphere := SolidSphere.new()
## sphere.radius = 2.0
## $AdaptiveMesh.edit(sphere, Transform3D(Basis(), hit_position), BooleanOp.Operation.SUBTRACT)
## [/codeblock]

## Emitted when every piece has finished its edits.
signal edited
## Emitted when a component takes over its target (see [method activate]).
signal activated
## Emitted after one piece's batch of edits is drawn. [param key] is its key in
## [member AdaptiveMeshData.pieces].
signal piece_edited(key: Vector4i)
## Emitted when [method bake] has finished and the pieces are in place.
signal baked
## Emitted when a moving mesh has nothing left (everything dug away, or only flakes too
## thin to collide). A part this mesh separated frees its body then; on a body of your own,
## the body is frozen, so it doesn't fall away with nothing to collide with.
signal emptied
## Emitted when a dig's fragments are in the scene (see [member debris]).
signal debris_spawned(bodies: Array[RigidBody3D])
## Emitted when parts digs and cuts divided off have left the mesh: [param parts] as adaptive
## meshes of their own, each on a [RigidBody3D], and [param plain] as plain rigid bodies
## (smaller than [member MeshSeparation.min_adaptive_size]). See [member separation].
signal separated(parts: Array[AdaptiveMesh], plain: Array[RigidBody3D])

## What the pieces are made of. In the editor it's baked and saved by itself (see
## [member auto_bake]); empty in a running game, the node bakes it from its source. Edits
## update it: save it to keep them. Nodes sharing one data resource each switch to their
## own copy on their first edit. Assigning it shows the pieces it holds.
@export var data: AdaptiveMeshData:
	set(value):
		data = value
		_owns_data = false
		if not _baking:
			_assigned_data = value  # what reset() goes back to
		if is_node_ready() and not _baking:
			_spawn_pieces()
		update_configuration_warnings()
## What to bake from. Changing it bakes again (losing edits).
@export var source: SolidSource:
	set(value):
		source = value
		if is_node_ready() and not Engine.is_editor_hint():
			bake()
		update_configuration_warnings()
## How to cut the mesh into pieces. Empty: one piece. Changing it bakes again (losing
## edits).
@export var chunking: Chunking:
	set(value):
		chunking = value
		if is_node_ready() and not Engine.is_editor_hint():
			bake()
## Where the mesh may exist, in this node's space: unions never build outside it (and with
## chunking, pieces are only made inside it). Empty: no limit.
@export var max_bounds := AABB()
## Editor only: bake and save [member data] by itself when there's none, and again about a
## second after what it's baked from changes (the target's meshes, the source, chunking,
## bounds). Turn it off for very big meshes and use the Bake button instead.
@export var auto_bake := true
## Runs the booleans. Empty uses the default (see [method get_default_backend]): the
## Manifold backend if the adaptive_mesh_native add-on is installed and its library loads
## here, otherwise Godot's CSG nodes.
@export var backend: BooleanBackend
## Tidies the triangles each edit made (short edges, slivers). Empty skips it.
@export var cleanup: MeshCleanup
## Materials and shading. Empty uses the defaults.
@export var drawing: PieceDrawing
## Physics. Empty uses the defaults (collision on).
@export var collision: PieceCollision
## Breaks what each dig removes into fragments that fall as plain rigid bodies. Empty (or
## [member MeshDebris.enabled] off): no debris, at no cost.
@export var debris: MeshDebris:
	set(value):
		debris = value
		for piece: AdaptivePiece in _pieces.values():
			piece.debris = value
## When digs and cuts divide the mesh, the parts that come away become adaptive meshes of
## their own on [RigidBody3D]s (see [MeshSeparation]). Empty (or its
## [member MeshSeparation.enabled] off): nothing is checked, at no cost.
@export var separation: MeshSeparation
## Main-thread time per frame for booleans (milliseconds). It counts against one tally
## shared by every adaptive mesh (see [FrameBudget]): this mesh's booleans wait while the
## frame's total, all meshes included, is over it. An edit reaching more pieces than fit
## spreads over the next frames instead of stalling one, and so do many meshes edited at
## once. The first boolean of a frame always runs. 0: no limit. Only backends that need the
## main thread use it (the CSG one does).
@export_range(0.0, 33.0, 0.1, "or_greater") var main_thread_budget_ms := 4.0:
	set(value):
		main_thread_budget_ms = value
		if _frame_budget != null:
			_frame_budget.budget_ms = value
@export_group("Component")
## The node (and the meshes under it) this mesh makes adaptive. Added under a
## [MeshInstance3D] in the editor, it's set to that parent by itself. Empty (a node made in
## code): the parent, if it's a [MeshInstance3D] and [member source] is empty or a
## [NodeSource]. Its meshes are read with
## the [NodeSource] in [member source] if there is one (for its repair settings, such as
## closing an open terrain sheet), or with the defaults. Put this node exactly on it (as a child with no offset; anywhere else it moves
## there when the game starts).
@export var target: Node3D:
	set(value):
		target = value
		_node_source = null
		update_configuration_warnings()
## When a component takes over its target. On the first edit, untouched objects cost
## nothing; but if the target's own collision is simpler than its mesh (a box or hull on a
## rock), collision becomes exact at that moment. At start takes over right away, so it
## never switches mid-game.
@export var activation := Activation.ON_FIRST_EDIT

enum Activation { ON_FIRST_EDIT, AT_START }

## [method dismantle]'s default gap between cubes, as a fraction of the cube size.
const DISMANTLE_GAP := 0.05

## Every adaptive mesh in a running game is in this group.
const GROUP := &"adaptive_meshes"

# Collision objects of components' targets (instance id -> the component), for find().
# Kept here rather than in metadata so it's never saved with a scene.
static var _owners := {}

var _pieces := {}  # Vector4i -> AdaptivePiece
# Vector4i -> {neighbour key -> the piece's visible triangles touching that neighbour's
# cell}: what each neighbour needs to shade its side of the seam.
var _borders := {}
var _pending: Array = []  # [solid, global transform, operation] queued while baking
var _splitting := {}  # Vector4i -> [solid, local transform, operation] queued while it splits
# Vector4i -> points on the piece's walls that a split neighbour added, to insert into its
# edges once it's idle (so the seam has no T-junctions).
var _seam_points := {}
var _triangle_counts := {}  # Vector4i -> visible triangles, until the piece changes
var _piece_boxes := {}  # Vector4i -> [solid, its AABB], for get_aabb()
var _baking := false
var _bake_pending := false  # bake() called deferred from _ready, not started yet
var _owns_data := false
var _auto_baking := false  # editor: an auto-bake is running
var _auto_poll := 0.0  # editor: seconds since the last check for changes
var _settling := ""  # editor: a new fingerprint seen once, waiting to stay the same
var _open_edges := 0  # open edges of what the last bake read (booleans fail on them)
var _assigned_data: AdaptiveMeshData  # data set from outside (saved), not baked here
var _idle_check_queued := false
# Edits (or pieces removed) since [signal edited] last fired: going idle after a redraw
# alone (a neighbour's seam shading, follow-up hulls) isn't an edit.
var _edits_unreported := false
var _default_backend: BooleanBackend
# The class meshes without a backend use (see get_default_backend()), found once.
static var _default_backend_script: Script
# Settings used when none are set: read only, so one copy for every mesh (a thousand parts
# don't each make their own).
static var _default_drawing := PieceDrawing.new()
static var _default_collision := PieceCollision.new()
var _frame_budget: FrameBudget  # made when first needed (see _budget)
var _active := false  # pieces shown (always, unless a component that hasn't taken over)
var _node_source: NodeSource
var _taken: Array = []  # [object, property, value before taking over]
var _target_collision: PieceCollision  # the target's physics layers, for the pieces
var _render_settings := {}  # the target's look, for the pieces' MeshInstance3Ds
var _claimed: Array[int] = []  # this component's entries in _owners
var _unsplittable := {}  # Vector4i -> true: pieces that can't be split cleanly (not saved)
var _group_task := -1  # the baking job running now, if any
var _debris: Array[RigidBody3D] = []  # fragments in the scene, oldest first
var _moving: RigidBody3D  # moving mode: the body the pieces put their hulls on
var _mass_per_volume := 0.0  # moving mode: the body's mass over the volume it started with
var _piece_mass := {}  # Vector4i -> [solid, volume, volume x centre], for the body's mass
# A separated part, until its pieces appear: what was worked out for them on a worker
# ({borders, hulls, masses}, by key).
var _prepared := {}
var _spawned_part := false  # a separated part: its settings set when it was made
var _owns_body := false  # a separated part: this mesh made its body, and frees it when emptied
# Separation (only used with a separation setting on):
var _sep_cache := {}  # Vector4i -> [solid, its parts (MeshSeparation.part_infos)], last check
var _sep_dirty := {}  # Vector4i -> true: pieces edited since the last check
var _sep_checking := false
var _sep_ready := false  # the first check (what's separate from the start) is done
var _sep_ground := NAN  # the mesh's bottom when the first check ran
var _sep_authored := {}  # snapped corners of parts that were separate from the start
var _sep_round := 0  # bumped when the pieces are replaced: a check in flight is stale


func _notification(what: int) -> void:
	# Added under a mesh in the editor: target it explicitly, so the inspector shows it.
	if what == NOTIFICATION_PARENTED and Engine.is_editor_hint() and target == null \
			and (source == null or source is NodeSource) and get_parent() is MeshInstance3D:
		target = get_parent()
	# Jobs still running read this node: let them finish before the node goes away (and
	# before a game quits: see WorkerJobs).
	if what == NOTIFICATION_PREDELETE:
		if _group_task >= 0:
			WorkerThreadPool.wait_for_group_task_completion(_group_task)
			_group_task = -1
		WorkerJobs.finish(self)


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	# So find() knows the target and its collision before the takeover, and the body a
	# moving mesh's pieces collide as.
	var claimed: Array[Node] = []
	if is_component():
		claimed.append(get_target())
		var bodies: Array[CollisionObject3D] = []
		_target_bodies(get_target(), bodies)
		claimed.append_array(bodies)
	if get_body() != null:
		claimed.append(get_body())  # rays hit the moving body, not the pieces
	for node in claimed:
		var id := node.get_instance_id()
		var current: Object = _owners.get(id)
		if current == null or not is_instance_valid(current):  # the first component keeps it
			_owners[id] = self
			_claimed.append(id)


func _exit_tree() -> void:
	for id in _claimed:
		if _owners.get(id) == self:
			_owners.erase(id)
	_claimed.clear()


func _ready() -> void:
	set_process(Engine.is_editor_hint())  # only the editor's auto-bake uses _process
	if is_component():
		if not _spawned_part:  # (a part's settings come from the mesh it came off)
			_read_target()
		if Engine.is_editor_hint():
			return  # the target shows itself
		if target != null and target != get_parent():
			global_transform = target.global_transform
		if activation == Activation.AT_START:
			activate()
		return
	_active = true
	if data != null and data.is_baked():
		_spawn_pieces(_prepared.get(&"borders", {}))
	elif source != null and not Engine.is_editor_hint():
		# Deferred: booleans add nodes to the tree, which fails while a scene is still
		# adding its children. Edits until then queue as they do while baking.
		_bake_pending = true
		_start_bake.call_deferred()


# Only real problems; notes (such as the collision switch) are in the inspector. With
# auto-bake on, missing or stale data isn't a problem: it's on its way.
func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var baked := data != null and data.is_baked()
	if is_component():
		if _node_source_for(get_target()).get_mesh_instances().is_empty():
			out.append("The target has no MeshInstance3D to take over.")
		if get_target() == get_parent() and not transform.is_equal_approx(Transform3D.IDENTITY):
			out.append("Sits off its target: keep this node's transform at zero, or its pieces won't line up with the mesh they replace.")
	elif source == null and not baked:
		out.append("Set a source (or baked data), or put this node under a MeshInstance3D (or set a target) to make that mesh adaptive.")
	if _open_edges > 0:
		out.append("The mesh isn't closed (%d open edges), so digging and building fail on it. Close it in your modelling tool, or use a NodeSource's repair settings." % _open_edges)
	if not auto_bake and get_bake_source() != null:
		if not baked:
			out.append("No baked data (auto-bake is off): it's baked %s. Press Bake in the inspector to save it." % [
					"on the first edit" if is_component() else "every time the game starts"])
		elif not data.fingerprint.is_empty() and data.fingerprint != get_bake_fingerprint():
			out.append("The baked data is out of date (auto-bake is off): the source, chunking or bounds changed since it was baked. Press Bake again.")
	return out


## A note for the inspector, not a problem: the target's own collision is simpler than its
## mesh (a box or hull), so collision becomes exact when the first edit takes over. Empty
## when that doesn't apply.
func get_collision_note() -> String:
	if is_component() and activation == Activation.ON_FIRST_EDIT and _has_simplified_collision(get_target()):
		return "Its own collision is simpler than its mesh, so collision becomes exact when the first edit takes over. Set Activation to At Start if that switch would show."
	return ""


## What the bake reads, in words, for the inspector: the target and its meshes, and
## whether the settings are the defaults or a [NodeSource]'s; or the source.
func get_reads_description() -> String:
	if is_component():
		var target_node := get_target()
		var meshes := _node_source_for(target_node).get_mesh_instances().size()
		return "%s (%d mesh%s), %s" % [target_node.name, meshes, "" if meshes == 1 else "es",
				"with the source's repair settings" if source is NodeSource else "default settings"]
	if source == null:
		return "nothing yet"
	var kind: String = source.get_script().get_global_name()
	var scene_source := source as SceneSource
	var mesh_source := source as MeshSource
	if scene_source != null and scene_source.scene != null:
		return "%s (%s)" % [kind, scene_source.scene.resource_path.get_file()]
	if mesh_source != null and mesh_source.mesh != null and not mesh_source.mesh.resource_path.is_empty():
		return "%s (%s)" % [kind, mesh_source.mesh.resource_path.get_slice("::", 0).get_file()]
	return kind


## How the pieces collide, in words, for the inspector: off, the [member collision]
## settings, the layers copied from the target's collision, or the defaults.
func get_collision_description() -> String:
	if collision != null:
		if not collision.enabled:
			return "off"
		return "its own settings (layer %d, mask %d)" % [collision.layer, collision.mask]
	if is_component():
		var bodies: Array[CollisionObject3D] = []
		_target_bodies(get_target(), bodies)
		if not bodies.is_empty():
			return "copies %s (layer %d, mask %d)" % [get_target().get_path_to(bodies[0]) if get_target() != bodies[0]
					else bodies[0].name, bodies[0].collision_layer, bodies[0].collision_mask]
	return "default (layer 1, mask 1)"


## True while the editor's auto-bake is baking.
func is_auto_baking() -> bool:
	return _auto_baking


## Where baked data is saved: the file [member data] is in, if it has one; otherwise
## [code]<mesh>.adaptive.res[/code] next to the mesh or model it's baked from (next to the
## scene for a mesh made inside it). A file there baked from something else gets a numbered
## name instead. Empty when there's nowhere yet (an unsaved scene).
func get_data_path() -> String:
	if data != null and not data.resource_path.is_empty() and not data.resource_path.contains("::"):
		return data.resource_path
	var from := ""
	var source_now := get_bake_source()
	if source_now is NodeSource:
		var meshes := (source_now as NodeSource).get_mesh_instances()
		if not meshes.is_empty():
			from = meshes[0].mesh.resource_path.get_slice("::", 0)
		if from.is_empty() and get_target() != null:
			from = get_target().scene_file_path
	elif source_now is SceneSource and (source_now as SceneSource).scene != null:
		from = (source_now as SceneSource).scene.resource_path
	elif source_now is MeshSource and (source_now as MeshSource).mesh != null:
		from = (source_now as MeshSource).mesh.resource_path.get_slice("::", 0)
	if from.is_empty():
		var tree := get_tree()
		var scene := tree.edited_scene_root if tree != null else null
		if scene == null:
			scene = owner
		from = scene.scene_file_path if scene != null else ""
	if from.is_empty():
		return ""
	var base := from.get_base_dir().path_join(from.get_file().get_basename())
	var fingerprint := get_bake_fingerprint()
	var n := 1
	while true:
		var path := "%s%s.adaptive.res" % [base, "" if n == 1 else "_%d" % n]
		if not FileAccess.file_exists(path):
			return path
		var existing := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as AdaptiveMeshData
		if existing != null and existing.fingerprint == fingerprint:
			return path  # already baked from the same thing: share it
		n += 1
	return ""


# Editor: watches what the data is baked from, and bakes again once a change has settled.
func _process(delta: float) -> void:
	if not Engine.is_editor_hint() or not auto_bake or _baking or _auto_baking or not is_inside_tree():
		return
	_auto_poll += delta
	if _auto_poll < 1.0:
		return
	_auto_poll = 0.0
	if get_bake_source() == null:
		return
	var fingerprint := get_bake_fingerprint()
	if data != null and data.is_baked() and data.fingerprint == fingerprint:
		_settling = ""
		return
	if fingerprint != _settling:
		_settling = fingerprint  # changed (or first seen): wait a second for it to settle
		return
	_settling = ""
	_auto_bake()


# Editor: bakes, saves next to the mesh (or reuses a matching file there) and points
# [member data] at the file.
func _auto_bake() -> void:
	_auto_baking = true
	update_configuration_warnings()
	var path := get_data_path()
	var had := data.resource_path if data != null else ""
	var existing := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as AdaptiveMeshData \
			if not path.is_empty() and FileAccess.file_exists(path) else null
	if existing != null and existing.fingerprint == get_bake_fingerprint():
		_use_saved(existing, had)  # baked already (another copy of the same mesh)
		_auto_baking = false
		return
	await bake()
	if not is_inside_tree():
		_auto_baking = false
		return
	if not path.is_empty():
		var error := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
		if error == OK:
			var editor := _editor()
			if editor != null:
				editor.get_resource_filesystem().update_file(path)
			_use_saved(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as AdaptiveMeshData, had)
		else:
			push_warning("AdaptiveMesh: couldn't save the baked data to %s (%s); it stays in the scene." % [path, error_string(error)])
			_mark_scene_unsaved()
	else:
		_mark_scene_unsaved()  # no file yet: the scene keeps it until it's saved
	_auto_baking = false
	update_configuration_warnings()


func _use_saved(saved: AdaptiveMeshData, had: String) -> void:
	_baking = true  # quiet: the pieces (if shown) are already this data's
	data = saved
	_baking = false
	_assigned_data = saved
	if saved.resource_path != had:
		_mark_scene_unsaved()  # the scene now points at a different file
	update_configuration_warnings()


static func _mark_scene_unsaved() -> void:
	var editor := _editor()
	if editor != null:
		editor.mark_scene_as_unsaved()


# The editor's EditorInterface, or null in a running game (looked up by name, so this
# script also runs where the class doesn't exist).
static func _editor() -> Object:
	if not Engine.is_editor_hint() or not Engine.has_singleton(&"EditorInterface"):
		return null
	return Engine.get_singleton(&"EditorInterface")


## The node this mesh makes adaptive as a component, or null when it isn't one (see
## [member target]).
func get_target() -> Node3D:
	if target != null:
		return target
	if source == null or source is NodeSource:
		return get_parent() as MeshInstance3D
	return null


## Turns this moving mesh into a plain one: its pieces' drawn meshes and hulls stay on its
## body, but it can't be edited any more and costs no more than any rigid body. Frees this
## node. With [param lifetime] above 0, the body shrinks away and is freed after that many
## seconds. Does nothing on a static mesh. (A separated part's limit,
## [member MeshSeparation.max_parts], uses it.)
func make_plain(lifetime: float = 0.0) -> void:
	var body := get_body()
	if body == null or is_queued_for_deletion():
		return
	if not _active:
		# A part not edited yet is a plain body already (its drawn meshes and hulls): only
		# this node goes.
		queue_free()
		if lifetime > 0.0:
			_expire(body, lifetime)
		return
	if _moving == null:
		return
	if is_component() and _owns_body:
		# A part edited since it came away: what it showed before (hidden now) goes, and so
		# do the hulls it collided as then (switched off now).
		var shown := get_target()
		for view in shown.find_children("*", "MeshInstance3D", false, false):
			view.queue_free()
		if shown is MeshInstance3D:
			shown.queue_free()  # (a part's own view; this node is under it, and goes too)
		for entry: Array in _taken:
			if entry[0] is CollisionShape3D and is_instance_valid(entry[0]):
				(entry[0] as Node).queue_free()
		_taken.clear()
	var materials := _resolved_materials()
	for piece: AdaptivePiece in _pieces.values():
		var mesh := piece.get_mesh()
		if mesh != null:
			var view := MeshInstance3D.new()
			view.mesh = mesh
			for property: StringName in _render_settings:
				view.set(property, _render_settings[property])
			if view.layers == 0:
				view.layers = 1
			AdaptivePiece.set_materials(view, materials)
			body.add_child(view)
			view.global_transform = global_transform
		for hull in piece.get_collision_shapes():
			var shape := CollisionShape3D.new()
			shape.shape = hull
			body.add_child(shape)
			shape.global_transform = global_transform
	queue_free()
	if lifetime > 0.0:
		_expire(body, lifetime)


## The [RigidBody3D] this mesh moves with (the nearest one above it), or null for a static
## mesh. See "Moving" in the class description.
func get_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


## True when this mesh moves with a [RigidBody3D] (see [method get_body]).
func is_moving() -> bool:
	return get_body() != null


## True when this mesh makes another node adaptive (see [member target]).
func is_component() -> bool:
	return get_target() != null


## False for a component that hasn't taken over its target yet.
func is_active() -> bool:
	return _active


## What [method bake] reads: [member source], or the target's meshes for a component.
func get_bake_source() -> SolidSource:
	if source != null and not source is NodeSource:
		return source
	var node := get_target()
	return _node_source_for(node) if node != null else null


## Identifies what a bake would be made from (source, chunking, bounds); stored in
## [member AdaptiveMeshData.fingerprint].
func get_bake_fingerprint() -> String:
	var from := get_bake_source()
	if from == null:
		return ""
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	SolidSource.hash_bytes(hashing, from.get_fingerprint().to_utf8_buffer())
	if chunking != null:
		SolidSource.hash_object(hashing, chunking, 0)
	SolidSource.hash_bytes(hashing, var_to_bytes(max_bounds))
	return hashing.finish().hex_encode()


## Component: takes over the target now (normally the first edit does): its meshes are
## hidden, its collision is switched off, and this mesh's pieces show in their place. Bakes
## first if there's no baked data. Does nothing if already active, or in the editor.
func activate() -> void:
	if _active or Engine.is_editor_hint() or not is_inside_tree():
		return
	_active = true
	if data != null and data.is_baked():
		_spawn_pieces()
		_take_over()
	elif not _baking and not _bake_pending:
		bake()  # takes over when it's done


## The adaptive mesh [param object] belongs to (a collision body a ray hit, a piece, the
## mesh a component targets, or anything under them), or null if none.
static func find(object: Object) -> AdaptiveMesh:
	var node := object as Node
	while node != null:
		if node is AdaptiveMesh:
			return node
		var owner_mesh: AdaptiveMesh = _owners.get(node.get_instance_id())
		if owner_mesh != null and is_instance_valid(owner_mesh):
			return owner_mesh
		node = node.get_parent()
	return null


## Every adaptive mesh in [param tree] (see [constant GROUP]).
static func get_all(tree: SceneTree) -> Array[AdaptiveMesh]:
	var out: Array[AdaptiveMesh] = []
	for node in tree.get_nodes_in_group(GROUP):
		out.append(node)
	return out


func _start_bake() -> void:
	_bake_pending = false
	bake()


## Queues [param shape] at [param shape_transform] (global space) with [param operation]
## on every piece it reaches.
func edit(shape: SolidShape, shape_transform: Transform3D, operation: BooleanOp.Operation) -> void:
	edit_solid(shape.get_solid(), shape_transform, operation)


## Like [method edit], but with a solid instead of a shape. With [param debris] off, what a
## subtract removes is discarded, never debris (as for [method cut]).
func edit_solid(shape: Solid, shape_transform: Transform3D, operation: BooleanOp.Operation, debris: bool = true) -> void:
	if not _active and is_component() and not Engine.is_editor_hint():
		activate()
	if _baking or _bake_pending:
		_pending.append([shape, shape_transform, operation, debris])
		return
	if data == null:
		return
	_own_data()
	var local := global_transform.affine_inverse() * shape_transform
	_route(shape, local, operation, data.keys_overlapping((local * shape.get_aabb()).grow(1e-4)), debris)


## Cuts a slit into the mesh: subtracts a slab [param thickness] thick that runs from
## [param from] to [param to] (global; the line the cut starts along, on or just outside
## the surface) and reaches [param depth] in [param direction] (into the mesh). Deep enough
## to come out the other side, it divides the mesh in two (with
## [member separation], the part that's cut off becomes a mesh of its own); shallower, it's a
## notch.
##
## [param thickness] 0 uses [method get_cut_thickness]; anything thinner than
## [method get_min_cut_thickness] is raised to it, since booleans get unreliable when a
## cut is much thinner than the object. Does nothing if [param direction] runs along the
## line. The faces the cut makes get [param tag] (drawn with that slot of
## [member PieceDrawing.materials]; give it the tag your digs use, for the same cut look).
func cut(from: Vector3, to: Vector3, direction: Vector3, depth: float, thickness: float = 0.0, tag: int = 1) -> void:
	var slab := get_cut_slab(from, to, direction, depth, thickness, tag)
	if not slab.is_empty():
		edit_solid((slab[0] as SolidShape).get_solid(), slab[1], BooleanOp.Operation.SUBTRACT, false)


## Cuts the whole mesh into cubes [param cube_size] across (world units): a cut (see
## [method cut]) on every plane [param cube_size] apart along each of the mesh's own axes,
## through its whole box ([method get_aabb]), all in one batch. The grid is centred on the
## box, so the cubes at the edges are the same size on both sides. With [member separation],
## the cubes come apart as meshes of their own (the anchor rules still apply: on the
## Ground anchor, the bottom layer stays). [param thickness] is the gap the cuts take out
## between cubes (world units); 0 uses [constant DISMANTLE_GAP] of [param cube_size], so the
## cuts show. Never thinner than [method get_min_cut_thickness]. The faces the cuts make
## get [param tag] (as for [method cut]). Returns how many cuts it made (none if the mesh is
## no bigger than one cube).
func dismantle(cube_size: float, thickness: float = 0.0, tag: int = 1) -> int:
	var box := get_aabb()
	if cube_size <= 0.0 or not box.has_volume():
		return 0
	thickness = maxf(thickness if thickness > 0.0 else cube_size * DISMANTLE_GAP, get_min_cut_thickness())
	var made := 0
	for axis in 3:
		# This axis's scale: the grid and the slabs are in world units, the box isn't.
		var scale := global_transform.basis[axis].length()
		if scale <= 0.0:
			continue
		var step := cube_size / scale
		var count := int(ceil(box.size[axis] / step - 1e-4))
		if count < 2:
			continue
		# Centred: the first plane is half the leftover in from the box's side.
		var first := box.position[axis] + (box.size[axis] - (count - 1) * step) * 0.5 - step * 0.5 + step
		var size := box.size * 1.02 + Vector3.ONE * 1e-3  # past the box, so the slab cuts clean through
		size[axis] = thickness / scale
		var slab := SolidBox.new()
		slab.size = size
		slab.tag = tag
		var solid := slab.get_solid()
		for k in count - 1:
			var centre := box.get_center()
			centre[axis] = first + k * step
			edit_solid(solid, global_transform * Transform3D(Basis(), centre), BooleanOp.Operation.SUBTRACT, false)
			made += 1
	return made


## The slab [method cut] would subtract for these arguments, as
## [code][SolidBox, its global transform][/code] (to preview a cut, or check what it would
## take), or empty if it would cut nothing.
func get_cut_slab(from: Vector3, to: Vector3, direction: Vector3, depth: float, thickness: float = 0.0,
		tag: int = 1) -> Array:
	var along := to - from
	var inward := direction - along.normalized() * direction.dot(along.normalized()) if along.length_squared() > 0.0 else Vector3.ZERO
	if along.length_squared() < 1e-12 or inward.length_squared() < 1e-12 or depth <= 0.0:
		return []
	var x := along.normalized()
	var y := inward.normalized()
	thickness = maxf(thickness if thickness > 0.0 else get_cut_thickness(), get_min_cut_thickness())
	if thickness <= 0.0:
		thickness = 0.01  # no data to size it by yet
	var slab := SolidBox.new()
	slab.size = Vector3(along.length(), depth, thickness)
	slab.tag = tag
	return [slab, Transform3D(Basis(x, y, x.cross(y)), (from + to) * 0.5 + y * depth * 0.5)]


## The thickness [method cut] uses by default: 1/1000 of the mesh's size (the longest side
## of [method get_aabb], world units), the thinnest it makes.
func get_cut_thickness() -> float:
	return _world_size() / 1000.0


## The thinnest cut [method cut] makes: 1/1000 of the mesh's size (world units).
func get_min_cut_thickness() -> float:
	return _world_size() / 1000.0


## The box around the mesh as it is now (every piece in [member data], edits included), in
## this node's space; empty with no data. Kept per piece until it changes, so it's cheap to
## call often.
func get_aabb() -> AABB:
	var box := AABB()
	var first := true
	if data == null:
		return box
	for key: Vector4i in data.pieces:
		var solid: Solid = data.pieces[key]
		if solid.is_empty():
			continue
		var entry: Array = _piece_boxes.get(key, [])
		if entry.is_empty() or not is_same(entry[0], solid):
			entry = [solid, solid.get_aabb()]
			_piece_boxes[key] = entry
		box = entry[1] if first else box.merge(entry[1])
		first = false
	return box


func _world_size() -> float:
	return (global_transform * get_aabb()).get_longest_axis_size()


## True when baking is done and no piece has edits queued or running.
func is_idle() -> bool:
	if _baking or _bake_pending or not _pending.is_empty() or not _splitting.is_empty() 			or not _seam_points.is_empty():
		return false
	for piece: AdaptivePiece in _pieces.values():
		if not piece.is_idle():
			return false
	return true


## Makes [member data] from [member source]: cuts it with [member chunking] and builds every
## piece's mesh, then shows the pieces. Throws away edits. A coroutine (cutting may take a
## few frames); [signal baked] fires when it's done.
func bake() -> void:
	if _baking:
		return
	_baking = true
	_assigned_data = null
	_clear_pieces()
	var made := AdaptiveMeshData.new()
	if source == null:
		_node_source = null  # read the target's meshes as they are now
	elif source is NodeSource:
		(source as NodeSource).node = null  # likewise (the next read sets it again)
	var from := get_bake_source()
	made.fingerprint = get_bake_fingerprint()
	var solid := from.get_solid() if from != null else Solid.new()
	var open := solid.count_open_edges()
	_open_edges = open
	if open > 0:
		push_warning("AdaptiveMesh: the source isn't closed (%d open edges); booleans will fail on it." % open)
	made.materials = from.get_materials() if from != null else ([] as Array[Material])
	made.chunking = chunking.duplicate() as Chunking if chunking != null else null
	made.region = max_bounds
	var box := solid.get_aabb()
	made.extent = max_bounds if max_bounds.has_volume() else box.grow(maxf(box.get_longest_axis_size(), 1.0))
	if made.chunking == null:
		if not solid.is_empty():
			made.pieces[Vector4i.ZERO] = solid
	else:
		var cut: Dictionary = await made.chunking.split(solid, made.extent, get_backend())
		for cell: Vector3i in cut:
			made.pieces[AdaptiveMeshData.cell_key(cell)] = cut[cell]
	var borders: Dictionary = await _bake_meshes(made)
	_baking = true  # (the data setter is quiet while baking)
	data = made
	_owns_data = true
	_baking = false
	_spawn_pieces(borders)
	if _active and is_component():
		_take_over()
	baked.emit()
	var queued := _pending.duplicate()
	_pending.clear()
	for args: Array in queued:
		edit_solid(args[0], args[1], args[2], args[3])


## Throws away all edits: back to the data assigned to [member data] (such as a saved
## bake), or bakes again from [member source] if it was baked here. A component hands its
## target back as authored (and takes over again at once if [member activation] is At
## Start).
func reset() -> void:
	_pending.clear()
	clear_debris()
	if is_component():
		# Back to the target as authored; the next edit takes over again (or right away, for
		# one that takes over at start).
		_hand_back()
		data = _assigned_data
		if activation == Activation.AT_START:
			activate()
		return
	if _assigned_data != null and _assigned_data.is_baked():
		data = _assigned_data
		baked.emit()
	else:
		bake()


## The fragments of earlier digs still in the scene, oldest first (see [member debris]).
func get_debris() -> Array[RigidBody3D]:
	_debris = _debris.filter(func(body: Variant) -> bool: return is_instance_valid(body) and not body.is_queued_for_deletion())
	return _debris


## Frees every fragment of earlier digs.
func clear_debris() -> void:
	for body in get_debris():
		body.queue_free()
	_debris.clear()


## The pieces by key (see [member AdaptiveMeshData.pieces]).
func get_pieces() -> Dictionary:
	return _pieces


## Every visible triangle of every piece as three positions (this node's space), for
## collision snapshots, raycasts or debug drawing.
func get_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	var hidden := _hidden_tags()
	for piece: AdaptivePiece in _pieces.values():
		faces.append_array(piece.solid.get_faces(hidden))
	return faces


## Each piece's current collision shape (this node's space; empty with collision off).
## Pieces never change a shape they made: edits make a new one. So holding on to these is
## a snapshot of the surface as it is now, at no cost, for example for raycasts that
## should ignore what a stroke is digging.
func get_collision_shapes() -> Array[Shape3D]:
	var out: Array[Shape3D] = []
	for piece: AdaptivePiece in _pieces.values():
		out.append_array(piece.get_collision_shapes())
	return out


## Triangles drawn across all pieces (the faces between pieces aren't counted). Counted
## once per piece and kept until it changes, so it's cheap to call every frame.
func get_triangle_count() -> int:
	var count := 0
	var cap := data.get_cap_tag() if data != null else -1
	for key: Vector4i in _pieces:
		if not _triangle_counts.has(key):
			var visible_count := 0
			for tag in (_pieces[key] as AdaptivePiece).solid.tags:
				if tag != cap:
					visible_count += 1
			_triangle_counts[key] = visible_count
		count += _triangle_counts[key]
	return count


func get_backend() -> BooleanBackend:
	if backend != null:
		return backend
	if _default_backend == null:
		_default_backend = get_default_backend()
	return _default_backend


## A new backend of the kind meshes with no [member backend] use: the
## adaptive_mesh_native add-on's [code]ManifoldBooleanBackend[/code] (much faster, and off the
## main thread) if it's installed and its native library loads on this platform, otherwise
## [CsgBooleanBackend]. Found by its class name, so this add-on doesn't need that one.
static func get_default_backend() -> BooleanBackend:
	if _default_backend_script == null:
		_default_backend_script = CsgBooleanBackend
		for entry: Dictionary in ProjectSettings.get_global_class_list():
			if entry.get("class") != &"ManifoldBooleanBackend":
				continue
			var script := load(entry.get("path", "")) as Script
			if script != null and script.call(&"is_available"):
				_default_backend_script = script
			break
	return _default_backend_script.new()


# This mesh's share of the frame budget (made when first needed: most parts never use it).
func _budget() -> FrameBudget:
	if _frame_budget == null:
		_frame_budget = FrameBudget.new()
		_frame_budget.budget_ms = main_thread_budget_ms
	return _frame_budget


func _get_drawing() -> PieceDrawing:
	return drawing if drawing != null else _default_drawing


func _get_collision() -> PieceCollision:
	if collision != null:
		return collision
	return _target_collision if _target_collision != null else _default_collision


func _hidden_tags() -> PackedInt32Array:
	var cap := data.get_cap_tag() if data != null else -1
	return PackedInt32Array([cap]) if cap >= 0 else PackedInt32Array()


# Edits change the data; nodes sharing it shouldn't see that.
func _own_data() -> void:
	if not _owns_data:
		var copy := data.copy()
		_baking = true  # quiet setter
		data = copy
		_baking = false
		_owns_data = true


# Sends an edit (in this node's space) to the pieces at [param keys]: queued for a piece
# that is splitting, and creating pieces in empty cells for unions.
func _route(shape: Solid, local: Transform3D, operation: BooleanOp.Operation, keys: Array[Vector4i],
		debris: bool = true) -> void:
	if not keys.is_empty():
		_edits_unreported = true
	var op := BooleanOp.create(shape, local, operation)  # shared by the pieces it reaches
	op.debris = debris
	for key in keys:
		if _splitting.has(key):
			(_splitting[key] as Array).append([shape, local, operation, debris])
			continue
		var piece: AdaptivePiece = _pieces.get(key)
		if piece == null:
			# Only a union can put something into an empty cell, and only inside the bounds.
			if operation != BooleanOp.Operation.UNION:
				continue
			if data.region.has_volume() and not data.region.intersects(data.get_cell(key)):
				continue
			data.pieces[key] = Solid.new()
			piece = _make_piece(key)
		piece.add_op(op)


func _clear_pieces() -> void:
	for piece: AdaptivePiece in _pieces.values():
		piece.queue_free()
	_pieces.clear()
	_borders.clear()
	_splitting.clear()
	_seam_points.clear()
	_triangle_counts.clear()
	_piece_boxes.clear()
	_piece_mass.clear()
	_unsplittable.clear()
	_sep_cache.clear()
	_sep_dirty.clear()
	_sep_ready = false
	_sep_ground = NAN
	_sep_authored.clear()
	_sep_round += 1
	_sep_checking = false


# Shows [member data]'s pieces. [param borders] are their border faces if already known
# (from baking); otherwise they're worked out here.
func _spawn_pieces(borders: Dictionary = {}) -> void:
	_clear_pieces()
	if data == null or not _active:
		return
	_moving = get_body() if not Engine.is_editor_hint() else null
	_piece_mass = _prepared.get(&"masses", {}).duplicate()
	for key: Vector4i in data.pieces:
		_borders[key] = borders[key] if borders.has(key) else _border_parts_of(key, data.pieces[key])
	# A part shown as one mesh until now: its pieces' own, from the surfaces kept for them.
	var drawn: Dictionary = _prepared.get(&"surfaces", {})
	for key: Vector4i in drawn:
		if data.pieces.has(key) and data.meshes.get(key) == null:
			data.meshes[key] = AdaptivePiece.make_mesh(drawn[key])
	for key: Vector4i in data.pieces:
		_make_piece(key)
	if _prepared.get(&"connected", false):
		# A part that came off another mesh is one connected whole: nothing in it is
		# separate from the start, so there's nothing for a first check to note. (The next
		# check, after an edit, works out every piece afresh.)
		_sep_ready = true
		_sep_authored = {}
	else:
		_check_separation()  # what's separate from the start, before any edit
	_prepared = {}
	if not is_component():
		_update_mass()  # (a component does it once it has taken over, see _take_over)


# Builds every piece's mesh on worker threads (with its neighbours' border faces, so seams
# shade smoothly), stores them in [param into], and returns the border faces by key.
func _bake_meshes(into: AdaptiveMeshData) -> Dictionary:
	var keys: Array[Vector4i] = []
	var around := []
	for key: Vector4i in into.pieces:
		keys.append(key)
		around.append(_cells_around(into, key))
	if keys.is_empty():
		return {}
	var parts := []
	parts.resize(keys.size())
	var cut := _cut_axes(into)
	var cap := into.get_cap_tag()
	# (Static calls only: the jobs mustn't call into this node, see AdaptivePiece.)
	var border_job := func(i: int) -> void:
		parts[i] = AdaptiveMesh._border_parts(into.pieces[keys[i]], into.get_cell(keys[i]), cut, cap, around[i])
	_group_task = WorkerThreadPool.add_group_task(border_job, keys.size())
	while not WorkerThreadPool.is_group_task_completed(_group_task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(_group_task)
	_group_task = -1
	var borders := {}
	for i in keys.size():
		borders[keys[i]] = parts[i]
	var hidden := PackedInt32Array([cap]) if cap >= 0 else PackedInt32Array()
	var crease := _get_drawing().crease_angle
	var surfaces := []
	surfaces.resize(keys.size())
	var mesh_job := func(i: int) -> void:
		surfaces[i] = AdaptivePiece.job_mesh((into.pieces[keys[i]] as Solid).build_surfaces(crease, hidden,
				AdaptiveMesh._faces_for(borders, keys[i], around[i])))
	_group_task = WorkerThreadPool.add_group_task(mesh_job, keys.size())
	while not WorkerThreadPool.is_group_task_completed(_group_task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(_group_task)
	_group_task = -1
	for i in keys.size():
		into.meshes[keys[i]] = AdaptivePiece.as_mesh(surfaces[i])
	return borders


func _make_piece(key: Vector4i) -> AdaptivePiece:
	var piece := AdaptivePiece.new()
	piece.name = "Piece_%d_%d_%d_%d" % [key.x, key.y, key.z, key.w]
	piece.solid = data.pieces[key]
	piece.initial_mesh = data.meshes.get(key)
	piece.backend = get_backend()
	piece.cleanup = cleanup
	var look := _get_drawing()
	piece.materials = _resolved_materials()
	piece.crease_angle = look.crease_angle
	piece.cast_shadow = look.cast_shadow
	piece.render_settings = _render_settings
	var physics := _get_collision()
	piece.collision = physics.enabled
	piece.collision_layer = physics.layer
	piece.collision_mask = physics.mask
	piece.hidden_tags = _hidden_tags()
	piece.frame_budget = _budget()
	piece.moving_body = _moving
	piece.hulls_per_piece = physics.hulls_per_piece
	var hulls: Array[PackedVector3Array] = []
	hulls.assign(_prepared.get(&"hulls", {}).get(key, []))
	piece.initial_hulls = hulls
	piece.debris = debris
	_set_neighbours(piece, key)
	piece.find_borders = data.chunking != null
	piece.border_cell = data.get_cell(key)
	piece.border_cut = _cut_axes(data)
	piece.border_cap = data.get_cap_tag()
	_set_bounds(piece, key)
	piece.edited.connect(_on_piece_edited.bind(key))
	piece.drawn.connect(_on_piece_drawn.bind(key))
	piece.broke_off.connect(_on_piece_broke_off)
	piece.finished.connect(_queue_idle_check)
	add_child(piece, false, Node.INTERNAL_MODE_FRONT)
	_pieces[key] = piece
	return piece


# Tells [param piece] (at [param key]) who its neighbours are and gives it their border
# faces for its seam normals. Doesn't redraw it.
func _set_neighbours(piece: AdaptivePiece, key: Vector4i) -> void:
	piece.border_cells = _cells_around(data, key)
	piece.normal_faces = _faces_for(_borders, key, piece.border_cells)


# A piece's bounds: its cell (within the region). Sides shared with a neighbouring cell are
# walls, so faces a union leaves there are hidden caps; outer sides show the shape's faces.
func _set_bounds(piece: AdaptivePiece, key: Vector4i) -> void:
	var region := data.region
	if data.chunking == null:
		piece.bounds = region
		piece.bounds_walls = 0
		return
	var cell := data.get_cell(key)
	piece.bounds = cell.intersection(region) if region.has_volume() else cell
	piece.bounds_tag = data.get_cap_tag()
	var walls := 0
	for axis in 3:
		if not data.chunking.cuts_axis(axis):
			continue
		var at_region_start := region.has_volume() and cell.position[axis] <= region.position[axis]
		var at_region_end := region.has_volume() and cell.end[axis] >= region.end[axis]
		if not at_region_start:
			walls |= BooleanBackend.side_bit(axis, false)
		if not at_region_end:
			walls |= BooleanBackend.side_bit(axis, true)
	piece.bounds_walls = walls


func _on_piece_edited(key: Vector4i) -> void:
	var started := StageProfile.begin()
	_on_piece_edited_work(key)
	StageProfile.end(&"main: edit bookkeeping", started)


func _on_piece_edited_work(key: Vector4i) -> void:
	var edited_piece: AdaptivePiece = _pieces.get(key)
	if edited_piece == null:
		return
	data.pieces[key] = edited_piece.solid
	_triangle_counts.erase(key)
	if _separation_on():
		_sep_dirty[key] = true
	# The border faces were found on the worker, against the neighbours the piece had when
	# the edit started; if a neighbour split since, find them again.
	var parts := edited_piece.border_parts
	if not is_same(edited_piece.border_parts_cells, edited_piece.border_cells):
		parts = _border_parts_of(key, edited_piece.solid)
	_set_border(key, parts)
	_exchange_wall_points(key)
	piece_edited.emit(key)
	_queue_idle_check()
	if _seam_points.has(key):
		_close_seam.call_deferred(key)
	_maybe_split.call_deferred(key)


# A piece and a neighbour split to a different depth don't have their corners in the same
# places along the wall between them: the finer one has corners where its own walls meet
# that wall, the coarser one doesn't. After an edit on either, the finer one's corners
# there (where the edit reached) go into the coarser one's edges once it's idle (see
# [method _close_seam]), so the seam matches point for point.
func _exchange_wall_points(key: Vector4i) -> void:
	var piece: AdaptivePiece = _pieces.get(key)
	if piece == null or not piece.edited_box.has_volume() or not data.pieces.has(key):
		return
	var cell := data.get_cell(key)
	for n in data.neighbour_keys(key):
		if n.w == key.w or not data.pieces.has(n):
			continue
		var other := data.get_cell(n)
		var shared := cell.grow(1e-4).intersection(other.grow(1e-4))
		if not shared.intersects(piece.edited_box):
			continue
		shared = shared.intersection(piece.edited_box)
		if key.w > n.w:
			_queue_seam_points(n, _cell_edge_points(data.pieces[key], cell, shared))
		else:
			_queue_seam_points(key, _cell_edge_points(data.pieces[n], other, shared))


# [param solid]'s points inside [param box] that lie on two or more of [param cell]'s sides
# (its edges, where its walls meet).
func _cell_edge_points(solid: Solid, cell: AABB, box: AABB) -> PackedVector3Array:
	var out := PackedVector3Array()
	var cut := _cut_axes(data)
	for p in solid.positions:
		if not box.has_point(p):
			continue
		var sides := 0
		for axis in 3:
			if cut[axis] and (absf(p[axis] - cell.position[axis]) < 1e-4 or absf(p[axis] - cell.end[axis]) < 1e-4):
				sides += 1
		if sides >= 2:
			out.append(p)
	return out


# Queues [param points] to go into [param key]'s edges (see [method _close_seam]).
func _queue_seam_points(key: Vector4i, points: PackedVector3Array) -> void:
	if points.is_empty() or not _pieces.has(key):
		return
	var queued: PackedVector3Array = _seam_points.get(key, PackedVector3Array())
	queued.append_array(points)
	_seam_points[key] = queued
	_close_seam.call_deferred(key)


# Stores [param key]'s border faces; neighbours whose share changed redraw their seam
# shading, now or, given [param later] (key -> true), when [method _redraw_seams] is
# called with it (once each, however many of their neighbours changed).
func _set_border(key: Vector4i, parts: Dictionary, later: Variant = null) -> void:
	var old: Dictionary = _borders.get(key, {})
	_borders[key] = parts
	var none := PackedVector3Array()
	var changed := {}
	for neighbour in data.neighbour_keys(key):
		if parts.get(neighbour, none) != old.get(neighbour, none):
			changed[neighbour] = true
	if later != null:
		(later as Dictionary).merge(changed)
	else:
		_redraw_seams(changed)


# Neighbours at [param keys] (key -> true) take their seam shading from the current
# border faces and redraw.
func _redraw_seams(keys: Dictionary) -> void:
	for key: Vector4i in keys:
		var piece: AdaptivePiece = _pieces.get(key)
		if piece != null:
			piece.normal_faces = _faces_for(_borders, key, piece.border_cells)
			piece.request_redraw()


# Inserts the points a split neighbour added on [param key]'s walls into its edges, once
# it's idle, and redraws it.
func _close_seam(key: Vector4i) -> void:
	var piece: AdaptivePiece = _pieces.get(key)
	if piece == null:
		_seam_points.erase(key)
		_queue_idle_check()
		return
	if not piece.is_idle() or not _seam_points.has(key):
		return  # tried again after its edits (or already done)
	var points: PackedVector3Array = _seam_points[key]
	_seam_points.erase(key)
	var fixed := piece.solid.duplicate() as Solid  # the old one may be shared
	if fixed.split_edges_at(points, 1e-4) > 0:
		piece.solid = fixed
		data.pieces[key] = fixed
		_triangle_counts.erase(key)
		piece.request_redraw()
		_set_border(key, _border_parts_of(key, fixed))
	_queue_idle_check()


func _on_piece_drawn(key: Vector4i) -> void:
	var piece: AdaptivePiece = _pieces.get(key)
	if piece != null and _owns_data:
		data.meshes[key] = piece.get_mesh()
	if _seam_points.has(key):
		_close_seam.call_deferred(key)
	_queue_idle_check()


# A dig took [param removed] (this node's space) out of a piece: break it up and drop the
# fragments, if debris is on.
func _on_piece_broke_off(removed: Solid, cut_tag: int) -> void:
	if debris == null or not debris.enabled or not debris.fragments or not is_inside_tree():
		return
	# In world space (physics can't scale bodies), from a static function: it waits for
	# frames, and this node may be gone by the end.
	AdaptiveMesh._spawn_debris(weakref(self), debris, removed.transformed(global_transform), cut_tag,
			get_backend(), _budget(), _resolved_materials(), _get_drawing().crease_angle, _debris_parent())


# Where debris goes: the current scene (not under this node, so find() doesn't take it for
# the mesh), or this node's viewport if it's in another one.
func _debris_parent() -> Node:
	var parent: Node = get_tree().current_scene
	if parent == null or not parent.is_ancestor_of(self):
		parent = get_viewport()
	return parent


static func _spawn_debris(mesh_ref: WeakRef, settings: MeshDebris, removed: Solid, cut_tag: int,
		backend_used: BooleanBackend, budget: FrameBudget, materials: Array[Material], crease: float,
		parent: Node) -> void:
	var fragments: Array[Solid] = await settings.break_up(removed, cut_tag, backend_used, budget, mesh_ref.get_ref())
	# (The scene may have gone while they were cut.)
	if not fragments.is_empty() and mesh_ref.get_ref() != null and is_instance_valid(parent):
		await _spawn_bodies(mesh_ref, settings, fragments, PackedInt32Array(), MeshDebris.get_centre(removed),
				settings.scatter_speed, settings.lifetime, budget, materials, crease, parent)


# Adds a rigid body per solid in [param solids] (world space; [param hidden] tags not
# drawn) to [param parent], within the frame budget, flying away from [param middle] at
# about [param scatter] and freed after [param lifetime] (0: kept). Then hands them to the
# mesh as dig fragments.
static func _spawn_bodies(mesh_ref: WeakRef, settings: MeshDebris, solids: Array[Solid], hidden: PackedInt32Array,
		middle: Vector3, scatter: float, lifetime: float, budget: FrameBudget, materials: Array[Material],
		crease: float, parent: Node) -> void:
	# Centred on their middles, with their surfaces and hull points, on a worker:
	# [centre, solid, surfaces, hull points].
	var prepared: Array = await MeshDebris.run_on_worker(func() -> Array:
		var out := []
		for solid in solids:
			var centre := MeshDebris.get_centre(solid)
			var centred := solid.transformed(Transform3D(Basis(), -centre))
			out.append([centre, centred, centred.build_surfaces(crease, hidden), MeshDebris.get_hull_points(centred)])
		return out, mesh_ref.get_ref())
	var bodies: Array[RigidBody3D] = []
	for entry: Array in prepared:
		await budget.wait_turn()
		var mesh: AdaptiveMesh = mesh_ref.get_ref()
		if mesh == null or not is_instance_valid(parent):
			return
		var start := Time.get_ticks_usec()
		var centre: Vector3 = entry[0]
		var body := settings.make_body(entry[1], AdaptivePiece.make_mesh(entry[2]), entry[3], materials)
		parent.add_child(body)
		body.global_transform = Transform3D(Basis(), centre)
		if scatter > 0.0:
			var away := centre - middle
			if away.length_squared() < 1e-8:
				away = Vector3(settings.rng.randf_range(-1, 1), 1.0, settings.rng.randf_range(-1, 1))
			body.linear_velocity = away.normalized() * scatter * settings.rng.randf_range(0.6, 1.2)
			body.angular_velocity = Vector3(settings.rng.randf_range(-1, 1), settings.rng.randf_range(-1, 1),
					settings.rng.randf_range(-1, 1)) * scatter
		if lifetime > 0.0:
			_expire(body, lifetime)
		bodies.append(body)
		budget.spend(Time.get_ticks_usec() - start)
	var owner_mesh: AdaptiveMesh = mesh_ref.get_ref()
	if owner_mesh != null:
		owner_mesh._add_debris(bodies, settings.max_bodies)


# Frees [param body] after [param lifetime] seconds, shrinking its meshes away over the
# last half second.
static func _expire(body: RigidBody3D, lifetime: float) -> void:
	var fade := minf(0.5, lifetime)
	var tween := body.create_tween()
	tween.tween_interval(lifetime - fade)
	var views := body.find_children("*", "MeshInstance3D", true, false)
	if views.is_empty():
		tween.tween_interval(fade)
	for i in views.size():
		(tween.parallel() if i > 0 else tween).tween_property(views[i], ^"scale", Vector3.ONE * 0.01, fade)
	tween.tween_callback(body.queue_free)


func _add_debris(bodies: Array[RigidBody3D], limit: int) -> void:
	var alive := get_debris()
	alive.append_array(bodies)
	while alive.size() > limit:
		alive.pop_front().queue_free()
	_debris = alive
	debris_spawned.emit(bodies)


func _separation_on() -> bool:
	return separation != null and separation.enabled and _active and data != null \
			and not Engine.is_editor_hint()


# Looks for parts digs and cuts have divided off, on a worker, and separates them. The
# first check after the pieces appear only notes what's separate from the start. One check
# at a time; edits during it are looked at by the next one.
func _check_separation() -> void:
	if not _separation_on() or _sep_checking or not is_inside_tree():
		return
	if _sep_ready and _sep_dirty.is_empty():
		return
	_sep_checking = true
	var first := not _sep_ready
	var solids := data.pieces.duplicate()
	var dirty := _sep_dirty.duplicate()
	_sep_dirty.clear()
	# Corners closer than this count as the same, across a seam (each side cut separately).
	var snap := maxf(data.extent.get_longest_axis_size(), 1.0) * 2e-6
	# Each changed piece's parts are worked out first, over all worker threads (after a big
	# cut, that's most of the work); the job finding how they join then finds them cached.
	var cache := _sep_cache.duplicate()
	var changed := []
	for key: Vector4i in solids:
		var entry: Array = cache.get(key, [])
		if entry.is_empty() or not is_same(entry[0], solids[key]):
			changed.append(key)
	var cap := data.get_cap_tag()
	var found := []
	found.resize(changed.size())
	var infos_job := func(i: int) -> void:
		found[i] = MeshSeparation.part_infos(solids[changed[i]], cap)
	var fill := func() -> void:
		for i in changed.size():
			cache[changed[i]] = [solids[changed[i]], found[i]]
	var find := MeshSeparation.find_parts_job(solids, cache, dirty, cap, snap,
			MeshSeparation.resolve(separation.anchor, _moving != null), _sep_ground, separation.anchor_margin,
			_sep_authored, first)
	# Dust (too small, or a flake thinner than a quarter of the thinnest cut) is dropped.
	var min_size := separation.min_size
	var flake := maxf(data.extent.get_longest_axis_size(), 1.0) / 3000.0 / 4.0
	# Preparing the parts is light per part: one job does them all (spread over threads,
	# a thousand small jobs reading the same data only get in each other's way).
	var job := func() -> Dictionary:
		var started := StageProfile.begin()
		var result: Dictionary = find.call()
		StageProfile.end(&"separation: joining parts", started)
		for i in (result.separating as Array).size():
			AdaptiveMesh._prepare_part(result, i, min_size, flake)
		return result
	AdaptiveMesh._run_separation_check(weakref(self), [changed.size(), infos_job, fill], job, solids, _sep_round,
			first)


# On a worker, after the parts are found: separating part [param i]'s share of each piece
# (merged), whether it's kept (not dust) and its box, appended to its entry, so the main
# thread doesn't do it for every part (a dismantled castle has a thousand).
static func _prepare_part(result: Dictionary, i: int, min_size: float, flake: float) -> void:
	var started := StageProfile.begin()
	_prepare_part_work(result, i, min_size, flake)
	StageProfile.end(&"separation: prepare parts", started)


static func _prepare_part_work(result: Dictionary, i: int, min_size: float, flake: float) -> void:
	var entry: Array = result.separating[i]
	entry[1] = MeshSeparation.merge_solids(entry[1])  # the part as one solid
	var shares := {}  # key -> its share of that piece (all of the part's parts in it)
	for place: Array in entry[0]:
		if not shares.has(place[0]):
			shares[place[0]] = [] as Array[Solid]
		(shares[place[0]] as Array[Solid]).append(result.cache[place[0]][1][place[1]][0])
	for key: Vector4i in shares:
		shares[key] = MeshSeparation.merge_solids(shares[key])
	var part: Solid = entry[1]
	var kept := part.get_volume() >= min_size * min_size * min_size and not MeshSeparation.is_flake(part, flake)
	entry.append_array([shares, kept, part.get_aabb()])


# [param infos] is [count, job, fill]: the changed pieces' parts, worked out over all
# worker threads (each is a fair amount of work) and filled into the cache before
# [param job] runs.
static func _run_separation_check(mesh_ref: WeakRef, infos: Array, job: Callable, solids: Dictionary, round: int,
		first: bool) -> void:
	await WorkerJobs.run_group(infos[1], infos[0], mesh_ref.get_ref())
	if mesh_ref.get_ref() == null:
		return
	(infos[2] as Callable).call()
	var result: Dictionary = await MeshDebris.run_on_worker(job, mesh_ref.get_ref())
	var mesh: AdaptiveMesh = mesh_ref.get_ref()
	if mesh != null and mesh._sep_round == round:
		mesh._finish_separation_check(result, solids, first)


# Takes the parts [method MeshSeparation.find_parts_job] found off their pieces (if those
# haven't changed since) and spawns them as meshes of their own.
func _finish_separation_check(result: Dictionary, solids: Dictionary, first: bool) -> void:
	var started := StageProfile.begin()
	_finish_separation_check_work(result, solids, first)
	StageProfile.end(&"main: separation", started)


func _finish_separation_check_work(result: Dictionary, solids: Dictionary, first: bool) -> void:
	_sep_checking = false
	_sep_cache = result.cache
	_sep_ground = result.ground
	if first:
		_sep_authored = result.authored
		_sep_ready = true
	var parts := []  # [the part (this node's space), {key: its share of that piece}, its box]
	var leaving := {}  # Vector4i -> part indices leaving that piece
	var takers := {}  # Vector4i -> how many separating parts (dust too) take some of that piece
	for entry: Array in result.separating:
		var places: Array = entry[0]  # [key, part index] per part of it
		if not _unchanged(places.map(func(place: Array) -> Vector4i: return place[0]), solids):
			for place: Array in places:
				_sep_dirty[place[0]] = true  # changed meanwhile: look again next time
			continue
		var taken := {}
		for place: Array in places:
			if not leaving.has(place[0]):
				leaving[place[0]] = []
			(leaving[place[0]] as Array).append(place[1])
			taken[place[0]] = true
		for key: Vector4i in taken:
			takers[key] = takers.get(key, 0) + 1
		if entry[3]:  # not dust (see _prepare_parts)
			parts.append([entry[1], entry[2], entry[4]])
	if leaving.is_empty():
		if not _sep_dirty.is_empty():
			_queue_idle_check()  # look again once idle
		return
	# What's left of each piece a part leaves (nothing: the piece goes, and if one part took
	# all of it, its drawn mesh goes with that part), and the parts' data. The heavy part (seam shading, hulls, masses, merging
	# small parts) runs on a worker; nothing changes until it's done.
	var rests := {}  # key -> [kept part infos, kept solids]
	var whole := {}  # key -> drawn mesh
	for key: Vector4i in leaving:
		var infos: Array = _sep_cache[key][1]
		var kept := []
		var kept_solids: Array[Solid] = []
		for i in infos.size():
			if not (leaving[key] as Array).has(i):
				kept.append(infos[i])
				kept_solids.append(infos[i][0])
		if kept.is_empty():
			# Only a part that took all of the piece can show the piece's drawn mesh: parts
			# that each took a share (a piece cut into several parts) draw their own.
			if takers.get(key, 0) == 1:
				whole[key] = data.meshes.get(key)
		else:
			rests[key] = [kept, kept_solids, data.get_cell(key), _cells_around(data, key)]
	var datas := []  # [its shares, merge it, plain]; the data is made on the worker
	var min_adaptive := separation.min_adaptive_size if separation != null else 0.0
	for part: Array in parts:
		var box: AABB = part[2]
		datas.append([part[1], (part[1] as Dictionary).size() > 1 and _fits_one_cell(box),
				box.get_longest_axis_size() < min_adaptive])
	_sep_checking = true  # until it's applied: a check now would find the same parts
	# What the parts' data share with this mesh's (the split cells copied: the worker reads
	# them while this mesh may split more).
	var shared := [data.split_keys.duplicate(), data.chunking, data.region, data.extent, data.materials.duplicate(), whole]
	var work := AdaptiveMesh._separation_work(rests, _cut_axes(data), data.get_cap_tag(), datas, _get_drawing().crease_angle,
			_get_collision().hulls_per_piece, shared)
	AdaptiveMesh._run_separation(weakref(self), work, solids, leaving.keys(), parts, rests, _sep_round)


# True if the pieces at [param keys] are still the ones in [param solids], idle and not
# splitting.
func _unchanged(keys: Array, solids: Dictionary) -> bool:
	for key: Vector4i in keys:
		var piece: AdaptivePiece = _pieces.get(key)
		if piece == null or not piece.is_idle() or _splitting.has(key) or not is_same(data.pieces.get(key), solids[key]):
			return false
	return true


# The data of a part made of [param shares] (key -> its share of that piece), with the
# mesh's chunk grid. [param shared]: [split cells, chunking, region, extent, materials,
# whole] from the mesh, whole being key -> drawn mesh for pieces leaving whole, whose
# drawn meshes the part reuses. The part gets the split cells its pieces are in (not the
# mesh's others: a thousand parts don't each copy every split of the mesh).
static func _part_data(shares: Dictionary, shared: Array) -> AdaptiveMeshData:
	var made := AdaptiveMeshData.new()
	var split: Dictionary = shared[0]
	var whole: Dictionary = shared[5]
	for key: Vector4i in shares:
		made.pieces[key] = shares[key]
		if whole.get(key) != null:
			made.meshes[key] = whole[key]
		var up := key
		while up.w > 0:
			up = Vector4i(up.x >> 1, up.y >> 1, up.z >> 1, up.w - 1)
			if split.has(up):
				made.split_keys[up] = true
	made.chunking = shared[1]
	made.region = shared[2]
	made.extent = shared[3]
	made.materials = (shared[4] as Array[Material]).duplicate()
	return made


# What separating takes off the main thread, from plain values: each piece's rest (joined)
# and its seam shading; each part's data (merged if it should be), its pieces' seam
# shading, hull points, volumes and drawn surfaces (so a part's pieces show at once,
# without a job each); or, for a plain part, its surfaces (shaded at [param crease]) and
# hull points. Returns [job count, job (called with each index, on any worker thread),
# result (called after)]; the result is {rests: key -> [rest, border parts],
# parts: [[data, borders, hulls, masses, surfaces] or [null, surfaces, hull]...]}. One job
# per rest and per part, so a big cut (a dismantle's thousand cubes) uses every thread.
static func _separation_work(rests: Dictionary, cut: Array[bool], cap: int, datas: Array, crease: float,
		hull_count: int, shared: Array) -> Array:
	var rest_keys := rests.keys()
	var rest_out := []
	rest_out.resize(rest_keys.size())
	var part_out := []
	part_out.resize(datas.size())
	var job := func(i: int) -> void:
		var started := StageProfile.begin()
		AdaptiveMesh._separation_item(i, rest_keys, rests, rest_out, part_out, datas, cut, cap, crease, hull_count,
				shared)
		StageProfile.end(&"separation: part data", started)
	var result := func() -> Dictionary:
		var rests_by_key := {}
		for i in rest_keys.size():
			rests_by_key[rest_keys[i]] = rest_out[i]
		return {rests = rests_by_key, parts = part_out}
	return [rest_keys.size() + datas.size(), job, result]


# One item of [method _separation_work]: rest [param i], or past the rests, a part.
static func _separation_item(i: int, rest_keys: Array, rests: Dictionary, rest_out: Array, part_out: Array,
		datas: Array, cut: Array[bool], cap: int, crease: float, hull_count: int, shared: Array) -> void:
	if i < rest_keys.size():
		var key: Vector4i = rest_keys[i]
		var rest := MeshSeparation.merge_solids(rests[key][1])
		rest_out[i] = [rest, AdaptiveMesh._border_parts(rest, rests[key][2], cut, cap, rests[key][3])]
		return
	var entry: Array = datas[i - rest_keys.size()]
	if entry[2]:
		var shares: Array[Solid] = []
		shares.assign((entry[0] as Dictionary).values())
		var whole := MeshSeparation.merge_solids(shares)
		var hidden := PackedInt32Array([cap]) if cap >= 0 else PackedInt32Array()
		part_out[i - rest_keys.size()] = [null, whole.build_surfaces(crease, hidden), whole.get_hull_points()]
		return
	var made := AdaptiveMesh._part_data(entry[0], shared)
	if entry[1]:
		var joined := made.merged()
		if joined != null:
			made = joined
	var made_cut := AdaptiveMesh._cut_axes(made)
	var made_cap := made.get_cap_tag()
	var made_hidden := PackedInt32Array([made_cap]) if made_cap >= 0 else PackedInt32Array()
	var borders := {}
	var hulls := {}
	var masses := {}
	var around := {}
	for key: Vector4i in made.pieces:
		var solid: Solid = made.pieces[key]
		around[key] = AdaptiveMesh._cells_around(made, key)
		borders[key] = AdaptiveMesh._border_parts(solid, made.get_cell(key), made_cut, made_cap, around[key])
		hulls[key] = ConvexCells.hull_sets(solid, hull_count)
		var volume := solid.get_volume()
		masses[key] = [solid, volume, solid.get_centre() * volume]
	# What it shows until something edits it: one mesh, however many pieces it has (each
	# mesh and node costs about the same to make when a part spawns, whatever its size). A
	# part of one piece shows that piece's mesh (kept if the piece left whole); for several,
	# their surfaces joined, each piece's kept for when it takes over (see _spawn_pieces;
	# pieces that left whole keep their meshes for it too).
	# The meshes are made when it spawns, within the frame budget (a mesh made on a worker
	# still has its data sent to the GPU on the main thread before the frame is drawn,
	# outside any budget).
	var keys := made.pieces.keys()
	var surfaces := {}  # key -> drawn surfaces
	for key: Vector4i in keys:
		if keys.size() > 1 or made.meshes.get(key) == null:
			surfaces[key] = (made.pieces[key] as Solid).build_surfaces(crease, made_hidden,
					AdaptiveMesh._faces_for(borders, key, around[key]))
	var view: Variant = null  # the joined surfaces, for a part of several pieces
	if keys.size() > 1:
		view = AdaptiveMesh._joined_surfaces(surfaces.values())
	part_out[i - rest_keys.size()] = [made, borders, hulls, masses, surfaces, view]


# [param lists] of drawn surfaces ([code][tag, arrays][/code] each, see
# [method Solid.build_surfaces]) as one: a surface per tag, in the order tags first come.
# UVs are kept if every surface of that tag has them.
static func _joined_surfaces(lists: Array) -> Array:
	var by_tag := {}  # tag -> [positions, normals, uvs or null, indices]
	for list: Array in lists:
		for entry: Array in list:
			var arrays: Array = entry[1]
			var joined: Array = by_tag.get(entry[0], [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(),
					PackedInt32Array()])
			# (Each array taken out, added to and put back: a packed array read from an Array
			# is a copy.)
			var positions: PackedVector3Array = joined[0]
			var base := positions.size()
			positions.append_array(arrays[Mesh.ARRAY_VERTEX])
			joined[0] = positions
			var normals: PackedVector3Array = joined[1]
			normals.append_array(arrays[Mesh.ARRAY_NORMAL])
			joined[1] = normals
			if joined[2] != null and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
				var uvs: PackedVector2Array = joined[2]
				uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
				joined[2] = uvs
			else:
				joined[2] = null
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var all_indices: PackedInt32Array = joined[3]
			var first := all_indices.size()
			all_indices.append_array(indices)
			for k in indices.size():
				all_indices[first + k] += base
			joined[3] = all_indices
			by_tag[entry[0]] = joined
	var out := []
	for tag: int in by_tag:
		var joined: Array = by_tag[tag]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = joined[0]
		arrays[Mesh.ARRAY_NORMAL] = joined[1]
		arrays[Mesh.ARRAY_TEX_UV] = joined[2]
		arrays[Mesh.ARRAY_INDEX] = joined[3]
		out.append([tag, arrays])
	return out


static func _run_separation(mesh_ref: WeakRef, work: Array, solids: Dictionary, keys: Array, parts: Array,
		rests: Dictionary, round: int) -> void:
	await WorkerJobs.run_group(work[1], work[0], mesh_ref.get_ref())
	var mesh: AdaptiveMesh = mesh_ref.get_ref()
	if mesh != null and mesh._sep_round == round:
		mesh._apply_separation((work[2] as Callable).call(), solids, keys, parts, rests)


# Takes the parts off their pieces, as [method _separation_work] worked them out, if the
# pieces are still as the check saw them (otherwise looks again), then spawns the parts.
func _apply_separation(result: Dictionary, solids: Dictionary, keys: Array, parts: Array, rests: Dictionary) -> void:
	var started := StageProfile.begin()
	_apply_separation_work(result, solids, keys, parts, rests)
	StageProfile.end(&"main: separation", started)


func _apply_separation_work(result: Dictionary, solids: Dictionary, keys: Array, parts: Array, rests: Dictionary) -> void:
	_sep_checking = false
	if not _unchanged(keys, solids):
		for key: Vector4i in keys:
			_sep_dirty[key] = true
		_queue_idle_check()
		return
	_own_data()
	var redrawing := []
	var seams := {}  # neighbours to redraw once all is taken off (once each)
	for key: Vector4i in keys:
		if not rests.has(key):
			_remove_piece(key, seams)
			continue
		var rest: Solid = result.rests[key][0]
		_sep_cache[key] = [rest, rests[key][0]]
		data.pieces[key] = rest
		_triangle_counts.erase(key)
		var piece: AdaptivePiece = _pieces[key]
		piece.solid = rest
		piece.request_redraw()
		redrawing.append(weakref(piece))
		_set_border(key, result.rests[key][1], seams)
	_redraw_seams(seams)
	if not parts.is_empty():
		var prepared := []
		var centres := PackedVector3Array()  # (global)
		for i in parts.size():
			prepared.append([parts[i][0]] + (result.parts[i] as Array))
			centres.append(global_transform * (parts[i][2] as AABB).get_center())
		AdaptiveMesh._separate_when_redrawn(weakref(self), redrawing, prepared, _budget(), centres)
	if not _sep_dirty.is_empty():
		_queue_idle_check()  # look again once idle


# Spawns [param parts] ([part, data, borders, hulls, masses] each) once the pieces they left
# ([param redrawing], weak references) are drawn and collide without them, so the parts
# don't start inside the old collision. One at a time within the frame [param budget].
static func _separate_when_redrawn(mesh_ref: WeakRef, redrawing: Array, parts: Array, budget: FrameBudget,
		centres: PackedVector3Array) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	while redrawing.any(func(ref: WeakRef) -> bool: return ref.get_ref() != null and not (ref.get_ref() as AdaptivePiece).is_idle()):
		await tree.process_frame
	var made: Array[AdaptiveMesh] = []
	var plain: Array[RigidBody3D] = []
	# Nearest the camera first, so a big separation shows up where the player looks first.
	# (Sorted as (distance, index) pairs by the engine: a GDScript comparison per step costs
	# tens of milliseconds for a thousand parts.)
	var first_mesh: AdaptiveMesh = mesh_ref.get_ref()
	if first_mesh == null or not first_mesh.is_inside_tree():
		return
	var viewport := first_mesh.get_viewport()
	var order := []
	for i in parts.size():
		order.append(Vector2(FrameBudget.camera_distance(viewport, centres[i]), i))
	order.sort()
	for entry: Vector2 in order:
		var part: Array = parts[int(entry.y)]
		await budget.wait_turn(entry.x)
		var mesh: AdaptiveMesh = mesh_ref.get_ref()
		if mesh == null or not mesh.is_inside_tree():
			return
		var start := Time.get_ticks_usec()
		if part[1] == null:
			plain.append(mesh._spawn_plain_part(part[0], part[2], part[3]))
		else:
			made.append(mesh._spawn_part(part[0], part[1], {borders = part[2], hulls = part[3], masses = part[4],
					surfaces = part[5], view = part[6]}))
		budget.spend(Time.get_ticks_usec() - start)
	var owner_mesh: AdaptiveMesh = mesh_ref.get_ref()
	if owner_mesh != null:
		owner_mesh.separated.emit(made, plain)


# A new adaptive mesh on a frozen [RigidBody3D] for [param part] (this node's space), made of
# [param made] (its pieces under this mesh's chunk grid, or one piece if it was merged) with
# this mesh's settings; [param prepared] is what [method _separation_work] worked out for it
# (seam shading, hull points, volumes and drawn surfaces per piece), so it doesn't work them
# out again: its pieces show at once.
# It's placed where this mesh is, and let go (with this mesh's velocity at its centre, if
# this one moves) once its pieces have their hulls.
func _spawn_part(part: Solid, made: AdaptiveMeshData, prepared: Dictionary) -> AdaptiveMesh:
	var started := StageProfile.begin()
	var out := _spawn_part_work(part, made, prepared)
	StageProfile.end(&"main: spawn parts", started)
	return out


func _spawn_part_work(part: Solid, made: AdaptiveMeshData, prepared: Dictionary) -> AdaptiveMesh:
	var density := _mass_per_volume if _moving != null and _mass_per_volume > 0.0 else separation.density
	# One mesh shows the part: its pieces' surfaces joined, or its one piece's mesh.
	var surfaces: Dictionary = prepared.get(&"surfaces", {})  # key -> drawn surfaces
	var shown: ArrayMesh
	if prepared.get(&"view") != null:
		shown = AdaptivePiece.make_mesh(prepared[&"view"])  # (each piece's is made when it takes over)
	else:
		for key: Vector4i in surfaces:
			made.meshes[key] = AdaptivePiece.as_mesh(surfaces[key])
		prepared.erase(&"surfaces")
		if made.pieces.size() == 1:
			shown = made.meshes.get(made.pieces.keys()[0])
	prepared.erase(&"view")
	prepared[&"connected"] = true  # a part is one connected whole: see _spawn_pieces
	var body := _part_body(part, density)
	# Where the part sits in its body (this mesh's place, any scale).
	var local := body.transform.affine_inverse() * _part_frame_parent() * global_transform
	# Until something edits it, the part is a plain body: one mesh and its hulls, worked out
	# with the separation, and a dormant component targeting the mesh. The first edit (or
	# activate()) takes over from them, as for any component, so a part that's never touched
	# costs what a plain rigid body costs.
	var view := MeshInstance3D.new()
	view.name = "Part"
	view.transform = local
	view.mesh = shown
	for property: StringName in _render_settings:
		view.set(property, _render_settings[property])
	if view.layers == 0:
		view.layers = 1
	AdaptivePiece.set_materials(view, _resolved_materials())
	if _get_collision().enabled:
		var hulls: Dictionary = prepared.get(&"hulls", {})
		for key: Vector4i in hulls:
			for points: PackedVector3Array in hulls[key]:
				if points.size() < 4:
					continue
				var hull := ConvexPolygonShape3D.new()
				hull.points = points
				var shape := CollisionShape3D.new()
				shape.shape = hull
				shape.transform = local
				body.add_child(shape)
	# Its centre of mass (the mass is the body's already), from the pieces' volumes.
	var volume := 0.0
	var moment := Vector3.ZERO
	for entry: Array in (prepared.get(&"masses", {}) as Dictionary).values():
		volume += entry[1]
		moment += entry[2]
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = local * (moment / volume) if volume > 1e-9 else local * part.get_centre()
	var adaptive := AdaptiveMesh.new()
	adaptive.name = "Adaptive"
	adaptive.target = view
	adaptive.auto_bake = false
	adaptive.max_bounds = max_bounds
	adaptive.backend = backend
	adaptive.cleanup = cleanup
	adaptive.drawing = drawing
	adaptive.collision = collision
	adaptive.debris = debris
	adaptive.separation = separation
	adaptive.main_thread_budget_ms = main_thread_budget_ms
	adaptive._render_settings = _render_settings
	adaptive._mass_per_volume = density
	adaptive._prepared = prepared
	adaptive._owns_body = true
	adaptive._spawned_part = true
	adaptive.data = made
	view.add_child(adaptive)
	body.add_child(view)
	body.freeze = false
	_debris_parent().add_child(body)
	var motion := _part_motion(part)
	body.linear_velocity = motion[0]
	body.angular_velocity = motion[1]
	separation.add_part(adaptive)
	return adaptive


# A plain rigid body for a small [param part] (this node's space): drawn from
# [param surfaces], colliding as the hull of [param hull], not adaptive. Moving like the
# mesh, if it moves.
func _spawn_plain_part(part: Solid, surfaces: Array, hull: PackedVector3Array) -> RigidBody3D:
	var started := StageProfile.begin()
	var out := _spawn_plain_part_work(part, surfaces, hull)
	StageProfile.end(&"main: spawn parts", started)
	return out


func _spawn_plain_part_work(part: Solid, surfaces: Array, hull: PackedVector3Array) -> RigidBody3D:
	var density := _mass_per_volume if _moving != null and _mass_per_volume > 0.0 else separation.density
	var body := _part_body(part, density)
	var local := body.transform.affine_inverse() * _part_frame_parent() * global_transform
	var view := MeshInstance3D.new()
	view.mesh = AdaptivePiece.make_mesh(surfaces)
	for property: StringName in _render_settings:
		view.set(property, _render_settings[property])
	if view.layers == 0:
		view.layers = 1
	AdaptivePiece.set_materials(view, _resolved_materials())
	view.transform = local
	body.add_child(view)
	if hull.size() >= 4:
		var shape := CollisionShape3D.new()
		var convex := ConvexPolygonShape3D.new()
		convex.points = hull
		shape.shape = convex
		shape.transform = local
		body.add_child(shape)
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = local * part.get_centre()
	body.freeze = false
	_debris_parent().add_child(body)
	var motion := _part_motion(part)
	body.linear_velocity = motion[0]
	body.angular_velocity = motion[1]
	if separation.plain_lifetime > 0.0:
		_expire(body, separation.plain_lifetime)
	return body


# A frozen [RigidBody3D] for a part of this mesh ([param part], this node's space; mass from
# its volume and [param density]), placed where this mesh is (physics can't scale a body:
# the body takes this mesh's place and turn, what goes under it any scale), behaving like
# this mesh's body if it moves, with this mesh's physics layers if it doesn't. Not in the
# tree yet.
func _part_body(part: Solid, density: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = (get_target().name if is_component() else name) + "Part"
	if _moving != null:
		# It's a piece of that body: it behaves like it.
		for property in [&"collision_layer", &"collision_mask", &"gravity_scale", &"physics_material_override",
				&"linear_damp_mode", &"linear_damp", &"angular_damp_mode", &"angular_damp", &"continuous_cd",
				&"can_sleep"]:
			body.set(property, _moving.get(property))
	else:
		# On the mesh's layers, and colliding with them too: static meshes often have no
		# mask (they never need one), but a part that moves does, or it falls through the
		# world it came from.
		body.collision_layer = _get_collision().layer
		body.collision_mask = _get_collision().mask | _get_collision().layer
	if body.physics_material_override == null:
		body.physics_material_override = separation.get_physics_material()
	body.mass = maxf(part.get_volume() * density, 0.001)
	body.freeze = true
	var frame := Transform3D(global_transform.basis.orthonormalized(), global_transform.origin)
	body.transform = _part_frame_parent().affine_inverse() * frame
	return body


# Where parts go ([method _debris_parent]) as a global transform (identity for a viewport).
func _part_frame_parent() -> Transform3D:
	var parent := _debris_parent()
	return (parent as Node3D).global_transform if parent is Node3D else Transform3D.IDENTITY


# [velocity, spin] for [param part] (this node's space): this mesh's body's motion at the
# part's centre, or nothing for a static mesh.
func _part_motion(part: Solid) -> Array:
	if _moving == null:
		return [Vector3.ZERO, Vector3.ZERO]
	var middle := global_transform * part.get_centre()
	var pivot := _moving.global_transform * _moving.center_of_mass
	return [_moving.linear_velocity + _moving.angular_velocity.cross(middle - pivot), _moving.angular_velocity]


# True if [param box] (this node's space) is no bigger than a chunk along every axis the
# chunking cuts.
func _fits_one_cell(box: AABB) -> bool:
	if data.chunking == null:
		return true
	var cell := data.get_cell(Vector4i.ZERO)
	for axis in 3:
		if data.chunking.cuts_axis(axis) and box.size[axis] > cell.size[axis] + 1e-6:
			return false
	return true


# Unfreezes a separated part's body once its mesh is idle (its hulls are on), with
# [param velocity] and [param spin].
static func _release(body_ref: WeakRef, mesh_ref: WeakRef, velocity: Vector3, spin: Vector3) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	while mesh_ref.get_ref() != null and not (mesh_ref.get_ref() as AdaptiveMesh).is_idle():
		await tree.process_frame
	var body: RigidBody3D = body_ref.get_ref()
	if body == null:
		return
	body.freeze = false
	body.linear_velocity = velocity
	body.angular_velocity = spin


# Drops the piece at [param key] (nothing left of it): its node, its data and its share of
# the neighbours' seam shading (redrawn now, or later: see [method _set_border]).
func _remove_piece(key: Vector4i, later: Variant = null) -> void:
	_edits_unreported = true
	_set_border(key, {}, later)
	_borders.erase(key)
	var piece: AdaptivePiece = _pieces.get(key)
	if piece != null:
		piece.queue_free()
		_pieces.erase(key)
	data.pieces.erase(key)
	data.meshes.erase(key)
	_triangle_counts.erase(key)
	_piece_boxes.erase(key)
	_piece_mass.erase(key)
	_sep_cache.erase(key)


# A piece still counts as busy while it emits; check once it has wrapped up.
func _queue_idle_check() -> void:
	if not _idle_check_queued:
		_idle_check_queued = true
		_emit_if_idle.call_deferred()


func _emit_if_idle() -> void:
	_idle_check_queued = false
	if is_idle():
		if _check_emptied():
			return
		_update_mass()
		if _edits_unreported:
			_edits_unreported = false
			edited.emit()
		# (Also when nothing new was edited: a check that ran into an edit while it worked
		# asks for another once idle. It returns at once if there's nothing to look at.)
		_check_separation()


# Splits the piece at [param key] if it has grown past the chunking's limit and is done
# with its edits.
func _maybe_split(key: Vector4i) -> void:
	var rules := data.chunking if data != null else null
	if rules == null or rules.split_above <= 0 or key.w >= rules.max_split_depth or _splitting.has(key):
		return
	var piece: AdaptivePiece = _pieces.get(key)
	if piece == null or not piece.is_idle() or piece.solid.get_triangle_count() <= rules.split_above \
			or _unsplittable.has(key):
		return
	if _face_on_split_plane(key, piece.solid):
		_unsplittable[key] = true  # cutting along a flat face loses it (see below)
		return
	_split_piece(key, piece)


# True if a visible face of [param solid] lies in one of the planes that would split
# [param key]. Cutting exactly along a flat face is ambiguous for booleans, which may drop
# it (a terrain's flat side wall on a halfway line, say), so such pieces stay whole.
func _face_on_split_plane(key: Vector4i, solid: Solid) -> bool:
	var cell := data.get_cell(key)
	var cap := data.get_cap_tag()
	for axis in 3:
		if not data.chunking.cuts_axis(axis):
			continue
		var middle := cell.get_center()[axis]
		for t in solid.tags.size():
			if solid.tags[t] == cap:
				continue
			var flat := true
			for c in 3:
				if absf(solid.positions[solid.indices[t * 3 + c]][axis] - middle) > 1e-4:
					flat = false
					break
			if flat:
				return true
	return false


# Area of [param solid]'s visible faces (caps between pieces left out).
static func _visible_area(solid: Solid, cap: int) -> float:
	var total := 0.0
	for t in solid.tags.size():
		if solid.tags[t] == cap:
			continue
		var a := solid.positions[solid.indices[t * 3]]
		total += (solid.positions[solid.indices[t * 3 + 1]] - a).cross(solid.positions[solid.indices[t * 3 + 2]] - a).length()
	return total * 0.5


# True if [param made] (child key -> its share of [param solid]) shows exactly what the
# piece did: a cut that lost or added faces leaves the piece whole.
static func _split_clean(made: Dictionary, solid: Solid, cap: int) -> bool:
	var children_area := 0.0
	for child: Vector4i in made:
		children_area += _visible_area(made[child], cap)
	var area := _visible_area(solid, cap)
	return absf(children_area - area) <= 1e-4 * maxf(area, 1.0)


# Siblings can still differ along the walls between them: the boolean may drop a vertex
# on a straight edge in one and keep it in the other. Gives each child in [param made]
# the others' wall vertices, so the seams match vertex for vertex. [param cells]: child
# key -> its cell.
static func _match_sibling_walls(made: Dictionary, cells: Dictionary, cut_axes: Array[bool]) -> void:
	for child: Vector4i in made:
		var box: AABB = (cells[child] as AABB).grow(1e-4)
		var own := {}
		for p in (made[child] as Solid).positions:
			own[p] = true
		var points := PackedVector3Array()
		for other: Vector4i in made:
			if other == child:
				continue
			var walls: AABB = cells[other]
			for p in (made[other] as Solid).positions:
				if own.has(p) or not box.has_point(p):
					continue
				for axis in 3:
					if cut_axes[axis] and (absf(p[axis] - walls.position[axis]) < 1e-4 or absf(p[axis] - walls.end[axis]) < 1e-4):
						points.append(p)
						break
		if not points.is_empty():
			var fixed := (made[child] as Solid).duplicate() as Solid
			fixed.split_edges_at(points, 1e-4)
			made[child] = fixed


# A worker job splitting [param solid] with [param cuts] ([child key, its cut] each) on a
# thread-safe [param backend]: the children's shares (child key -> solid, empty ones left
# out) with matching walls, null if a boolean failed, or false if the split didn't come
# out clean.
static func _split_job(solid: Solid, cuts: Array, cells: Dictionary, cap: int, backend: BooleanBackend,
		cut_axes: Array[bool]) -> Callable:
	return func() -> Variant:
		var started := StageProfile.begin()
		var made := {}
		for cut: Array in cuts:
			var ops: Array[BooleanOp] = [cut[1]]
			var half: Solid = backend.combine(solid, ops, AABB(), cap)
			if half == null:
				return null
			if not half.is_empty():
				made[cut[0]] = half
		if not AdaptiveMesh._split_clean(made, solid, cap):
			return false
		AdaptiveMesh._match_sibling_walls(made, cells, cut_axes)
		StageProfile.end(&"chunk splits", started)
		return made


# Cuts the piece at [param key] into its children (see
# [method AdaptiveMeshData.get_children]). Edits reaching it meanwhile wait and go to the
# children; the children stay hidden until they're all drawn, then replace the piece.
func _split_piece(key: Vector4i, piece: AdaptivePiece) -> void:
	_splitting[key] = []
	var parent := data.get_cell(key)
	var cap := data.get_cap_tag()
	var child_keys := data.get_children(key)
	var cells := {}
	for child in child_keys:
		cells[child] = data.get_cell(child)
	var backend_used := get_backend()
	var made: Variant = {}
	if backend_used.is_thread_safe():
		# The cuts (boxes made here: resources aren't made on workers) on a worker thread, with
		# the checks and the walls matched: nothing of it on the main thread.
		var cuts := []
		for child in child_keys:
			cuts.append([child, _cut_to(cells[child], parent, cap)])
		made = await WorkerJobs.run(AdaptiveMesh._split_job(piece.solid, cuts, cells, cap, backend_used,
				_cut_axes(data)), self)
		if _pieces.get(key) != piece:
			return  # baked again or reset meanwhile
	else:
		for child in child_keys:
			await _budget().wait_turn(piece._priority())
			if _pieces.get(key) != piece:
				return  # baked again or reset meanwhile
			var start := Time.get_ticks_usec()
			var ops: Array[BooleanOp] = [_cut_to(cells[child], parent, cap)]
			var half: Solid = await backend_used.combine(piece.solid, ops, AABB(), cap)
			StageProfile.end(&"main: chunk splits", start)
			_budget().spend(Time.get_ticks_usec() - start)
			if _pieces.get(key) != piece:
				return
			if half == null:
				made = null
				break
			if not half.is_empty():
				made[child] = half
		if made != null:
			if not AdaptiveMesh._split_clean(made, piece.solid, cap):
				made = false
			else:
				AdaptiveMesh._match_sibling_walls(made, cells, _cut_axes(data))
	if made == null or made is bool:
		if made == null:
			push_warning("AdaptiveMesh: splitting piece %s failed; it stays whole." % key)
		else:
			# A cut that lost or added faces: keep the piece whole.
			push_warning("AdaptiveMesh: splitting piece %s didn't come out clean; it stays whole." % key)
			_unsplittable[key] = true
		var waiting: Array = _splitting[key]
		_splitting.erase(key)
		for args: Array in waiting:
			piece.edit_local(args[0], args[1], args[2], args[3])
		_queue_idle_check()
		return
	# Points a neighbour's split left for this piece (queued before or while it split) go
	# to the children whose cells have them: the piece they were for is going.
	if _seam_points.has(key):
		var queued: PackedVector3Array = _seam_points[key]
		_seam_points.erase(key)
		for child: Vector4i in made:
			var box := data.get_cell(child).grow(1e-4)
			var points := PackedVector3Array()
			for p in queued:
				if box.has_point(p):
					points.append(p)
			if not points.is_empty():
				var fixed := (made[child] as Solid).duplicate() as Solid
				fixed.split_edges_at(points, 1e-4)
				made[child] = fixed
	# Swap the data over: the cell is now its children.
	data.pieces.erase(key)
	data.meshes.erase(key)
	data.split_keys[key] = true
	_pieces.erase(key)
	_borders.erase(key)
	_triangle_counts.erase(key)
	for child: Vector4i in made:
		data.pieces[child] = made[child]
		_borders[child] = _border_parts_of(child, made[child])
	# Neighbours now border the children: same faces, filed under new keys. Their own
	# shading doesn't change, so they don't redraw.
	var neighbours := {}
	for child: Vector4i in made:
		for n in data.neighbour_keys(child):
			if not data.is_inside(n, key):
				neighbours[n] = true
	for n: Vector4i in neighbours:
		if data.pieces.has(n):
			_borders[n] = _border_parts_of(n, data.pieces[n])
	for n: Vector4i in neighbours:
		var piece_n: AdaptivePiece = _pieces.get(n)
		if piece_n != null:
			_set_neighbours(piece_n, n)
	# The children have vertices where the new walls meet the old ones; neighbours across
	# the old walls get them too.
	var on_walls := {}
	var cut := _cut_axes(data)
	for child: Vector4i in made:
		for p in (made[child] as Solid).positions:
			for axis in 3:
				if cut[axis] and (absf(p[axis] - parent.position[axis]) < 1e-4 or absf(p[axis] - parent.end[axis]) < 1e-4):
					on_walls[p] = true
					break
	for n: Vector4i in neighbours:
		if not _pieces.has(n):
			continue
		var box := data.get_cell(n).grow(1e-4)
		var points := PackedVector3Array()
		for p: Vector3 in on_walls:
			if box.has_point(p):
				points.append(p)
		if not points.is_empty():
			var queued: PackedVector3Array = _seam_points.get(n, PackedVector3Array())
			queued.append_array(points)
			_seam_points[n] = queued
			_close_seam(n)
	var children: Array[AdaptivePiece] = []
	for child: Vector4i in made:
		var made_piece := _make_piece(child)
		made_piece.visible = false
		children.append(made_piece)
	# Edits that arrived meanwhile go to the children (or make pieces in empty ones).
	var waiting: Array = _splitting[key]
	_splitting.erase(key)
	for args: Array in waiting:
		var shape: Solid = args[0]
		var local: Transform3D = args[1]
		var inside: Array[Vector4i] = []
		for k in data.keys_overlapping((local * shape.get_aabb()).grow(1e-4)):
			if data.is_inside(k, key):
				inside.append(k)
		_route(shape, local, args[2], inside, args[3])
	_queue_idle_check()
	# Show the children once each has a mesh, then drop the old piece.
	while children.any(func(c: AdaptivePiece) -> bool: return is_instance_valid(c) and c.get_mesh() == null):
		await get_tree().process_frame
	for c in children:
		if is_instance_valid(c):
			c.visible = true
	piece.queue_free()


# An intersect with [param cell], pushed out past the sides it shares with [param parent]
# (the piece already ends there) so only the new walls are cut, with [param cap].
static func _cut_to(cell: AABB, parent: AABB, cap: int) -> BooleanOp:
	var box := cell
	for axis in 3:
		var start := cell.position[axis]
		var end := cell.end[axis]
		var margin := 1.0 + parent.size[axis] * 0.01
		if is_equal_approx(start, parent.position[axis]):
			start -= margin
		if is_equal_approx(end, parent.end[axis]):
			end += margin
		box.position[axis] = start
		box.size[axis] = end - start
	var mesh := BoxMesh.new()
	mesh.size = box.size
	var solid := Solid.from_mesh(mesh)
	solid.uvs = PackedVector2Array()
	solid.weld()
	solid.tags.fill(cap)
	return BooleanOp.create(solid, Transform3D(Basis(), box.get_center()), BooleanOp.Operation.INTERSECT)


# The cells of [param key]'s neighbours, by key.
static func _cells_around(from: AdaptiveMeshData, key: Vector4i) -> Dictionary:
	var cells := {}
	for n in from.neighbour_keys(key):
		cells[n] = from.get_cell(n)
	return cells


static func _cut_axes(from: AdaptiveMeshData) -> Array[bool]:
	var out: Array[bool] = [false, false, false]
	if from.chunking != null:
		for axis in 3:
			out[axis] = from.chunking.cuts_axis(axis)
	return out


func _border_parts_of(key: Vector4i, solid: Solid) -> Dictionary:
	return _border_parts(solid, data.get_cell(key), _cut_axes(data), data.get_cap_tag(), _cells_around(data, key))


# Visible triangles of [param solid] (whose cell is [param cell]) with a corner on the
# cell's walls, filed by which of the neighbouring [param cells] (key -> box) they touch:
# what each neighbour needs to shade its side of the seam. Safe on worker threads.
static func _border_parts(solid: Solid, cell: AABB, cut: Array[bool], cap: int, cells: Dictionary) -> Dictionary:
	var started := StageProfile.begin()
	var out := _border_parts_work(solid, cell, cut, cap, cells)
	StageProfile.end(&"seam faces", started)
	return out


static func _border_parts_work(solid: Solid, cell: AABB, cut: Array[bool], cap: int, cells: Dictionary) -> Dictionary:
	if NativeKernel.on():
		var mask := (1 if cut[0] else 0) | (2 if cut[1] else 0) | (4 if cut[2] else 0)
		return ClassDB.class_call_static(NativeKernel.CLASS, &"border_parts", solid.positions, solid.indices,
				solid.tags, cell, mask, cap, cells)
	var parts := {}
	if cells.is_empty():
		return parts
	var positions := solid.positions
	var on_wall := PackedByteArray()
	on_wall.resize(positions.size())
	for v in positions.size():
		var p := positions[v]
		for axis in 3:
			if cut[axis] and (absf(p[axis] - cell.position[axis]) < 1e-4 or absf(p[axis] - cell.end[axis]) < 1e-4):
				on_wall[v] = 1
				break
	var indices := solid.indices
	var tags := solid.tags
	var border := PackedInt32Array()
	for t in tags.size():
		var i := t * 3
		if tags[t] != cap and (on_wall[indices[i]] or on_wall[indices[i + 1]] or on_wall[indices[i + 2]]):
			border.append(i)
	for key: Vector4i in cells:
		var box: AABB = (cells[key] as AABB).grow(1e-4)
		# In a fixed order (booleans reorder triangles), so comparing with the last edit's
		# faces only sees real changes.
		var found := []
		for i in border:
			var a := positions[indices[i]]
			var b := positions[indices[i + 1]]
			var c := positions[indices[i + 2]]
			if box.has_point(a) or box.has_point(b) or box.has_point(c):
				if b < a and b < c:
					found.append([b, c, a])
				elif c < a and c < b:
					found.append([c, a, b])
				else:
					found.append([a, b, c])
		if found.is_empty():
			continue
		found.sort()
		var faces := PackedVector3Array()
		faces.resize(found.size() * 3)
		for f in found.size():
			faces[f * 3] = found[f][0]
			faces[f * 3 + 1] = found[f][1]
			faces[f * 3 + 2] = found[f][2]
		parts[key] = faces
	return parts


# What the pieces around [param key] (in [param cells]) share with it, from [param borders].
static func _faces_for(borders: Dictionary, key: Vector4i, cells: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n: Vector4i in cells:
		var parts: Dictionary = borders.get(n, {})
		if parts.has(key):
			out.append_array(parts[key])
	return out


# The source's materials, overridden by [member PieceDrawing.materials].
func _resolved_materials() -> Array[Material]:
	var overrides := _get_drawing().materials
	var base: Array[Material] = data.materials if data != null else ([] as Array[Material])
	var out: Array[Material] = []
	for tag in maxi(overrides.size(), base.size()):
		var material: Material = overrides[tag] if tag < overrides.size() else null
		if material == null and tag < base.size():
			material = base[tag]
		out.append(material)
	return out


# The source reading [param node]: [member source] if it's a [NodeSource] (with its repair
# settings), otherwise one made here with the defaults.
func _node_source_for(node: Node3D) -> NodeSource:
	var assigned := source as NodeSource
	if assigned != null:
		if assigned.node != node:
			assigned.node = node
		return assigned
	if _node_source == null or _node_source.node != node:
		_node_source = NodeSource.new()
		_node_source.node = node
	return _node_source


# The target's collision objects, and the shapes in them, not counting this node's own.
func _target_bodies(node: Node, out: Array[CollisionObject3D]) -> void:
	if node == self:
		return
	if node is CollisionObject3D:
		out.append(node)
	for child in node.get_children():
		_target_bodies(child, out)


# Reads the target's look and physics layers for the pieces.
func _read_target() -> void:
	var meshes := _node_source_for(get_target()).get_mesh_instances()
	_render_settings = {}
	if not meshes.is_empty():
		var first := meshes[0]
		for property in [&"cast_shadow", &"layers", &"gi_mode", &"visibility_range_begin",
				&"visibility_range_begin_margin", &"visibility_range_end", &"visibility_range_end_margin",
				&"visibility_range_fade_mode", &"material_overlay", &"extra_cull_margin", &"lod_bias"]:
			_render_settings[property] = first.get(property)
	var bodies: Array[CollisionObject3D] = []
	_target_bodies(get_target(), bodies)
	_target_collision = null
	if not bodies.is_empty():
		_target_collision = PieceCollision.new()
		_target_collision.layer = bodies[0].collision_layer
		_target_collision.mask = bodies[0].collision_mask


# Hides the target's meshes (render layers 0, so this node, a child, stays visible) and
# switches off its collision shapes, remembering how they were.
func _take_over() -> void:
	if not _taken.is_empty():
		return
	for mesh in _node_source_for(get_target()).get_mesh_instances():
		_taken.append([mesh, &"layers", mesh.layers])
		mesh.layers = 0
	var bodies: Array[CollisionObject3D] = []
	_target_bodies(get_target(), bodies)
	if _moving != null:
		if not bodies.has(_moving):
			bodies.append(_moving)  # the pieces' hulls replace its shapes
		for property in [&"mass", &"center_of_mass_mode", &"center_of_mass"]:
			_taken.append([_moving, property, _moving.get(property)])
	for body in bodies:
		for owner_id in body.get_shape_owners():
			var shape_owner := body.shape_owner_get_owner(owner_id)
			if shape_owner is CollisionShape3D or shape_owner is CollisionPolygon3D:
				_taken.append([shape_owner, &"disabled", shape_owner.get(&"disabled")])
				shape_owner.set(&"disabled", true)
	_update_mass()
	activated.emit()


# Moving mode: true (after dealing with it) if nothing collidable is left: no pieces, or
# only flakes. A part frees its body; a body of the user's is frozen.
func _check_emptied() -> bool:
	if _moving == null or not is_instance_valid(_moving) or data == null:
		return false
	var flake := maxf(data.extent.get_longest_axis_size(), 1.0) / 3000.0 / 4.0
	for key: Vector4i in data.pieces:
		var solid: Solid = data.pieces[key]
		if not solid.is_empty() and not MeshSeparation.is_flake(solid, flake):
			return false
	var body := _moving
	_moving = null
	emptied.emit()
	if _owns_body:
		body.queue_free()
	else:
		body.freeze = true
	return true


# Moving mode: the body's mass follows the mesh's volume (at the mass per volume it had
# when the pieces first appeared) and its centre of mass the mesh's middle. Volumes are
# kept per piece until it changes.
func _update_mass() -> void:
	if _moving == null or not is_instance_valid(_moving) or data == null:
		return
	var volume := 0.0
	var moment := Vector3.ZERO
	for key: Vector4i in data.pieces:
		var solid: Solid = data.pieces[key]
		var entry: Array = _piece_mass.get(key, [])
		if entry.is_empty() or not is_same(entry[0], solid):
			var piece_volume := solid.get_volume()
			entry = [solid, piece_volume, solid.get_centre() * piece_volume]
			_piece_mass[key] = entry
		volume += entry[1]
		moment += entry[2]
	if volume <= 1e-9:
		return
	if _mass_per_volume <= 0.0:
		_mass_per_volume = _moving.mass / volume
	_moving.mass = maxf(volume * _mass_per_volume, 0.001)
	_moving.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	_moving.center_of_mass = (_moving.global_transform.affine_inverse() * global_transform) * (moment / volume)


# Undoes [method _take_over] and drops the pieces.
func _hand_back() -> void:
	for entry: Array in _taken:
		if is_instance_valid(entry[0]):
			(entry[0] as Object).set(entry[1], entry[2])
	_taken.clear()
	_active = false
	_clear_pieces()


# True if [param node] collides with anything other than its meshes' exact triangles.
func _has_simplified_collision(node: Node) -> bool:
	if node == null or node == self:
		return false
	if node is CollisionShape3D and not ((node as CollisionShape3D).shape is ConcavePolygonShape3D):
		return true
	if node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _has_simplified_collision(child):
			return true
	return false
