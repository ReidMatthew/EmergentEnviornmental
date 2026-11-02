@tool
class_name GpuThread
extends RefCounted
## A thread that owns a local RenderingDevice and runs batches of GPU work on it. A local
## device can only be used from the thread that created it, so every GPU backend (mesher,
## generator) owns one of these and calls [method run] from whatever thread it is on.
##
## The work itself is done by a kernel object with three methods, all called on the GPU
## thread:
## [codeblock]
## func setup(rd: RenderingDevice) -> void            # once, after the device is created
## func process(rd: RenderingDevice, inputs: Array) -> Array  # one output per input, in order
## func teardown(rd: RenderingDevice) -> void         # once, before the device is freed
## [/codeblock]
## Inputs submitted from several threads at once are merged into one [code]process[/code]
## call (up to [member max_batch]), so a kernel can share fixed costs such as readback
## stalls across all of them.
##
## Creating the device and pipelines takes a while (about 200 ms for the noise generator),
## so it happens on the GPU thread in the background: construction returns at once. Check
## [method is_ready] without blocking, or call [method wait_until_ready] from a worker
## thread before [method run].
##
## The owner must call [method stop] before it is freed (from its NOTIFICATION_PREDELETE).
## The thread's loop keeps this object alive until then. Don't let the kernel reference
## the owner, or the owner would never be freed either.

## False when no RenderingDevice could be created (Compatibility renderer, --headless).
## Only meaningful once [method is_ready] is true.
var available := false
## Most inputs passed to one process() call.
var max_batch := 16

var _kernel: Object
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _thread := Thread.new()
var _queue: Array[_Request] = []
var _stopping := false
var _started := false


func _init(kernel: Object, batch_limit: int = 16) -> void:
	_kernel = kernel
	max_batch = batch_limit
	_thread.start(_main)


## True once the device has been created (or found unavailable). Never blocks.
func is_ready() -> bool:
	_mutex.lock()
	var ready := _started
	_mutex.unlock()
	return ready


## Blocks until the device has been created, then returns [member available]. Call it
## from worker threads; on the main thread it would stall the frame.
func wait_until_ready() -> bool:
	while not is_ready():
		OS.delay_usec(500)
	return available


## Runs [param inputs] through the kernel and returns its outputs in the same order.
## Blocks until done. Only call once [method wait_until_ready] returned true.
func run(inputs: Array) -> Array:
	var requests: Array[_Request] = []
	_mutex.lock()
	for input: Variant in inputs:
		var request := _Request.new()
		request.input = input
		requests.append(request)
		_queue.append(request)
	_mutex.unlock()
	for request in requests:
		_wake.post()
	var outputs := []
	for request in requests:
		request.done.wait()
		outputs.append(request.output)
	return outputs


## Finishes queued work, frees the device and joins the thread.
func stop() -> void:
	_mutex.lock()
	_stopping = true
	_mutex.unlock()
	_wake.post()
	if _thread.is_started():
		_thread.wait_to_finish()


func _main() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd != null:
		_kernel.setup(rd)
	_mutex.lock()
	available = rd != null
	_started = true
	_mutex.unlock()
	if rd == null:
		return

	# Every request posts _wake once, so a batch that takes several requests leaves extra
	# posts behind; those wake-ups just find the queue empty and wait again.
	while true:
		_wake.wait()
		_mutex.lock()
		var batch: Array[_Request] = []
		while not _queue.is_empty() and batch.size() < maxi(max_batch, 1):
			batch.append(_queue.pop_front())
		var stopping := _stopping and _queue.is_empty()
		_mutex.unlock()
		if not batch.is_empty():
			var inputs := []
			for request in batch:
				inputs.append(request.input)
			var outputs: Array = _kernel.process(rd, inputs)
			for i in batch.size():
				batch[i].output = outputs[i]
				batch[i].done.post()
		elif stopping:
			break

	_kernel.teardown(rd)
	rd.free()


class _Request:
	extends RefCounted

	var input: Variant
	var output: Variant
	var done := Semaphore.new()
