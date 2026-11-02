class_name RiverCourse
extends RefCounted
## The land of the rivers demo, as one height field: a shelf the water starts on, a cliff it falls
## down into a medium pond, a river spiralling round that pond and on to a large pond, another
## that winds down to a small whirlpool with a pit in the middle. Everything is in "map" metres: x
## along, z across, y up from the floor; the map is [constant SIZE] across, and the simulation
## box has the same corner (see [method to_world]).
##
## The land lies [constant WALL] above the beds of the water near it, blending smoothly from one level
## to the next (a weighted mean of the nearby features, nearest most). Each feature is a valley cut
## into that: its bed (a point, or a line with a height at each point), and banks rising from its
## edge at a slope of their own until they meet the land. A feature's water is a depth over its bed.

const SIZE := Vector2(360.0, 300.0)
const CAP := 62.0
## How far above the beds of the water near it the land lies (m), before it falls to the valleys.
const WALL := 5.0
## The grid of the land's general height, before the valleys are cut (m between samples).
const BASE_SPACING := 4.0


class Channel:
	# x, bed height, z
	var points := PackedVector3Array()
	var half_width := 2.5
	var depth := 0.9
	var bank := 1.5
	var name := ""

	func length() -> float:
		var total := 0.0
		for i in range(1, points.size()):
			total += Vector2(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z).length()
		return total


class Pond:
	var center := Vector2.ZERO
	var radius := 10.0
	var bed := 0.0
	var depth := 1.2
	var bank := 1.5
	# A pit in the middle: its radius and how far below the bed it goes.
	var pit_radius := 0.0
	var pit_depth := 0.0
	var name := ""


var channels: Array[Channel] = []
var ponds: Array[Pond] = []
# Where things go, in map coordinates (x, y, z).
var inlet := Vector3(120, 55.4, 86)
var drain := Vector3(250, 1.1, 275)
# The shelf's bed (its water is 1.4 m deep).
var shelf_bed := 54.6


func _init() -> void:
	# The shelf the water starts on and the cliff it falls down: a flat run to the lip, then
	# a drop of nearly the whole height in a metre.
	var shelf := Channel.new()
	shelf.name = "Shelf"
	shelf.points = PackedVector3Array([Vector3(120, shelf_bed, 74), Vector3(120, shelf_bed, 121.5), Vector3(120, 27.0, 122.6)])
	shelf.half_width = 9.0
	shelf.depth = 1.4
	shelf.bank = 3.0
	channels.append(shelf)

	var pond_a := Pond.new()
	pond_a.name = "Medium pond"
	pond_a.center = Vector2(120, 150)
	pond_a.radius = 15.0
	pond_a.bed = 28.0
	pond_a.bank = 3.0
	ponds.append(pond_a)

	# From the medium pond, most of the way round it (leaving the waterfall's side clear) and out; the
	# radius grows as it goes. Its bed is flat where it leaves the pond and half way, steeper between.
	var ring := Channel.new()
	ring.name = "Circular river"
	ring.bank = 3.0
	var profile: Array[Vector2] = [Vector2(0.0, 28.6), Vector2(0.1, 28.5), Vector2(0.35, 24.4), Vector2(0.5, 24.2), Vector2(0.85, 17.4), Vector2(1.0, 16.6)]
	var start_angle := deg_to_rad(215.0)
	var sweep := deg_to_rad(260.0)
	var steps := 52
	var coords := PackedVector2Array()
	var arcs := PackedFloat32Array()
	var arc := 0.0
	for i in range(0, steps + 1):
		var t := float(i) / steps
		var a := start_angle - sweep * t
		var r := 26.0 + 12.0 * t
		var p := Vector2(120.0 + cos(a) * r, 150.0 + sin(a) * r)
		if i > 0:
			arc += p.distance_to(coords[i - 1])
		coords.append(p)
		arcs.append(arc)
	var points := PackedVector3Array()
	points.append(Vector3(120.0 + cos(start_angle) * 14.0, profile[0].y, 150.0 + sin(start_angle) * 14.0))
	for i in coords.size():
		points.append(Vector3(coords[i].x, _along(profile, arcs[i] / arc), coords[i].y))
	ring.points = points
	channels.append(ring)

	var link := Channel.new()
	link.name = "River to the large pond"
	var end_at := points[points.size() - 1]
	link.points = PackedVector3Array([end_at, Vector3(172, 16.5, 126), Vector3(192, 16.0, 133), Vector3(208, 15.4, 142)])
	link.bank = 3.0
	channels.append(link)

	var pond_l := Pond.new()
	pond_l.name = "Large pond"
	pond_l.center = Vector2(232, 150)
	pond_l.radius = 26.0
	pond_l.bed = 13.4
	pond_l.bank = 3.0
	ponds.append(pond_l)

	# Winding down to the whirlpool: a straight run, two bends, a straight run.
	var winding := Channel.new()
	winding.name = "Winding river"
	winding.bank = 3.0
	# A straight run (flat at first), two bends, a flat bend between them, a straight run.
	var way: Array[Vector3] = [Vector3(232, 14.0, 172), Vector3(232, 13.9, 196), Vector3(240, 11.4, 214), Vector3(226, 8.9, 230),
			Vector3(214, 8.8, 246), Vector3(228, 6.3, 258), Vector3(248, 3.4, 262), Vector3(250, 2.8, 267)]
	var winding_points := PackedVector3Array()
	for point in way:
		winding_points.append(point)
	winding.points = winding_points
	channels.append(winding)

	var whirl := Pond.new()
	whirl.name = "Whirlpool"
	whirl.center = Vector2(250, 275)
	whirl.radius = 9.0
	whirl.bed = 2.0
	whirl.depth = 1.2
	whirl.bank = 3.0
	whirl.pit_radius = 3.5
	whirl.pit_depth = 1.4
	ponds.append(whirl)


