# Meshers

Isosurface meshers behind one swappable interface: hand any mesher a block of samples
(`MesherGrid`) and get indexed triangles back (`MeshData`). Callers hold a `Mesher`
and don't care which algorithm or backend (GDScript, compute shader, later GDExtension)
is behind it.

| | |
|---|---|
| Version | 0.3.0 (keep in sync with `plugin.cfg`) |
| Last tested on | Godot 4.7.2 (Forward+, D3D12) |
| Depends on | none |

Used by `marching_terrain`. Nothing here knows about chunks, terrain or storage
formats; keep it that way so other add-ons can use it.

## Install

1. Copy this folder into `res://addons/` of the target project.
2. Project > Project Settings > Plugins > enable **Meshers** (optional: everything is a
   `class_name` script, so it works with the plugin off).

## What enabling the plugin changes

- none

## Usage

```gdscript
var center := Vector3(10, 10, 10)
var grid := MesherGrid.from_function(Vector3i(21, 21, 21), 1.0,
		func(p: Vector3) -> float: return p.distance_to(center) - 6.3)  # < 0 is inside
var mesh := MarchingCubesCpuMesher.new().polygonize(grid)
var array_mesh := ArrayMesh.new()
array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.get_surface_arrays())
```

`MesherGrid` in short:
- `size` samples, laid out x fastest; `origin` and `spacing` place them in output space.
- Samples as floats (`values`) or one byte each (`bytes`, decoded as
  `(byte - byte_center) * byte_scale`; GPU meshers decode them in the shader). Below `iso`
  is inside.
- Optional per-sample `materials` (written to vertex `COLOR.r` as `id / 255`).
- `cell_begin`/`cell_end` restrict which cells are meshed, so callers can pass padding
  samples that are only read for normals and for closing seams.
- Optional: `skirt_depth` (seam skirts) and `transitions` (Transvoxel transition cells
  against a neighbour of twice the resolution). Leave them empty if you don't chunk.

## Meshers

| Mesher | Triangles end up | Notes |
|---|---|---|
| `MarchingCubesCpuMesher` | CPU (`MeshData`) | GDScript reference; runs on worker threads |
| `MarchingCubesGpuMesher` | GPU -> read back -> `MeshData` | compute shader, batched; falls back to CPU |
| `MarchingCubesGpuIndirectMesher` | stay on the GPU (triangle pool + indirect MultiMesh) | draw with a material that includes `gpu/pull.gdshaderinc` |
| `DualContouringCpuMesher` | CPU (`MeshData`) | keeps sharp edges and corners; exact normals optional |
| `SdfDualContouringCpuMesher` | CPU (`MeshData`) | sharp features from distance samples alone; slow, single blocks |

The three marching cubes meshers produce the same triangles, normals and materials (the
tests check this triangle for triangle), including Transvoxel transition cells and skirts.

The GPU meshers need Forward+ or Mobile. Under Compatibility or `--headless` they warn
once and run on the CPU (the indirect one then behaves like the readback one).

### Which one?

| | Marching cubes | Dual contouring | DC of signed distance data |
|---|---|---|---|
| Sharp edges and corners | bevelled | kept (best with exact normals) | kept, from samples alone |
| Speed (32^3 noise chunk, GDScript) | 9 ms (GPU 2.5 ms) | 38 ms | seconds |
| Chunks join exactly | yes | yes (same resolution) | no |
| Different resolutions (Transvoxel) | yes | no | no |
| Skirts | yes | no | no |
| Always manifold | yes | no (see below) | no |
| GPU | yes | not yet | no |

Corner error on a rotated box (mean distance from its 8 corners to the nearest vertex,
1-unit cells; `dual_contouring` test): marching cubes 0.70, dual contouring with normals
from the samples 0.73, dual contouring with exact normals 0.16, dual contouring of signed
distance data 0.17.

