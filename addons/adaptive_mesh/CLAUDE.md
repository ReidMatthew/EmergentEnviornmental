# adaptive_mesh: notes for Claude

## Current direction: the core (decided 2026-10-09, after 0.13.0)

Work happens on branch `ms-adaptive-mesh-core`; tag `adaptive_mesh-v0.13.0` is the state
before it.

**The goal:** any division of a mesh, with every resulting piece still adaptive. One node
(`AdaptiveMesh`) for everything, static or moving; no second node class.

**Fracturing is paused.** Don't extend `MeshDebris`. Its dig fragments stay as they are;
its loose parts were replaced by core separation in 0.16.0.

### Decisions

- **Cuts are subtractions.** Slicing subtracts a thin box (swept for a saw stroke, a thin
  shell for a curved cut), never a zero-thickness plane: the gap is what separates parts.
  A cut that doesn't go all the way through is a notch. Thickness at least about 1/1000
  of the object's size (booleans get unreliable thinner).
- **Separation is a connectivity check** after edits settle (today's `_loose_job`:
  pieces' islands joined across walls by shared corners), with anchor rules deciding
  what stays.
- **Separated parts inherit the parent's pieces.** The check already says which piece
  islands make up a part, so the new object's data is exactly those solids under the same
  keys, chunking, region, materials and cap tag: no recutting, no booleans, shared (not
  copied) solids. Uneven coverage is fine. The grid lives in the object's own space, so
  it moves with it.
- **Static versus moving is a physics mode, not a structure.** Under a static target,
  pieces keep a trimesh `StaticBody3D` each (as now). Under a `RigidBody3D`, pieces add
  convex shapes to that body (`CollisionObject3D` shape owners, one owner per piece), and
  the mesh keeps the body's mass and centre of mass up to date. The body's origin doesn't
  move; the centre of mass is set as custom.
- **Edits on moving objects** are converted to the mesh's own space when requested
  (`edit_solid` already does this), so a cut lands where it was aimed even if it's applied
  a frame later.

### Phases (each usable on its own, tested and committed before the next)

1. **Shared frame budget and a cutting brush.** Done in 0.14.0: `FrameBudget` tally shared
   by all meshes; `AdaptiveMesh.cut()` (thin slab, thickness limits from `get_aabb()`);
   the dig tool's cut mode (X). Not done: a swept saw stroke (a thin box swept along a
   stroke needs `BrushStroke` to orient the shape; add it when a game needs it).
   - `FrameBudget` shared by all adaptive meshes (static), so many moving objects can't
     each take 4 ms a frame.
   - A cut: thin `SolidBox` brush with a minimum thickness, swept along a stroke; the demo
     dig tool gets a cut mode.
   - Tests: a partial cut leaves one part (a notch); a full cut separates (the existing
     loose-part slab tests); thin-cut results stay closed.
