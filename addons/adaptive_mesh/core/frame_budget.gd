@tool
class_name FrameBudget
extends RefCounted
## Shares main-thread time per frame between jobs, so many jobs in one frame (say, an edit
## reaching several pieces, or several meshes edited at once) spread over a few frames
## instead of hitching one. A job awaits [method wait_turn], does its work, then reports
## the time with [method spend].
##
## Every budget counts against one tally per frame, shared by all of them: each adaptive
## mesh has its own budget (its own limit), but the time all of them spend in a frame adds
## up, so a hundred meshes edited at once still take about one budget's worth per frame,
## not a hundred. The first job of a frame always runs, however long it takes.
##
## Jobs that have to wait are let through by priority (lowest first; see
## [method camera_distance]), so a big operation shows up nearest the camera first and
## finishes further away a few frames later.

## Main-thread time per frame, in milliseconds: a job waits while the frame's shared tally
## is at or over this. 0 or less: no limit (the job runs at once, but still counts).
var budget_ms := 4.0

static var _frame := -1
static var _used_usec := 0
static var _queue: Array[_Ticket] = []  # jobs waiting, let through at the start of a frame
static var _next_seq := 0
static var _driving := false


class _Ticket:
	signal go
	var priority := 0.0
	var seq := 0
	var limit_usec := 0.0


## Returns once the job may run: now if this frame has time left and nobody is waiting,
## otherwise when the budget lets it through (a later frame; lower [param priority] first,
## then in the order they came).
func wait_turn(priority: float = 0.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	_roll_over()
	if budget_ms <= 0.0 or tree == null or (_used_usec < budget_ms * 1000.0 and _queue.is_empty()):
		return
	var ticket := _Ticket.new()
	ticket.priority = priority
	ticket.seq = _next_seq
	_next_seq += 1
	ticket.limit_usec = budget_ms * 1000.0
	_queue.append(ticket)
	if not _driving:
		_driving = true
		FrameBudget._drive.call_deferred()
	await ticket.go


## Records [param usec] microseconds of main-thread time spent this frame.
func spend(usec: int) -> void:
	_roll_over()
	_used_usec += usec


## Main-thread time all budgets have recorded this frame, in microseconds.
static func get_used_usec() -> int:
	_roll_over()
	return _used_usec


## A priority for [method wait_turn]: how far [param where] (global) is from the active
## camera of [param viewport] (0 without one), so nearer work goes first.
static func camera_distance(viewport: Viewport, where: Vector3) -> float:
	var camera := viewport.get_camera_3d() if viewport != null else null
	return camera.global_position.distance_to(where) if camera != null else 0.0


static func _roll_over() -> void:
	var frame := Engine.get_process_frames()
	if frame != _frame:
		_frame = frame
		_used_usec = 0


# Lets waiting jobs through, a frame at a time: at the start of each frame, best priority
# first, while the frame has time left (the first always goes). Each job runs up to its next
# await when let through, and reports its time, so the tally is current for the next one.
static func _drive() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	while not _queue.is_empty():
		await tree.process_frame
		_roll_over()
		_queue.sort_custom(func(a: _Ticket, b: _Ticket) -> bool:
			return a.priority < b.priority or (a.priority == b.priority and a.seq < b.seq))
		var released := 0
		while not _queue.is_empty():
			var ticket: _Ticket = _queue[0]
			if released > 0 and _used_usec >= ticket.limit_usec:
				break
			_queue.remove_at(0)
			released += 1
			ticket.go.emit()
	_driving = false
