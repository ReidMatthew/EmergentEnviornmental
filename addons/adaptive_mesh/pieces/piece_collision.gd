@tool
class_name PieceCollision
extends Resource
## Physics for an [AdaptiveMesh]'s pieces: each piece gets a [StaticBody3D] with a
## trimesh shape, rebuilt after every edit. Empty on the mesh uses the defaults (collision
## on); turn [member enabled] off for none.

@export var enabled := true
@export_flags_3d_physics var layer := 1
@export_flags_3d_physics var mask := 1
## Moving meshes only (under a [RigidBody3D]): how many convex hulls each piece collides
## as. One hull fills in a piece's hollows and hooks; more follow them more closely (see
## [method ConvexCells.hull_sets]), at more cost per edit (worked out on a worker thread)
## and in the physics engine.
@export_range(1, 32) var hulls_per_piece := 1
