package main

import platform_api "aio:platform"
import "aio:procinfo"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

// Process work that must not stall a frame: the process snapshot behind padding groups and
// program icons, and reading or drawing their icons. The main thread asks, the worker answers and
// wakes it, and the main thread adopts the answer. Program_Icon_Cache owns the icons; the worker
// only runs their jobs.
Process_Worker :: struct {
	// Guards everything below except worker, platform and allocator, which are set before the thread
	// starts. jobs and done reserve PROGRAM_ICON_LIMIT jobs up front, the most icons that can be
	// pending at once, so appending never grows them and cannot fail.
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Program_Icon_Job,
	done:      [dynamic]Program_Icon_Job,
	snapshot:  Process_Snapshot,
	// The shells whose processes the requested snapshot lists.
	roots:     [dynamic]u32,
	stop:      bool,
	worker:    ^thread.Thread,
	platform:  ^platform_api.Platform,
	allocator: mem.Allocator,
}

// One snapshot at a time: nil while none is wanted, then asked for, being taken by the worker, and
// ready until the main thread takes it. Only the process_snapshot_* transitions below write it, with
// pw.mutex held.
Process_Snapshot :: union {
	Process_Snapshot_Requested,
	Process_Snapshot_Taking,
	Process_Snapshot_Ready,
}

Process_Snapshot_Requested :: struct {}
Process_Snapshot_Taking :: struct {}

// Owned by the worker's allocator until taken. A failed snapshot is ready with no processes.
Process_Snapshot_Ready :: struct {
	processes: []procinfo.Process_Info,
}

// Reports whether the worker must be woken. A snapshot being taken or waiting to be taken already
// answers the request, so it is not taken twice.
process_snapshot_ask :: proc(s: ^Process_Snapshot) -> bool {
	if s^ != nil {return false}
	s^ = Process_Snapshot_Requested{}
	return true
}

// Reports whether the worker should take a snapshot now.
process_snapshot_begin :: proc(s: ^Process_Snapshot) -> bool {
	if _, requested := s^.(Process_Snapshot_Requested); !requested {return false}
	s^ = Process_Snapshot_Taking{}
	return true
}

process_snapshot_finish :: proc(s: ^Process_Snapshot, processes: []procinfo.Process_Info) {
	_, taking := s^.(Process_Snapshot_Taking)
	assert(taking)
	s^ = Process_Snapshot_Ready{processes}
}

// Hands over a ready snapshot, which the caller then owns.
process_snapshot_collect :: proc(s: ^Process_Snapshot) -> (processes: []procinfo.Process_Info, ready: bool) {
	snapshot := s^.(Process_Snapshot_Ready) or_return
	s^ = nil
	return snapshot.processes, true
}

process_worker_destroy :: proc(pw: ^Process_Worker) {
	if pw.worker != nil {
		sync.mutex_lock(&pw.mutex)
		pw.stop = true
		sync.cond_signal(&pw.cond)
		sync.mutex_unlock(&pw.mutex)
		thread.join(pw.worker)
		thread.destroy(pw.worker)
		if ready, ok := pw.snapshot.(Process_Snapshot_Ready); ok {
			procinfo.process_snapshot_destroy(ready.processes, pw.allocator)
		}
	}
	delete(pw.jobs)
	delete(pw.done)
	delete(pw.roots)
	pw^ = {}
}

// The platform the worker wakes when it finishes work, or nil when headless and nothing waits on
// the loop. The worker binds it at its first start and keeps it for its lifetime.
@(private)
process_worker_platform :: proc(app: ^App) -> ^platform_api.Platform {
	return app.platform_ready ? &app.platform : nil
}

@(private)
process_worker_start :: proc(pw: ^Process_Worker, platform: ^platform_api.Platform) -> bool {
	if pw.worker != nil {return true}
	if reserve(&pw.jobs, PROGRAM_ICON_LIMIT) != nil || reserve(&pw.done, PROGRAM_ICON_LIMIT) != nil {
		log.error("reserving the process worker queues failed")
		return false
	}
	pw.worker = thread.create(process_worker_main)
	if pw.worker == nil {log.error("starting the process worker failed"); return false}
	pw.worker.data = pw
	pw.platform = platform
	pw.allocator = context.allocator
	thread.start(pw.worker)
	return true
}

@(private)
process_worker_main :: proc(t: ^thread.Thread) {
	pw := (^Process_Worker)(t.data)
	roots := make([dynamic]u32, pw.allocator)
	defer delete(roots)
	for {
		sync.mutex_lock(&pw.mutex)
		for len(pw.jobs) == 0 && !pw.stop {
			if _, requested := pw.snapshot.(Process_Snapshot_Requested); requested {break}
			sync.cond_wait(&pw.cond, &pw.mutex)
		}
		if pw.stop {sync.mutex_unlock(&pw.mutex); return}
		if process_snapshot_begin(&pw.snapshot) {
			clear(&roots)
			_, roots_err := append(&roots, ..pw.roots[:])
			sync.mutex_unlock(&pw.mutex)
			snapshot, err := procinfo.process_tree(roots[:], pw.allocator)
			if roots_err != nil {err = .Out_Of_Memory}
			if err != .None {log.errorf("process snapshot failed: %v", err)}
			sync.mutex_lock(&pw.mutex)
			process_snapshot_finish(&pw.snapshot, snapshot)
			sync.mutex_unlock(&pw.mutex)
		} else {
			job := pop_front(&pw.jobs)
			sync.mutex_unlock(&pw.mutex)
			job.found = program_icon_read(job)
			sync.mutex_lock(&pw.mutex)
			_, _ = append(&pw.done, job)
			sync.mutex_unlock(&pw.mutex)
		}
		if pw.platform != nil && platform_api.wake(pw.platform) != .None {
			log.error("waking the main loop from the process worker failed")
		}
	}
}

// Asks for the processes of the shells `roots` names and everything below them.
process_snapshot_request :: proc(pw: ^Process_Worker, platform: ^platform_api.Platform, roots: []u32) {
	if !process_worker_start(pw, platform) {return}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
	clear(&pw.roots)
	if _, err := append(&pw.roots, ..roots); err != nil {log.error("process snapshot: out of memory"); return}
	if process_snapshot_ask(&pw.snapshot) {sync.cond_signal(&pw.cond)}
}

// The finished snapshot, if any; the caller destroys it with pw.allocator.
process_snapshot_take :: proc(pw: ^Process_Worker) -> (snapshot: []procinfo.Process_Info, ready: bool) {
	if pw.worker == nil {return}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
	return process_snapshot_collect(&pw.snapshot)
}

// Queues the read of a pending icon. The worker must already run, so no icon is left pending without
// a job to settle it.
@(private)
process_icon_request :: proc(pw: ^Process_Worker, job: Program_Icon_Job) {
	assert(pw.worker != nil)
	sync.mutex_lock(&pw.mutex)
	_, _ = append(&pw.jobs, job)
	sync.cond_signal(&pw.cond)
	sync.mutex_unlock(&pw.mutex)
}

// Moves the finished icon jobs into `out`, which holds PROGRAM_ICON_LIMIT, and returns how many.
@(private)
process_icon_results :: proc(pw: ^Process_Worker, out: []Program_Icon_Job) -> int {
	if pw.worker == nil {return 0}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
	count := copy(out, pw.done[:])
	assert(count == len(pw.done))
	clear(&pw.done)
	return count
}
