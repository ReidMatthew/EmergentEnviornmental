@tool
class_name StageProfile
extends RefCounted
## Adds up the time each stage of the pipeline takes (booleans, clean-up, surfaces, seam
## faces, hulls, separation, putting results in the scene, spawning parts), on whichever
## thread it runs, for benchmarks. Off by default: then each stage only reads
## [member enabled].
##
##   StageProfile.enabled = true
##   StageProfile.reset()
##   ... edits ...
##   print(StageProfile.get_totals())  # stage -> [microseconds, calls]

## Turns the profiling on.
static var enabled := false

static var _lock := Mutex.new()
static var _totals := {}  # stage -> [usec, calls]


## Call at the start of a stage; pass what it returns to [method end].
static func begin() -> int:
	return Time.get_ticks_usec() if enabled else 0


## Call at the end of [param stage] with what [method begin] returned. Thread-safe.
static func end(stage: StringName, started: int) -> void:
	if not enabled or started == 0:
		return
	var spent := Time.get_ticks_usec() - started
	_lock.lock()
	var entry: Array = _totals.get(stage, [0, 0])
	entry[0] += spent
	entry[1] += 1
	_totals[stage] = entry
	_lock.unlock()


static func reset() -> void:
	_lock.lock()
	_totals.clear()
	_lock.unlock()


## stage -> [microseconds, calls], since the last [method reset].
static func get_totals() -> Dictionary:
	_lock.lock()
	var out := _totals.duplicate(true)
	_lock.unlock()
	return out