2. **Moving mode.** Done in 0.15.0: `get_body()` (nearest `RigidBody3D` above), pieces'
   hulls as shape owners on it (`AdaptivePiece.moving_body`), mass from the body's own
   mass per volume, custom centre of mass, inertia left to the engine (looked fine in the
   falling test, not checked on odd shapes), `rigid_rock.tscn` demo. Not done: several
   hulls per piece ("collision detail"), a moving dig tool stroke (the demo's stroke
   snapshot doesn't follow a moving body).
   - Detect a `RigidBody3D` owning the target (or the mesh's parent): taking over disables
     the body's own shapes (as for static bodies now) and adds the pieces' convex shapes
     to it, positioned relative to the body.
   - Convex collision per piece, built on the worker with the mesh and surfaces: first one
     hull per piece (`MeshDebris.get_hull_points`), then optionally several per piece by
     clipping into cells (`MeshDebris.clip`) for hollow pieces (a "collision detail"
     setting).
   - Mass from volume x density, custom centre of mass from `MeshDebris.get_centre`,
     inertia left for the engine to work out from the shapes (check what Jolt does; set
     it ourselves if it's poor).
   - Demo: a rigid rock or crate you can dig and cut while it tumbles.
   - Tests: shapes on the body after takeover and after edits; mass and centre of mass
     follow edits; a dig on a moved body lands at the right local spot; no shape left on
     the body from removed pieces.
3. **Core separation: separated parts become adaptive.** Done in 0.16.0: `MeshSeparation`
   (settings + `find_parts_job`), `AdaptiveMesh.separation`, `_spawn_part` (inherited
   pieces, settings, look, body physics, velocity at the part's centre, frozen until its
   hulls are on), `_remove_piece` for pieces left empty, `MeshDebris.loose_parts` removed.
   Not done: a "plain body" option for small parts (they're dust below `min_size`, adaptive
   above); that's phase 5's minimum adaptive size.
   - Move the connectivity check out of `MeshDebris` into the core: a separation setting on
     `AdaptiveMesh` (on/off, anchor, minimum adaptive size, what small parts become: plain
     body or dust). Anchors: Ground (default for static), Largest (default for moving),
     Nothing.
   - A separated part spawns as a `RigidBody3D` with an `AdaptiveMesh` child holding the
     inherited pieces and the parent's settings (drawing, cleanup, backend, separation,
     physics layers). Its pieces build their meshes on spawn. From a moving parent it
     starts with the parent's velocity at its centre (v + w x r).
   - Parts are divisible again (the same check runs on them).
   - Remove `MeshDebris.loose_parts` (superseded), with a changelog note.
   - Tests: slicing a chunked box spawns a body whose data has the inherited keys and the
     right volume, closed pieces; it can be dug and sliced again; the remaining mesh keeps
     the rest; a moving parent's velocity carries over; off checks nothing.
4. **Merging small objects.** Done in 0.17.0, at spawn only: `AdaptiveMeshData.merged()`
   and `_fits_one_cell()` in `_spawn_part`. Not done: merging a mesh that shrinks under
   a chunk later through digs (call `merged()` on idle if it's ever needed). When an object's whole extent fits in one cell but it has
   several pieces (a part straddling a cell corner), merge them into one unchunked piece:
   drop the paired wall (cap) faces, weld the seams, chunking off for that object (a
   merged piece can't keep a cell's bounds). Tests: volume kept, closed, one piece.
5. **Limits and lifecycle.** Done in 0.18.0: `min_adaptive_size` (plain small parts),
   `max_parts` / `over_limit` (`MeshSeparation.add_part`, `AdaptiveMesh.make_plain()`),
   `plain_lifetime`; separation's heavy work moved to `_separation_job` (worker), parts
   added within the frame budget. Measured: terrain slice worst frame 10.4 ms with
   separation vs 9.3-10.7 ms without; moving-rock digs about as costly as static ones; no
   per-frame processing for parts at rest. The five phases are done; what's left is under
   "Not done" in each. Minimum adaptive size (smaller parts: plain body or dust);
   most adaptive objects at once (oldest become plain bodies or are freed); sleeping
   bodies cost nothing; measured targets: a dig on a moving object costs about what it
   does on a static one, and a separation spawns without a frame over the budget.

### Next steps (planned 2026-10-09, after 0.18.0)

In order; each tested and committed before the next.

1. **Land it.** Merge `ms-adaptive-mesh-core` into `main`, tag `adaptive_mesh-v0.18.0`.
   Then the showcase on `ms-game-audio` (the user's branch: ask first) needs its scenes
   moved from `MeshDebris.loose_parts` to `separation`, and any `separated` handlers to
   two arguments.
2. **Soak test.** Done in 0.18.2 (`tests/soak.gd`, opt-in `soak` group): found and fixed
   eight bugs (see the changelog). Still open: under an extreme split threshold (150) one
   seed (5) ends up with 2 open edges on a 4000-triangle piece at the deepest split, from
   a thin cut's boolean on a big piece, not from seams; and splitting many pieces at once
   costs frames of 70-80 ms at that threshold. Physics makes the mixed runs vary from
   run to run, so a failure there may not repeat: rerun a few times. An opt-in test group that cuts and digs at random for a while (static
   and moving meshes, parts of parts): every piece closed, volume conserved (mesh + parts
   + removed), object counts within `max_parts`, no growing ObjectDB leaks, worst frame
   logged. Most of 0.14-0.18 is new; find the breakages before games do.
3. **Better collision for moving meshes.** Done in 0.19.0: `PieceCollision.hulls_per_piece`,
   `ConvexCells.hull_sets()` (recursive halving across the longest side plus island
   splits: the Voronoi version was k-squared clips and 3-4x slower), follow-up hull jobs
   after drawing (`AdaptivePiece._follow_up_hulls`), clip outline limited to plane edges. Several hulls per piece: clip the piece into a
   few cells (move `MeshDebris.clip` and the Voronoi helpers into core) and hull each, on
   the worker with the mesh. A `collision_detail` setting. Fixes hooked parts popping
   and hollow rocks colliding as filled.
4. **Tools.** `BrushStroke` gets a shape orientation, so a thin box can be swept along a
   drag (a saw); the demo dig tool's stroke follows a moving body (snapshot in the body's
   space). A cutting demo scene (a log or a plank to saw, parts that keep being
   adaptive).
5. **Small loose ends.** Merge a mesh that shrinks below a chunk through digging (call
   `merged()` on idle); per-mesh vs shared `max_parts` (the resource is shared by every
   copy of a prefab).
6. **Later, if needed.** The native Manifold backend: done (see below). Fracturing
   (paused) once the core is settled.

Open questions still with the user: main use (large-scale destruction or object-level
cutting) and whether a huge part (half a building) should ever become one moving body;
a `max_moving_size` (bigger parts stay static, as separate meshes) is the likely answer.

### Risks to watch

- Convex collision quality (one hull bridges hollows) and popping when a moving body's
  shapes are swapped mid-contact.
- Inertia: Godot's `RigidBody3D` only takes a diagonal inertia; the engine's automatic
  value may be poor for odd shapes.
- Cost: CSG booleans are main-thread only; many moving objects edited at once compete for
  one budget.
- Object count grows with every division (phase 5 limits).

### Open questions for the user

- Main use: large-scale destruction (buildings, terrain) or object-level cutting (props,
  rocks)? Sets the defaults (anchor, minimum adaptive size, limits).
- Should a separated part of a static mesh ever become a huge moving object (half a
  building), or stay static above some size?

## Real-time plan (decided 2026-10-09, at 0.21.0)

The goal: any operation, however big (dismantle is only an example of a complex one), runs
in real time: small edits settle in a frame or two, big ones cost in proportion to the
geometry they touch, spread over every core, never a frame over budget. **General, not
tuned per operation**: the user rejected a dismantle-specific shortcut (cutting straight
into grid cells, skipping booleans and separation). Dismantle stays an ordinary batch of
cuts; it just has to get fast because everything does.

What the stage profile showed (before step 1, Manifold backend): booleans were a small
share; GDScript was the rest. Cleanup 72-120 ms in strokes and blasts (3 s of CPU for the
castle dismantle), surfaces 20-50 ms (0.9 s dismantle), joining parts ~20 ms on every
separation check, islands and seam faces 4-16 ms (0.3 s dismantle). GDScript also doesn't
scale over threads: many small jobs reading the same shared data got slower (132 ms
across threads vs 48 ms on one); only native code scales.

0. **Stage profile and benchmark.** Done: `core/stage_profile.gd` (`StageProfile`, off by
   default) times every stage on any thread; `adaptive_mesh_native/tests/benchmark.gd`
   runs fixed scenarios (dig, stroke, blast, castle dig/stroke/cut/dismantle, rigid rock)
   per backend and prints the stage table (`-- manifold`, `-- csg`, `-- script` for the
   GDScript geometry, words to pick scenarios). Judge every step below by it.
1. **Native geometry core.** Done: `AdaptiveMeshKernel` in adaptive_mesh_native (clean-up,
   surfaces, seam faces, islands, part info, weld, joining parts), used through
   `core/native_kernel.gd` (`NativeKernel.on()`, `enabled` to switch it off). Ports are
   exact (same float/double arithmetic, same order, same tie-breaks): the add-on's tests
   compare native and GDScript output array for array on dug terrain and castle pieces.
   Keep it that way: change both together, and extend the parity test. Since 0.23.0 also
   volume and centre, bounding box, `encloses`, merging, `split_edges_at`,
   `fix_t_junctions`, seam snapping, `count_open_edges` and `AdaptiveMeshData.merged`
   (`kernel_more.cpp`). `_with_hollows` uses them; its own loop stays GDScript.
2. **One native call per piece edit.** Done: `AdaptiveMeshKernel.edit_piece` (boolean,
   weld, clean-up, surfaces, collision data, seam faces), used by `AdaptivePiece` through
   `NativeKernel.edit_job` when `NativeKernel.can_fuse` (Manifold backend, plain
   `MeshCleanup`). Hull points, `get_faces` and `hull_sets` (with `clip` and
   `triangulate`) are ported too, exactly (parity test); the zero-volume parts are found
   from the output mesh instead of `Decompose` (castle stroke 10.4 -> 2.1 ms). Native
   phases are timed (`ManifoldBoolean.set_timing`, shown by the benchmark as "native:").
   Measured: rigid rock dig 28 -> 20 ms (hulls 10 -> 0.8 ms); static scenarios about the
   same as after step 1, because what's left per piece is Manifold itself. Per terrain
   stroke (18 piece edits): boolean 17.6 ms, converting the target to a Manifold 9.1,
   clean-up 8.8, converting the brushes 4.6, the target pre-pass 4.2, everything else
   ~7. Settle times are now mostly frames: an edit's job lands, its result is applied
   the next frame, neighbours redraw their seam shading the frame after (a single dig
   settles in 3 frames).
   0.23.0: a piece's edits in one frame go in one job (`edit_local` starts the job
   deferred), and worker jobs are checked at `frame_pre_draw` too, so a job done during
   a frame is applied in it. Not done (measured not worth it yet: in a dismantle the
   conversions and pre-pass are ~6% of the boolean CPU):
   keep each piece's Manifold between edits (the
   conversion and the pre-pass are ~40% of the per-piece cost, but clean-up changes the
   mesh after every boolean, so the cached Manifold would have to be rebuilt from the
   cleaned mesh or the clean-up done in Manifold terms); cache brush Manifolds (a brush is
   placed in float maths before packing, for matching seams, so the cache would hold the
   packed mesh, not the Manifold); Manifold's own parallel backend (TBB) for very big
   single pieces.
3. **Native separation.** Partly done in 0.23.0: merging (`merged`, `merge_solids`) and
   the checks are native; the parts' data is made on the worker (each part keeps only the
   split cells its pieces are in); neighbour lookups are quicker (`GridChunking` caches its
   steps). Castle dismantle: part data 1366 -> ~590 ms of CPU, main thread 22 -> 10 ms.
   Not done: the rest as below (GDScript on 31 threads runs ~5x slower per call than on
   one: e.g. `_cells_around` 37 us alone, ~200 us in the group). Finding parts (islands
   per changed piece, joining across walls, anchors) and preparing them (merging, borders, hulls, surfaces per part:
   `_separation_item`) in C++, only for the pieces that changed. Today
   `_separation_work` runs over a group task of GDScript items; native, it would be one
   call that threads itself. Then freeing a thousand parts costs about what one does.
