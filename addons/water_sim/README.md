# Water Sim

Real-time simulated liquids: water and slime in one simulation, pushing on each other. The solver is
MLS-MPM (moving least squares material point method) in C++ on worker threads, and you build scenes from
small component nodes. Drawn as particles: there is no surface mesh.

Built after the approach of Grant Kot's *Liquid Crystal*: a very large number of cheap particles on the CPU, a sparse grid,
fused particle-grid transfers, his capped (bounded) pressure, adaptive particle detail. The status, next steps and what was tried
are in [`source_assets/water_sim/TODO.md`](../../source_assets/water_sim/TODO.md). The previous version (GPU stepper, surface
meshes, trails, heat and lava) is the git tag `water-sim-0.15.3`.

| | |
|---|---|
| Version | 0.24.0 (keep in sync with `plugin.cfg`) |
| Last tested on | Godot 4.7.2 |
| Depends on | none |
| Platforms | Windows x86_64 (native library in `bin/`; source in `source_assets/water_sim/`) |

## Install

Copy this folder into `res://addons/` and add the nodes. No plugin to enable (enabling it
changes nothing), no project settings.

## What enabling the plugin changes

- nothing

## How it works

A [`WaterSim`](water_sim.gd) node is a box of simulation (centred on the node in x and z, from the node up). Matter in it
is particles, eight per grid cell. Every particle has a **substance** (a [`WaterSimSubstance`](substance.gd) resource): a
liquid with its own density, viscosity and friction. Ready-made: `water.tres` and
`slime.tres` (purple, thick). Substances push on each other with no extra code: slime sinks in water.

Each substep a particle reads its velocity and the affine matrix from the grid of the last substep, moves, and at once scatters its
momentum into the next grid (the transfers are fused, so neither is stored: a particle is a position and a substance byte,
in 16 bytes). Space is cut into blocks of 4 x 4 x 4 cells; a block with particles, and the ones round it, has a slot (64 grid nodes
in each of two grids and its particles in pages of 256), so an empty domain costs a 4-byte table entry a block and nothing else.
A block is a task: it copies the nodes its particles read, scatters into a private array and adds that into the next grid; blocks of
one parity along every axis never share a node, so there are eight passes and no atomics. A particle that crossed into another block is
moved there after the passes, which is all the sorting there is. A step is exactly `max_substeps` substeps, shortened (the water
runs slow rather than blowing up) when something moves faster than a cell a substep. `threads` is 1 by default; 0 is every core. Above 1 it is the most a step may use: `step_budget_ms` (8 by default, 0: all of them) has a step in the background use as few as keep it under that many milliseconds, and more at once in a splash, so the rest of the machine is the game's (the water is the same on any number). The transfers
need AVX2, FMA and F16C (nearly every PC CPU since 2013); without them the simulation doesn't run.

