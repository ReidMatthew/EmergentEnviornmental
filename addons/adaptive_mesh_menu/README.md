# Adaptive mesh menu

The settings of a scene's `AdaptiveMesh` nodes in the `menus` add-on: a Mesh notch with a Mesh tab (the main thread budget, and how
many meshes and triangles there are), and a tab each for the Cleanup, Separation and Debris settings the meshes have. A setting
goes to every mesh in the scene. The Save button at the bottom right of the menu writes the tab showing to `user://menus.cfg`; the
next start loads it.

| | |
|---|---|
| Version | 0.1.0 |
| Last tested on | not yet run in a window |
| Depends on | `menus`, `adaptive_mesh` |

## Install

Copy this folder into `res://addons/` next to `menus` and `adaptive_mesh`. No plugin to enable, no autoload. Neither of the others
needs this one.

## Usage

Put `menus/menus.tscn` and a node with `mesh_menu.gd` (`AdaptiveMeshMenu`) in the scene, after its `AdaptiveMesh` nodes. It does
nothing without a menu host or a mesh. A tab shows only when some mesh has that resource (`cleanup`, `separation`, `debris`).

Only what a mesh reads when it edits is here. How it is drawn and collided is baked into its pieces, so it is left out.

## Changelog

- 0.1.0: First version.