4. **Cheap new parts, adaptive on demand.** Done (first part): a separated part spawns
   as a rigid body with one `MeshInstance3D` (since 0.23.1: its pieces' surfaces joined,
   or its one piece's mesh), its hulls, and a dormant `AdaptiveMesh` component under the
   view, targeting it, with the part's data (each piece's surfaces kept in `_prepared`
   for its own mesh at takeover); the first edit (or `activate()`) takes over as for any
   component (`_prepared` keeps borders, hulls and masses for it). `separated` still
   reports `AdaptiveMesh` parts (dormant: `is_active()` false, no pieces yet).
   `make_plain()` on a dormant part just drops the component. Spawning: ~0.2 -> ~0.12 ms
   a part on the main thread (castle dismantle: 220 -> ~120 ms). What's left per part:
   entering the tree ~0.05 ms, the component and the nodes ~0.05 ms. Not done: batched
   creation through the servers (would need parts without nodes until edited).
   0.23.1, castle dismantle spawning 202 -> ~170 ms (1,101 parts): one mesh and one view
   per part, no holder node, no `_read_target` for a spawned part, shared default
   settings, the frame budget made when first used. What's left per part (us): the mesh
   ~60 (a fixed cost per mesh: buffers; the vertices hardly count), entering the tree
   ~35 (mostly the physics body and shapes), the component ~17, the view ~15, the body
   ~14, hull shapes ~9. Tried and dropped: packing vertex data on workers in GDScript
   (byte-identical to Godot's, but no main-thread gain for small meshes, and ~0.8 us a
   vertex on the workers). Next if needed: hulls as shape owners on the body instead of
   `CollisionShape3D` nodes (takeover, `make_plain` and reset would switch owners).
