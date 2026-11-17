package main

import "aio:layout"
import "aio:localpath"
import "aio:platform"
import "aio:pty"
import "aio:settings"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Files dropped on a window from Explorer open as a click on a link to them would: a Markdown file in a
// Markdown pane, a folder in a shell, any other file in Neovim in a new terminal pane. Each opens beside
// the pane under the drop, or beside the focused pane when the drop lands on chrome, and the next file
// opens beside the one before. No more than FILE_DROP_LIMIT files open from one drop, so a dropped folder's
// worth of files does not start a process each.
FILE_DROP_LIMIT :: 8

@(private = "file")
FILE_DROP_PROGRAM :: "nvim"

// The program a non-Markdown file opens in, built like a Link Programs entry so its command line,
// quoting and batch handling are theirs.
@(private = "file")
FILE_DROP_EDITOR :: settings.Opener {
	name    = "Neovim",
	command = FILE_DROP_PROGRAM + " %1",
}

@(private = "file")
File_Drop_Result :: enum u8 {
	Opened,
	// Not a local file or folder that exists; reported once for the whole drop.
	Unavailable,
	// Refused with a notice already shown.
	Refused,
}

// Opens the files the event names, as the window's drop.
files_dropped :: proc(app: ^App, w: ^Window, drop: platform.Files_Drop_Event) {
	if !gesture_cancel(app, w) {return}
	tree := window_tree(w)
	if tree == nil {return}
	node := tree.focus
	if shown, over := layout.hit_test(w.panes[:], f32(drop.x), f32(drop.y)); over {node = shown.node}
	editor := FILE_DROP_EDITOR
	editor_found: Maybe(bool)
	total, unavailable := 0, 0
	rest := drop.paths
	for path in strings.split_iterator(&rest, "\n") {
		if path == "" {continue}
		total += 1
		if total > FILE_DROP_LIMIT {continue}
		switch file_drop_one(app, w, node, path, &editor, &editor_found) {
		case .Opened:
			if tree = window_tree(w); tree != nil {node = tree.focus}
		case .Unavailable:
			unavailable += 1
		case .Refused:
		}
	}
	if unavailable > 0 {target_unavailable(app)}
	if total > FILE_DROP_LIMIT {
		notify(app, .Warning, fmt.tprintf("Opened the first %d of %d dropped files.", FILE_DROP_LIMIT, total))
	}
}

@(private = "file")
file_drop_one :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	path: string,
	editor: ^settings.Opener,
	editor_found: ^Maybe(bool),
) -> File_Drop_Result {
	file, ok := localpath.prepare_open(path)
	if !ok {return .Unavailable}
	defer localpath.open_file_destroy(&file)
	switch {
	case os.is_dir(file.target):
		launch := Pane_Launch {
			directory = file.target,
			profile   = file_drop_profile(app, w, node),
		}
		if _, opened := shell_open_placed(app, w, node, launch, .Split_Right); !opened {
			notify(app, .Error, "Could not open a shell.")
			return .Refused
		}
	case !file.confirm && markdown_is_path(file.target):
		placement: Pane_Placement = app.settings.pane.markdown_floating ? .Float : .Split_Right
		acting, beside, found := pane_placement_window(app, w, node, placement)
		if found &&
		   markdown_open_at(
			   app,
			   acting,
			   acting.workspace,
			   acting.workspace.selected,
			   beside,
			   file.target,
			   floating = placement == .Float,
		   ) {
			return .Opened
		}
		notify(app, .Error, "Could not open the file.")
		return .Refused
	case:
		if !file_drop_editor_found(app, editor, editor_found) {return .Refused}
		line, ready := link_program_line(app, editor, file.path)
		if !ready {return .Refused}
		launch := Pane_Launch {
			command   = line,
			directory = filepath.dir(file.path),
		}
		if _, opened := shell_open_placed(app, w, node, launch, .Split_Right); !opened {
			notify(app, .Error, "Could not start Neovim.")
			return .Refused
		}
	}
	return .Opened
}

// Whether Neovim can start, looked up for the first file that needs it and the answer kept for the drop,
// so a missing program is reported once and Markdown files and folders still open.
@(private = "file")
file_drop_editor_found :: proc(app: ^App, editor: ^settings.Opener, found: ^Maybe(bool)) -> bool {
	if known, ok := found.?; ok {return known}
	program, err := pty.resolve_program(FILE_DROP_PROGRAM, context.temp_allocator)
	ready := err.kind == .None
	if ready {pty.program_destroy(&program, context.temp_allocator)}
	found^ = ready
	if !ready {
		notify(app, .Error, "nvim is not on PATH, so only Markdown files and folders open from a drop.")
	}
	return ready
}

// The shell profile of the terminal pane at `node`, so a dropped folder opens in the shell it was dropped
// on; empty for any other pane or none.
@(private = "file")
file_drop_profile :: proc(app: ^App, w: ^Window, node: layout.Node_Id) -> string {
	for shown in w.panes {
		if shown.node != node {continue}
		if entry := workspace_session_for_content(app, shown.content); entry != nil {return entry.profile_id}
	}
	return ""
}