## The height of a profile (pairs of how far along, 0 to 1, and a height) at t.
func _along(profile: Array[Vector2], t: float) -> float:
	for i in range(1, profile.size()):
		if t <= profile[i].x:
			return lerpf(profile[i - 1].y, profile[i].y, (t - profile[i - 1].x) / maxf(profile[i].x - profile[i - 1].x, 1e-6))
	return profile[profile.size() - 1].y


## A map position and height as a world position (the demo's box is centred on the origin).
static func to_world(map: Vector3) -> Vector3:
	return Vector3(map.x - SIZE.x * 0.5, map.y, map.z - SIZE.y * 0.5)


## The land as a grid of heights, row by row (z), with a sample every spacing metres.
func build_heights(spacing: float) -> PackedFloat32Array:
	var nx := int(round(SIZE.x / spacing)) + 1
	var nz := int(round(SIZE.y / spacing)) + 1
	var heights := _base(spacing, nx, nz)
	for channel in channels:
		for i in range(1, channel.points.size()):
			_carve_segment(heights, nx, nz, spacing, channel, channel.points[i - 1], channel.points[i])
	for pond in ponds:
		_carve_pond(heights, nx, nz, spacing, pond)
	# One light blur takes the stair steps off the banks of channels that run across the grid.
	return _soften(heights, nx, nz)


# The land before the valleys: a coarse grid of the weighted mean of the features' beds (plus
# WALL), made fine by interpolation.
func _base(spacing: float, nx: int, nz: int) -> PackedFloat32Array:
	var cx := int(ceil(SIZE.x / BASE_SPACING)) + 1
	var cz := int(ceil(SIZE.y / BASE_SPACING)) + 1
	var coarse := PackedFloat32Array()
	coarse.resize(cx * cz)
	for j in cz:
		for i in cx:
			var p := Vector2(i * BASE_SPACING, j * BASE_SPACING)
			var total := 0.0
			var weight := 0.0
			for channel in channels:
				var near := _nearest(channel, p)
				var w := 1.0 / pow(maxf(near.x - channel.half_width, 0.0) + 1.0, 3.0)
				total += w * (near.y + WALL)
				weight += w
			for pond in ponds:
				var w := 1.0 / pow(maxf(p.distance_to(pond.center) - pond.radius, 0.0) + 1.0, 3.0)
				total += w * (pond.bed + WALL)
				weight += w
			coarse[j * cx + i] = minf(total / weight, CAP)
	var heights := PackedFloat32Array()
	heights.resize(nx * nz)
	for j in nz:
		var fz := j * spacing / BASE_SPACING
		var z0 := mini(int(fz), cz - 2)
		var tz := fz - z0
		for i in nx:
			var fx := i * spacing / BASE_SPACING
			var x0 := mini(int(fx), cx - 2)
			var tx := fx - x0
			var top := lerpf(coarse[z0 * cx + x0], coarse[z0 * cx + x0 + 1], tx)
			var bottom := lerpf(coarse[(z0 + 1) * cx + x0], coarse[(z0 + 1) * cx + x0 + 1], tx)
			heights[j * nx + i] = lerpf(top, bottom, tz)
	return heights


# [1 2 1] / 4 along x, then along z.
func _soften(heights: PackedFloat32Array, nx: int, nz: int) -> PackedFloat32Array:
	var along_x := PackedFloat32Array()
	along_x.resize(nx * nz)
	for j in nz:
		var row := j * nx
		for i in nx:
			var left := heights[row + maxi(i - 1, 0)]
			var right := heights[row + mini(i + 1, nx - 1)]
			along_x[row + i] = (left + 2.0 * heights[row + i] + right) * 0.25
	var out := PackedFloat32Array()
	out.resize(nx * nz)
	for j in nz:
		var up := maxi(j - 1, 0) * nx
		var down := mini(j + 1, nz - 1) * nx
		for i in nx:
			out[j * nx + i] = (along_x[up + i] + 2.0 * along_x[j * nx + i] + along_x[down + i]) * 0.25
	return out