5. **Less main-thread work.** Partly done: meshes are made in the worker jobs
   (`AdaptivePiece.job_mesh` / `as_mesh`), except under the headless (dummy) renderer,
   whose mesh storage isn't thread-safe and crashes (real renderers' is: threaded
   resource loading makes meshes too); a redraw of a piece whose solid hasn't changed
   (seam shading) keeps its collision shape (`KEEP_COLLISION`), since building a trimesh
   shape (the physics engine does it when the shape is assigned, on the main thread) was
   most of applying a result. Castle dismantle: applying 250-380 -> ~100 ms; cuts done in
   ~0.21 s instead of ~0.4; everything out in ~0.8 s (window) instead of ~1.5.
   0.23.0: `FrameBudget` lets waiting work through nearest the camera first
   (`wait_turn(priority)`; parts spawn nearest first); chunk splits run on a worker;
   requests are cheap (`SolidBox` no longer makes a `BoxMesh`: 4.7 ms each; one
   `BooleanOp` per edit shared by its pieces). Separated parts' meshes are made at spawn,
   in the budget: **a mesh made on a worker thread still uploads to the GPU on the main
   thread before drawing, outside the budget** (a dismantle's 1,300 meshes made a 60-75
   ms frame; the faster the group, the worse). Piece edit jobs still make theirs on the
   worker (a few per frame). Not done: building collision shapes off the main thread
   (not possible through Godot's API: the engine builds them on assignment).

Measured at 0.23.0 (window, Manifold, benchmark waiting for separated parts): every
scenario with no frame over 16.7 ms; castle stroke 67-125 ms (176 at 0.22.0, worst frame
38 -> 10); cut 44 ms; dismantle all parts out in ~0.83 s, worst frame 15 ms (0.22.0:
same total, 30 ms frame). Benchmark lessons: separation runs after the pieces are idle
(the benchmark waits 60 idle frames for parts); parts go into `current_scene`, which a
`-s` script doesn't set unless told to (they piled up across rounds before); a lambda
captures locals by value. Profiling lessons: an unprofiled main-thread gap is often work
the engine does for worker threads (mesh uploads); `sort_custom` with a GDScript
comparator costs ~3 us per comparison (sort `Vector2(key, index)` with `sort()`).

Order: 2 -> 4 -> 3 -> 5 (2 is the broad win; 4 the big one for operations that free many
parts). Risks: seams and closedness (the native code must keep today's rules: the tests
and the parity test guard it); platforms (more of the system native: keep the GDScript
path working as the fallback); physics of a thousand moving bodies is then Jolt's cost
(`max_parts`, `plain_lifetime` are the levers).

## Native Manifold backend: done (2026-10-09, sibling add-on `adaptive_mesh_native`)

`addons/adaptive_mesh_native/` holds `ManifoldBooleanBackend` and the DLL;
`source_assets/adaptive_mesh_native/` the C++ source and `build.py` (fetches llvm-mingw,
SCons/CMake/Ninja, godot-cpp and Manifold into `%LOCALAPPDATA%/adaptive_mesh_native`,
outside the OneDrive repo). `AdaptiveMesh.get_default_backend()` picks it up by class name.

What made it match CSG (all needed, found the hard way):
- Each target goes through `BatchBoolean({empty, target}, Add)` before it's cut, as Godot's
  CSG does (its combiner root is empty): Manifold's clean-up of the target (dropping points
  in the middle of straight edges) then doesn't depend on the cut, so sibling pieces cut
  from one solid still match on their walls.
