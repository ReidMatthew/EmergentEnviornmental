@tool
class_name Qef
extends RefCounted
## Small 3x3 linear algebra for the dual meshers: the quadratic error function (QEF) of dual
## contouring, eigen decomposition, plane fitting. Matrices are row-major
## [PackedFloat64Array]s of 9 (GDScript floats are doubles; [Vector3] is not).


## The point nearest (in least squares) to the planes through [param points] with
## [param normals] (unit length): minimises [code]sum((normals[i] . (x - points[i]))^2)[/code].
## Directions the planes don't pin down (eigenvalues of A^T A below
## [param threshold] times the largest) are left at the points' average, which keeps
## vertices on flat and gently curved parts from sliding along the surface.
static func solve(normals: PackedVector3Array, points: PackedVector3Array, threshold: float) -> Vector3:
	if points.is_empty():
		return Vector3.ZERO
	var mass := Vector3.ZERO
	for p in points:
		mass += p
	mass /= points.size()
	var ata := PackedFloat64Array()
	ata.resize(9)
	var atb := PackedFloat64Array()
	atb.resize(3)
	for k in normals.size():
		var n := normals[k]
		add_plane(ata, atb, n, n.dot(points[k] - mass), 1.0)
	return mass + pseudo_solve(ata, atb, threshold)


## Adds the row [code]weight * (n . x = d)[/code] to the normal equations [param ata],
## [param atb].
static func add_plane(ata: PackedFloat64Array, atb: PackedFloat64Array, n: Vector3, d: float, weight: float) -> void:
	for r in 3:
		atb[r] += weight * n[r] * d
		for c in 3:
			ata[r * 3 + c] += weight * n[r] * n[c]


## x minimising |A x - b|^2 from the normal equations, ignoring directions whose eigenvalue
## is below [param threshold] times the largest (a truncated pseudo-inverse).
static func pseudo_solve(ata: PackedFloat64Array, atb: PackedFloat64Array, threshold: float) -> Vector3:
	var eigen := symmetric_eigen(ata)
	var values: PackedFloat64Array = eigen[0]
	var vectors: Array = eigen[1]
	var largest := maxf(absf(values[0]), maxf(absf(values[1]), absf(values[2])))
	if largest < 1e-12:
		return Vector3.ZERO
	var x := Vector3.ZERO
	for k in 3:
		if values[k] < threshold * largest:
			continue
		var v: Vector3 = vectors[k]
		x += v * ((v.x * atb[0] + v.y * atb[1] + v.z * atb[2]) / values[k])
	return x


## Solves [param m] x = [param b] (Cramer's rule). Returns [param fallback] when [param m]
## is singular.
static func solve_3x3(m: PackedFloat64Array, b: PackedFloat64Array, fallback: Vector3) -> Vector3:
	var det := m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) \
			+ m[2] * (m[3] * m[7] - m[4] * m[6])
	if absf(det) < 1e-14:
		return fallback
	var dx := b[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (b[1] * m[8] - m[5] * b[2]) \
			+ m[2] * (b[1] * m[7] - m[4] * b[2])
	var dy := m[0] * (b[1] * m[8] - m[5] * b[2]) - b[0] * (m[3] * m[8] - m[5] * m[6]) \
			+ m[2] * (m[3] * b[2] - b[1] * m[6])
	var dz := m[0] * (m[4] * b[2] - b[1] * m[7]) - m[1] * (m[3] * b[2] - b[1] * m[6]) \
			+ b[0] * (m[3] * m[7] - m[4] * m[6])
	return Vector3(dx / det, dy / det, dz / det)


## Eigenvalues and unit eigenvectors of symmetric [param m] (Jacobi rotations), as
## [code][PackedFloat64Array values, [Vector3, Vector3, Vector3]][/code], unsorted.
static func symmetric_eigen(m: PackedFloat64Array) -> Array:
	var a := m.duplicate()
	var v := PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])
	for sweep in 12:
		if a[1] * a[1] + a[2] * a[2] + a[5] * a[5] < 1e-24:
			break
		for pair in 3:
			var p := 0 if pair < 2 else 1
			var q := 1 if pair == 0 else 2
			var apq := a[p * 3 + q]
			if absf(apq) < 1e-30:
				continue
			var theta := (a[q * 4] - a[p * 4]) / (2.0 * apq)
			var t := 1.0 / (absf(theta) + sqrt(theta * theta + 1.0))
			if theta < 0.0:
				t = -t
			var c := 1.0 / sqrt(t * t + 1.0)
			var s := t * c
			for k in 3:  # columns: A J
				var akp := a[k * 3 + p]
				var akq := a[k * 3 + q]
				a[k * 3 + p] = c * akp - s * akq
				a[k * 3 + q] = s * akp + c * akq
			for k in 3:  # rows: J^T (A J)
				var apk := a[p * 3 + k]
				var aqk := a[q * 3 + k]
				a[p * 3 + k] = c * apk - s * aqk
				a[q * 3 + k] = s * apk + c * aqk
			for k in 3:  # V J
				var vkp := v[k * 3 + p]
				var vkq := v[k * 3 + q]
				v[k * 3 + p] = c * vkp - s * vkq
				v[k * 3 + q] = s * vkp + c * vkq
	var vectors := []
	for j in 3:
		vectors.append(Vector3(v[j], v[3 + j], v[6 + j]).normalized())
	return [PackedFloat64Array([a[0], a[4], a[8]]), vectors]


## Best-fit plane through [param points] (principal component analysis), as
## [code][centroid, unit normal][/code]. The normal is the direction the points spread
## least along; its sign is arbitrary.
static func fit_plane(points: PackedVector3Array) -> Array:
	var centroid := Vector3.ZERO
	for p in points:
		centroid += p
	centroid /= maxi(points.size(), 1)
	var cov := PackedFloat64Array()
	cov.resize(9)
	for p in points:
		var d := p - centroid
		for r in 3:
			for c in 3:
				cov[r * 3 + c] += d[r] * d[c]
	var eigen := symmetric_eigen(cov)
	var values: PackedFloat64Array = eigen[0]
	var smallest := 0
	for k in range(1, 3):
		if values[k] < values[smallest]:
			smallest = k
	return [centroid, eigen[1][smallest]]
