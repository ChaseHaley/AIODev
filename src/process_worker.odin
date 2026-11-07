package main

import platform_api "aio:platform"
import "aio:program_art"
import "aio:procinfo"
import "core:image/png"
import "core:log"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:thread"

// Process work that must not stall a frame: the process snapshot behind padding groups and
// program icons (about 10 ms with a few hundred processes), and reading or drawing their icons.
// The main thread asks, the worker answers and wakes it, and the main thread adopts the answer.
Process_Worker :: struct {
	icons:     [PROGRAM_ICON_LIMIT]Program_Icon,
	clock:     u64,
	// Guards everything below except worker, platform and allocator, which are set before the thread
	// starts. jobs and done reserve one job per pending icon up front, so the worker never grows them.
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Program_Icon_Job,
	done:      [dynamic]Program_Icon_Job,
	snapshot:  Process_Snapshot,
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

// A pending icon's path and pixels are borrowed by its job; icons are never evicted while pending.
@(private)
Program_Icon_Job :: struct {
	index:  int,
	source: Program_Icon_Source,
	path:   string,
	paint:  program_art.Paint,
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
		if ready, ok := pw.snapshot.(Process_Snapshot_Ready); ok {
			procinfo.process_snapshot_destroy(ready.processes, pw.allocator)
		}
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
		for len(pw.jobs) == 0 && !pw.stop {
			if _, requested := pw.snapshot.(Process_Snapshot_Requested); requested {break}
			sync.cond_wait(&pw.cond, &pw.mutex)
		}
		if pw.stop {sync.mutex_unlock(&pw.mutex); return}
		if process_snapshot_begin(&pw.snapshot) {
			sync.mutex_unlock(&pw.mutex)
			snapshot, err := procinfo.process_snapshot(pw.allocator)
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

process_snapshot_request :: proc(pw: ^Process_Worker, platform: ^platform_api.Platform) {
	if !process_worker_start(pw, platform) {return}
	sync.mutex_lock(&pw.mutex)
	defer sync.mutex_unlock(&pw.mutex)
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
process_icon_request :: proc(pw: ^Process_Worker, index: int) {
	assert(pw.worker != nil)
	icon := &pw.icons[index]
	sync.mutex_lock(&pw.mutex)
	job := Program_Icon_Job {
		index  = index,
		source = icon.source,
		path   = icon.path,
		paint  = icon.paint,
		size   = icon.size,
		pixels = icon.pixels,
	}
	_, _ = append(&pw.jobs, job)
	sync.cond_signal(&pw.cond)
	sync.mutex_unlock(&pw.mutex)
}

// Takes finished icon reads; reports whether one produced an icon to draw, and the path of a user's
// PNG that could not be read, valid until the icon is reused.
process_icons_adopt :: proc(pw: ^Process_Worker) -> (ready: bool, unreadable: string) {
	if pw.worker == nil {return}
	sync.mutex_lock(&pw.mutex)
	for job in pw.done {
		program_icon_move(&pw.icons[job.index], job.found ? .Ready : .Missing)
		ready ||= job.found
		if !job.found && job.source == .File {unreadable = pw.icons[job.index].path}
	}
	clear(&pw.done)
	sync.mutex_unlock(&pw.mutex)
	return
}

// Runs on the worker: reads or draws one icon into its job's pixels.
@(private)
program_icon_read :: proc(job: Program_Icon_Job) -> bool {
	switch job.source {
	case .Executable:
		return platform_api.executable_icon(job.path, job.size, job.pixels)
	case .Artwork:
		art, found := program_art.find(job.path)
		return found && program_art.draw(art, job.size, job.paint, job.pixels)
	case .File:
		return program_icon_png(job.path, job.size, job.pixels)
	}
	return false
}

// A user's PNG fitted into size x size, centred, each pixel averaging the source pixels it covers.
// Limited like Shell Icon, since the decoder reads the whole file before checking it.
@(private)
program_icon_png :: proc(path: string, size: int, pixels: []u8) -> bool {
	if !platform_api.local_file_within_limit(path, SHELL_ICON_MAX_BYTES) {return false}
	header, header_error := png.load(path, {.return_header})
	defer png.destroy(header)
	if header_error != nil ||
	   header == nil ||
	   header.width < 1 ||
	   header.height < 1 ||
	   header.width > 1024 ||
	   header.height > 1024 {return false}
	image, image_error := png.load(path, {.alpha_add_if_missing, .alpha_premultiply})
	defer png.destroy(image)
	if image_error != nil || image == nil || image.depth != 8 || image.channels != 4 {return false}
	source := image.pixels.buf[:]
	longest := max(image.width, image.height)
	width, height := max(1, image.width * size / longest), max(1, image.height * size / longest)
	left, top := (size - width) / 2, (size - height) / 2
	slice.fill(pixels[:size * size * 4], 0)
	for y in 0 ..< height {
		y0 := y * image.height / height
		y1 := max(y0 + 1, (y + 1) * image.height / height)
		for x in 0 ..< width {
			x0 := x * image.width / width
			x1 := max(x0 + 1, (x + 1) * image.width / width)
			sum: [4]u32
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					from := (sy * image.width + sx) * 4
					for c in 0 ..< 4 {sum[c] += u32(source[from + c])}
				}
			}
			count := u32((x1 - x0) * (y1 - y0))
			to := ((top + y) * size + left + x) * 4
			for c in 0 ..< 4 {pixels[to + c] = u8((sum[c] + count / 2) / count)}
		}
	}
	return true
}
