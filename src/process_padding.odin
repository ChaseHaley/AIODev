package main

import "aio:procinfo"
import "aio:settings"
import "aio:term"
import "core:math"
import "core:time"

@(private)
PROCESS_INTERVAL :: 500 * time.Millisecond

pane_padding :: proc(app: ^App, scale: f32, entry: ^Session_Entry) -> f32 {
	padding := app.settings.window.padding
	if entry != nil {
		if value, ok := entry.process_padding.?; ok {padding = value}
	}
	return math.round(f32(padding) * scale)
}

// One process snapshot per interval serves padding groups and program icons alike, and is skipped
// when neither is in use. The worker takes it; windows redraw only when a pane's padding or
// program changes. app.process_deadline, zero while nothing polls, is this poll's alone.
update_processes :: proc(app: ^App) {
	processes, ready := process_snapshot_take(&app.processes)
	defer if ready {procinfo.process_snapshot_destroy(processes, app.processes.allocator)}
	padding := app.settings.process.padding_groups != ""
	polling := program_polling(app)
	running := false
	for &entry in app.sessions {
		if entry.status == .Running && polling {running = true; continue}
		if program_forget(&entry) {mark_all_dirty(app)}
		running ||= entry.status == .Running && padding
	}
	if !running {app.process_deadline = {}; return}
	now := clock_now(&app.clock)
	if app.process_deadline == {} || time.tick_diff(now, app.process_deadline) <= 0 {
		app.process_deadline = time.tick_add(now, PROCESS_INTERVAL)
		process_snapshot_request(&app.processes, process_worker_platform(app), session_roots(app))
	}
	if len(processes) == 0 {return}
	relayout, redraw := false, false
	for &entry in app.sessions {
		if entry.status != .Running {continue}
		root := term.process_id(entry.session)
		if padding {relayout ||= padding_update(app, &entry, processes, root)}
		if polling {redraw ||= program_update(app, &entry, processes, root)}
	}
	if relayout {
		for window in app.windows {window_relayout(app, window); window.dirty = true}
	} else if redraw {mark_all_dirty(app)}
}

// The running panes' shells, in temporary memory.
session_roots :: proc(app: ^App) -> []u32 {
	roots := make([dynamic]u32, 0, len(app.sessions), context.temp_allocator)
	for &entry in app.sessions {
		if entry.status == .Running {append(&roots, term.process_id(entry.session))}
	}
	return roots[:]
}

// The running panes' shells and every process below them, read now into temporary memory; nil
// when that fails.
session_processes :: proc(app: ^App) -> []procinfo.Process_Info {
	processes, err := procinfo.process_tree(session_roots(app), context.temp_allocator)
	return err == .None ? processes : nil
}

// When update_processes next asks for a snapshot; false while nothing polls.
process_poll_deadline :: proc(app: ^App) -> (time.Tick, bool) {
	return app.process_deadline, app.process_deadline != {}
}

// New settings may poll for other reasons, so the next update asks for a snapshot at once.
process_poll_restart :: proc(app: ^App) {
	app.process_deadline = {}
}

@(private)
padding_update :: proc(
	app: ^App,
	entry: ^Session_Entry,
	processes: []procinfo.Process_Info,
	root: u32,
) -> bool {
	index := procinfo.process_leaf(processes, root)
	padding := app.settings.window.padding
	entry.padding_leaf_length = 0
	if index >= 0 {
		entry.padding_leaf_length = copy(entry.padding_leaf[:], transmute([]u8)processes[index].executable)
		for steps := 0; index >= 0 && steps <= len(processes); steps += 1 {
			matched := false
			padding, matched = settings.process_padding(&app.settings, processes[index].executable)
			if matched || processes[index].id == root {break}
			index = procinfo.process_ancestor(processes, index)
			if index >= 0 && processes[index].id == root {break}
		}
	}
	previous := app.settings.window.padding
	if value, ok := entry.process_padding.?; ok {previous = value}
	entry.process_padding = padding
	return previous != padding
}
