# water_sim: notes for Claude

CPU MLS-MPM liquids (water, slime) in a GDExtension, built as component nodes, drawn as particles by a screen-space fluid pass.
The goal is water like Grant Kot's *Liquid Crystal* inside a real-time game. Read `README.md` for how it is used and
`source_assets/water_sim/TODO.md` for what comes next, what is true now, what was tried and lost, and how to measure. It is the only
plan. The old full log is at `git show ea43b54:source_assets/water_sim/KOT_LOG.md` (320 KB): open it only for a specific experiment,
never read it whole.

## Rules

- **No dead branches.** A scheme that lost (the J stress, acoustic mode, trilinear weights, the coupled grids, the skin, the mesh)
  goes under "Settled" in `TODO.md` and is removed from the code, not kept behind an option. Git history has it.
- **Perf work is code, never cheaper settings.** Measure before and after; keep a change only if it helps outside the noise.
  Add each experiment's deciding numbers to "History" in `TODO.md`, in a line or two, and keep that file short.
- **Standalone.** No dependency on other add-ons; the plugin changes nothing. Scenes are composed nodes and sub-scenes.
- **Settings, not environment variables,** in the native library: tunables go through `Settings` (`backend.h`) and a
  `WaterSimSolver` setter. Tools may read env vars and call the setters.
- Before trying anything in "Settled" in `TODO.md`, have a new idea for why it would work this time.

## How it fits together

- Native source `source_assets/water_sim/src/`: `solver.*` + `solver_step.cpp` (the fused kernel and the bounded pressure, the
  only pressure there is), `solver_sleep.cpp`, `solver_adapt.cpp` + `solver_hier.cpp` (levels of detail, the grid hierarchy),
  `shapes.*`, `thread_pool.*`, `waves.*` (`WaterSimWaves`, still water's heightfield), `water_sim_solver.*` (the Godot class
  `WaterSimSolver`, which pushes a `Settings` to the `Backend`, which is the one `Solver`).
- `water_sim.gd` (`WaterSim` node) owns the solver and sends its inputs every frame (`_update_inputs`); components (`components/`)
  find their sim and contribute shapes, fields, emitters. `views/fluid_effect.gd` + `fluid_view.gd` draw from the solver's point
  buffer (there is no mesh path: the water is only ever drawn from the particles); `views/spray_*` draw spray on the GPU.
- `tool_kit/` is player tools built from components. `demo/` is the demos; `addons/water_sim_menu` (a separate add-on) is their menu.

## Building and running

- Godot: `C:/Users/msrei/OneDrive/Documents/Godot/Godot_v4.7.2-stable_win64_console.exe`.
- Build: `WATER_SIM_NATIVE="$LOCALAPPDATA/adaptive_mesh_native" python source_assets/water_sim/build.py`. A running editor locks the
  DLL: close it, or rename the DLL first (it can be renamed while loaded; the editor keeps the old code until it restarts). Those
  renames leave `*.dll.locked_*` in `bin/`, git-ignored; delete them now and then.
- No test suite (removed 2026-10-19; it is in git history). After a native or solver change run `tools/regression_check.gd`
  (`godot --headless --fixed-fps 60 --path . -s res://addons/water_sim/tools/regression_check.gd`, deterministic, about 10 s) and look at the game scale demo
  (`demo/scenes/game_scale_demo.tscn`). A script that fails to compile makes it hang, not fail: give it a timeout and read stderr.
- Defaults: `cell_size` 1/8 m, `max_substeps` 1 (the bounded pressure always takes exactly that many; the user chose 1 on 2026-10-28, though 2 holds a pond up better at 1/8 m),
  `fixed_step` 1/60 s. Some demos (kot, rivers) use one substep at coarser cells. Quadratic weights only.
- Measure with `tools/bench.gd`: a fixed demo run to one JSON in `res://.bench/`, `COMPARE=a.json,b.json` for the difference. `WaterSim.threads` is only the most a step may use under `step_budget_ms` (default 8 ms); `bench.gd` turns that off unless `BUDGET=ms`, so its `THREADS` is what is measured.
  Prefer it over screenshots and long logs. Other tools are listed in `TODO.md`.

## Traps

- **Heredocs turn `\n` in C strings into real newlines.** Edit C++ with the Edit tool, not bash or python heredocs.
- **Godot does not reimport a shader when only an included `.glslinc` changes.** After editing one, delete
  `.godot/imported/fluid_*.glsl-*` and run `--import`, or the old shader runs against new data.
- **Denormal floats.** The bounded pressure's settling multiplies calm velocities by < 1 every substep, so they decay into denormals, which cost 100+ cycles
  an operation and stall every block waiting on them (bounded mode ran 2-4x slower and bimodally until `FlushDenormals`). New
  pool tasks that touch particle or grid values get one too. Time a slow stage by thread-ms against waiting thread-ms first.
- **Benchmarks drift with machine load** (the user may be gaming). Alternate before/after runs several times; check what else runs.
- **Say which thread count a number is for.** The target in a game is 4 threads; judge work there. The count stays
  customizable (more or fewer by the part of the game and how much the water matters), so 2 and 8 are secondary checks. Where our
  other choices conflict with what Kot states, his win (`TODO.md`).
- **Before removing a name, search every add-on and demo that uses it**, across files: `addons/water_sim_menu` and `demos/castle_moat` call in, and `bench.gd` dumps every stat `get_stats` returns.
- D3D12 (Godot's default renderer on Windows here) ignores point sprite size. Godot crashes if it quits while a GDScript job
  runs on a worker thread.