# How far a point is from a channel's line, and the bed where it is nearest.
func _nearest(channel: Channel, p: Vector2) -> Vector2:
	var best := Vector2(1e9, 0.0)
	for i in range(1, channel.points.size()):
		var a := channel.points[i - 1]
		var b := channel.points[i]
		var from := Vector2(a.x, a.z)
		var ab := Vector2(b.x, b.z) - from
		var t := clampf((p - from).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var d := p.distance_to(from + ab * t)
		if d < best.x:
			best = Vector2(d, lerpf(a.y, b.y, t))
	return best


func _carve_segment(heights: PackedFloat32Array, nx: int, nz: int, spacing: float, channel: Channel, a: Vector3, b: Vector3) -> void:
	var reach := channel.half_width + maxf(CAP - minf(a.y, b.y), 0.0) / channel.bank
	var i0 := maxi(int(floor((minf(a.x, b.x) - reach) / spacing)), 0)
	var i1 := mini(int(ceil((maxf(a.x, b.x) + reach) / spacing)), nx - 1)
	var j0 := maxi(int(floor((minf(a.z, b.z) - reach) / spacing)), 0)
	var j1 := mini(int(ceil((maxf(a.z, b.z) + reach) / spacing)), nz - 1)
	var from := Vector2(a.x, a.z)
	var ab := Vector2(b.x, b.z) - from
	var len2 := maxf(ab.length_squared(), 1e-9)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := Vector2(i * spacing, j * spacing)
			var t := clampf((p - from).dot(ab) / len2, 0.0, 1.0)
			var d := p.distance_to(from + ab * t)
			var h := lerpf(a.y, b.y, t) + channel.bank * maxf(d - channel.half_width, 0.0)
			var at := j * nx + i
			if h < heights[at]:
				heights[at] = h


func _carve_pond(heights: PackedFloat32Array, nx: int, nz: int, spacing: float, pond: Pond) -> void:
	var reach := pond.radius + maxf(CAP - pond.bed, 0.0) / pond.bank
	var i0 := maxi(int(floor((pond.center.x - reach) / spacing)), 0)
	var i1 := mini(int(ceil((pond.center.x + reach) / spacing)), nx - 1)
	var j0 := maxi(int(floor((pond.center.y - reach) / spacing)), 0)
	var j1 := mini(int(ceil((pond.center.y + reach) / spacing)), nz - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var r := Vector2(i * spacing, j * spacing).distance_to(pond.center)
			var bed := pond.bed
			if pond.pit_radius > 0.0 and r < pond.pit_radius * 1.6:
				# A pit with a smooth edge.
				bed -= pond.pit_depth * (1.0 - smoothstep(pond.pit_radius * 0.5, pond.pit_radius * 1.6, r))
			var h := bed + pond.bank * maxf(r - pond.radius, 0.0)
			var at := j * nx + i
			if h < heights[at]:
				heights[at] = h


## The water to start with, as shapes in map coordinates: dictionaries of shape (a
## [enum WaterSim.Shape]), transform (a map position, turned about y) and extents.
func water_shapes() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for channel in channels:
		if channel.name == "Shelf":
			# From the back of the shelf to its lip.
			list.append({ "shape": WaterSim.Shape.BOX, "transform": Transform3D(Basis(), Vector3(120, shelf_bed + 0.7, 98)),
					"extents": Vector3(channel.half_width, 0.7, 24.0) })
			continue
		var pts := channel.points
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			var length := Vector2(b.x - a.x, b.z - a.z).length()
			var pieces := maxi(int(ceil(length / 5.0)), 1)
			for k in pieces:
				var p0 := a.lerp(b, float(k) / pieces)
				var p1 := a.lerp(b, float(k + 1) / pieces)
				var mid := (p0 + p1) * 0.5
				var dir := Vector2(p1.x - p0.x, p1.z - p0.z)
				if dir.length() < 0.05:
					continue
				# Water a depth over the bed, a little over the width of the channel's bed.
				var basis := Basis(Vector3.UP, atan2(-dir.y, dir.x))
				list.append({ "shape": WaterSim.Shape.BOX, "transform": Transform3D(basis, Vector3(mid.x, mid.y + channel.depth * 0.5, mid.z)),
						"extents": Vector3(dir.length() * 0.5 + 0.1, channel.depth * 0.5, channel.half_width) })
	for pond in ponds:
		list.append({ "shape": WaterSim.Shape.CYLINDER, "transform": Transform3D(Basis(), Vector3(pond.center.x, pond.bed + pond.depth * 0.5, pond.center.y)),
				"extents": Vector3(pond.radius + 0.5, pond.depth * 0.5, 0) })
		if pond.pit_radius > 0.0:
			list.append({ "shape": WaterSim.Shape.CYLINDER, "transform": Transform3D(Basis(), Vector3(pond.center.x, pond.bed - pond.pit_depth * 0.5, pond.center.y)),
					"extents": Vector3(pond.pit_radius * 1.6, pond.pit_depth * 0.5 + 0.05, 0) })
	return list
