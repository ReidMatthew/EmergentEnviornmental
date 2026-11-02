@tool
@abstract
class_name SolidSource
extends Resource
## Where an [AdaptiveMesh] gets its shape when it bakes: [MeshSource] for a closed
## mesh, [SceneSource] for an imported scene (a .glb or .tscn), repaired and closed if
## needed. Subclass this for other sources.

var _cached: Solid
var _cached_materials: Array[Material] = []


func _init() -> void:
	# A method, not a lambda: a lambda using self would keep this resource alive for good
	# (it holds the resource, and the resource holds it through its own signal).
	changed.connect(_forget)


func _forget() -> void:
	_cached = null


## The closed solid to bake from, built once and reused until a property changes. Don't
## modify it.
func get_solid() -> Solid:
	if _cached == null:
		_cached_materials = []
		_cached = _build()
	return _cached


## Materials by tag for the solid's surfaces (null where the source has none).
func get_materials() -> Array[Material]:
	get_solid()
	return _cached_materials


## A short string that changes whenever the solid would: [AdaptiveMesh] stores it with a
## bake and warns when they no longer match. By default it hashes the stored properties,
## files by their contents (an imported model re-exported counts as a change) and meshes by
## their arrays. Override it if the solid depends on anything else.
func get_fingerprint() -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	hash_object(hashing, self, 0)
	return hashing.finish().hex_encode()


## Adds [param value] to [param hashing]: see [method get_fingerprint].
static func hash_value(hashing: HashingContext, value: Variant, depth: int = 0) -> void:
	if not value is Resource:
		hash_bytes(hashing, var_to_bytes(value))
		return
	var resource: Resource = value
	var path := resource.resource_path
	if not path.is_empty():
		var file := path.get_slice("::", 0)
		hash_bytes(hashing, path.to_utf8_buffer())
		hash_bytes(hashing, _file_md5(file).to_utf8_buffer())
		if FileAccess.file_exists(file + ".import"):
			hash_bytes(hashing, _file_md5(file + ".import").to_utf8_buffer())
		return
	var mesh := resource as Mesh
	if mesh != null:
		for s in mesh.get_surface_count():
			hash_bytes(hashing, var_to_bytes(mesh.surface_get_arrays(s)))
		return
	if depth < 4:
		hash_object(hashing, resource, depth + 1)


# A file's MD5, worked out again only when the file changes.
static var _md5_cache := {}  # path -> [modified time, md5]


static func _file_md5(file: String) -> String:
	var time := FileAccess.get_modified_time(file)
	var cached: Array = _md5_cache.get(file, [])
	if not cached.is_empty() and cached[0] == time:
		return cached[1]
	var md5 := FileAccess.get_md5(file)
	_md5_cache[file] = [time, md5]
	return md5


## Adds [param bytes] to [param hashing] (HashingContext refuses empty input).
static func hash_bytes(hashing: HashingContext, bytes: PackedByteArray) -> void:
	if not bytes.is_empty():
		hashing.update(bytes)


## Adds [param object]'s stored properties to [param hashing].
static func hash_object(hashing: HashingContext, object: Object, depth: int) -> void:
	for property in object.get_property_list():
		if not property.usage & PROPERTY_USAGE_STORAGE or property.name in [&"script", &"resource_path",
				&"resource_name", &"resource_local_to_scene", &"resource_scene_unique_id"]:
			continue
		hash_bytes(hashing, String(property.name).to_utf8_buffer())
		hash_value(hashing, object.get(property.name), depth)


## Builds the solid, appending each tag's material to [param _cached_materials] in tag
## order.
@abstract func _build() -> Solid
