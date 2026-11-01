package main

import platform_api "aio:platform"
import "aio:pty"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

// Process work that must not stall a frame: the process snapshot behind padding groups and
// program icons (about 10 ms with a few hundred processes), and reading icons from executables.
// The main thread asks, the worker answers and wakes it, and the main thread adopts the answer.
Process_Worker :: struct {
	icons:           [PROGRAM_ICON_LIMIT]Program_Icon,
	clock:           u64,
	// Guards everything below except worker, platform and allocator, which are set before the thread
	// starts. jobs and done reserve one job per pending icon up front, so the worker never grows them.
	mutex:           sync.Mutex,
	cond:            sync.Cond,
	jobs:            [dynamic]Program_Icon_Job,
	done:            [dynamic]Program_Icon_Job,
	snapshot_wanted: bool,
	snapshot_ready:  bool,
	snapshot:        []pty.Process_Info,
	stop:            bool,
	worker:          ^thread.Thread,
	platform:        ^platform_api.Platform,
	allocator:       mem.Allocator,
}

// A pending icon's path and pixels are borrowed by its job; icons are never evicted while pending.
@(private)
Program_Icon_Job :: struct {
	index:  int,
	path:   string,
	size:   int,
	pixels: []u8,
	found:  bool,
}

process_worker_destroy :: proc(pw: ^Process_Worker) {
	if pw.worker != nil {
		sync.mutex_lock(&pw.mutex)
		pw.stop = true
		sync.cond_signal(&pw.cond)
		sync.mutex_unlock(&pw.mutex)
		thread.join(pw.worker)
		thread.destroy(pw.worker)
		pty.process_snapshot_destroy(pw.snapshot, pw.allocator)
	}
	for &icon in pw.icons {
		delete(icon.path)
		delete(icon.pixels)
	}
	delete(pw.jobs)
	delete(pw.done)
	pw^ = {}
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
	for {
		sync.mutex_lock(&pw.mutex)
		for len(pw.jobs) == 0 && !pw.snapshot_wanted && !pw.stop {sync.cond_wait(&pw.cond, &pw.mutex)}
		if pw.stop {sync.mutex_unlock(&pw.mutex); return}
		if pw.snapshot_wanted {
			pw.snapshot_wanted = false
			sync.mutex_unlock(&pw.mutex)
			snapshot, err := pty.process_snapshot(pw.allocator)
			if err != .None {log.errorf("process snapshot failed: %v", err)}
			sync.mutex_lock(&pw.mutex)
			pty.process_snapshot_destroy(pw.snapshot, pw.allocator)
			pw.snapshot, pw.snapshot_ready = snapshot, true
			sync.mutex_unlock(&pw.mutex)
		} else {
			job := pop_front(&pw.jobs)
			sync.mutex_unlock(&pw.mutex)
			job.found = platform_api.executable_icon(job.path, job.size, job.pixels)
			sync.mutex_lock(&pw.mutex)
			_, _ = append(&pw.done, job)
			sync.mutex_unlock(&pw.mutex)
		}
		if pw.platform != nil && platform_api.wake(pw.platform) != .None {
			log.error("waking the main loop from the process worker failed")
		}
	}
}

// Asks for a snapshot unless one is already being taken or waits to be adopted.
process_snapshot_request :: proc(pw: ^Process_Worker, platform: ^platform_api.Platform) {
	if !process_worker_start(pw, platform) {return}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
	if pw.snapshot_ready {return}
	pw.snapshot_wanted = true
	sync.cond_signal(&pw.cond)
}

// The finished snapshot, if any; the caller destroys it with pw.allocator. A failed snapshot is
// returned as ready with no processes.
process_snapshot_take :: proc(pw: ^Process_Worker) -> (snapshot: []pty.Process_Info, ready: bool) {
	if pw.worker == nil {return}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
	snapshot, ready = pw.snapshot, pw.snapshot_ready
	pw.snapshot, pw.snapshot_ready = nil, false
	return
}

@(private)
process_icon_request :: proc(pw: ^Process_Worker, index: int, platform: ^platform_api.Platform) {
	if !process_worker_start(pw, platform) {return}
	icon := &pw.icons[index]
	sync.mutex_lock(&pw.mutex)
	job := Program_Icon_Job {
		index  = index,
		path   = icon.path,
		size   = icon.size,
		pixels = icon.pixels,
	}
	_, _ = append(&pw.jobs, job)
	sync.cond_signal(&pw.cond)
	sync.mutex_unlock(&pw.mutex)
}

// Takes finished icon reads; reports whether one produced an icon to draw.
process_icons_adopt :: proc(pw: ^Process_Worker) -> bool {
	if pw.worker == nil {return false}
	ready := false
	sync.mutex_lock(&pw.mutex)
	for job in pw.done {
		pw.icons[job.index].state = job.found ? .Ready : .Missing
		ready ||= job.found
	}
	clear(&pw.done)
	sync.mutex_unlock(&pw.mutex)
	return ready
}
