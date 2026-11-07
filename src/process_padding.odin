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
// program changes.
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
	now := time.tick_now()
	if app.process_deadline == {} || time.tick_diff(now, app.process_deadline) <= 0 {
		app.process_deadline = time.tick_add(now, PROCESS_INTERVAL)
		process_snapshot_request(&app.processes, process_worker_platform(app))
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

@(private)
padding_update :: proc(
	app: ^App,
	entry: ^Session_Entry,
	processes: []procinfo.Process_Info,
	root: u32,
) -> bool {
	index := procinfo.process_leaf(processes, root)
	padding := app.settings.window.padding
	entry.process_name_length = 0
	if index >= 0 {
		entry.process_name_length = copy(entry.process_name[:], transmute([]u8)processes[index].executable)
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
