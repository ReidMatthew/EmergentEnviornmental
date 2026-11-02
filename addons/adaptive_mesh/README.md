# Adaptive Mesh

Dig into and add to an authored mesh at runtime with mesh booleans. Untouched parts keep
the exact triangles you authored; new triangles only appear where a shape cut or joined
the surface, at the shape's own density. Low poly where nothing happened, detail only
where it did.

| | |
|---|---|
| Version | 0.23.1 (keep in sync with `plugin.cfg`) |
| Last tested on | Godot 4.7.2 (Forward+, D3D12) |
| Depends on | none (later: `meshers`, for shapes made from distance fields) |

Nothing in here is terrain-specific: the same node works for rocks, walls, props or a
terrain chunk.

## Install

1. Copy this folder into `res://addons/` of the target project.
2. Project > Project Settings > Plugins > enable **Adaptive Mesh**. Optional: everything is
   a `class_name` script and works with the plugin off; the plugin adds the editor's Bake
   button.

## What enabling the plugin changes

- Adds a **Bake** button to `AdaptiveMesh`'s inspector (see [Baking in the
  editor](#baking-in-the-editor)). Nothing else: no autoloads, settings or input actions.

## Usage

`AdaptiveMesh` is the only node you add, for a rock or a whole terrain. Use it one of two
ways:

- **As a component on a mesh you already have** (terrain, props, rocks, buildings): the
  usual way, and how all the demos are built. Put it under the `MeshInstance3D`, or next to
  an imported model with `target` set (see [Making existing meshes
  adaptive](#making-existing-meshes-adaptive)).
- **On its own, with a `source`**, for meshes made in code with no node of their own to
  attach to:

  ```gdscript
  var mesh := AdaptiveMesh.new()
  mesh.source = MeshSource.new()
  mesh.source.mesh = generated_mesh    # a closed Mesh
  mesh.chunking = GridChunking.new()   # optional
  add_child(mesh)                      # bakes when it enters the tree
  ```

What it does is set by the resources in its slots:

| Slot | Resource | What for |
|---|---|---|
| `source` | component: empty, or a `NodeSource` for repair settings; on its own: `MeshSource` (a closed mesh) or `SceneSource` (a .glb/.tscn, repaired if needed) | what to bake from |
| `chunking` | empty (one piece) or `GridChunking` | cut big meshes into pieces, so an edit only works on the pieces it touches |
| `data` | `AdaptiveMeshData` | the baked pieces: shapes and ready-to-draw meshes; edits update it |
| `drawing` | `PieceDrawing` | materials by tag, crease angle, shadows (empty: defaults) |
| `collision` | `PieceCollision` | on/off, layer, mask, hulls per piece for moving meshes (empty: on, one hull) |
| `backend` | empty: `get_default_backend()` (the Manifold backend if the `adaptive_mesh_native` add-on is installed, otherwise `CsgBooleanBackend`) | runs the booleans |
| `cleanup` | `MeshCleanup` (empty: off) | tidies the triangles each edit made |
| `separation` | `MeshSeparation` (empty: off) | parts digs and cuts divide off become adaptive meshes of their own, on rigid bodies |
| `debris` | `MeshDebris` (empty: off) | breaks what each dig removes into fragments that fall as plain rigid bodies (fracturing; paused) |

One plain setting besides `max_bounds`: `main_thread_budget_ms` (default 4), the main-thread
time per frame booleans may take. Every adaptive mesh counts against one shared tally per
frame, so an edit reaching more pieces than fit, or many meshes edited at once, is spread
over the next frames instead of stalling one (the first boolean of a frame always runs; 0
means no limit for that mesh). Work waiting for its turn goes nearest the camera first, so
a big operation shows up where the player is looking first and finishes further away a
few frames later.

Baking cuts the source with `chunking` and builds every piece's mesh (on worker threads);
the result is `data`. Bake in the editor and save it (below), and the game starts with the
pieces ready. Without saved `data`, the node bakes when the game starts (the terrain demo
takes about 2 s). `bake()` does it on demand and `baked` fires when it's done; edits made
while baking are applied afterwards. `reset()` throws edits away: back to the saved `data`,
or a fresh bake if there was none. Then:

```gdscript
var sphere := SolidSphere.new()
sphere.radius = 2.0
$AdaptiveMesh.edit(sphere, Transform3D(Basis(), hit_position), BooleanOp.Operation.SUBTRACT)
```

### Making existing meshes adaptive

Add an `AdaptiveMesh` as a child of a `MeshInstance3D` and leave its `source` empty, or
put it anywhere and point `target` at the node to make adaptive (it reads every
`MeshInstance3D` under it, with their materials, skipping `UCX_`-style collision meshes).
Added under a mesh in the editor, it sets `target` to that parent by itself, so the
inspector shows what it's attached to. Keep it at zero transform under its target; one
placed elsewhere moves onto the target when the game starts. Slots you leave empty use
the target: what it reads (its meshes, default settings) and how it collides (copies the
physics layers of the target's own collision, and follows them if they change). The
inspector panel spells both out ("Reads: ...", "Collision: ..."). To repair what it reads (merge near-miss seams, close an open
terrain sheet), give it a `NodeSource` as its `source`: the same repair settings as
`SceneSource`, read from the target. Sizes are the target's own, so scale the model (or
its import), not the source.

```
Rock (MeshInstance3D)          your mesh, untouched
├── Collision (StaticBody3D)   its collision, as authored
└── Adaptive (AdaptiveMesh)  added: that's all
```

- **Dormant until edited.** The rock draws and collides as authored and costs nothing
  extra. The first edit (or `activate()`) takes over: the rock's meshes are hidden
  (render layers 0, so the component, a child, still shows), its collision shapes are
  switched off, and the component's pieces show instead. Pieces copy the rock's render
  layers, shadow casting, GI mode, visibility range and material overlay, and collide on
  its physics layers (unless `collision` is set). `activated` fires then.
- **`activation`**: `On First Edit` (default) or `At Start`. A rock whose own collision is
  simpler than its mesh (a box or hull, the usual) collides with its exact triangles once
  it takes over, so whatever rests on it can shift a little at that moment; the inspector
  notes it (under the Bake button), and `At Start` takes over when the game starts instead.
- **Bake** saves `<mesh>.adaptive.res` next to the mesh (or scene). Put the component in
  the rock's own scene (`rock.tscn`) and every placed rock shares that bake, each copying
  it only when first edited. Without a bake, the first edit bakes it (a short stall for a
  rock). For an imported `.glb`, wrap it in a small scene with the component (the usual
  prefab), or put the component next to the instance with `target` set (Godot only lets
  you add children inside an imported scene with Editable Children).
- **`reset()`** hands the mesh back as authored; the next edit takes over again.
- **Static or moving.** Under a static target, pieces collide as `StaticBody3D`s with
  their exact triangles. Under a `RigidBody3D`, the mesh moves with it: see
  [Moving meshes](#moving-meshes).

**Which mesh did I hit?** `AdaptiveMesh.find(hit.collider)` returns the adaptive mesh a
collision object belongs to (a dormant mesh's own collision, a piece, or the mesh itself),
or null for ordinary geometry:

```gdscript
var target := AdaptiveMesh.find(hit.collider)
if target != null:
	target.edit(brush, Transform3D(Basis(), hit.position), BooleanOp.Operation.SUBTRACT)
```

Every adaptive mesh in a running game is in the `adaptive_meshes` group
(`AdaptiveMesh.get_all(get_tree())`), for example to edit every one a blast reaches.
Reserving a physics layer for diggable things (`PieceCollision.layer`, or the rock's
own layer for components) lets rays and shape queries hit only them.

### Moving meshes

Put the component on the mesh of a `RigidBody3D` (or an `AdaptiveMesh` anywhere under one)
and it moves with the body (`is_moving()`, `get_body()`). Nothing to switch on: the body
above it is what decides.

- **Collision:** moving bodies need convex shapes, so each piece collides as its convex
  hull, added to the body as a shape of its own (built on the worker thread with the
  piece's mesh, replaced on every edit). Taking over switches the body's own shapes off,
  as for a static target, and `reset()` gives them back.
- **Mass:** the body keeps the mass it has, and from then on its mass follows the mesh's
  volume (a rock dug in half weighs half). Its centre of mass is set to the middle of the
  mesh's volume, so it tips the way it should once one side is dug away. Inertia is left
  to the physics engine, worked out from the hulls.
- **Edits** are placed in the mesh's own space when they're made, so a dig or a cut lands
  where it was aimed even if the body moves before the edit is applied.
- **Scale:** physics can't scale a `RigidBody3D`; scale the mesh (and its collision shape)
  under it instead, uniformly. The demo's rigid rock does.
- **`find()`** knows the body, so a ray that hits it finds the mesh.
- **Dug away:** when nothing collidable is left (everything dug away, or only flakes),
  `emptied` fires; a part that separated frees its body, and a body of your own is frozen
  so it doesn't fall away with nothing to collide with.
- **Hulls:** `collision.hulls_per_piece` (1 by default) sets how many convex hulls each
  piece collides as. One hull fills in the piece's hollows and hooks (a slot dug through a
  rock still collides as if solid); more follow them: the piece is halved again and again
  across its longest side, each half split into the parts that don't touch, and each part
  is a hull (`ConvexCells.hull_sets()`). With more than one, the hulls are worked out on a
  worker thread after the edit is drawn, so collision catches up a frame or two after the
  look. Cost per piece on that worker: about 5 ms for 4 hulls and 10 ms for 8 on an
  80-triangle rock, 16-30 ms on a 1,000-triangle piece; and more shapes for the physics
  engine. The demo's rigid rocks use 4.
- **Limits for now:** swapping a resting body's hulls can nudge it.

### Baking in the editor

You don't have to: with `auto_bake` on (the default) the node bakes by itself in the
editor, when it's added without data and again about a second after what it's baked from
changes (a component's target meshes, the source, the chunking or `max_bounds`; it waits
for edits to settle). It saves silently, as compressed binary, and points `data` at the
file:

- **Where:** the file `data` is already in, if any; otherwise `<mesh>.adaptive.res` next to
  the mesh or model it's baked from, or next to the scene for a mesh made inside the scene.
  In a scene that hasn't been saved yet, the data stays in the scene until it is.
- **Shared:** a file there that was baked from the same thing is reused, so every copy of
  a rock (or a prefab like `rock.tscn`) shares one bake. A file baked from something else
  isn't overwritten: the new one gets a number (`crate_2.adaptive.res`).
- **What it watches:** every bake stores a fingerprint of what it was made from (file
  contents for imported models, mesh arrays otherwise); the node compares it once a
  second. Nodes sharing one file must share their settings too (give a copy with different
  chunking its own data).

The game then starts with the pieces ready (the terrain demo: about 70 ms instead of 2 s).
A big terrain takes a couple of seconds to bake, in the background; turn `auto_bake` off
to bake it only when you press the plugin's **Bake** button (the button also suggests a
path the first time, and overwrites that file after). The inspector shows what's baked,
where it's saved, and notes such as the collision switch.

Warnings in the scene tree are for real problems only: a component with no mesh to take
over, a component sitting off its target, a mesh that isn't closed (booleans fail on it),
and, with `auto_bake` off, a missing or out-of-date bake. In the editor a standalone node
shows its pieces; a component shows nothing extra (its target shows itself).

### Demos

Three scenes built the way you'd use the add-on: ordinary models, each made adaptive by an
`AdaptiveMesh` component with its bake saved next to the model, and small components
around them.

| Node | What it is |
|---|---|
| the model | an ordinary mesh or imported model, with its `Adaptive` component (`AdaptiveMesh`: chunking, drawing, cleanup and bounds in the inspector; `data` = the saved bake) |
| `Camera` | `components/orbit_camera.gd`: right drag orbits, wheel zooms |
| `DigTool` | `components/dig_tool.gd`: left drag digs whatever adaptive mesh is under the mouse (`AdaptiveMesh.find()`; set `mesh` to limit it to one), Shift + left drag builds, holding still goes deeper or higher, Ctrl + wheel sizes the brush. X switches to cutting (then dismantling, then back): drag a line across a mesh (starting beside it is fine), let go, and it's cut along the line away from the camera, `cut_depth` of the way through (Ctrl + wheel; 100% divides it). The part to copy into a game: mouse rays into a `BrushStroke`, raycasting a snapshot of the surface (`get_collision_shapes()`) so strokes don't dive into their own trench. X cycles on to dismantling: click a mesh and it's cut into cubes `cube_size` across (`dismantle()`; Ctrl + wheel sizes them). Brush, layers, spacing, sweep, speeds, cut depth and cube size are exported |
| `DebugOverlay` | `components/debug_overlay.gd`: controls and stats on screen (for its `mesh`, or whatever the dig tool last dug); F wireframe, E or 1-4 brush detail, T sweep, C cleanup, K chunks on/off (bakes again), B debris on/off, L separation on/off, R reset. Diagnostics only: delete it and the rest still works |

- `demo/rocks_demo.tscn`: six rocks on ordinary ground. Each is `demo/rock.tscn`: a plain
  `MeshInstance3D` with a convex hull for collision, made adaptive by an `AdaptiveMesh`
  child; they all share one bake (`models/rock.adaptive.res`). The rocks stay ordinary
  meshes until dug (the overlay counts how many have taken over); the ground isn't
  adaptive, so the tool leaves it alone. Digs break off falling debris, and a rock dug or
  cut right through has its top come off as a rock of its own (still adaptive: dig or
  cut it again). Three more are `demo/rigid_rock.tscn`: the same rock on a `RigidBody3D`
  (mesh and hull scaled under it), dropped at the start; dig or cut one and it moves on
  with its new shape, its smaller part flying off.
- `demo/hill_demo.tscn`: a `MeshInstance3D` showing a low-poly hill (`models/hill.res`,
  24 wide) with exact collision (`models/hill_shape.res`) and an `Adaptive` child, cut
  into 16 pieces. It stays an ordinary mesh until dug; digs break off falling debris, and
  parts dug or cut off all the way round come away as adaptive meshes of their own.
- `demo/terrain_demo.tscn`: `models/low_poly_terrain.glb` placed as it is, a
  12,000-triangle low-poly terrain imported 200 units wide, with an `Adaptive` node next
  to it (`target` set: imported scenes don't take children) holding a `NodeSource` that
  merges its seams and closes it to a floor. It's cut into 64 pieces and takes over at
  start (the model has no collision of its own). See [Using an imported
  terrain](#using-an-imported-terrain). Fresh cuts draw as soil, the walls and floor the
  repair adds as rock. Parts cut off all the way round come away as adaptive meshes (cut
  under an overhang, or dig in from the side); no dig fragments here: with brushes this
  big they'd be boulders.
- `demo/castle_demo.tscn`: a castle on a rolling field, with rocks around it. The castle
  is a copy of toon_shading's demo castle (`demo/tools/castle_layout.gd`, so that add-on
  isn't needed): its 880 overlapping primitives merged into one closed 29,000-triangle
  mesh, cut into 92 pieces of 16 units (`castle.tscn`). The field is a closed slab 256
  units wide, flat under the castle, cut into 24-unit columns (`field.tscn`). Both take
  over at start; the 40 rocks are `rock.tscn` scaled up, ordinary until dug. One brush
  (tag 10) draws as cut stone in the castle, soil in the field and the inside of a rock.
  Dig through a tower's base or cut a wall and what's no longer standing on the ground
  comes down as adaptive meshes of its own. `demo/tools/build_castle_demo.gd` builds the
  models, their bakes and the scene (run it headless; see its header).

The hill and terrain brushes start with their detail matched to the surface's triangles (`edge_length`
0.8 on the hill, 3.81, the model's average edge, on the terrain).

- **Operations:** `SUBTRACT` (dig), `UNION` (add), `INTERSECT` (keep only the overlap).
- **Shapes** (`SolidShape`): `SolidSphere` (an icosphere; `subdivisions` 0-4 gives 20
  to 5,120 triangles, which sets how detailed and how expensive each crater is),
  `SolidBox`, and `SolidMesh` (any closed mesh: a rock, a crater with a hand-made rim).
  `edit_solid()` takes a solid instead.
- **Automatic sphere detail (optional):** set `SolidSphere.edge_length` above 0 and the
  sphere picks the subdivision level whose edges come closest to that length, so small and
  big craters come out about equally dense. 0 (the default) uses `subdivisions`.
- **Strokes:** `BrushStroke` turns any continuous edit (a held mouse button, a drill,
  a burning fuse) into as few cuts as it can. Call `begin(mesh, point)`, then
  `update(point, delta)` every frame (the same point to hold still), then `end()`.
  - The brush sits at the input point, pushed along `advance_direction` by how far it has
    advanced. It advances at `advance_speed` while the input moves slower than that (or
    always, with `advance_while_moving`; `max_advance` caps it), so holding still digs a
    bore or builds a pillar and dragging digs along the surface.
  - It edits only once the brush has moved `spacing`, and never while the mesh is still
    busy (movement in between goes into the next edit).
  - With `sweep`, each edit is the shape swept from the last brush position to the new
    one (`Solid.swept`, convex shapes only), so a stroke is one trench, bore or pillar
    instead of a pile of overlapping stamps. `band_edge_length` sets how long the sweep's
    triangles are along the stroke; `SolidSphere.get_edge_length()` matches it to the
    brush.
  - Feed it points on the surface as it was when the stroke began, or a dig stroke dives
    into its own trench. `get_collision_shapes()` is that snapshot for free: pieces never
    change a shape they made (edits make new ones), so holding on to the current shapes
    keeps the surface as it was. The demo puts them on a physics layer of its own at the
    start of each stroke and raycasts that.
- **Cuts:** `cut(from, to, direction, depth, thickness = 0, tag = 1)` subtracts a thin slab that
  runs along the line `from` - `to` (global) and reaches `depth` in `direction`. Shallow,
  it's a notch; deep enough to come out the other side, it divides the mesh (with
  `separation` on, the part that's cut off becomes a mesh of its own).
  - A cut is a subtraction, never a zero-thickness plane: the gap is what separates the
    parts. Thickness 0 uses `get_cut_thickness()` (1/1000 of the mesh's size, also
    the thinnest: anything under `get_min_cut_thickness()` is raised to it), since booleans get
    unreliable when a cut is much thinner than the object. `get_aabb()` is the size it
    goes by (the mesh as it is now, kept per piece).
  - What a cut removes is discarded: it never becomes debris, even with `debris` on
    (`edit_solid(..., debris = false)` does the same for any subtract).
  - The demo's cut mode starts each cut just in front of the mesh's box along the view,
    so dragging from beside an object cuts it from its front face.
- **Dismantling:** `dismantle(cube_size, thickness = 0, tag = 1)` cuts the whole mesh into cubes
  `cube_size` across (world units): a cut on every plane that far apart along each of the
  mesh's own axes, through its whole box, in one batch, the grid centred on the box,
  each cut taking out a gap of `thickness` (default 5% of the cube size, so the cuts
  show). It returns how many cuts it made. With `separation` on, the cubes come apart as meshes of
  their own; on the Ground anchor the bottom layer stays (it stands on the ground), and
  cubes resting on cubes stay stacked until something knocks them. The castle demo's
  castle at cube size 5: 51 cuts, about 1,150 cubes, in about 4 s, with frames of up
  to about 160 ms while the cubes are added.
- **Edits are queued** per piece and applied in batches: every edit made while a batch
  runs goes into the next one. `piece_edited(key)` fires when a piece's batch is drawn
  (`key` is a `Vector4i`, see splitting below),
  `edited` when every piece is done; `is_idle()` says whether anything is pending.
- **Tags:** every triangle has an int tag that survives booleans. The source's surfaces
  (or materials, for `SceneSource`) get tags 0, 1, ...; a shape's faces get its `tag`
  (default 1). Each tag draws with the source's material for it, overridden by
  `drawing.materials[tag]`, so cut faces can look like dirt while the authored surface
  stays grass.
- **Bounds:** with `max_bounds` set, unions never add anything outside the box; the faces
  where a union is cut off there are drawn with the shape's tag. With chunking, pieces are
  only made inside it. Subtractions are unaffected.
- **Cleanup (optional):** give `cleanup` a `MeshCleanup` and every batch is tidied on
  the worker thread before drawing: short edges (`min_edge_length`) and needle slivers are
  collapsed, cap slivers (`sliver_angle`) get their longest edge flipped, never moving the
  surface by more than `max_error`.
  - Only triangles the edit made can change. `unlock_rings` (0-4) also lets it reshape
    that many rings of old triangles around them, which fixes the long thin fans where a
    cut meets the old surface; 0 keeps every untouched triangle exactly.
  - Edges sharper than `feature_angle` and edges where tags meet are kept: vertices on
    them only slide along them. Vertices on a piece's bounds never move.
  - Removed vertices are merged into a neighbour, so no new positions appear. Override
    `clean()` for another simplifier.
- **Chunking:** `GridChunking` cuts the mesh into cells `cell_size` apart (0 on an axis
  doesn't cut along it, so terrain can use columns; `offset` moves the grid).
  - The cut uses the same booleans, halving the source until every piece is one cell.
    Faces that close a piece off at its cell walls get the chunking's `cap_tag` and are
    hidden; each piece's bounds is its cell, so unions don't spill into a neighbour (the
    neighbour gets its own part) and cleanup never moves seam vertices. Neighbouring
    surfaces meet exactly (tested after digs and builds across walls, with and without
    cleanup).
  - Shading carries across the seams: each piece also gets its neighbours' triangles
    along the shared walls, so vertices on a wall draw the same normal on both sides. A
    piece's wall faces are filed per neighbour, and only a neighbour whose share changed
    redraws (on the worker thread): a dig in the middle of a piece redraws none, a dig
    next to one wall only the piece across it (it used to be all eight).
  - Unions create pieces in empty cells (inside `max_bounds`, if set).
  - **Crowded pieces split.** Booleans cost about as much as the whole piece, so a place
    dug over and over would get slower. When a piece passes the chunking's `split_above`
    triangles (default 2000) after its edits, it's cut in half along every axis the
    chunking cuts (4 pieces for terrain columns), up to `max_split_depth` times (default
    3). Detail ends up finer exactly where it was edited. The new pieces stay hidden until
    they're drawn, then replace the old one; edits made meanwhile wait and go to them.
    Neighbours across the old walls get the new seam vertices inserted into their edges,
    so seams keep matching vertex for vertex (no T-junctions). Pieces are keyed
    `Vector4i(x, y, z, depth)`: depth 0 is a chunking cell, and a split cell's children
    are one depth down (`AdaptiveMeshData.split_keys` lists the split cells; saved data
    keeps them).
  - **Put cell walls along edges the source already has** where you can (a mesh authored
    on a grid: a cell size that is a multiple of its spacing, `offset` onto a grid line).
    The demo hill cuts into 16 pieces with no extra triangles that way (672 -> 576,
    Manifold also merges its flat bottom), but with walls between its grid lines it gains
    a row of triangles along every wall (996). Keep walls off large flat faces.
  - Per edit, a 16 x 16 box costs about 65 ms in one piece and 20-35 ms in 4 x 4 columns,
    about the same as an 8 x 8 box in columns: the cost follows the edit, not the mesh.
    Small meshes gain little.
- **Each piece is its own node** (internal `AdaptivePiece` children, with a
  `MeshInstance3D` each), so Godot culls the pieces out of view one by one.
- **Collision:** each piece gets a `StaticBody3D` with a trimesh shape, rebuilt after every
  batch.
- **Shading:** faces that bend less than `drawing.crease_angle` (default 40 degrees) are
  shaded smooth across their edges, so curved cuts look round and sharp edges stay sharp;
  0 shades flat.
- **Saving:** `data` holds every piece's shape and drawn mesh, edits included. Save it as a
  `.res`; a node given saved data shows it at once, with nothing to bake or build. Nodes
  can share one data resource (twenty copies of a rock): each switches to its own copy on
  its first edit, so edits never leak between them.

### Separation

Give `separation` a `MeshSeparation` and when digs and cuts divide the mesh (a cut right
through, an overhang tunnelled under, a pillar cut at its foot), the parts that come away
become adaptive meshes of their own, each on a `RigidBody3D`: they fall, and they can be
dug, cut and divided again. Leave the slot empty or untick `enabled` and nothing is
checked, at no cost (the demos' L key toggles `enabled`). `separated(parts, plain)` hands
you the new meshes (and any plain bodies, below).

- **What stays:** `anchor`. `Auto` (default): `Ground` on a static mesh, `Largest` on a
  moving one. `Ground`: parts reaching down to the mesh's bottom (its lowest point when it
  appeared, plus `anchor_margin`, in its own space) stay; for anything standing on the
  ground or closed off below. `Largest`: the biggest part stays. `Nothing`: once a static
  mesh is in two or more parts, they all come away (something that should come down when
  it breaks); a moving mesh keeps its biggest part.
- **Only what digs and cuts divide:** parts that were separate from the start (a floating
  island in the model) stay where they are, even when dug into.
- **What a part is made of:** the pieces it was part of, under the same keys and chunk
  grid (the shapes shared, no booleans), with the mesh's settings (drawing, cleanup,
  backend, debris, separation), look and physics layers. Pieces that leave whole bring
  their drawn meshes and leave the mesh entirely; the rest redraw without the part.
- **Small parts are one piece:** a part no bigger than a chunk that straddles cell walls
  (a pebble across a corner would otherwise be four pieces) is joined into one piece
  without chunking: `AdaptiveMeshData.merged()` drops the walls between its pieces and
  welds the seams (each side was cut separately, so seam corners within a hair are made
  one). If they don't join up closed, the part keeps its pieces.
- **Its body:** placed where the mesh is (any scale goes on the mesh under it, since
  physics can't scale bodies), held still until its hulls are on, then let go. A part of a
  moving mesh takes the body's speed at its own centre, the body's mass per volume and
  its physics settings (gravity scale, damping, physics material, continuous collision,
  sleeping); a part of a static mesh gets `density` and the mesh's collision layers, and
  collides with those layers too (static meshes often have no mask of their own).
- **Dust:** parts smaller than `min_size` across are dropped instead.
- **How it's found:** once the mesh is idle after edits, a worker thread splits the
  pieces that changed into parts that don't touch (kept for next time; untouched pieces
  aren't read again) and joins parts across the walls between pieces by their shared
  corners. A part spawns once the pieces it left have redrawn, so it never starts inside
  their old collision.
- **Limits:** `min_adaptive_size`: parts smaller than that come away as plain rigid
  bodies (drawn, colliding as one hull, not editable), which cost no more than any rigid
  body. `max_parts`: at most that many adaptive parts made with these settings at once
  (every mesh using the resource counts); past it, the oldest is made plain or freed
  (`over_limit`). `plain_lifetime`: plain parts shrink away and are freed after that
  long (0 keeps them). `make_plain()` turns any moving adaptive mesh into a plain body
  yourself; `MeshSeparation.get_parts()` lists the adaptive parts counted.
- **Cost:** none while digging, and none per frame for a part at rest (nothing runs per
  frame; it costs what its rigid body costs). The check runs on a worker after edits
  settle, and so does working out the parts (the rest of each piece, seam shading, hulls,
  masses, merging small parts); parts are added within the frame budget, one at a time.
  Slicing the terrain demo in four: worst frame 10.4 ms with separation on, 9.3-10.7 ms
  with it off (headless). A dig on a moving rock costs about what it does on a static one
  (worst frames 2-8 ms either way).
- **For now:** a part collides as one hull per piece, so a hooked part may start out
  touching the mesh and get pushed clear.

### Debris

Fracturing, paused: kept as it is. Give `debris` a `MeshDebris` and every dig (a
subtract) breaks what it removed into fragments that fly apart as plain `RigidBody3D`s and
shrink away (`fragments`, on). Leave the slot empty or untick `enabled` and there's none,
at no cost (the demos' B key toggles `enabled`).

- **What a fragment is:** the material the dig took out of a piece, cut by a random
  Voronoi split into pieces about `fragment_size` across (at most `max_fragments` per dig
  per piece), each part that doesn't touch the rest its own fragment. A dig across the
  pieces of a chunked mesh breaks along the piece walls too. Fragments keep the mesh's
  materials: the outside as it was, the inside with the cut's tag.
- **How it falls:** each fragment starts exactly in the hole it came out of and flies
  apart at `scatter_speed`. For convex brushes (spheres, boxes, their sweeps) its hull
  stays inside the hole, so nothing starts stuck in the mesh. Freed after `lifetime`.
- **Collision:** a convex hull of the fragment's outermost corners, a little smaller than
  itself; mass from its volume and `density`. Fragments smaller than `min_size` across, or
  thinner than a sixth of it, are dropped as dust instead.
- **How many:** at most `max_bodies` per mesh (the oldest go first). `reset()` and
  `clear_debris()` free them all; `get_debris()` lists them.
- **Layers:** `layer` and `mask`. Keep fragments off the layers your dig rays hit, or a
  click on one won't reach the mesh behind it (the demos put them on layer 3 and let them
  collide with layers 1 and 3).
- **Cost:** one more boolean per dig on each piece it reaches (about the dig's own cost,
  on the main thread with the CSG backend, within `main_thread_budget_ms`, while the dig's
  own worker job runs). The cutting into fragments is done by clipping on worker threads,
  not booleans (a cut whose outline has a hole, a few percent of them, takes a boolean).
  On the hill demo, ten digs with fragments take the same worst frame as without (about
  10 ms of CPU, headless) and about 2% more time in all. `fragments` off: none of this.
- **Your own bodies:** override `MeshDebris.make_body()` (sounds on impact, particles,
  pooling), or connect to `debris_spawned(bodies)`. Fragments go into the current scene,
  not under the mesh, so `AdaptiveMesh.find()` doesn't take them for the mesh.
- **Not adaptive:** they're plain rigid bodies; you can't dig into them.

### Using an imported terrain

Terrains made only for rendering usually aren't solids, and booleans need solids. The
repair settings fix the usual problems: they're on `NodeSource` (a component reading its
target) and `SceneSource` (a standalone mesh reading a scene file). The terrain demo is
set up like this:

1. **Import the model at the size you want.** In the `.glb`'s import settings, Root Scale
   0.02 makes this 10,000-unit model 200 wide; its `UCX_` collision meshes are set to Skip
   Import, so placed copies don't draw them. Then place the model as it is.
2. **Add an `AdaptiveMesh` next to it** with `target` set to the model, and a `NodeSource`
   as its `source`:

```gdscript
var repairs := NodeSource.new()
repairs.merge_tolerance = 0.02   # its four pieces miss each other by up to 0.02 units
repairs.close_to_floor = true    # it's an open sheet: add walls and a floor
repairs.floor_depth = 40.0       # deeper than anything will dig
$Adaptive.source = repairs
$Adaptive.target = $Terrain
$Adaptive.activation = AdaptiveMesh.Activation.AT_START  # the model has no collision
```

What the repairs do, in order (baking prints a report, and warns if the result still
isn't closed):

1. **Combines every `MeshInstance3D`** under the target (or in the scene, for
   `SceneSource`, optionally under `root_path`), placed where it sits, into one solid with
   one tag per material. Meshes named like collision meshes (`skip_prefixes`: `UCX_` and
   friends) are skipped, so they don't duplicate the visible ones.
2. **Scales** it to `width` (`SceneSource` only: a component's pieces must match its
   target, so scale the model instead).
3. **Joins pieces** that don't quite meet: `merge_tolerance` (`Solid.merge_close`), then
   optionally `fix_t_junctions` for borders where one side has a vertex the other
   doesn't. A terrain should end up with one open loop, its outer edge
   (`Solid.get_boundary_loops`).
4. **Closes** an open sheet with `close_to_floor`: walls straight down from the open edge
   and a flat floor, `floor_depth` below the lowest point, with their own tag (after the
   scene's materials; `floor_material` sets its look).

A mesh you author yourself is best modelled closed in Blender; then it needs no repairs.

Baking cuts the source by halving it until every piece is one cell, so each cut only
works on the piece it halves. For the demo terrain (12,780 triangles after closing): 64
pieces and their meshes in about 2 s. Bake in the editor and save it to skip that at
start.

### Fewer small triangles

Every cut adds the brush's triangles inside the solid, plus slivers where the cut line
crosses the old triangles, plus fragments wherever cuts overlap. The opt-in `quality` test
drags the same stroke across the demo hill several ways (radius 1.5, 24 units, slow then
fast; "tiny" is under 0.005 square units, a "sliver" has an angle under 10 degrees):

| Variant | Edits | New triangles | Tiny | Slivers | Time (ms) |
|---|---|---|---|---|---|
| Before: a stamp every 0.12 s | 28 | 5,334 | 1,989 | 2,034 | 1,115 |
| Stamps spaced 0.75 | 30 | 5,536 | 2,022 | 2,082 | 1,262 |
| Swept, spaced 0.75 | 30 | 4,470 | 1,197 | 1,654 | 1,133 |
| Stamps spaced 1.5 | 16 | 3,582 | 960 | 1,138 | 468 |
| Swept, spaced 1.5 | 16 | 3,688 | 733 | 1,164 | 520 |
| Stamps 0.12 s + `edge_length` 0.8 | 28 | 2,906 | 905 | 1,236 | 730 |
| Swept, spaced 1.5 + `edge_length` 0.8 | 16 | 1,188 | 263 | 519 | 303 |

- Fewer, wider-spaced edits help most: each one adds a cut line and its slivers.
  Spacing by distance also makes the result independent of how fast the mouse moves.
- Sweeping removes 25-40% of the tiny triangles at the same spacing (the overlapping
  crater rims are gone), but barely touches the slivers along the cut lines.
- `edge_length` cuts triangles by matching the brush to the size it needs to be.
- Combined: 78% fewer new triangles, 87% fewer tiny ones, 75% fewer slivers, and 3.7x
  faster. What remains is mostly slivers along cut lines.

The cleanup pass deals with those (`min_edge_length` 0.25, `max_error` 0.03):

| Variant | Edits | New triangles | Tiny | Slivers | Time (ms) |
|---|---|---|---|---|---|
| Before + cleanup, rings 0 | 28 | 1,940 | 40 | 118 | 994 |
| Before + cleanup, rings 1 | 28 | 1,824 | 9 | 69 | 1,032 |
| Swept 1.5 + `edge_length` 0.8 + cleanup, rings 0 | 16 | 658 | 70 | 108 | 443 |
| Swept 1.5 + `edge_length` 0.8 + cleanup, rings 1 | 16 | 600 | 38 | 63 | 456 |

- Cleanup alone removes 98% of the tiny triangles and 94-97% of the slivers, and the
  booleans get cheaper because the solid stays smaller.
- With everything on: 89% fewer new triangles, 98% fewer tiny ones and 97% fewer
  slivers than before, with the same volume dug out (shape kept).
- A cleanup costs about 1 ms per 50 triangles of the whole solid (it rebuilds adjacency
  every time), on the worker thread.

## Licences

`demo/models/low_poly_terrain.glb`: "low poly terrain" by Power-craft
(https://sketchfab.com/Power-craft), from
https://sketchfab.com/3d-models/low-poly-terrain-e95cad736a3843df8dd960c155003ed2,
licensed CC BY 4.0 (http://creativecommons.org/licenses/by/4.0/). Unmodified; the demo
scales and closes it at load.

## How it works

```
bake()  -> source.get_solid() -> chunking.split()  -> build meshes (worker threads) -> data
edit()  -> each piece it reaches (AdaptivePiece, one per cell):
             queue -> backend.combine_main(solid, ops)  CSG: right away (main thread, frame budget)
                   -> one worker job:
                        backend.combine() / _finish()   Manifold: the whole boolean here; CSG: result to a solid
                        cleanup.clean(...)              optional tidy-up
                        solid.build_surfaces()          draw arrays + collision faces
                        border faces                    for the neighbours' seam shading
                   -> ArrayMesh + ConcavePolygonShape3D, data updated, piece_edited
                   -> neighbours whose share of the border changed redraw -> edited
                   -> past split_above triangles: split into smaller cells
```

An edit shows up the frame after it's made (`piece_edited`); `edited` fires once
neighbouring pieces have redrawn their seam shading too, usually a frame or two later.

- `Solid` holds positions, indices, one tag per triangle and optional UVs. It welds
  vertices on the way in, so meshes split at UV seams (like `BoxMesh`) count as closed.
- `BooleanBackend` is swappable. `CsgBooleanBackend` builds a hidden CSG tree (Godot's
  CSG uses the Manifold library since 4.4) and bakes it; tags travel through it as one
  placeholder material per tag. The sibling add-on `adaptive_mesh_native` adds
  `ManifoldBooleanBackend`, which calls Manifold directly through a GDExtension, on
  worker threads, with the same results; meshes use it by themselves when it's installed
  (`get_default_backend()`, found by class name: this add-on doesn't need it).
- Jobs on worker threads go through `WorkerJobs`, and whatever starts one waits for it
  before it's freed: Godot crashes if it quits while a GDScript job still runs.
- The heaviest geometry (clean-up, surfaces and normals, seam faces, islands, welding,
  joining parts in separation checks) runs in C++ when `adaptive_mesh_native` is
  installed: `NativeKernel` calls its `AdaptiveMeshKernel` instead of the GDScript, which
  gives exactly the same results (that add-on's tests check it) 5 to 20 times faster.
  Without it, the GDScript runs. `NativeKernel.enabled = false` switches it off.
- `StageProfile` adds up the time each stage takes on any thread (booleans, clean-up,
  surfaces, seam faces, hulls, separation, applying results, spawning parts), for the
  benchmark in `adaptive_mesh_native/tests/benchmark.gd`.

### The CSG backend's limits

Godot's CSG nodes only work inside the scene tree, on the main thread. With
`CsgBooleanBackend`:

- Booleans run **on the main thread**. The backend forces the CSG update
  (`_update_shape()`), so they finish in the same frame instead of at its end; on a Godot
  without that method it waits a frame instead.
- They cost a few milliseconds for a piece of a few hundred triangles (3.5 ms for the
  terrain demo's busiest piece, 410 triangles, and a 320-triangle sphere) and grow with
  the whole solid: 70 ms for the same dig on the whole 12,780-triangle terrain.

That's fine for props and small pieces, and fine for prototyping. For big meshes, use
chunking so each piece stays small, and install `adaptive_mesh_native`: its backend runs
on worker threads at about a third of the cost (a dig stroke's worst frame on the terrain
demo: 14.9 ms with CSG, 6.9 ms with it).

## Architecture

```
plugin.gd                                        the editor plugin: adds the Bake button
editor/
  bake_inspector.gd                              the Bake button: bakes and saves data
icon.svg                                         the node's icon in the scene tree
adaptive_mesh.gd          AdaptiveMesh         the node: slots, baking, routing edits to pieces, component mode
brush_stroke.gd           BrushStroke          a drag as spaced, optionally swept edits
core/
  solid.gd                Solid                closed mesh + tags; weld, repair, sweep, normals, faces, volume, islands
  adaptive_mesh_data.gd   AdaptiveMeshData     baked pieces (shapes + meshes), cells, materials
  boolean_op.gd           BooleanOp            one step: shape, transform, operation
  boolean_backend.gd      BooleanBackend       abstract: combine(target, ops, bounds, ...)
  csg_boolean_backend.gd  CsgBooleanBackend    Godot CSG nodes (Manifold), main thread
  frame_budget.gd         FrameBudget          shares main-thread time per frame between pieces
  worker_jobs.gd          WorkerJobs           jobs on worker threads, waited for when their owner is freed
  native_kernel.gd        NativeKernel         uses adaptive_mesh_native's C++ geometry when it's installed
  stage_profile.gd        StageProfile         time per pipeline stage, for benchmarks (off by default)
  mesh_cleanup.gd         MeshCleanup          collapses and flips away small and thin triangles
  mesh_separation.gd      MeshSeparation       separation settings; finds the parts a mesh is in
  convex_cells.gd         ConvexCells          clipping solids by planes, Voronoi cells, hull sets for collision
sources/
  solid_source.gd         SolidSource          abstract: what to bake from (cached)
  mesh_source.gd          MeshSource           a closed mesh
  scene_source.gd         SceneSource          an imported scene: combine, scale, merge, close
  node_source.gd          NodeSource           a node's meshes in the scene (what a component reads)
chunking/
  chunking.gd             Chunking             abstract: cells and cutting
  grid_chunking.gd        GridChunking         a regular grid, cut by halving
pieces/
  adaptive_piece.gd       AdaptivePiece        internal: one piece's solid, edit queue, mesh, collision
  piece_drawing.gd        PieceDrawing         materials by tag, crease angle, shadows
  piece_collision.gd      PieceCollision       on/off, layer, mask
debris/
  mesh_debris.gd          MeshDebris           digs' removed material into falling fragments: Voronoi clipping, hulls, bodies
shapes/
  solid_shape.gd          SolidShape           abstract: builds an Solid, cached
  solid_sphere.gd         SolidSphere          icosphere
  solid_box.gd            SolidBox
  solid_mesh.gd           SolidMesh            any closed mesh
demo/
  hill_demo.tscn, terrain_demo.tscn, rocks_demo.tscn, castle_demo.tscn   the demos: ordinary models with an AdaptiveMesh component
  castle.tscn, field.tscn                        the castle demo's castle and field prefabs
  rock.tscn                                      a rock prefab made adaptive by a component
  rigid_rock.tscn                                the same rock on a RigidBody3D: a moving adaptive mesh
  components/                                    orbit_camera, dig_tool, debug_overlay
  tools/                                         build_castle_demo.gd and castle_layout.gd (a copy of toon_shading's castle)
  materials/                                     the castle demo's plain materials
  models/                                        the hill (and its collision shape), terrain and rock, with their saved bakes
```

### Adding your own

| To add | Extend | Implement |
|---|---|---|
| Source | `SolidSource` | `_build()` (append materials by tag to `_cached_materials`); `emit_changed()` when a property changes; override `get_fingerprint()` if the solid depends on more than the stored properties |
| Chunking | `Chunking` | `get_cell`, `keys_overlapping`, `neighbour_keys`, `cuts_axis`, `split` (coroutine) |
| Boolean backend | `BooleanBackend` | `combine(target, ops, bounds, bounds_tag, bounds_walls)` (may be a coroutine); `is_thread_safe()`. Main-thread backends can also split the work: `combine_main` (main thread, may be a coroutine) and `combine_finish` (worker thread) |
| Shape | `SolidShape` | `_build_solid()`; call `emit_changed()` when a property changes |
| Cleanup | `MeshCleanup` | `clean(solid, before, bounds)` (worker thread) |

## Tests

```
godot --headless --path <project> -s res://addons/adaptive_mesh/tests/run_tests.gd
```

Name groups after `--` to run only those, or `all` to include the opt-in ones.

| Group | Covers |
|---|---|
| `solid` | building from meshes (UV seams welded, tags per surface), `SolidBox` matching a `BoxMesh`, icospheres closed and wound like Godot's front faces, `edge_length` picking levels, swept spheres and boxes closed and outward, repairing a two-piece sheet (`merge_close`, `fix_t_junctions`, `close_to_floor`), mirrored transforms staying outward, crease shading, surfaces per tag, hidden tags |
| `booleans` | subtract keeping every untouched triangle exactly, closed results, unions cut to bounds with `bounds_tag` faces, intersect, several ops in one batch, 40 chained random edits staying closed (time per edit printed) |
| `node` | one piece: baking on its own, drawing, a frame's edits going in one batch and kept in the data, collision following edits, reset, a union cut off at `max_bounds` closed by shown faces, `drawing.materials`, collision off |
| `cleanup` | fewer triangles, tiny ones and slivers after overlapping digs, still closed, volume kept, untouched triangles kept exactly, no new positions, `unlock_rings`, bounds vertices kept, cleanup inside `AdaptiveMesh` |
| `chunks` | cutting (each chunk closed, seams joined, area kept), digs across chunk walls reaching only the chunks they touch with seams still matching, cleanup keeping seams, the same normals drawn on both sides of every seam, built into new pieces above, `max_bounds` (nothing outside; cut-off unions closed by shown faces), saved and loaded `data` (no baking, saved meshes shown), two nodes sharing data, per-edit cost flat as the mesh grows, crowded pieces splitting (also with random edits arriving mid-split, against a mesh that never splits) (same surface as unsplit, seams matching vertex for vertex, edits across new and old walls, split data saved and loaded), neighbours redrawing only when their seam changed, collision shapes as snapshots |
| `stroke` | holding still digs a bore and builds a pillar to the right depth and height in a few swept edits, a fast drag stays level, `max_advance`, `advance_while_moving` |
| `latency` (opt-in) | on the terrain demo's data: frames until an edit shows and until it settles (at 60 fps), and the worst frame (uncapped), for one piece, four pieces and a stroke (printed) |
| `component` | auto-bake saving (next to the mesh, data pointed at the file, a matching file shared, another's never overwritten); dormant until the first edit (draws and collides as authored, `find()` knows it); taking over (bake if needed, mesh hidden, collision off, pieces on its physics layers and with its look); saved data taking over in the same frame and copied on edit; `At Start`; a target set by path; reset handing back; fingerprints going stale and matching again; warnings only for problems (the collision switch is a note); freeing a mesh mid-edit |
| `debris` | `Solid` volume and islands; Voronoi cells filling their box; clipping (closed, half a box, a sphere cut in two adding up, a cut with a hole left to a boolean, which still adds up); breaking up a sphere into closed fragments that add up, kept whole when small, dropped under `min_size`; a mesh's dig dropping rigid bodies with hulls in the hole that hold what it removed, building dropping nothing, reset clearing them; no setting or `enabled` off dropping nothing, `max_bodies`, `lifetime`; `edited` firing after a dig's debris work |
| `separation` | a cut most of the way round separating nothing; all the way round, the top coming away as an adaptive mesh on a rigid body in the scene, `find()` knowing it, inheriting its pieces' keys and chunk grid, closed and the right volume, mass from volume and density, let go once its hulls are on and falling; the mesh keeping the bottom; the part dug and divided again (the smaller side leaving it); off looking at nothing; `Largest` and `Nothing` (the mesh left with no pieces, pieces leaving whole bringing their drawn meshes); a part separate from the start staying; a moving mesh's part leaving with its speed and physics settings, both weighing their share; a box and a sphere across a cell corner merging from 4 pieces into 1 (closed, same volume, no walls left); a small block cut off a chunked base coming away as one closed piece without chunking; with `min_adaptive_size` above it, coming away as a plain body (one mesh, one hull, not adaptive, moving, mass from volume); `max_parts` 1 making the oldest part plain (node gone, its pieces' meshes and hulls kept on its body) or freeing it; nothing running per frame for a part at rest |
| `cut` | the frame budget shared by every mesh (one budget's spending makes another wait, 0 runs at once, waiting work going nearest first); `get_aabb()` and cut thicknesses following the size; a shallow cut is a notch (one closed part, the right volume), a cut right through divides into two equal closed halves, a too-thin cut made at the limit, a direction along the line cutting nothing; a level cut across a chunked mesh dropping the part above; a cut making no debris while a dig does |
| `moving` | under a `RigidBody3D`: `get_body()`, `find()` taking the body for the mesh; taking over (the body's own shape off, the piece's hull on the body where the mesh sits in it), mass kept and the centre of mass in the middle; after a bite, mass following the volume, the centre moving away from it, a new hull; reset handing the body back as it was; a dig on a turned body that moves before the edit is applied still landing where it was aimed; one hull per piece when chunked; a body falling onto a floor and resting on its hulls; everything dug away (a part's body freed, a user's body frozen); a slot cut through a rigid box filled in by one hull and left open by 8 (whose walls still collide) |
| `demos` | the hill and terrain demos start from their saved bakes (no baking), the bakes match a fresh bake and their fingerprints, holding the mouse digs (needs a window; skipped with `--headless`), reset goes back to the saved bake; the rocks demo's rocks stay dormant, share an up-to-date bake, `find()` tells them from the ground, digging one takes over only that one, a line dragged across another in cut mode (starting beside it) cuts it through, and a rigid rock dug takes over its body with the piece's hull |
| `quality` (opt-in) | one dig stroke done several ways: edits, new, tiny and sliver triangles, volume removed and time printed (the table above) |
| `soak` (opt-in) | a long random run (two seeds, 60 steps) of digs, builds and cuts on a static chunked mesh, a moving one and every part that comes off them (parts of parts too), checking after each step that every piece is closed, the total volume (meshes, parts, plain bodies) changed by exactly what the edit removed or added, adaptive parts stay within `max_parts` and nothing fell through the floor; worst frames printed; everything freed afterwards with no orphan nodes and no growth in objects. Then a static mesh splitting at 150 triangles, dug and cut for 100 steps, every piece staying closed |

## Changelog

- 0.23.1: Cheaper separated parts.
  - A part shows as one mesh until it's edited (its pieces' surfaces joined, or its one
    piece's mesh), with no holder node: the dormant component sits under that mesh and
    targets it. Each piece gets its own mesh when the part takes over, from surfaces kept
    for it, at once. A part made plain keeps that one mesh.
  - Spawned parts skip reading their target (their settings come from the mesh they came
    off); every mesh shares its default drawing and collision settings; a mesh's share of
    the frame budget is made when first used.
  - Castle dismantle: spawning ~1,100 parts 202 -> ~170 ms of main-thread time, all out
    ~0.83 -> ~0.74 s, still no frame over 16.7 ms.
- 0.23.0: Fewer frames per edit, nearest first, cheaper big operations.
  - Every edit a piece gets in one frame goes in one job (the first used to start alone,
    the rest waiting for it): a dismantle runs 92 piece jobs instead of 184.
  - Worker jobs are checked twice a frame (also just before drawing), so a job done
    during a frame is applied in that frame.
  - The frame budget lets waiting work through nearest the camera first
    (`FrameBudget.wait_turn(priority)`, `FrameBudget.camera_distance()`); separated parts
    spawn nearest first.
  - Chunk splits run on a worker thread (thread-safe backends): a castle stroke's worst
    frame 37 -> 12 ms.
  - Cheaper requests: `SolidBox` scales a unit box instead of making a `BoxMesh` each time
    (a cut's call 3.9 -> 0.3 ms, a dismantle's 13 -> 4 ms); one `BooleanOp` shared by
    every piece an edit reaches.
  - Separation: the parts' data is made on the worker, each part keeping only the split
    cells its pieces are in; neighbours redraw their seams once per separation, not once
    per changed neighbour; quicker neighbour lookups. Main thread 22 -> 10 ms for a
    dismantle.
  - Separated parts' meshes are made when each part spawns, within the frame budget, not
    on the workers: a mesh made on a worker still sends its data to the GPU on the main
    thread before the frame is drawn, outside any budget, and a dismantle's thousand
    meshes landed in one frame (60-75 ms).
  - Native (with `adaptive_mesh_native` 0.2.0): volume, centre, bounding box, `encloses`,
    merging, `split_edges_at`, `fix_t_junctions`, seam snapping, `count_open_edges`,
    `AdaptiveMeshData.merged`.
  - Benchmarks (window, Manifold, against 0.22.0 measured the same way): castle stroke
    176 -> 67-125 ms, worst frame 38 -> 10 ms; cut 62 -> 44 ms; dismantle, all ~1,100
    parts out, 0.82 s either way, but no frame over 16.7 ms (worst 30 -> 15 ms). Soak
    deep splits: worst frame 119-146 -> 76-78 ms.
  - Fixed: editing after a dismantle could stop the game (a script error, which the editor
    breaks on). The demo overlay kept its wireframe under the mesh it showed, freed with
    a part; `MeshDebris.break_up` passed on a mesh freed while it worked;
    `BrushStroke` and the demo's cut tool kept using a freed mesh. The demos test frees a
    part the overlay shows.
  - Tests: the runner fails a group that hits a script error (a group that didn't compile
    used to pass with no checks run).
- 0.22.0: Dormant parts, meshes on worker threads.
  - Separated parts start dormant: a rigid body showing the part's meshes and colliding
    as its hulls, with an `AdaptiveMesh` component that takes over on the first edit (or
    `activate()`). A part nobody touches costs what a plain rigid body costs.
  - Meshes are made on worker threads (not under the headless renderer, whose mesh
    storage isn't thread-safe), and a redraw that only changes shading keeps the piece's
    collision shape. Castle dismantle: everything out in ~0.8 s instead of ~1.5.
  - Tests: a race in the chunks group (two bakes awaited one after the other) could hang
    the run.
- 0.21.0: A native backend (sibling add-on), dismantle gaps, seams across split depths.
  - New sibling add-on `adaptive_mesh_native` 0.1.0 (GDExtension, Windows x86_64 for
    now): `ManifoldBooleanBackend`, Manifold called directly, on worker threads, giving the
    same results as CSG; and `AdaptiveMeshKernel`, the clean-up, surfaces, seam faces,
    islands, welding and joining parts in C++. New `AdaptiveMesh.get_default_backend()`:
    meshes with no `backend` use the Manifold one when it's installed, CSG otherwise; new
    `NativeKernel` uses the C++ geometry when it's installed. A castle stroke settles in
    99 ms instead of 244 (CSG and GDScript), the castle dismantle in 1.1 s instead of 2.95.
  - New `StageProfile`: time per pipeline stage, for benchmarks.
  - With adaptive_mesh_native, a piece's whole edit (boolean, clean-up, surfaces,
    collision data, seam faces) is one native call (`NativeKernel.edit_job`), and moving
    pieces' hulls are worked out natively (a rigid rock dig settles in 20 ms instead of
    35).
  - `dismantle()` takes out a visible gap between the cubes: 5% of the cube size by
    default (`DISMANTLE_GAP`), instead of the 1/1000-of-the-mesh cut thickness, which was
    too thin to see (the cubes looked uncut).
  - New `WorkerJobs`: every job on a worker thread is waited for when the node that
    started it is freed (pieces did, the mesh's separation, debris and hull jobs didn't).
    Fixes a crash when a game quits mid-edit.
  - Fixed: seams between pieces split to different depths. An edit across the wall
    between a finer piece and a coarser one left the coarser one without the finer one's
    corners on that wall (T-junctions); now they're put into its edges after each edit.
    And points a neighbour's split left for a piece that was itself splitting were lost.
    Both showed with the faster backend (edits and splits overlap more).
  - Separated parts spawn much faster (dismantling the castle into 1,100 cubes: the
    cubes are all out 0.8 s after the cuts instead of 2.2 s): each part's pieces get
    their drawn meshes from the separation job (no job each after spawning), that job
    and the pieces' part analysis run over all worker threads, a spawned part skips its
    first separation check (it's one connected whole), `MeshSeparation.add_part` no
    longer scans every part on every add, and results going into the scene (meshes,
    collision) share the frame budget, so many pieces finishing at once spread over
    frames.
  - Fixed: when a piece left entirely as several parts (a dismantle; any cut that frees
    more than one part from one chunk), each part drew the whole piece's mesh, so copies
    of the piece (a lattice of thin cut plates) flew about with every small part. A piece's
    drawn mesh now only goes with a part that took all of it.
  - `cut()`, `get_cut_slab()` and `dismantle()` take a `tag` for the faces they make (1 by
    default, as before); the demo dig tool passes its brush's, so cuts look like digs
    (they drew with the mesh's material 1: the castle's roof blue).
  - Fixed: an edit that landed while the mesh's first separation check was still running
    was never checked (since 0.19.1 the follow-up check waited for an edit report).
- 0.20.0: Dismantle.
  - New `AdaptiveMesh.dismantle(cube_size, thickness)`: cuts the whole mesh into cubes (a
    cut on every plane `cube_size` apart along each axis, in one batch); with separation
    the cubes come apart.
  - The demo dig tool's `cut_mode` is now `mode` (dig, cut, dismantle; X cycles), with
    `cube_size` (Ctrl + wheel in dismantle mode). The demos set a cube size to suit them
    (castle 5, terrain 10, hill 3, rocks 0.3).
- 0.19.1: Castle demo, slippery parts, thinner cuts.
  - `demo/castle_demo.tscn`: a copy of toon_shading's castle (merged into one closed mesh,
    92 pieces) on a generated field, with rocks; `demo/tools/build_castle_demo.gd` builds
    it. `rock.tscn` draws the dig tag 10 as its inside too.
  - `MeshSeparation.friction` and `MeshDebris.friction` (0.3; Godot's default is 1): the
    bodies they spawn get it as a physics material, so parts slide and topple instead of
    sticking. A moving mesh's parts keep its body's material if it has one.
  - `cut()`'s default thickness is 1/1000 of the mesh's size (was 1/250), the thinnest
    it makes.
  - Fixed: `edited` fired a second time after a dig across chunks (neighbours redrawing
    their seam shading count as going idle since 0.19.0); it now fires once per batch of
    edits, and the separation check with it.
- 0.19.0: Several hulls per piece for moving meshes.
  - `PieceCollision.hulls_per_piece` (1): moving meshes collide as that many convex hulls
    per piece, following hollows and hooks (`ConvexCells.hull_sets()`: halving and
    splitting into parts that don't touch). Worked out on a worker after the edit is
    drawn; separated parts get theirs with the rest of their set-up.
  - `ConvexCells`: clipping, Voronoi cells and hull sets moved into the core
    (`MeshDebris` keeps its functions, which call them); clipping is faster (it only
    looks at edges on the cutting plane).
  - `AdaptivePiece.get_collision_shapes()` (all of a piece's shapes).
  - Cuts never make debris (`edit_solid()` has a `debris` argument for any subtract).
  - Fixed: after a redraw, the mesh could miss that it was idle again (mass, separation
    checks and `edited` waited for the next edit).
  - The demo's rigid rocks use 4 hulls per piece.

- 0.18.2: Fixes from the new soak test.
  - A dig that stays inside the mesh (a hollow) no longer gets undone: separating took the
    hollow for a part of its own and dropped it. Hollows belong to what surrounds them.
  - A part with two pieces in the same chunk (joined through neighbouring chunks) no
    longer loses one of them.
  - Shapes and sources (`SolidShape`, `SolidSource`) no longer leak: they kept themselves
    alive through their own `changed` signal.
  - A moving part dug down to nothing frees its body (it fell forever with nothing to
    collide with); a body of your own is frozen instead. New signal `emptied`.
  - Flakes (thinner than a quarter of the thinnest cut) are dropped when they separate,
    whatever `min_size` is: physics can't collide with them.
  - The CSG backend no longer leaves a node behind when there's nothing to cut.
  - Splitting crowded pieces leaves their neighbours closed: seam points are inserted on
    both sides of edges that are split only by UV, aren't inserted twice, and
    zero-area triangles (two corners in one place) are dropped when welding. (Since
    0.8.0.)
  - New `get_cut_slab()`: the slab `cut()` would subtract, to preview it.

- 0.18.1: Parts of a static mesh with no collision mask (usual for static bodies) collide
  with the mesh's own layers too, instead of falling through the world.

- 0.18.0: Limits, and separating off the main thread.
  - `MeshSeparation` limits: `min_adaptive_size` (smaller parts come away as plain rigid
    bodies), `max_parts` and `over_limit` (the oldest adaptive part past the limit is made
    plain or freed), `plain_lifetime`; `get_parts()`.
  - New `make_plain()`: a moving adaptive mesh becomes a plain body (its drawn meshes and
    hulls kept).
  - `separated` now has a second argument: `separated(parts, plain)`.
  - Working out what separates (the rest of each piece and its seam shading, each part's
    seam shading, hulls and masses, merging) runs on a worker; parts are added within the
    frame budget. Slicing the terrain demo no longer spikes (worst frame as with
    separation off).

- 0.17.0: Small parts are one piece.
  - A part that comes away no bigger than a chunk but across cell walls is joined into one
    piece without chunking, instead of several.
  - New `AdaptiveMeshData.merged()`: the data as one piece, walls dropped and seams welded
    (null if it doesn't join up closed).

- 0.16.0: Parts that come away stay adaptive.
  - New `separation` slot (`MeshSeparation`, off by default): when digs and cuts divide
    the mesh, the parts that come away become adaptive meshes of their own on
    `RigidBody3D`s, inheriting their pieces (same keys and chunk grid, shapes shared, no
    booleans) and the mesh's settings and look; they can be dug, cut and divided again.
    `anchor` (`Auto`, `Ground`, `Largest`, `Nothing`), `anchor_margin`, `min_size`,
    `density`. A moving mesh's parts take its speed, mass per volume and physics settings.
    New signal `separated(parts)`.
  - Removed (breaking): `MeshDebris.loose_parts`, `anchor`, `anchor_margin`,
    `loose_part_lifetime`, the `MeshDebris.Anchor` enum, and the `parts_fell` signal. Use
    `separation` instead. `MeshDebris` (dig fragments) is otherwise unchanged; fracturing
    is paused.
  - Pieces left with nothing are dropped from the mesh.
  - Demos: separation on the rocks, rigid rocks, hill and terrain (L toggles it).

- 0.15.0: Moving meshes.
  - Under a `RigidBody3D` the mesh moves with it: pieces collide as convex hulls on the
    body (built on the worker thread, replaced on each edit) instead of static trimeshes;
    taking over switches the body's own shapes off and `reset()` gives them back.
  - The body's mass follows the volume from the mass it had; its centre of mass follows
    the shape. New `get_body()` and `is_moving()`; `find()` knows the body.
  - `Solid.get_hull_points()` and `Solid.get_centre()` (moved from `MeshDebris`, which
    still has both).
  - The rocks demo has three rigid rocks (`demo/rigid_rock.tscn`).

- 0.14.0: Cuts, and one frame budget for every mesh.
  - New `cut(from, to, direction, depth, thickness)`: a thin slab subtraction along a line,
    a notch when shallow, dividing the mesh when it goes through. Thickness defaults to
    `get_cut_thickness()` and never goes under `get_min_cut_thickness()`. New
    `get_aabb()`.
  - `FrameBudget` keeps one tally per frame for every adaptive mesh, so many meshes edited
    at once share `main_thread_budget_ms` instead of each taking it.
  - The demo dig tool has a cut mode (X): drag a line across a mesh, let go to cut;
    Ctrl + wheel sets how far through.

- 0.13.0: Loose parts fall.
  - `MeshDebris.loose_parts` (off by default): when digs cut a part off all the way round,
    it leaves the mesh and falls as one body. `anchor` picks what stays (`Ground`,
    `Largest`, `Nothing`), parts separate from the start stay, and
    `loose_part_lifetime` sets how long fallen parts last. New signal `parts_fell(bodies)`.
    Found on a worker thread after edits settle, re-reading only changed pieces.
  - `MeshDebris.fragments` switches dig fragments on its own (on), so either kind can be
    used without the other; the settings are grouped (Dig fragments, Loose parts, Bodies).
  - Fixed: with dig fragments on, `edited` didn't fire after digs (pieces now emit
    `finished` once their debris work is done too).
  - The demos drop loose parts (L toggles them); the terrain demo has them without dig
    fragments.

- 0.12.0: Debris.
  - New `debris` slot (`MeshDebris`, off by default): each dig breaks what it removed into
    fragments that fall as rigid bodies and shrink away after `lifetime`. Settings for size,
    count, dust, density, scatter, lifetime, the most at once, and physics layers;
    `make_body()` to make your own. New on the node: `debris_spawned(bodies)`,
    `get_debris()`, `clear_debris()`; `reset()` clears them.
  - Fragments are cut by clipping on worker threads (Voronoi cells), with a boolean only
    for cuts whose outline has a hole; the removed material takes one boolean per dig,
    run while the dig's own worker job does; bodies are added within the frame budget.
  - `Solid.get_volume()` and `Solid.get_islands()`; `AdaptivePiece.set_materials()`.
  - The hill and rock demos drop debris (B toggles it).

- 0.11.0: Baking takes care of itself in the editor.
  - New `auto_bake` (on): in the editor the node bakes when added without data, and again
    about a second after its target's meshes, source, chunking or bounds change. It saves
    silently next to the mesh or model (`get_data_path()`: the existing file, else
    `<mesh>.adaptive.res`, reused if baked from the same thing, numbered if not) and points
    `data` at it.
  - Configuration warnings only for real problems: no mesh to take over, an offset from
    the target, an open (unclosed) mesh, and a missing or stale bake only with
    `auto_bake` off. The collision-switch warning is now a note in the inspector
    (`get_collision_note()`).
  - File hashes for fingerprints are cached by modification time.
  - Added under a `MeshInstance3D` in the editor, a component sets `target` to it by
    itself (the demos set it too), and the inspector says what empty slots resolve to:
    what it reads (`get_reads_description()`) and how it collides
    (`get_collision_description()`).

- 0.10.0: Components, unprefixed names, and fixes found by stress testing.
  - Class names drop the `MS` prefix: `MSAdaptiveMesh` is `AdaptiveMesh`, `MSSolid` is
    `Solid`, and so on for every class. The group is `adaptive_meshes`.
    Saved data loads unchanged (it refers to scripts by path).
  - `AdaptiveMesh` works as a component: under a `MeshInstance3D` with no source, or
    with `target` set, it reads the target's meshes (new `NodeSource`) and stays dormant
    until the first edit (or the start, `activation`), then takes over: target hidden,
    its collision off, pieces with its look and physics layers. `activate()`, `activated`,
    `is_component()`, `is_active()`, `get_target()`, `get_bake_source()`; `reset()` hands
    the target back.
  - `AdaptiveMesh.find(object)` and the `adaptive_meshes` group
    (`get_all(tree)`); an icon.
  - Bakes store a fingerprint of their source, chunking and bounds
    (`AdaptiveMeshData.fingerprint`, `SolidSource.get_fingerprint()`), and the editor
    warns when it's out of date. Component warnings: no meshes, an offset, collision
    simpler than the mesh, no bake.
  - Demo: `rocks_demo.tscn` and the `rock.tscn` prefab; the dig tool digs whatever
    adaptive mesh it hits; the overlay follows it.
  - Fixed: splitting a piece whose flat face lay on a halfway line (the hill's sides at
    +-12) dropped that face; such pieces now stay whole, and every split checks the
    children's visible area against the piece's (0.8.0 bug, showed as an intermittent
    test failure).
  - Fixed: siblings from one split could disagree about a vertex on a straight edge they
    share (a T-junction); they now get each other's wall vertices.
  - Fixed: freeing a mesh while its edits or bake ran on worker threads could crash (the
    tests crashed on exit). Worker jobs are now built from plain values and never call into
    a node, and pieces and meshes wait for running jobs before they're freed.
  - Fixed: an error when a seam fix was queued twice.
  - A component's `source` can be a `NodeSource`, for repair settings (merge seams,
    close an open sheet); the component fills in its target. `NodeSource` hides `width`:
    scale the model instead, so the pieces line up with it.
  - All three demos are ordinary models made adaptive by a component: the hill is a
    `MeshInstance3D` with exact collision; the terrain is the `.glb` placed as it is
    (imported 200 wide with Root Scale 0.02, its `UCX_` meshes skipped on import) with a
    component next to it that takes over at start.
  - `reset()` on a component that takes over at start takes over again right away.
  - Fixed: a second component on the same target took over `find()`'s record of it,
    and removed it when freed.
  - Tests: new `component` group; the demos group covers the rocks demo; `chunks` adds
    random edits arriving mid-split. The cost test now checks the triangles each edit's
    booleans process instead of wall time, which depends on frames (it failed with a window
    open).

- 0.9.0: Editor workflow and real demo scenes.
  - `MSAdaptiveMesh` and its pieces run in the editor (`@tool`): the node shows saved
    `data` there, never baking or editing on its own, and warns when it has no baked data.
  - The plugin adds a Bake button to the node's inspector: it bakes and saves `data` as
    compressed binary, asking where the first time (next to the source model by default)
    and overwriting that file after.
  - `reset()` goes back to the `data` that was assigned (such as a saved bake) instead of
    always baking again. A node baking from its source no longer bakes in the editor.
  - `get_triangle_count()` is counted once per piece and kept until it changes (it was a
    loop over every triangle on every call; the demo HUD called it every frame).
  - Demos rebuilt as scenes made of components (`demo/hill_demo.tscn`,
    `demo/terrain_demo.tscn`; `components/orbit_camera.gd`, `dig_tool.gd`,
    `debug_overlay.gd`) with saved bakes in `demo/models/`, replacing the script-built
    `demo.tscn` and `terrain_demo.gd`. The hill is a saved mesh (`models/hill.res`). The
    terrain demo starts in about 70 ms instead of 2.5 s. New `demos` test group.

- 0.8.0: Edits stay fast where they pile up, and cost less everywhere.
  - Crowded pieces split: past the chunking's new `split_above` triangles (default 2000),
    a piece is halved along the cut axes, up to `max_split_depth` (default 3) times.
    Neighbours get the new seam vertices (new `MSSolid.split_edges_at`), so seams still
    match exactly. Piece keys are now `Vector4i(x, y, z, depth)` (were `Vector3i`):
    `MSAdaptiveMeshData.pieces`, `meshes`, `piece_edited(key)` and `get_pieces()`; new
    `MSAdaptiveMeshData.split_keys`, `cell_key()`, `get_children()`, `is_inside()`.
    Saved data from 0.7.0 needs baking again.
  - Neighbours redraw their seam shading only when the faces they share with the edited
    piece changed (border faces are filed per neighbour, in a fixed order).
  - Faster worker jobs, with identical results: cleanup builds its vertex adjacency in
    flat arrays and only for the vertices it touches, compares old and new triangles by
    integer keys, caches neighbour sets, feature edges and normals, and checks the cheap
    reasons to reject a collapse first (about 9 -> 7 ms on the terrain's busiest piece
    after three digs); `MSSolid.build_surfaces` uses flat arrays instead of dictionaries
    of arrays (3.0 -> 1.2 ms); border faces test each vertex once (1.2 -> 0.3 ms, now
    filed per neighbour).
  - New `get_collision_shapes()`: the pieces' current shapes, a free snapshot of the
    surface. The demo's strokes use it instead of copying every face at the start of a
    stroke.
  - Terrain demo at 60 fps: an edit in one piece settles in 1 frame (was 2), the worst
    frame of a 10-dig stroke is 14 ms (was 19).
- 0.7.0: Faster edits. Booleans finish in the frame they start (the CSG backend forces
  the CSG update instead of waiting for the end of the frame), and everything after them
  (welding, cleanup, surfaces, collision faces, border faces) is one worker job instead of
  three, with welding and border faces moved off the main thread. New
  `main_thread_budget_ms` (`MSFrameBudget`) spreads booleans over frames when an edit
  reaches many pieces. On the terrain demo at 60 fps, edits show 1 frame after they're
  made (was 2-3); the worst frame of an edit across four pieces went from 15 to 9 ms, of a
  10-dig stroke from 27 to 19 ms; fully settling takes about a frame longer for edits
  across pieces. `MSBooleanBackend` gains `combine_main` / `combine_finish`. Fixed: a node
  baking from its `source` when ready did so while the scene was still adding children,
  so the first booleans failed to add their CSG nodes ("Parent node is busy"); it bakes
  deferred now, and edits made before that queue. Demos: the brush matches the surface's
  triangle size from the start (terrain: the model's average edge length; E or 1-4 switch
  to fixed levels). New opt-in `latency` test group.

- 0.6.0: One node, built from components. `MSAdaptiveMesh` is now the only node for
  everything, one piece or many: `source` (`MSMeshSource`, new `MSSceneSource` with the
  import repair built in), `chunking` (empty or `MSGridChunking`), `data`
  (`MSAdaptiveMeshData`: baked shapes and drawn meshes, saved to skip baking, shared until
  edited), `drawing` (`MSPieceDrawing`), `collision` (`MSPieceCollision`), `backend`,
  `cleanup`. `MSChunkedAdaptiveMesh` is gone; the old single-piece node is the internal
  `MSAdaptivePiece`. `bake()`, `baked`, `piece_edited` (was `chunk_edited`),
  `get_pieces()` (was `get_chunks()`). Pieces draw from baked meshes, so loading saved data
  builds nothing. Fixed: a union cut off at `max_bounds` was closed by hidden cap faces,
  leaving a hole; backends now take `bounds_walls`, and only sides shared with another
  piece are hidden.
- 0.5.0: Imported terrains. Mesh repair on `MSSolid`: `merge_close`,
  `fix_t_junctions`, `get_boundary_loops`, `close_to_floor`.
  `MSChunkedAdaptiveMesh.source_solid` to split a ready solid. Splitting is hierarchical
  (halving), about 3.5x faster for 81 chunks and spread over frames. New terrain demo
  (`demo/terrain_demo.tscn`) on a CC BY 4.0 low-poly terrain from Sketchfab; the hill demo
  can be extended (`_setup_terrain`, `_scale`).
- 0.4.1: Fixed lighting jumps at chunk borders: vertices on a chunk wall now average the
  faces on both sides (`MSAdaptiveMesh.normal_faces`, `request_redraw()`, `drawn`
  signal; `MSSolid.build_surfaces` takes `extra_faces`), and hidden faces (chunk caps) no
  longer count towards normals. Neighbours redraw only when an edit changes a chunk's
  wall faces. Folder renamed from `ms_adaptive_mesh` to `adaptive_mesh`.
- 0.4.0: Chunks. `MSChunkedAdaptiveMesh` splits a big mesh into a grid of
  `MSAdaptiveMesh` chunks with hidden caps and edits only the chunks an edit touches;
  unions build new chunks up to `max_bounds`; `solids` saves every chunk. Empty targets
  and results are fine in the backends now (dig a chunk out, build into an empty cell).
  `edit_solid()` on both nodes; `MSBrushStroke` drives either. `MSSolid.from_mesh` snaps
  corners within `merge_distance` (1e-5) so float noise doesn't leave holes, and both
  nodes warn when their source mesh isn't closed. The demo is chunked (K toggles). New
  `chunks` test group.
- 0.3.0: Cleanup pass. `MSMeshCleanup` (short-edge and sliver collapses, sliver flips,
  shape error limit, feature and bounds locks, `unlock_rings`) and
  `MSAdaptiveMesh.cleanup`. The demo cleans after every edit (C toggles it). New `cleanup`
  test group; `quality` compares strokes with and without it.
- 0.2.0: Fewer small triangles. `MSSolidSphere.edge_length` (optional automatic detail)
  and `get_edge_length()`; `MSBrushStroke` (distance-spaced, busy-merged, optionally swept
  edits, advancing while held still to dig in or build out); `MSSolid.swept` and
  `remove_unused`. The demo uses strokes (holding still digs deeper or builds higher),
  raycasts the surface as it was when a stroke began (so a drag no longer drills into its
  own trench), and gains E (automatic detail) and T (sweep) toggles. New `stroke` test
  group and opt-in `quality` group.
- 0.1.0: Initial version. `MSAdaptiveMesh`, `MSSolid`, `MSBooleanOp`, the CSG boolean
  backend, sphere/box/mesh shapes, demo.
