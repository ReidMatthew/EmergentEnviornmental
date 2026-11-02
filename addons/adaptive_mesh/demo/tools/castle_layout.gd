@tool
extends RefCounted
## The layout of toon_shading's demo castle, copied here so this demo doesn't need that
## add-on: an octagonal curtain wall with round towers, a gatehouse with a drawbridge, a
## keep with a spire and corner turrets, a great hall, a chapel and banners. The same
## numbers as the original; instead of drawing anything, [method build] lists its
## primitives for build_castle_demo.gd to merge into one closed mesh.
##
## Changed from the original: unit primitives have fewer segments where it doesn't show,
## and the curtain wall's corbels sit a little into the wall (see [method _wall]).
##
## The origin is the base of the castle at the centre of the courtyard; the gatehouse faces
## +Z. It's about 92 units across and 68 high.

## Tags (one material each in the merged mesh).
const STONE := 0
const ROOF := 1
const WINDOW := 2
const BANNER := 3
const WOOD := 4

## Unit primitives (each 1 x 1 x 1, centred), by name.
const UNITS := ["box", "cylinder", "cone", "pyramid", "prism", "sphere"]

var wall_radius := 40.0
var wall_height := 16.0
var wall_sides := 8

const WALL_THICK := 3.0

var _parts: Array = []


## Every primitive: [unit name (see [constant UNITS]), tag, transform].
func build() -> Array:
	_parts.clear()
	_build()
	return _parts


## The unit mesh for [param unit] (see [constant UNITS]).
static func unit_mesh(unit: String) -> Mesh:
	match unit:
		"box":
			return BoxMesh.new()
		"cylinder", "cone", "pyramid":
			var m := CylinderMesh.new()
			m.top_radius = 0.5 if unit == "cylinder" else 0.0
			m.bottom_radius = 0.5
			m.height = 1.0
			m.radial_segments = 4 if unit == "pyramid" else 20
			m.rings = 1
			return m
		"prism":
			var m := PrismMesh.new()
			m.left_to_right = 0.5
			m.size = Vector3.ONE
			return m
		"sphere":
			var m := SphereMesh.new()
			m.radius = 0.5
			m.height = 1.0
			m.radial_segments = 16
			m.rings = 8
			return m
	return null


func _build() -> void:
	_build_curtain_wall()
	_build_gatehouse()
	_build_keep(Vector3(-4, 0, -8))
	_build_great_hall(Vector3(17, 0, -4))
	_build_chapel(Vector3(-22, 0, 10))
	_build_courtyard_details()


# --- Curtain wall -----------------------------------------------------------

func _build_curtain_wall() -> void:
	# The gate sits in the middle of the side facing +Z, so corners are offset
	# half a side from +Z.
	var phase := PI * 0.5 + PI / wall_sides
	for k in wall_sides:
		var a0 := phase + TAU * k / wall_sides
		var a1 := phase + TAU * (k + 1) / wall_sides
		var p0 := Vector3(cos(a0), 0, sin(a0)) * wall_radius
		var p1 := Vector3(cos(a1), 0, sin(a1)) * wall_radius
		_wall(p0, p1, wall_height, k == wall_sides - 1)
		# The two corners either side of the gate are left to the gatehouse's
		# own towers.
		if k != 0 and k != wall_sides - 1:
			_tower(p0, 5.5, 25.0, 13.0, k % 2 == 0)


