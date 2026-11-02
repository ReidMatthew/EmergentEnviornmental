@tool
class_name DualContouringCpuMesher
extends DualMesher
## Dual contouring (Ju, Losasso, Schaefer and Warren, "Dual Contouring of Hermite Data",
## SIGGRAPH 2002) in plain GDScript. Each cell's vertex goes where the tangent planes at the
## surface crossings on its edges meet (the QEF minimiser), so sharp edges and corners
## survive instead of being bevelled off as with marching cubes.
##
## Tangent planes need normals at the crossings. By default they come from the samples (the
## gradient of the cell's trilinear interpolation), which rounds features a little where a
## cell straddles them; set [member gradient_function] when the field is analytic to use
## exact normals instead. Either way a vertex only reads its own cell, so blocks meet
## exactly (see [DualMesher]).

## Eigenvalues of the QEF below this fraction of the largest are ignored, so planes that
## are nearly parallel (flat or gently curved surface) don't push the vertex far along the
## surface. Lower keeps shallower creases sharp; higher smooths more.
@export_range(0.0, 1.0, 0.001) var feature_threshold := 0.05
## Clamp vertices into their cell. Without it, vertices of thin or noisy features can land
## outside and fold the mesh.
@export var keep_in_cell := true

## Optional exact gradient: takes an output-space position, returns the field's gradient
## there (any length, pointing from inside to outside). Called from worker threads.
var gradient_function: Callable


func _place_vertices(surface: DualMesher.Surface) -> void:
	var grid := surface.grid
	var exact := gradient_function.is_valid()
	var positions := surface.cell_position
	var cell_normals := surface.cell_normal
	var normals := PackedVector3Array()
	var points := PackedVector3Array()
	for c in surface.get_cell_count():
		var coord := surface.cell_coord[c]
		normals.clear()
		points.clear()
		var sum := Vector3.ZERO
		for e in surface.cell_edges[c]:
			var p := surface.edge_point[e]
			var g: Vector3 = gradient_function.call(grid.origin + p * grid.spacing) if exact \
					else surface.gradient_in_cell(coord, p)
			points.append(p)
			if g.length_squared() > 0.0:
				g = g.normalized()
				normals.append(g)
				sum += g
			else:
				normals.append(Vector3.ZERO)
		var x := Qef.solve(normals, points, feature_threshold)
		if keep_in_cell:
			x = x.clamp(Vector3(coord), Vector3(coord + Vector3i.ONE))
		positions[c] = x
		cell_normals[c] = sum.normalized() if sum.length_squared() > 0.0 else Vector3.UP
	surface.cell_position = positions
	surface.cell_normal = cell_normals
