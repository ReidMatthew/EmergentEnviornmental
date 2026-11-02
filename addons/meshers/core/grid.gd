@tool
class_name MesherGrid
extends RefCounted
## A block of scalar samples to polygonise. This is the only input a mesher sees, so the
## core knows nothing about chunks, storage formats or terrain.
##
## Samples are laid out x fastest, then y, then z:
## [code]index = x + size.x * (y + size.y * z)[/code].

## Number of samples along each axis.
var size := Vector3i.ZERO
## One value per sample. Values below [member iso] are inside (solid). Leave empty and
## fill [member bytes] instead to pass samples as bytes.
var values := PackedFloat32Array()
## Samples as one byte each, used when [member values] is empty:
## [code]value = (byte - byte_center) * byte_scale[/code]. GPU meshers upload these as they
## are and decode in the shader, which saves a decode pass on the CPU and 3/4 of the upload.
## (Subtracting first keeps float32 decoding exact near the surface, where a scale-then-
## offset form would cancel catastrophically.)
var bytes := PackedByteArray()
var byte_center := 0.0
var byte_scale := 1.0
## Optional per-sample material id, same layout as [member values]. Leave empty for none.
var materials := PackedByteArray()
var iso := 0.0

## Cells to polygonise, by the index of their lowest sample. [member cell_end] is exclusive;
## a negative component means "up to the last full cell". Restricting the range lets callers
## pass padding samples that are only read for normals and closing seams.
var cell_begin := Vector3i.ZERO
var cell_end := Vector3i(-1, -1, -1)

## When above 0, meshers add short skirts this deep (output units) along the boundary of
## the cell range, covering the pixel-sized gaps rounding can leave between chunks (see
## [MesherSkirts]).
var skirt_depth := 0.0

## Faces of the cell range next to a chunk of twice the resolution, each with that chunk's
## samples on the face. Meshers fill those faces with Transvoxel transition cells instead of
## leaving cracks there (see [MesherTransition]). Empty for none.
var transitions: Array[MesherTransition] = []
## How far transition cells reach into the cell range, as a fraction of a cell: the last
## layer of cells next to a transition face is squeezed into the rest of its width.
var transition_width := 0.5

## Output position of sample (0, 0, 0), and the distance between neighbouring samples.
var origin := Vector3.ZERO
var spacing := 1.0


func get_cell_end() -> Vector3i:
	var last := size - Vector3i.ONE
	return Vector3i(
		last.x if cell_end.x < 0 else cell_end.x,
		last.y if cell_end.y < 0 else cell_end.y,
		last.z if cell_end.z < 0 else cell_end.z)


func index_of(x: int, y: int, z: int) -> int:
	return x + size.x * (y + size.y * z)


func get_sample_count() -> int:
	return size.x * size.y * size.z


## True when samples come from [member bytes].
func uses_bytes() -> bool:
	return values.is_empty() and not bytes.is_empty()


## Samples as floats, decoding [member bytes] if that's what the grid holds.
func get_values() -> PackedFloat32Array:
	if not uses_bytes():
		return values
	var lut := PackedFloat32Array()
	lut.resize(256)
	for i in 256:
		lut[i] = (i - byte_center) * byte_scale
	var out := PackedFloat32Array()
	out.resize(bytes.size())
	for i in bytes.size():
		out[i] = lut[bytes[i]]
	return out


## Samples ready for a GPU buffer: float bits, or the bytes padded to whole uints.
func get_gpu_samples() -> PackedByteArray:
	if not uses_bytes():
		return values.to_byte_array()
	var padded := bytes.duplicate()
	padded.resize(ceili(bytes.size() / 4.0) * 4)
	return padded


## Faces with transition cells, as a bit mask (see [method MesherSkirts.face_bit]).
func get_transition_faces() -> int:
	var faces := 0
	for t in transitions:
		faces |= 1 << t.face
	return faces


## [method get_transition_faces] and [member transition_width] (as float bits), as the GPU
## shaders take them.
func get_gpu_transition_params() -> PackedInt32Array:
	var width := PackedFloat32Array([transition_width]).to_byte_array().to_int32_array()[0]
	return PackedInt32Array([get_transition_faces(), width])


## Trilinear sample at output position [param position], or NAN outside the samples.
func sample(position: Vector3) -> float:
	var s := (position - origin) / spacing
	var base := Vector3i(s.floor())
	if base.x < 0 or base.y < 0 or base.z < 0 or base.x >= size.x - 1 or base.y >= size.y - 1 \
			or base.z >= size.z - 1:
		return NAN
	var f := s - Vector3(base)
	var sx := size.x
	var sxy := sx * size.y
	var i := base.x + sx * base.y + sxy * base.z
	var c := PackedFloat32Array()
	c.resize(8)
	var offsets := [0, 1, sx, sx + 1, sxy, sxy + 1, sxy + sx, sxy + sx + 1]
	var from_bytes := uses_bytes()
	for k in 8:
		c[k] = bytes[i + offsets[k]] if from_bytes else values[i + offsets[k]]
	var value := lerpf(lerpf(lerpf(c[0], c[1], f.x), lerpf(c[2], c[3], f.x), f.y),
			lerpf(lerpf(c[4], c[5], f.x), lerpf(c[6], c[7], f.x), f.y), f.z)
	return (value - byte_center) * byte_scale if from_bytes else value


## Allocates [member values] for [param sample_count] samples and fills them from
## [param fn], which takes a sample position (in output space) and returns its value.
## Handy for tests and one-off shapes.
static func from_function(sample_count: Vector3i, sample_spacing: float, fn: Callable) -> MesherGrid:
	var grid := MesherGrid.new()
	grid.size = sample_count
	grid.spacing = sample_spacing
	grid.values.resize(sample_count.x * sample_count.y * sample_count.z)
	var i := 0
	for z in sample_count.z:
		for y in sample_count.y:
			for x in sample_count.x:
				grid.values[i] = fn.call(Vector3(x, y, z) * sample_spacing)
				i += 1
	return grid