## One straight run of curtain wall from p0 to p1 with battered base, arrow
## slits, a corbelled parapet and crenellations on both faces. `has_gate`
## leaves room for the gatehouse in the middle.
func _wall(p0: Vector3, p1: Vector3, h: float, has_gate: bool) -> void:
	var along := (p1 - p0).normalized()
	var outward := Vector3((p0 + p1).x, 0, (p0 + p1).z).normalized()
	var length := p0.distance_to(p1)
	# Right-handed (no mirroring): X along the wall, Z outward.
	var basis := Basis(Vector3.UP.cross(outward), Vector3.UP, outward)

	var runs: Array = [[0.0, length]]
	if has_gate:
		runs = [[0.0, length * 0.5 - 7.5], [length * 0.5 + 7.5, length]]
	for run in runs:
		var u0: float = run[0]
		var u1: float = run[1]
		var c := p0 + along * (u0 + u1) * 0.5
		var run_len := u1 - u0
		# Wall, battered plinth and string course under the parapet.
		_oriented_box(STONE, c + Vector3(0, h * 0.5, 0), basis, Vector3(run_len, h, WALL_THICK))
		_oriented_box(STONE, c + Vector3(0, 1.5, 0), basis, Vector3(run_len, 3.0, WALL_THICK + 1.4))
		_oriented_box(STONE, c + outward * 0.35 + Vector3(0, h - 1.2, 0), basis, Vector3(run_len, 0.6, WALL_THICK + 0.7))
		# Corbels carrying the parapet out over the wall face, set a little into it (the
		# original's sit exactly on it, and one's corner then touches the next wall's face
		# along an edge, which the union leaves not quite closed).
		var corbels := int(run_len / 2.2)
		for i in corbels:
			var p := p0 + along * (u0 + (i + 0.5) * run_len / corbels)
			_oriented_box(STONE, p + outward * (WALL_THICK * 0.5 + 0.3) + Vector3(0, h - 2.0, 0),
					basis, Vector3(0.7, 1.2, 0.7))
		# Parapet (outer) with merlons, low inner wall on the wall-walk.
		_oriented_box(STONE, c + outward * 1.6 + Vector3(0, h + 0.5, 0), basis, Vector3(run_len, 1.0, 0.8))
		_oriented_box(STONE, c - outward * 1.4 + Vector3(0, h + 0.3, 0), basis, Vector3(run_len, 0.6, 0.5))
		var merlons := int(run_len / 3.0)
		for m in merlons:
			var p := p0 + along * (u0 + (m + 0.5) * run_len / merlons)
			_oriented_box(STONE, p + outward * 1.6 + Vector3(0, h + 1.9, 0), basis, Vector3(1.6, 1.8, 0.8))
		# Arrow slits along the outer face.
		var slits := int(run_len / 7.0)
		for i in slits:
			var p := p0 + along * (u0 + (i + 0.5) * run_len / slits)
			_oriented_box(WINDOW, p + outward * (WALL_THICK * 0.5 + 0.02) + Vector3(0, h * 0.55, 0),
					basis, Vector3(0.5, 2.6, 0.2))


## Round tower: battered base, string courses, slit windows on all sides, a
## corbelled crenellated crown and a conical roof with a finial (and a flag).
func _tower(base: Vector3, radius: float, height: float, roof_h: float, flag := false) -> void:
	_cylinder(STONE, base + Vector3(0, height * 0.5, 0), radius, height)
	_cone(STONE, base + Vector3(0, 2.5, 0), radius + 1.2, 5.0) # batter
	for y in range(9, int(height) - 3, 8):
		_cylinder(STONE, base + Vector3(0, y, 0), radius + 0.25, 0.5)
	var floors := int((height - 6.0) / 8.0)
	for f in floors:
		for side in 4:
			var a := TAU * side / 4.0 + f * 0.6
			var basis := Basis(Vector3.UP, -a + PI * 0.5)
			_oriented_box(WINDOW, base + Vector3(cos(a), 0, sin(a)) * (radius - 0.05)
					+ Vector3(0, 5.5 + f * 8.0, 0), basis, Vector3(0.7, 2.4, 0.3))

	# Crown: corbels, overhanging parapet, merlons.
	var crown := base + Vector3(0, height, 0)
	_ring_of_boxes(STONE, crown + Vector3(0, -0.8, 0), radius + 0.35, int(radius * 2.4), Vector3(0.6, 1.2, 0.8))
	_cylinder(STONE, crown + Vector3(0, 0.6, 0), radius + 0.8, 1.6)
	_ring_of_boxes(STONE, crown + Vector3(0, 2.1, 0), radius + 0.5, int(radius * 1.6), Vector3(1.2, 1.4, 0.7),
			PI / int(radius * 1.6))

	# Roof sits inside the merlons, with a ball and spike finial.
	var roof_base := crown + Vector3(0, 1.4, 0)
	_cone(ROOF, roof_base + Vector3(0, roof_h * 0.5, 0), radius + 0.3, roof_h)
	_sphere(STONE, roof_base + Vector3(0, roof_h + 0.3, 0), Vector3.ONE * 0.9)
	_cylinder(STONE, roof_base + Vector3(0, roof_h + 1.6, 0), 0.12, 2.6)
	if flag:
		_flag(roof_base + Vector3(0, roof_h + 0.6, 0), 4.5)


