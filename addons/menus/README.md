# Menus

A menu that slides out from the right of the screen (the `[` or `]` key), for the settings of any add-on's test scene. Panels from
different add-ons each get a notch of their own.

| | |
|---|---|
| Version | 0.1.0 |
| Last tested on | Godot 4.7 |
| Depends on | none |

## Install

Copy this folder into `res://addons/`. No plugin to enable, no autoload.

## Usage

1. Put `menus.tscn` (a `MenuHost`) in the scene.
2. Whatever has settings finds it and adds a panel. With no host in the scene, it skips them.

```gdscript
var host := MenuHost.find(get_tree())
if host != null:
	var panel := MenuPanel.new()
	panel.title = "Water"
	panel.check("Pause", false, func(on: bool) -> void: sim.simulating = not on)
	panel.slider("Gravity", 1, 40, 0.1, 9.8, func(v: float) -> void: sim.gravity = Vector3.DOWN * v)
	host.add_panel(panel)
```

`MenuPanel` has `section`, `label`, `check`, `slider`, `options`, `button`, `line` and `number`; `show_value(text, v)` updates a
control from code without calling its callback. `tab(name)` starts a tab inside the panel, for organisation. Each panel gets a notch of its own on the screen edge, labelled with its title; a click opens that panel.

Notches stack down the edge by themselves, ordered by `MenuPanel.order` (lowest first) and then by title, so they don't depend on which add-on added its panel first.

Keep an add-on's menu code out of its core scripts: put it in the demo or a small sibling add-on, so the add-on itself never needs `menus`.

`MenuHost` exports: `toggle_keys` (`[` or `]`), `width`, `open_on_start`, `show_button` (the notches at the top right, one per panel), `config_path` (where Save writes), `look` (a Theme for the menu).

`MenuPanel.tab(name)` starts a tab inside a panel.

Saving: the Save button at the bottom right writes the tab showing, of the panel showing, to `config_path` (`user://menus.cfg`; empty:
no saving). Each tab has a section `Panel / Tab` named by its controls' text, and no other tab is touched. When a panel is added its
saved sections are loaded onto its controls, and their callbacks run as if the player had set them.

A game that holds the mouse gets it back while the menu is open.

## Changelog

- 0.1.0: Slide-out, a notch per panel, tabs inside a panel (`MenuPanel.tab`), per-tab Save and load, the controls above.