- Shapes are placed in Godot's float maths before packing (not `Manifold::Transform` in
  double): two pieces cut by the same brush then get bit-identical seam points.
- No face IDs on input (Manifold groups flat faces itself; per-triangle IDs keep box
  diagonals as stray points on seams), tolerance `2 * FLT_EPSILON`.
- Zero-volume components (a sheet where a cell box only touches the source's face) are
  dropped.

Not done: other platforms (Linux/macOS/web builds), the cleanup/surfaces in C++ (the
old estimate: ~9 ms of GDScript per busy edit -> under 1 ms), caching shapes natively.
Measured: dig stroke worst frame 14.9 -> 6.9 ms on the terrain; castle dismantle cuts
1.9 -> 0.65 s; a dig in a 5,120-triangle sphere 38 -> 12 ms.

The faster backend exposed two seam bugs in the core, both fixed in 0.21.0: T-junctions
on walls between pieces at different split depths after edits (`_exchange_wall_points`),
and seam points lost when the piece they were for was splitting. Also `WorkerJobs`:
Godot crashes if it quits while a GDScript job runs on a worker thread.

## Deferred: adaptive rigid bodies

Decided 2026-10-07 (at 0.10.0): adaptive meshes are static (pieces collide as
StaticBody3D). Making a moving `RigidBody3D` adaptive is hard: moving bodies need convex
shapes (so every edit needs a convex decomposition, slow and approximate), mass, centre of
mass and inertia change with each edit, dug-through objects should split into separate
bodies (debris), swapping shapes on a moving body pops, and edits land a frame or more
after the body moved. Suggested first step when needed: a component on a frozen rigid body
that stays adaptive until `release()` (or its support is dug away), then approximates its
current shape once as convex parts, unfreezes and stops being adaptive.

Since 0.12.0 digs can drop debris (`MeshDebris`): plain, non-adaptive rigid bodies cut from
what each dig removed; since 0.13.0 parts cut off all the way round fall too
(`loose_parts`, found by `_loose_job` joining pieces' islands across walls). A future
"debris you can dig into" would build on it: `MeshDebris.clip()`, `Solid.get_islands()`
and `get_hull_points()` already exist. Fallen parts are one convex hull each; a hooked
part could use `break_up()` into convex-ish fragments instead.