## A flagpole with a pennant streaming in the wind (+X).
func _flag(base: Vector3, pole_h: float) -> void:
	_cylinder(STONE, base + Vector3(0, pole_h * 0.5, 0), 0.1, pole_h)
	var top := base + Vector3(0, pole_h - 0.9, 0)
	_oriented_box(BANNER, top + Vector3(1.8, 0, 0), Basis(Vector3.BACK, -0.08), Vector3(3.6, 1.6, 0.1))
	_oriented_box(BANNER, top + Vector3(4.1, -0.25, 0), Basis(Vector3.BACK, -0.15), Vector3(1.2, 0.9, 0.1))


# --- Gatehouse --------------------------------------------------------------

func _build_gatehouse() -> void:
	var g := Vector3(0, 0, wall_radius * cos(PI / wall_sides))
	_box(STONE, g + Vector3(0, 11.0, 0), Vector3(13, 22, 8))
	_box(STONE, g + Vector3(0, 1.5, 0.3), Vector3(14.4, 3, 8.6))
	_tower(g + Vector3(-8, 0, 2), 4.5, 26.0, 11.0, true)
	_tower(g + Vector3(8, 0, 2), 4.5, 26.0, 11.0, true)

	var face := g.z + 4.05
	# Arched gateway: dark opening, voussoirs, portcullis bars.
	_box(WINDOW, Vector3(0, 3.5, face), Vector3(5, 7, 0.2))
	_arch(WINDOW, Vector3(0, 7.0, face), 1.25, 2.5, 0.2, 0.0, PI, 8)
	_arch(STONE, Vector3(0, 7.0, face + 0.1), 2.9, 0.8, 0.5, 0.0, PI, 12)
	for x in [-1.8, -0.6, 0.6, 1.8]:
		_box(WOOD, Vector3(x, 4.2, face + 0.15), Vector3(0.25, 5.6, 0.2))
	for y in [2.0, 4.5]:
		_box(WOOD, Vector3(0, y, face + 0.15), Vector3(4.6, 0.25, 0.2))

	# Drawbridge lowered over the ditch, with its chains.
	var bridge := Vector3(0, 0.3, face + 5.2)
	_box(WOOD, bridge, Vector3(5.4, 0.5, 10))
	for x in [-2.5, 2.5]:
		var a := Vector3(x, 0.6, face + 10.0)
		var b := Vector3(x, 9.5, face + 0.2)
		_oriented_box(WOOD, (a + b) * 0.5, Basis.looking_at((b - a).normalized(), Vector3.UP),
				Vector3(0.15, 0.15, a.distance_to(b)))

	# Machicolation gallery over the gate, windows, crenellations.
	_box(STONE, Vector3(0, 17.5, face + 0.8), Vector3(8, 3, 1.6))
	for i in 6:
		_box(STONE, Vector3(-3.5 + i * 1.4, 15.6, face + 1.0), Vector3(0.5, 1.0, 1.0))
	for x in [-2.8, 0.0, 2.8]:
		_box(WINDOW, Vector3(x, 12.0, face + 0.02), Vector3(0.9, 2.6, 0.2))
	for i in 5:
		_box(STONE, Vector3(-5.2 + i * 2.6, 23.0, g.z + 3.6), Vector3(1.5, 2.0, 0.8))
		_box(STONE, Vector3(-5.2 + i * 2.6, 23.0, g.z - 3.6), Vector3(1.5, 2.0, 0.8))
	# Banners hanging either side of the gate.
	for x in [-4.6, 4.6]:
		_box(BANNER, Vector3(x, 10.0, face + 0.1), Vector3(1.6, 6.0, 0.1))
		_pyramid(BANNER, Vector3(x, 6.6, face + 0.1), 1.1, 0.8, 0.0)


