@tool
class_name WorkerJobs
extends RefCounted
## Runs jobs on worker threads for a node, and lets the node wait for the ones still
## running before it's freed. Godot crashes if it quits while a GDScript job is still
## running on a worker thread, so anything that starts one waits for it in
## [constant Object.NOTIFICATION_PREDELETE] (see [method finish]). Main thread only.

static var _running := {}  # owner instance id -> task ids still running for it
static var _groups := {}  # owner instance id -> group task ids still running for it
static var _ticker: _Ticker


# Ticks twice a frame: at its start (process) and once its processing is done, just before
# it's drawn. A job done during a frame is then picked up in that frame, not the next.
class _Ticker:
	signal tick

	func _on_frame() -> void:
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			tick.emit()


## Runs [param job] on a worker thread for [param owner] and returns what it returned,
## checking twice a frame whether it's done. A coroutine. The job must not touch nodes.
static func run(job: Callable, owner: Object) -> Variant:
	var result := []
	var task := WorkerThreadPool.add_task(func() -> void: result.append(job.call()))
	var id := owner.get_instance_id() if owner != null else 0
	if not _running.has(id):
		_running[id] = []
	(_running[id] as Array).append(task)
	var ticked := _tick()
	while _is_running(id, task) and not WorkerThreadPool.is_task_completed(task):
		await ticked
	if _is_running(id, task):  # (finish() waits for it otherwise, and forgets it)
		WorkerThreadPool.wait_for_task_completion(task)
		var tasks: Array = _running[id]
		tasks.erase(task)
		if tasks.is_empty():
			_running.erase(id)
	return result[0] if not result.is_empty() else null


## Runs [param job] (called with each index from 0 to [param count] - 1) spread over all
## worker threads for [param owner], checking twice a frame whether it's done. A coroutine.
## The job must not touch nodes.
static func run_group(job: Callable, count: int, owner: Object) -> void:
	if count <= 0:
		return
	var group := WorkerThreadPool.add_group_task(job, count)
	var id := owner.get_instance_id() if owner != null else 0
	if not _groups.has(id):
		_groups[id] = []
	(_groups[id] as Array).append(group)
	var ticked := _tick()
	while _is_grouped(id, group) and not WorkerThreadPool.is_group_task_completed(group):
		await ticked
	if _is_grouped(id, group):  # (finish() waits for it otherwise, and forgets it)
		WorkerThreadPool.wait_for_group_task_completion(group)
		var groups: Array = _groups[id]
		groups.erase(group)
		if groups.is_empty():
			_groups.erase(id)


## Waits for every job still running for [param owner] (call it when the owner is freed).
static func finish(owner: Object) -> void:
	var id := owner.get_instance_id()
	for task: int in _running.get(id, []):
		WorkerThreadPool.wait_for_task_completion(task)
	_running.erase(id)
	for group: int in _groups.get(id, []):
		WorkerThreadPool.wait_for_group_task_completion(group)
	_groups.erase(id)


# The signal jobs are checked on: see _Ticker.
static func _tick() -> Signal:
	if _ticker == null:
		_ticker = _Ticker.new()
		(Engine.get_main_loop() as SceneTree).process_frame.connect(_ticker._on_frame)
		RenderingServer.frame_pre_draw.connect(_ticker._on_frame)
	return _ticker.tick


static func _is_running(id: int, task: int) -> bool:
	return _running.has(id) and (_running[id] as Array).has(task)


static func _is_grouped(id: int, group: int) -> bool:
	return _groups.has(id) and (_groups[id] as Array).has(group)
