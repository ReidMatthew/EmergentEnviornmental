# Adaptive Mesh Native

Native code for `adaptive_mesh`, in one GDExtension: a boolean backend that calls the
[Manifold](https://github.com/elalish/manifold) library directly, and a geometry core that
runs the heaviest per-edit work (clean-up, surfaces and normals, seam faces, islands,
welding, joining separated parts) in C++.

| | |
|---|---|
| Version | 0.2.0 |
| Engine | Godot 4.5 or later (built against the 4.5 API) |
| Depends on | `adaptive_mesh` |
| Platforms | Windows x86_64 (elsewhere adaptive_mesh runs its GDScript and CSG; see [Building](#building)) |
| Plugin | none: drop the folder in, nothing to enable |

## What it does

Drop this folder into `addons/` next to `adaptive_mesh`. Nothing to set up: adaptive_mesh
looks for both parts by class name, so it doesn't need this add-on, and uses them when the
library loads.

- **Booleans: `ManifoldBooleanBackend`.** Meshes with no `backend` set use it
  (`AdaptiveMesh.get_default_backend()`). It runs on worker threads, where CSG nodes only
  work on the main thread, and gives the same results as Godot's CSG (which uses Manifold
  too: this backend feeds it the same way), so saved bakes made with CSG still match. Set a
  mesh's `backend` to a `CsgBooleanBackend` to keep it on CSG.
- **Geometry: `AdaptiveMeshKernel`.** adaptive_mesh's `NativeKernel` calls it in place of
  the GDScript for `MeshCleanup.clean`, `Solid.build_surfaces`, `Solid.weld`,
  `Solid.get_islands`, `Solid.get_hull_points`, `Solid.get_faces`,
  `ConvexCells.hull_sets` (with its clipping), `Solid.get_volume` / `get_centre` /
  `get_aabb` / `encloses` / `split_edges_at` / `fix_t_junctions` / `count_open_edges`,
  `MeshSeparation.merge_solids`, `AdaptiveMeshData.merged`, the seam faces, part info
  and the joining in separation checks. Every one is an exact port: the tests compare its output with the
  GDScript's, array for array, on dug terrain and castle pieces.
  `NativeKernel.enabled = false` turns it off.
- **A piece's whole edit in one call: `AdaptiveMeshKernel.edit_piece`.** With the
  Manifold backend and a plain `MeshCleanup`, a piece's edit (boolean, weld, clean-up,
  surfaces, collision data, seam faces) is one native call on a worker thread, with no
  GDScript between the steps.

## How much faster

From `tests/benchmark.gd` (headless, medians of three rounds, Manifold backend; time until
everything has settled, GDScript geometry -> native geometry):

| Scenario | Settled | Clean-up (all threads) | Surfaces |
|---|---|---|---|
| Terrain: one dig | 25 -> 16 ms | 8.5 -> 0.6 ms | 2.3 -> 0.3 ms |
| Terrain: 12-dig stroke | 112 -> 84 ms | 92 -> 8.5 ms | 20 -> 3.8 ms |
| Terrain: blast (8 digs at once) | 54 -> 24 ms | 120 -> 7.9 ms | 39 -> 6.2 ms |
| Castle: 12-dig stroke | 140 -> 99 ms | 72 -> 9.3 ms | 50 -> 7.8 ms |
| Castle: cut through the keep | 125 -> 87 ms | 108 -> 11 ms | 112 -> 15 ms |
| Castle: dismantle (1,100 cubes, all released) | 1.5 -> 1.1 s | 2,960 -> 156 ms | 868 -> 132 ms |
| Rigid rock: one dig (hulls 10 -> 0.8 ms) | 35 -> 20 ms | | |

And against Godot's CSG (both with the GDScript geometry): a castle stroke settles in 140
ms instead of 244 with no frame over 16.7 ms, a blast in 54 ms instead of 122.

What's left per piece is mostly Manifold itself (the boolean, and turning the piece into
a Manifold first), then putting results in the scene; a single dig now settles in about
three frames. The plan for the rest is in adaptive_mesh's CLAUDE.md ("Real-time plan").

## Files

```
adaptive_mesh_native.gdextension   loads bin/ (Windows x86_64)
manifold_boolean_backend.gd        ManifoldBooleanBackend: the BooleanBackend to use
bin/                               the library (built from source_assets/adaptive_mesh_native)
licenses/                          Manifold (Apache 2.0), godot-cpp (MIT), the LLVM/MinGW runtime linked in
tests/run_tests.gd                 each boolean against CSG; each geometry call against its GDScript
tests/benchmark.gd                 where the time goes, stage by stage, on the demos
```

Native classes: `ManifoldBoolean` (`combine`, `get_manifold_version`, and
`set_timing` / `get_timings` / `reset_timings` for its phases) and `AdaptiveMeshKernel`
(`edit_piece`, `clean`, `build_surfaces`, `border_parts`, `islands`, `part_info`, `weld`,
`join_parts`, `hull_points`, `faces`, `hull_sets`, `volume_centre`, `aabb`, `encloses`,
`merge`, `merged_solid`, `split_edges_at`, `fix_t_junctions`, `snap_seams`,
`count_open_edges`), all static. Use them through `ManifoldBooleanBackend` and
`NativeKernel`.

## Tests

```bash
godot --headless -s res://addons/adaptive_mesh_native/tests/run_tests.gd
```

```bash
godot --headless -s res://addons/adaptive_mesh_native/tests/benchmark.gd -- manifold
```

The benchmark takes backend names (`csg`, `manifold`), `script` (the GDScript geometry,
to compare), and words from scenario names (`castle`, `stroke`...). Per scenario it prints
how long until settled (pieces idle and any separated parts out), the worst frame, and
the time per stage (`StageProfile`; "main: the edit calls" is the edit requests
themselves).

adaptive_mesh's own test groups run on the native code whenever this add-on is installed.
To run them without it, move `adaptive_mesh_native.gdextension` out of the folder for the
run.

## Building

The source is in `source_assets/adaptive_mesh_native/` (not part of the add-on).

```bash
python source_assets/adaptive_mesh_native/build.py
```

It fetches a self-contained toolchain (llvm-mingw, plus SCons, CMake and Ninja through pip)
and godot-cpp and Manifold at pinned versions into `%LOCALAPPDATA%/adaptive_mesh_native`
(outside the repository), builds Manifold as a static library, then the extension into
`bin/`. The DLL needs nothing beside it: the C++ runtime is linked in. Close Godot first
(it locks the DLL).

When you change the GDScript an `AdaptiveMeshKernel` call replaces, change the C++ to
match and run the tests: they check the two still agree exactly.

Other platforms: build godot-cpp and Manifold with that platform's compiler, run SCons in
`source_assets/adaptive_mesh_native/` with the same arguments as `build.py`, and add the
library to `adaptive_mesh_native.gdextension`.

## Changelog

- 0.2.0: More of the geometry in C++, all exact ports checked against the GDScript:
  volume and centre, bounding box, `encloses`, merging solids, `split_edges_at`,
  `fix_t_junctions`, seam snapping, `count_open_edges` and `AdaptiveMeshData.merged`
  (castle dismantle: preparing the parts on workers 777 -> 574 ms of CPU). The benchmark
  counts separated parts in the settle time, puts each scenario's parts in its scene (so
  they're freed with it), and times the edit calls.
- 0.1.0: First version. `ManifoldBooleanBackend` and the `ManifoldBoolean` GDExtension
  (Manifold 3.5.3, godot-cpp for the 4.5 API); `AdaptiveMeshKernel`, the native geometry
  core; the stage benchmark. Windows x86_64.