# --- Keep -------------------------------------------------------------------

func _build_keep(k: Vector3) -> void:
	var size := Vector3(26, 38, 20)
	var top := size.y
	# Block, battered base, corner buttresses and string courses.
	_box(STONE, k + Vector3(0, top * 0.5, 0), size)
	_box(STONE, k + Vector3(0, 2.0, 0), size + Vector3(2.4, 4.0 - size.y, 2.4))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var corner := k + Vector3(sx * size.x * 0.5, 0, sz * size.z * 0.5)
			_box(STONE, corner + Vector3(0, top * 0.45, 0), Vector3(2.2, top * 0.9, 2.2))
			# Bartizans: little turrets corbelled out from the top corners.
			var b := corner + Vector3(sx * 0.6, top - 3.0, sz * 0.6)
			_cone(STONE, b + Vector3(0, -1.6, 0), 1.9, 3.2)
			_cylinder(STONE, b + Vector3(0, 2.0, 0), 1.9, 4.0)
			_cone(ROOF, b + Vector3(0, 6.5, 0), 2.3, 5.0)
	for y in [12.0, 24.0]:
		_box(STONE, k + Vector3(0, y, 0), Vector3(size.x + 0.5, 0.6, size.z + 0.5))

	# Windows on all four faces: tall arched lancets on the upper floors.
	for row in 3:
		var y := 7.0 + row * 11.0
		var tall := 3.4 if row == 0 else 4.6
		for col in 4:
			var x := -8.4 + col * 5.6
			for sz in [-1.0, 1.0]:
				var p := k + Vector3(x, y, sz * (size.z * 0.5 + 0.05))
				_box(WINDOW, p, Vector3(1.4, tall, 0.2))
				_pyramid(WINDOW, p + Vector3(0, tall * 0.5 + 0.4, 0), 1.0, 0.8)
		for col in 3:
			var z := -5.5 + col * 5.5
			for sx in [-1.0, 1.0]:
				var p := k + Vector3(sx * (size.x * 0.5 + 0.05), y, z)
				_box(WINDOW, p, Vector3(0.2, tall, 1.4))
				_pyramid(WINDOW, p + Vector3(0, tall * 0.5 + 0.4, 0), 1.0, 0.8)

	# Corbelled parapet and merlons on all four sides.
	_box(STONE, k + Vector3(0, top + 0.5, 0), Vector3(size.x + 1.2, 1.0, size.z + 1.2))
	for i in 8:
		var x := -size.x * 0.5 + 1.6 + i * (size.x - 3.2) / 7.0
		for sz in [-1.0, 1.0]:
			_box(STONE, k + Vector3(x, top - 0.6, sz * (size.z * 0.5 + 0.35)), Vector3(0.6, 1.2, 0.7))
			_box(STONE, k + Vector3(x, top + 2.0, sz * (size.z * 0.5 + 0.3)), Vector3(1.6, 2.0, 0.6))
	for i in 6:
		var z := -size.z * 0.5 + 1.6 + i * (size.z - 3.2) / 5.0
		for sx in [-1.0, 1.0]:
			_box(STONE, k + Vector3(sx * (size.x * 0.5 + 0.35), top - 0.6, z), Vector3(0.7, 1.2, 0.6))
			_box(STONE, k + Vector3(sx * (size.x * 0.5 + 0.3), top + 2.0, z), Vector3(0.6, 2.0, 1.6))

	# Central spire tower rising out of the roof.
	_tower(k + Vector3(3, top - 2.0, -1), 5.0, 22.0, 20.0, true)


