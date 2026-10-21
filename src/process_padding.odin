package main

import "aio:pty"
import "aio:settings"
import "aio:term"
import "core:math"
import "core:time"

@(private)
PROCESS_INTERVAL :: 500 * time.Millisecond

pane_padding :: proc(app: ^App, w: ^Window, entry: ^Session_Entry) -> f32 {
	padding := app.settings.window.padding
	if entry != nil {
		if value, ok := entry.process_padding.?; ok {padding = value}
	}
	return math.round(f32(padding) * w.scale)
}

update_process_padding :: proc(app: ^App) {
	if app.settings.process.padding_groups == "" {app.process_deadline = {}; return}
	running := false
	for entry in app.sessions {running ||= entry.status == .Running}
	if !running {app.process_deadline = {}; return}
	now := time.tick_now()
	if app.process_deadline != {} && time.tick_diff(now, app.process_deadline) > 0 {return}
	app.process_deadline = time.tick_add(now, PROCESS_INTERVAL)
	processes, err := pty.process_snapshot(context.temp_allocator)
	if err != .None {return}
	changed := false
	for &entry in app.sessions {
		if entry.status != .Running {continue}
		root := term.process_id(entry.session)
		index := pty.process_leaf(processes, root)
		padding := app.settings.window.padding
		entry.process_name_length = 0
		if index >= 0 {
			entry.process_name_length = copy(
				entry.process_name[:],
				transmute([]u8)processes[index].executable,
			)
			for steps := 0; index >= 0 && steps <= len(processes); steps += 1 {
				matched := false
				padding, matched = settings.process_padding(
					&app.settings,
					processes[index].executable,
				)
				if matched || processes[index].id == root {break}
				index = pty.process_ancestor(processes, index)
				if index >= 0 && processes[index].id == root {break}
			}
		}
		previous := app.settings.window.padding
		if value, ok := entry.process_padding.?; ok {previous = value}
		entry.process_padding = padding
		changed ||= previous != padding
	}
	if changed {
		for window in app.windows {window_relayout(app, window); window.dirty = true}
	}
}
