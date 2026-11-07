package main

import "aio:platform"
import "core:path/filepath"

// The active file a confirmation asks before opening.
Pending_File :: struct {
	file: platform.Terminal_File,
}

terminal_file_request :: proc(app: ^App, w: ^Window, path: string) {
	file, ok := platform.prepare_terminal_file(path)
	if !ok {notify(app, .Error, "That local file is not available."); return}
	if !file.confirm && markdown_is_path(file.target) {
		defer platform.terminal_file_destroy(&file)
		markdown_open_focused(app, w, file.target)
		return
	}
	if !file.confirm {
		defer platform.terminal_file_destroy(&file)
		if !open_file_link(app, file.path, "") {notify(app, .Error, "Could not open the file.")}
		return
	}
	if !gesture_cancel(app, w) {platform.terminal_file_destroy(&file); return}
	overlay_open(app, w, nil)
	confirmation_open(w, Pending_File{file}, extended = true, focus = .Cancel)
}

pending_file_text :: proc(pending: Pending_File) -> Confirmation_Text {
	return {
		title = "Open this file?",
		body = filepath.base(pending.file.target),
		note = pending.file.target,
		label = "Open",
	}
}

@(private)
pending_file_finish :: proc(app: ^App, pending: Pending_File, accept: bool) {
	if accept && !open_file_link(app, pending.file.path, pending.file.target) {
		notify(app, .Error, "Could not open the file.")
	}
}

@(private, require_results)
open_file_link :: proc(app: ^App, path, approved: string) -> bool {
	when ODIN_TEST {if app.open_file == nil {return false}}
	opener := app.open_file
	if opener == nil {opener = platform.open_terminal_file}
	return opener(path, approved)
}