# --- Courtyard buildings --------------------------------------------------------

## Great hall: long gabled building with buttresses, tall windows, chimneys.
func _build_great_hall(h: Vector3) -> void:
	var size := Vector3(12, 12, 26) # long axis along Z
	_box(STONE, h + Vector3(0, size.y * 0.5, 0), size)
	_gable(ROOF, h + Vector3(0, size.y + 4.0, 0), Basis.IDENTITY, Vector3(size.x + 1.4, 8.0, size.z + 1.0))
	# Gable ends are stone, stepped (crow-stepped) up the roof line.
	for sz in [-1.0, 1.0]:
		_gable(STONE, h + Vector3(0, size.y + 4.0, sz * (size.z * 0.5 + 0.2)), Basis.IDENTITY,
				Vector3(size.x, 8.0, 0.8))
		for step in 4:
			var x := (size.x * 0.5) * (1.0 - step / 4.0) - 0.5
			for sx in [-1.0, 1.0]:
				_box(STONE, h + Vector3(sx * x, size.y + 0.8 + step * 2.0, sz * (size.z * 0.5 + 0.2)),
						Vector3(1.2, 1.6, 1.0))
	for i in 5:
		var z := -size.z * 0.5 + 2.6 + i * (size.z - 5.2) / 4.0
		for sx in [-1.0, 1.0]:
			_box(STONE, h + Vector3(sx * (size.x * 0.5 + 0.5), size.y * 0.45, z), Vector3(1.0, size.y * 0.9, 1.4))
		if i < 4:
			var zw := z + (size.z - 5.2) / 8.0
			for sx in [-1.0, 1.0]:
				var p := h + Vector3(sx * (size.x * 0.5 + 0.05), 6.0, zw)
				_box(WINDOW, p, Vector3(0.2, 5.5, 1.5))
				_pyramid(WINDOW, p + Vector3(0, 3.2, 0), 1.0, 0.9)
	for z in [-7.0, 6.0]:
		_box(STONE, h + Vector3(3.0, size.y + 7.0, z), Vector3(1.6, 6.0, 1.6))
		_box(STONE, h + Vector3(3.0, size.y + 10.2, z), Vector3(2.0, 0.5, 2.0))


## Chapel: small gabled building with an apse and a bell turret.
func _build_chapel(c: Vector3) -> void:
	var size := Vector3(9, 9, 16)
	var basis := Basis(Vector3.UP, 0.5)
	_oriented_box(STONE, c + Vector3(0, size.y * 0.5, 0), basis, size)
	_gable(ROOF, c + Vector3(0, size.y + 3.0, 0), basis, Vector3(size.x + 1.0, 6.0, size.z + 0.8))
	var back := c + basis * Vector3(0, 0, -size.z * 0.5)
	_cylinder(STONE, back + Vector3(0, size.y * 0.4, 0), 3.6, size.y * 0.8)
	_cone(ROOF, back + Vector3(0, size.y * 0.8 + 2.0, 0), 4.0, 4.0)
	var front := c + basis * Vector3(0, 0, size.z * 0.5 - 1.5)
	_box(STONE, front + Vector3(0, size.y + 6.5, 0), Vector3(2.4, 4.0, 2.4))
	_pyramid(ROOF, front + Vector3(0, size.y + 11.0, 0), 3.0, 5.0, 0.5)
	_box(WINDOW, front + Vector3(0, size.y + 6.8, 0), Vector3(2.5, 1.8, 0.8))
	for i in 3:
		var p := c + basis * Vector3(size.x * 0.5 + 0.05, 5.0, -4.0 + i * 4.0)
		_oriented_box(WINDOW, p, basis, Vector3(0.2, 3.6, 1.0))
	var rose := c + basis * Vector3(0, 9.0, size.z * 0.5 + 0.05)
	_oriented_box(WINDOW, rose, basis, Vector3(2.4, 2.4, 0.2))