**The pressure is Liquid Crystal's bounded pressure, always.** Each substep a particle pushes with a force capped at a fixed size
(`bounded_gain`), computed from the density it gathers and this substep's volume change; it keeps no volume ratio per particle, so
there is no stiffness to set and one substep stays stable at small cells. Water that is slow and in a full place loses its leftover
motion (`bounded_settling`, `bounded_settle_speed`, `bounded_drift`; `bounded_drift_swing` settles a block's bulk motion that is moving back against the way it set off, which is a pond ringing, hard), which is what makes a pond lie still. **Game scale by
default:** `cell_size` 1/8 m and `max_substeps` 1: water at a person's scale (the game scale demo). A finer cell or deeper water wants more
substeps or a higher `bounded_gain` (at 1/8 m, 2 substeps hold a pond up better). Mind `max_particles` (60000 by default) at that size: the
game scale demo raises it to a million.

Colliders, force fields (vortex, push, wind), emitters, drains, a recycler (water in a loop), a converter (one substance into
another), a transmuter (a mesh into matter) and buoyancy for rigid bodies are components. Resting liquid can sit as
[`WaterSimStillWater`](still_water.gd) (columns of water drawn as one flat surface) and boxes can sleep and wake; see
`WaterSim.sleep()`. Water at rest never looks dead still: `surface_wave_height` (5 cm by default, 0 for none), `surface_wave_length`
and `surface_wave_speed` lift the particles as the fluid view draws them. The simulation doesn't see these waves and they wake nothing;
`sample_density`, `sample_velocity` and `raycast` follow them (`surface_wave_at`), so floating bodies do.

## Nodes

Put the components anywhere. Each one finds its simulation: the `WaterSim` above it, else the one whose box it's in, else
the one set in its `sim` property.

| Node | What it does |
|---|---|
| `WaterSim` | The simulation box. Size, cell size, gravity, budgets, sleep settings, the bounded pressure's tuning. API for gameplay: `fill`, `spray`, `fill_mesh`, `fill_faces`, `convert`, `remove`, `wake`, `sleep`, `sample_density`, `sample_velocity`, `raycast`, `get_stats`, `get_particle_count` (what the sim carries) and `get_fine_particle_count` (the matter, with adaptive detail counting a coarse particle as eight; `remove` and the recycler count this way too) (all in global space), and the `*_at` queries across every box and still water. |
| `WaterSimStillWater` | Resting liquid: columns of water drawn as one flat surface (`shaders/toon_water.gdshader`). Fills from the ground at start; boxes wake it into particles and settle it back. |
| `WaterSimWorld` | Starts boxes from a box scene where something happens and none is awake, within a budget; retires them when settled and empty. |
| `WaterSimEmitter` | Fills its shape once (`fill_on_start`, `fill()`; `fill_limit` stops at a number of particles, from the bottom up) or pours while `emitting` (`flow` in m³/s), up to `max_volume` if set (`pour_again()` restarts it). |
| `WaterSimCollider` | Child of a physics body. Its shapes block matter (or a mesh, baked into a distance grid). Moving bodies drag matter along. |
| `WaterSimVortex`, `WaterSimPush`, `WaterSimWind` | Force fields: a tornado or whirlpool, a blast, a wind. `spray` (off by default): the water at the surface inside sheds spray (`spray_amount`, its chance a step; `spray_speed`, flung outwards from the middle or a vortex's axis), from coarse particles too. |
| `WaterSimStream` | A river in the air along a `Curve3D` (its own, or a `Path3D` parent's): a chain of vortex fields along the path carries the water and cancels gravity, its speed growing from `speed_start` to `speed_end` (`ramp`), its `pull` holding the water in, a wider mouth (`mouth_scale`) gathering it, and the pull letting go over the last `release` of the path. Edit the curve and it lays itself out again. |
| `WaterSimOrb` | Gathers matter into a ball and holds it, in the air if need be: nested pulls growing with the distance from the centre, none in the core (each holds what is full rather than squeezing it). `feed_length` adds a column under it that draws water up from below until the ball is full (`full_density`). `spray`, `spray_amount`, `spray_speed`: the ball sheds spray from its surface. |
| `WaterSimConverter` | Turns matter in its shape into another substance (water into slime), at once with `apply()` or gradually while `active`. |
| `WaterSimRecycler` | Takes matter that reaches its shape and puts it back where an emitter is: flowing water in a loop. |
| `WaterSimDrain` | Removes matter in its shape. |
| `WaterSimTransmuter` | Under an object: `transmute()` fills its mesh with a substance and removes the object. |
| `WaterSimBuoyancy` | Under a `RigidBody3D`: floats it and lets the flow carry it. |
| `WaterSimFluidView` | Draws the water as water: a screen-space pass (a `CompositorEffect` added to the camera's compositor) of particle depth and thickness, smoothed, with refraction, fresnel and sun glints; shallow water is light (`shallow_color`), deep water takes the substance's `color`; water in front of water and slime in water are right by construction. `style`: TRANSLUCENT (the full see-through look), OPAQUE (lit solid water) or CLEAR (default: see-through at OPAQUE's cost: depth from the scene behind, `see_depth`; no refraction). `shape`: SPHERE (default), CUBE (sides along the simulation's axes) or DISC (a fifth as thick as wide: flat, turning upright with the water's vertical speed, all the way at 4 m/s, to face along its flow, so a river stays flat and a fall stands up; `discs_face_camera`, on by default, turns upright discs about the vertical to face the camera; in 13 spare bits of the particle's 8 bytes, about two degrees a step), each with a sphere's volume; less `smoothing` shows the shapes. Needs a rendering device (Forward+/Mobile). |
| `WaterSimSprayView` | Draws spray: whitish particles shed by the water where it is thin and fast (`from_fast`), flying free (`from_free`) or jolted (`from_impacts`), or held in a field or orb that sprays (`from_fields`), that fly on gravity and air drag and fade when they land (against the scene's and the water's depth) or grow old. Purely visual: the simulation never sees them; it flags them on its last substep (each substance's `spray` is its chance a step; slime 0) and a fixed GPU pool (`capacity`) moves and draws them after the water. `per_particle` (1-16): how many each shedding particle makes, on the GPU (free for the simulation; mind `capacity`). `size`, `opacity`, `lifetime`, `stretch` (streaks along their motion), `whiteness`. Hidden or `enabled` off, nothing is shed. Needs a rendering device (Forward+/Mobile). |
| `WaterSimParticleView` | Draws the particles as small meshes coloured by substance (for looking at the simulation; off in the demos by default). |
| `WaterSimLodView` | Draws the particles as see-through discs coloured by level of detail (debugging; the demos' L key). |

## Tool kit (`tool_kit/`)

Player tools built from components, with no code for a new one. A `WaterSimTool` node switches on the components under it while it
is used (emitters emit, drains drain, fields push, streams and orbs act; `linked` switches nodes elsewhere too, unmoved: a recycler
at a pool's floor feeding the tool's emitter). It scales their speeds, flows, rates and strengths by `power` and their sizes and
offsets by `reach`; is aimed at the surface under the mouse (`height` above it) or `distance` along the ray (`aim_mode`); is turned
upright, along the view, along the view kept level, or along the surface (`facing`); and acts while held, toggles, pulses for
`pulse_time`, or places working copies (`use`). `spray` switches its fields' and orbs' spray (on if any was given it).
`get_settings()` lists what a player may change.

A `WaterSimToolBelt` holds tools as children and works the selected one with the mouse: 1 to 0, Q and E pick, Shift / Ctrl / Alt
with the wheel change reach / power / height, C clears what the tools left; `selected` and `get_tools()` let a menu follow it (the
`water_sim_menu` add-on's Tools tab builds itself from the tools' settings when the HUD or menu is given the belt as `tools`).
`WaterSimStreamTool` draws a `WaterSimStream`: drag across the water, let go.

Notes from building them: a steered field overrides the pressure, so targets that converge (a pull into a point or onto an axis, or
into a region held still) crush water far past its density. Keep a pull's strength times speed within a few times gravity, and
leave a free core (as the orb does); the solver now tapers a push's and a vortex's pull to nothing in their core.

## Demo

The demos are all in `demo/scenes/` (water, waterfall, game scale, tool sandbox, spline, big world (kot), rivers). Each puts in `demo/ui/demo_hud.tscn` and sets its `sim`: the metrics, the settings menu (the `[` or `]` key; the Water panel of the optional `menus` and `water_sim_menu` add-ons, which save a tab's settings with the Save button) and the LOD debug mode (L), the same in every demo, on the game scale demo's settings (1/8 m cells, one substep, two levels of detail from 10 m, 4 threads, a million particles at most). The big world and the rivers shrink to fit those cells. The Choral model is in `demo/assets/`.

`demo/scenes/water_demo.tscn` (a pond with rocks and floating crates) and `demo/scenes/waterfall_demo.tscn` (three terraces). Keys 1 to 5
pick a tool (pour water, tornado, blast, pour slime, rock to water), left mouse uses it. The settings menu (`[` or `]`)
has threads, cell size, substeps, the pressure gain, pause (Esc) and the particle switch (P). In the game scale demo left click pulls water in at the mouse (the Tools tab sets how hard, and how far from the camera).
`demo/scenes/tool_sandbox.tscn` is every kind of tool on a 20 x 20 m pool of two million particles (1/8 m cells, 8 threads,
a step of about 10 ms): pour, blast, gather into a floating ball, tornado, whirlpool, geyser, draw a floating river, stasis (freeze
the water in mid-air), a water jet, a gust, summon (draw water from the pool's floor to the mouse), vanish and rain (the pool's
own water). The menu's Tools tab picks a tool and shows its settings; its Scene panel fills the pool with 0.1 to 5 million particles
(2 million steps in about 10 ms, 5 million in 30 to 70). `demo/scenes/spline_demo.tscn` is one `WaterSimStream`: a
corkscrew drawing water up out of a pool, once round and back down (T on and off, P the path).
`demo/scenes/game_scale_demo.tscn` is water at a person's scale: a 12 x 12 m pool of 0.125 m cells, empty at the start,
poured from a spout that never stops (R empties it), with a 1.60 m character (Choral, copied from `locomotion_library` so the add-on stands alone) on the bank and in the water.

## Cost (this machine, i9-14900HX, DDR5-5600 dual channel: 8 fast cores with two threads each and 16 slower ones; AVX2; `tools/sparse_bench.gd`)

Nanoseconds a particle a substep, a lake in the corner of a 512 x 512 x 128 cell domain (empty space costs nothing: the same
water in a 48 x 24 x 48 domain is the same 38 to 39 ns):

| threads | 780k particles | 3M particles |
|---|---|---|
| 1 | 39.8 | 41.1 |
| 4 | 12.0 | 13.3 |
| 8 | 8.0 | 8.3 |
| 16 | 5.6 | 4.8 (8.5x one thread) |
| 32 | 4.5 | 3.3 (12.5x one thread) |

Measured with the particles' stress, before the bounded pressure was the only one; the transfers are the same kind of work (the
game scale demo's step is now about 11 ns a particle-step on 32 threads, 1M particles in 10-12 ms). A game will not give the
simulation every core: at 60 fps the game scale demo's step is 7.1 ms on 2 threads, 6.0 on 3, 5.3 on 4 and 4.4 on 6, and the whole process used 22, 26, 31 and 36 CPU seconds over the same 20 s (see `step_budget_ms`).

## Limits

- CPU only; Windows x86_64 only; AVX2, FMA and F16C needed. A domain is a table of blocks (up to 33 million of them, 4 bytes each).
- Solids and gases aren't simulated.
- The bounded pressure holds water up in proportion to 1 / (a substep's length)^2: at the default 1/8 m cell two substeps hold a pond up better than the
  default one, and deeper water than a few metres wants a higher `bounded_gain`. Water at depth is a little less dense (a 4 m pond stands
  at about 0.93 of its rest height).
- LOD 3 and 4 cells are 4 and 8 fine cells across (2.7 and 5.3 m at the default cell): far water is that coarse, so a stream
  or a pool thinner than that far from the camera is not resolved there. Set `detail_distance` (or `detail_levels`) to suit the
  scene.

## Checking a change

No test suite: the old one is in git history. `tools/regression_check.gd` runs the game scale pond headless and deterministically and exits 1 if
it got worse; run it before and after any solver change, and look at the game scale demo (`demo/scenes/game_scale_demo.tscn`):

```
godot --headless --fixed-fps 60 --path . -s res://addons/water_sim/tools/regression_check.gd
```

`tools/bench.gd` runs a demo for a fixed time (in seconds, not frames) and writes one JSON (frame, GPU, render CPU, the solver's timings,
memory) to `res://.bench/`; `COMPARE=a.json,b.json` prints what changed between two runs. `tools/demo_shot.gd` takes a picture of
a demo. Both need a window for GPU numbers or pictures; see their headers for the environment variables. The other tools are listed in
`source_assets/water_sim/TODO.md`.

## Building the native library

```
python source_assets/water_sim/build.py
```

It fetches llvm-mingw, SCons and godot-cpp into `%LOCALAPPDATA%/water_sim` (or `WATER_SIM_NATIVE`; point that at
`adaptive_mesh_native`'s work folder to share it) and builds `bin/water_sim.windows.template_release.x86_64.dll`. Godot locks
loaded libraries: rename the old DLL (it can be renamed while loaded; the editor keeps the old code until it restarts) or close the editor first.

## Changelog

- Unreleased, **cleanup.** Removed, nothing in the project used them: `WaterSimSolver.set_vector_instructions`, `get_vector_instructions`, `get_cell_size`, `set_wall_friction`, `add_particles`, `mean_velocity`, `get_volume_ratios`, `get_multimesh_buffer` (`set_particle_request` builds the same buffers); `WaterSimEmitter.burst`, `WaterSimStillWater.get_column` and `get_volume`, `WaterSimStream.get_fields`, `WaterSimToolBelt.get_selected_tool`; the sand declaration in the native library; `shaders/toon_solid.gdshader`; the one-off tools `big_world`, `demo_levels`, `fine_share`, `fps_check`, `hidden_count`, `rivers_run`, `view_share`; the old pictures in `demo/assets/shots/`. The water is unchanged. The plans and the log are now one file, `source_assets/water_sim/TODO.md`.
- Unreleased: `WaterSimLodView` draws farthest first, by the camera: the stripes of red and blue it showed were its draw order, not the levels.
- Unreleased: **surface waves** (`WaterSim.surface_wave_height`, `surface_wave_length`, `surface_wave_speed`; `surface_wave_at`). `WaterSimParticleView`, `WaterSimLodView`, spray and still water's mesh don't move with them. **`WaterSim.sleep_after`** (8 s; `WaterSimSolver.set_sleep_after`): how long a block waits to sleep after it last had no quiet time, so a pond levels first (humps at 1 m: 3.0 to 1.6 cm). A change of detail level no longer starts a block's quiet time again.
- Unreleased: **thread budget**, `WaterSim.step_budget_ms` (8 ms by default; `WaterSimSolver.set_step_budget`; `get_stats` has `threads_used`): `threads` is now the most a step may use, and a step in the background uses as few as keep it under the budget. Game scale demo, at most 4 threads: 2 threads, step 6.9 ms, 21% less CPU for the whole process.
- Unreleased: `WaterSim.trim_flush`, `half_grid`, `fast_pressure`, `fast_points` and their `WaterSimSolver` setters removed: a block always flushes only what it reached, the half-float grid lost, and the pressure and points are always worked out the fast way. `WaterSimFluidView.shape` defaults to SPHERE. The opaque and clear looks draw their particles at half size (water GPU about a third less, edges a little softer). The fluid view's points are written by the step itself as it moves the particles. `threads` can change in play with no new threads below the most there have been. Game scale demo at 4 threads and 60 fps: step 5.33 to 4.75 ms.
- 0.24.0: **spray** (`WaterSimSprayView`): particles that are only drawn; force fields and orbs can spray too. **Drowsy blocks**, experimental and on by default (`WaterSim.drowsy_blocks`, `drowsy_speed`): a block awake but slower than 1 m/s moves every other step, twice as far (forces act on it at half rate). Taking or converting particles wakes only the blocks it changed. A pull gathers only into room (the sandbox's Gather ball was 34 times water's density in the middle, now about 1.1). The library needs F16C besides AVX2 and FMA.
- 0.23.0: **cleanup: only what the Liquid Crystal route uses.** The bounded pressure is the only pressure (`bounded_pressure`, the substances' `stiffness` and `settling`, and `WaterSim.cfl` are gone; a step is exactly `max_substeps` substeps). Removed: `WaterSimMeshView`, `WaterSim.quality`, acoustic mode, the trilinear kernel, the surface skin, `WaterSim.backend`, the spray and foam dots in the native library. Scene files and `.tres` substances with the old properties still load.
- 0.22: **the tool kit and new components:** `WaterSimStream`, `WaterSimOrb`, `WaterSimTool`, `WaterSimToolBelt`, `WaterSimStreamTool`, the tool sandbox and spline demos, a Tools tab in `water_sim_menu`, `WaterSimEmitter.fill_limit`. A push's speed and a vortex's pull taper to nothing in their inner quarter.
- 0.21.1: water by a wall no longer sinks with LOD 3 and 4: those blocks keep the fine grid, and the bounded pressure counts hanging nodes at a wall or collider as full.
- 0.20.0: **four levels of detail** (`WaterSim.detail_levels`; `WaterSimSolver.set_adaptive` takes `max_level` up to 3): a level a band of `detail_distance`, one more under the water all the way; past LOD 2 the grid is coarse too (`solver_hier.cpp`).
- 0.19: **clear water** (`WaterSimFluidView.style` CLEAR), `WaterSimEmitter.max_volume`, the game scale demo moved into the add-on, far water no longer pays for sub-pixel triangles (a compute pass draws particles under `small_pixels`).
- 0.18: **a fixed step** (`WaterSim.fixed_step`, 1/60 s by default); the crawling crosshatch in the opaque and translucent views fixed.
- 0.17.0: **opaque water**, adaptive detail on by default, frozen blocks, one step a frame by default, 8-byte points, thin interior.
- 0.16.0: **CPU MLS-MPM** (Water-Sim-Kot): the sparse fused solver, water and slime, screen-space fluid drawing (`WaterSimFluidView`, `WaterSimFluidEffect`), adaptive detail, sleeping blocks, the big-world and rivers demos. Removed: the GPU stepper, surface nets and views, trails, heating, boiling, changes of state and lava.
- Earlier versions (0.1 to 0.15.3): see the README at the tag `water-sim-0.15.3`. Everything in between in full: this file's git history.
