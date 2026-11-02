# Water sim menu

The settings of a `WaterSim` in the `menus` add-on: a Water notch with Sim, Liquid, View, Spray, Tools and EXPERIMENTAL tabs (pause, cell size, substeps, pressure gain,
substances, how the water is drawn, its spray, the tools). The Save button at the bottom right of the menu writes the tab showing to
`user://menus.cfg`; the next start loads it.

| | |
|---|---|
| Version | 0.3.0 |
| Last tested on | not yet run |
| Depends on | `menus`, `water_sim` |

## Install

Copy this folder into `res://addons/` next to `menus` and `water_sim`. No plugin to enable, no autoload. Neither of the others needs
this one.

## Usage

Put `menus/menus.tscn` and a node with `water_menu.gd` (`WaterSimMenu`) in the scene, and set its `sim`. Set `tools` (a `WaterSimToolBelt`) for a Tools tab that picks the belt's tool and shows each tool's settings (from its
`get_settings()`), or `pull` for the pull tool's.
It finds the box's views, substances and colliders itself. Connect `cell_size_changed` to fill the water again when the scene fills
it itself (and turn `refill_emitters` off).

The water sim's demo HUD (`water_sim/demo/ui/demo_hud.tscn`) puts this menu in when this add-on and `menus` are in the project, and
does without when they are not.

Keys: Esc pauses, R resets, F shows the water, P the particles, M and B step through the water look and particle shape.

## Changelog

- 0.5.0: an EXPERIMENTAL tab for settings still being tried: drowsy blocks on/off and the speed under which a block may be
  drowsy, fast pressure, trim flush and half-float grid on/off (`water_sim` 0.24.0).
- 0.4.0: a Spray tab for a box with a `WaterSimSprayView` (`water_sim` 0.24.0): spray on/off, what sheds it (fast water,
  free-flying water, impacts), how many spray particles each shedding particle makes, and its look (size, opacity, lifetime, stretch).
- 0.3.0: follows `water_sim` 0.23.0: no quality selector, bounded-pressure switch, mesh section (N) or substance stiffness and settling; a pressure gain slider.
- 0.2.0: The Tools tab builds itself from a `WaterSimToolBelt` (`tools`): a drop-down of its tools, a Clear button, and the
  selected tool's settings, which follow changes made with the belt's keys.
- 0.1.0: First version, from the water sim demos' settings panel.