func _build_courtyard_details() -> void:
	# Well with a little roof.
	var w := Vector3(8, 0, 22)
	_cylinder(STONE, w + Vector3(0, 0.6, 0), 1.6, 1.2)
	for x in [-1.3, 1.3]:
		_box(WOOD, w + Vector3(x, 2.0, 0), Vector3(0.25, 3.0, 0.25))
	_gable(ROOF, w + Vector3(0, 4.0, 0), Basis(Vector3.UP, PI * 0.5), Vector3(3.6, 1.6, 3.6))
	# Stair up to the wall-walk beside the gatehouse.
	for i in 10:
		_box(STONE, Vector3(10.0 + i * 1.2, 0.8 + i * 1.5, wall_radius * 0.8), Vector3(1.4, 1.6 + i * 3.0, 3.0))


# --- Primitives (as toon_shading's procedural_builder.gd lays them out) -----------

func _add(unit: String, tag: int, xform: Transform3D) -> void:
	_parts.append([unit, tag, xform])


func _box(tag: int, center: Vector3, size: Vector3) -> void:
	_add("box", tag, Transform3D(Basis.from_scale(size), center))


func _oriented_box(tag: int, center: Vector3, basis: Basis, size: Vector3) -> void:
	_add("box", tag, Transform3D(basis * Basis.from_scale(size), center))


func _cylinder(tag: int, center: Vector3, radius: float, height: float) -> void:
	_add("cylinder", tag, Transform3D(Basis.from_scale(Vector3(radius * 2, height, radius * 2)), center))


func _cone(tag: int, center: Vector3, radius: float, height: float) -> void:
	_add("cone", tag, Transform3D(Basis.from_scale(Vector3(radius * 2, height, radius * 2)), center))


## Square pyramid (4-sided cone), e.g. a turret or chimney cap.
func _pyramid(tag: int, center: Vector3, width: float, height: float, yaw := 0.0) -> void:
	var basis := Basis(Vector3.UP, yaw + PI * 0.25) * Basis.from_scale(Vector3(width * 1.414, height, width * 1.414))
	_add("pyramid", tag, Transform3D(basis, center))


## Gable roof: a triangular prism. size.x = span, size.y = height, size.z = ridge length.
func _gable(tag: int, center: Vector3, basis: Basis, size: Vector3) -> void:
	_add("prism", tag, Transform3D(basis * Basis.from_scale(size), center))


func _sphere(tag: int, center: Vector3, size: Vector3) -> void:
	_add("sphere", tag, Transform3D(Basis.from_scale(size), center))


## Boxes laid round an arc in the XY plane centred at `center`.
func _arch(tag: int, center: Vector3, radius: float, thickness: float, depth: float,
		a_from: float, a_to: float, segments: int, basis := Basis.IDENTITY) -> void:
	var step := (a_to - a_from) / segments
	var seg_len := 2.0 * (radius + thickness * 0.5) * sin(step * 0.5) * 1.04
	for s in segments:
		var a := a_from + (s + 0.5) * step
		var pos := center + basis * (Vector3(cos(a), sin(a), 0) * radius)
		var seg_basis := basis * Basis(Vector3.BACK, a + PI * 0.5)
		_add("box", tag, Transform3D(seg_basis * Basis.from_scale(Vector3(seg_len, thickness, depth)), pos))


## Boxes spaced round a circle in the XZ plane, each facing outward.
func _ring_of_boxes(tag: int, center: Vector3, radius: float, count: int, size: Vector3, phase := 0.0) -> void:
	for i in count:
		var a := phase + TAU * i / count
		var basis := Basis(Vector3.UP, -a + PI * 0.5)
		_oriented_box(tag, center + Vector3(cos(a), 0, sin(a)) * radius, basis, size)