Rule of thumb: marching cubes for smooth, streamed, LOD'd terrain; dual contouring when the
field is analytic (brushes, CSG of primitives) or you want crisp edges; dual contouring of
signed distance data when all you have is a grid of distances to something sharp (baked
or imported SDFs) and you can afford to mesh it once.

### Dual meshers

Both dual meshers extend `DualMesher`: one vertex per cell the surface passes through,
one quad per grid edge it crosses. They take the same `MesherGrid` as marching cubes and
return `MeshData` (materials per vertex as usual; a cell takes the most common material
of its inside samples).

- **Blocks.** A grid meshes the quads of edges in its cell range, reaching one cell past
  `cell_end`, so keep one sample of padding past the range (the marching cubes layout).
  Same-resolution neighbours then join exactly with `DualContouringCpuMesher`.
- **`flat_shading`** gives each triangle its own vertices and face normal, which shows the
  sharp edges; off, each cell vertex gets the average of its crossing normals.
- **Not supported:** transition cells and skirts (both warn once and mesh without).
- **Manifoldness:** where a cell face is ambiguous (two diagonal corners inside), single
  vertex dual contouring joins the same two cells twice, and the edge between them is
  shared by four triangles. The mesh stays closed but isn't manifold there. Manifold Dual
  Contouring (Schaefer, Ju and Warren 2007) fixes this with several vertices per cell;
  not done yet.

**`DualContouringCpuMesher`** (Ju, Losasso, Schaefer and Warren, SIGGRAPH 2002) puts each
vertex where the tangent planes at its cell's crossings meet (`Qef`, a truncated
pseudo-inverse). Normals at the crossings come from the samples (the gradient of the
cell's trilinear interpolation) unless you set `gradient_function` (output-space position
-> gradient `Callable`, called from worker threads), which gives exact normals and much
sharper corners.
- `feature_threshold` (0.05): eigenvalues below this fraction of the largest are ignored,
  so nearly flat crossings don't throw the vertex along the surface. Lower keeps
  shallower creases.
- `keep_in_cell` (on): clamp vertices into their cell.

