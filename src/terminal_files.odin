package main

import "aio:platform"
import "aio:ui"
import "core:path/filepath"

Pending_File :: struct {
	confirm: ui.Confirm,
	file:    platform.Terminal_File,
}

pending_file_clear :: proc(pending: ^Pending_File) {
	platform.terminal_file_destroy(&pending.file)
	pending^ = {}
}

terminal_file_request :: proc(app: ^App, w: ^Window, path: string) {
	file, ok := platform.prepare_terminal_file(path)
	if !ok {notify(app, .Error, "That local file is not available."); return}
	if !file.confirm {
		defer platform.terminal_file_destroy(&file)
		if !open_file_link(app, file.path, "") {notify(app, .Error, "Could not open the file.")}
		return
	}
	if !gesture_cancel(app, w) {platform.terminal_file_destroy(&file); return}
	confirmation_cancel(app, w)
	pending_file_clear(&w.pending_file)
	w.pending_file.file = file
	w.pending_file.confirm.extended = true
	ui.confirm_open(&w.pending_file.confirm)
	w.pending_file.confirm.focus = .Cancel
	w.dirty = true
}

pending_file_text :: proc(pending: ^Pending_File) -> Pending_Close_Text {
	return {
		title = "Open this file?",
		body = filepath.base(pending.file.target),
		note = pending.file.target,
		label = "Open",
	}
}

pending_file_finish :: proc(app: ^App, w: ^Window, accept: bool) {
	pending := &w.pending_file
	if !pending.confirm.open {return}
	ui.confirm_close(&pending.confirm)
	if accept && !open_file_link(app, pending.file.path, pending.file.target) {
		notify(app, .Error, "Could not open the file.")
	}
	w.dirty = true
}

@(private, require_results)
open_file_link :: proc(app: ^App, path, approved: string) -> bool {
	when ODIN_TEST {if app.open_file == nil {return false}}
	opener := app.open_file
	if opener == nil {opener = platform.open_terminal_file}
	return opener(path, approved)
}