**`SdfDualContouringCpuMesher`** (Carrera, Wang, Batty, Stein and Sellán, "Dual
Contouring of Signed Distance Data", SIGGRAPH 2026, arXiv:2604.00157) needs no normals:
each sample is a sphere the surface should touch. Each outer iteration gives every sample
near the surface to the cell holding its closest point on the current mesh, fits each
cell's vertex to its samples (linearised and damped, `inner_iterations` times, with a
small pull towards the crossings' tangent planes), then fits a plane to the four vertices
around each crossed edge and moves the crossing and its normal towards it.
- Samples must be distances in output units (iso subtracted).
- `outer_iterations` 6 and `inner_iterations` 6 (the paper uses 100 each; both stop
  early once vertices settle within `tolerance`); `hermite_weight` 0.02, `update_weight`
  0.2 and `regularization` 0.1 are the paper's defaults; `band` 1.5 cells of samples are
  fitted.
- Vertices depend on samples around their cell, so neighbouring blocks don't join
  exactly. About 0.6 s for a 21^3 grid in GDScript: mesh once (bakes, imports), not per
  frame.
- Simplified from the paper: a cell's local mesh is its vertex fanned to its crossing
  points (no face intersection points), and four crossings on one face are paired by the
  sign at the face centre.

### GPU readback

`MarchingCubesGpuMesher` meshes in batches (`max_batch`, default 16) on its own
`GpuThread`: a local RenderingDevice can only be used from the thread that created it,
so work is queued to one dedicated thread and merged into batches. Reading results back
stalls until the GPU is idle (5-10 ms while the game is rendering), so each batch reads
back exactly twice: all vertex/index counts, then all triangles after the GPU has copied
them into one buffer. `get_batch_size()` tells callers how many grids to pass at once.

### GPU indirect

`MarchingCubesGpuIndirectMesher` keeps triangles on the GPU: nothing waits for a
readback and nobody builds meshes on the CPU.

- `acquire_target(bounds)` gives a `MesherIndirectTarget`: a slot in a shared triangle
  pool (an RGBA32F texture, one texel per vertex: position, plus normal and material
  packed into an exact integer) and an indirect MultiMesh that draws exactly that slot.
  `release_target()` gives it back.
- `submit(grids, targets)` meshes on the render thread on the **main** RenderingDevice
  (materials can only sample textures that live there). A last pass writes the instance
  count (64 triangles per instance) into each target's command buffer.
- Draw a target with a RenderingServer instance of its `multimesh`, a material that calls
  `ms_pull_vertex()` from `core/pull.gdshaderinc` (set `ms_triangle_pool` to
  `get_pool_texture()`), and the instance parameter `ms_vertex_base`.
- Triangle counts come back asynchronously a frame or two later. `take_empty()` and
  `take_overflowed()` report targets whose mesh was empty or didn't fit, so the caller can
  free the slot or draw that one from a CPU mesh (`get_fallback_mesher()`).
- Settings: `slot_triangles` (default 6144) and `max_slots` (default 256), so the pool is
  75 MB at the defaults; `max_batch` as for the readback mesher.

**Godot 4.7 notes**, for anyone touching this code:
- Allocate an indirect MultiMesh *before* setting its mesh. Godot only creates the
  command buffer in `multimesh_set_mesh`, and allocating afterwards discards it.
- Never call `multimesh_set_visible_instances` on these: it overwrites the GPU-written
  count. The command buffer is `[vertex count, instance count, 0, 0, 0]` per surface.
- `multimesh_free` doesn't free the command buffer (it drops the RID). The pool frees it
  itself, and recycles MultiMeshes instead of freeing them during play.
- `Texture2DRD` can't wrap integer formats, hence the float pool.

## Architecture

```
core/                       the interface every mesher shares
  mesher.gd                 Mesher                 abstract backend
  grid.gd                   MesherGrid             block of samples: the only mesher input
  mesh_data.gd              MeshData               indexed triangles (+ normals, material ids)
seams/                      joining chunks (grid options; marching cubes supports both)
  transition.gd             MesherTransition       finer samples on a face next to a finer block
  skirts.gd                 MesherSkirts           half-voxel seam skirts covering pixel-sized gaps
gpu/                        shared by the GPU meshers
  gpu_thread.gd             GpuThread              thread owning a local RenderingDevice
  indirect_target.gd        MesherIndirectTarget   a pool slot + indirect MultiMesh
  pull.gdshaderinc          vertex pulling include for materials drawing indirect targets
dual/                       shared by the dual meshers
  dual_mesher.gd            DualMesher             crossings, cells, quads; subclasses place vertices
  qef.gd                    Qef                    QEF solve, 3x3 eigen, plane fit
marching_cubes/
  cpu_mesher.gd             MarchingCubesCpuMesher
  tables/
    tables.gd               MarchingCubesTables    marching cubes tables (Lengyel's, Bourke's numbering)
    transvoxel_tables.gd    TransvoxelTables       Transvoxel transition cell tables (MIT)
  gpu/
    gpu_mesher.gd           MarchingCubesGpuMesher
    gpu_indirect_mesher.gd  MarchingCubesGpuIndirectMesher
    common.glslinc          marching cubes math shared by both compute shaders
    transition.glslinc      transition cells shared by both compute shaders
    polygonize.glsl         readback shader
    indirect.glsl           indirect shader (writes into the pool, finalizes draw counts)
dual_contouring/
  cpu_mesher.gd             DualContouringCpuMesher
sdf_dual_contouring/
  cpu_mesher.gd             SdfDualContouringCpuMesher
```

Each algorithm gets its own folder: `cpu_mesher.gd` at the top, GPU variants and their
shaders in `gpu/`, data tables in `tables/`. Code that several algorithms share gets a
folder of its own (`dual/`, `gpu/`), never one inside an algorithm's folder.

### Adding a mesher

Extend `Mesher` and implement `polygonize(grid)`. It runs on worker threads when
`is_thread_safe()` is true, so it must not touch the scene tree or shared state. Read
samples with `grid.get_values()` (decodes bytes), or handle `grid.bytes` yourself.
Override `polygonize_batch` and `get_batch_size` when meshing several grids together is
cheaper, and `warm_up` to start slow setup (GPU devices) early.

A dual method (one vertex per cell) only has to extend `DualMesher` and implement
`_place_vertices(surface)`: set `surface.cell_position` (grid space) and
`surface.cell_normal` for every cell. Surface nets, for example, would be the average of
each cell's crossings.

## Licences

`marching_cubes/tables/transvoxel_tables.gd` and the regular cell triangulations in
`marching_cubes/tables/tables.gd` come from Eric Lengyel's Transvoxel Algorithm data tables
(transvoxel.org, github.com/EricLengyel/Transvoxel; MIT, copyright 2009 Eric Lengyel; the
licence text is in `transvoxel_tables.gd`).

## Tests

```
godot --headless --path <project> -s res://addons/meshers/tests/run_tests.gd
```

GPU tests are skipped under `--headless`; leave the flag off (a window opens briefly) to
run them. Name groups after `--` to run only those.

| Group | Covers |
|---|---|
| `marching_cubes` | watertightness and winding, transition cells closing coarse/fine seams in several layouts, byte samples meshing like floats, the GPU meshers matching the CPU mesher triangle for triangle (the indirect one read back from its pool), skirts, pool slots and overflow |
| `dual_contouring` | QEF maths; both dual meshers on a sphere (closed, on the surface, outward normals and winding, flat shading); two blocks joining exactly; materials; corner error on a rotated box against marching cubes (printed) |
| `bench` | quick micro-benchmarks (printed) |

## Changelog

- 0.3.0: Class names drop the `MS` prefix: `MSMesher` is `Mesher`, `MSMesherGrid` is
  `MesherGrid`, and so on for every class. The shader include's functions and uniforms
  keep `ms_` (they live in the including shader).
- 0.2.0: Dual contouring (`MSDualContouringCpuMesher`) and dual contouring of signed
  distance data (`MSSdfDualContouringCpuMesher`), sharing `MSDualMesher` and `MSQef` in
  `dual/`. Folders reorganised: `core/` keeps the interface (mesher, grid, mesh data);
  transitions and skirts moved to `seams/`; `gpu_thread.gd`, `indirect_target.gd` and
  `pull.gdshaderinc` to `gpu/` (include `gpu/pull.gdshaderinc` now); the marching cubes
  GPU meshers and shaders to `marching_cubes/gpu/`, its tables to
  `marching_cubes/tables/`. Class names unchanged.

- 0.1.1: Folder renamed from `ms_meshers` to `meshers`.
- 0.1.0: Split out of `marching_terrain` 0.11.0. Renamed: `MSMCMesher` -> `MSMesher`,
  `MSMCGrid` -> `MSMesherGrid`, `MSMCMeshData` -> `MSMeshData`, `MSMCTransition` ->
  `MSMesherTransition`, `MSMCSkirts` -> `MSMesherSkirts`, `MSMCIndirectTarget` ->
  `MSMesherIndirectTarget`, `MSMCTables` -> `MSMarchingCubesTables`,
  `MSMCTransvoxelTables` -> `MSTransvoxelTables`, `MSMCCpuMesher` ->
  `MSMarchingCubesCpuMesher`, `MSMCGpuMesher` -> `MSMarchingCubesGpuMesher`,
  `MSMCGpuIndirectMesher` -> `MSMarchingCubesGpuIndirectMesher`; `mc_pull.gdshaderinc` ->
  `core/pull.gdshaderinc`. No behaviour change.
