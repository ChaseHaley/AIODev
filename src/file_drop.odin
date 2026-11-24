package main

import "aio:layout"
import "aio:localpath"
import "cosmos:platform"
import "aio:pty"
import "aio:settings"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "cosmos:host"

// Files dragged in from Explorer open where a pane dragged by its header would land. Over a window they
// show the header drag's outline (arrange.odin) at the place the pointer picks: beside a pane on its
// nearest side, along a window edge in its band, in a new tab on the tab strip's New tab zone, or beside the
// focused pane of the tab under the pointer. Over the title bar or any other chrome the outline sits beside
// the focused pane, on its right. The drop opens the first file there, a Markdown file in a Markdown pane,
// an HTML file in a web pane while pane.html_files is on, a folder in a shell, any other file with the Link
// Program the link menu would list first for a file (else Neovim) in a new terminal pane, and each further
// file beside the one before it. At most pane.drop_limit files open from one drop, so a dropped folder's
// worth of files does not start a process each.

@(private = "file")
FILE_DROP_PROGRAM :: "nvim"

// The program a non-Markdown file opens in when no Link Programs entry is offered for files, built like one
// so its command line, quoting and batch handling are theirs.
@(private = "file")
FILE_DROP_EDITOR :: settings.Opener {
	name    = "Neovim",
	command = FILE_DROP_PROGRAM + " %1",
}

// Files over a window: the outline's state, which is a header drag's (`carry`, whose grab names no pane
// because nothing is being moved), and the last pointer position, for a rest on a tab to switch to it.
File_Drag :: struct {
	carry:   Pane_Carry,
	pointer: [2]f32,
}

@(private = "file")
File_Drop_Result :: enum u8 {
	Opened,
	// Started as a window of its own by a Link Program, so there is no pane to chain the next file to.
	Started,
	// Not a local file or folder that exists; reported once for the whole drop.
	Unavailable,
	// Refused with a notice already shown.
	Refused,
}

// The first Link Programs entry, in Settings' order, that is offered for files: the first program row the
// link menu lists for a file (link_choices, D-088). Nil when none is.
@(private = "file", require_results)
file_drop_program :: proc(app: ^App) -> ^settings.Opener {
	indices: [settings.OPENER_LIMIT]int
	count := settings.openers_in_order(&app.settings.openers, indices[:])
	for index in indices[:count] {
		program := &app.settings.openers.items[index]
		if .Files in program.offers {return program}
	}
	return nil
}

// A drag of files entered, moved over or left the window.
files_drag :: proc(app: ^App, w: ^Window, e: platform.Files_Drag_Event) {
	if e.phase == .Leave {
		files_drag_leave(app, w)
		return
	}
	if _, dragging := w.file_drag.(File_Drag); !dragging || e.phase == .Enter {
		files_drag_leave(app, w)
		if !gesture_cancel(app, w) {return}
		w.file_drag = File_Drag {
			carry = {visit = {window = w.id, original_index = w.workspace.selected}},
		}
	}
	files_drag_move(app, w, f32(e.x), f32(e.y))
}

// Takes the outline away and shows the tab the window showed when the drag came in, which a rest on
// another tab may have replaced. Nothing else changed, so there is nothing more to undo.
@(private = "file")
files_drag_leave :: proc(app: ^App, w: ^Window) {
	files, dragging := &w.file_drag.(File_Drag)
	if !dragging {return}
	original := files.carry.visit.original_index
	w.file_drag = nil
	w.dirty = true
	if original != w.workspace.selected && original >= 0 && original < len(w.workspace.tabs) {
		tab_select(app, w, original, .Preserve_Marks)
	}
}

// Moves the drop target to the point, as a header drag moves its own (pane_drag_target_move).
@(private = "file")
files_drag_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	files, dragging := &w.file_drag.(File_Drag)
	if !dragging {return}
	files.pointer = {x, y}
	tabs := pane_drop_tabs(app, w, x, y, false)
	pane_drag_hover(app, w, &files.carry, w, tabs.destination, tabs.on_tab, false, host.clock_now(&app.clock))
	next := file_drop_place(app, w, x, y, tabs)
	if pane_destination_same(files.carry.destination, next) {return}
	rect: layout.Rect
	if drop, placed := &next.(Pane_Drop); placed {rect, drop.fit = file_drop_preview(app, w, drop^)}
	previous, was_placed := files.carry.destination.(Pane_Drop)
	files.carry.destination = next
	drop_ghost_move(app, &files.carry, rect, was_placed && previous.fit == .Fits)
	w.dirty = true
}

// A resting drag over another tab shows it when its moment is up, as a header drag does.
files_drag_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	files, dragging := &w.file_drag.(File_Drag)
	if !dragging {return}
	hover, armed := files.carry.visit.hover.?
	if armed && time.tick_diff(now, hover.at) <= 0 {files_drag_move(app, w, files.pointer.x, files.pointer.y)}
}

// When a resting drag next switches the tab under it.
files_drag_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	files, dragging := &w.file_drag.(File_Drag)
	if !dragging {return {}, false}
	hover, armed := files.carry.visit.hover.?
	return hover.at, armed
}

// Where files dropped at the point land, which the outline shows: what the header drag picks for a pane,
// except that a linked window offers no edge dock, and that a point on no pane or tab falls to the focused
// pane's right.
@(private = "file", require_results)
file_drop_place :: proc(app: ^App, w: ^Window, x, y: f32, tabs: Drop_Tabs) -> Pane_Destination {
	next := pane_drop_place(app, w, x, y, tabs, nil, layout.INVALID_NODE, false, edges = !window_linked(w))
	if next != nil {return next}
	tab, tree := selected_tab(w.workspace), window_tree(w)
	if tab == nil || tree == nil {return nil}
	return Pane_Drop{w.id, tab, .Beside, tree.focus, .Right, .Fits, false}
}

// The rectangle a new pane would take at `drop`, and whether it fits there. A new tab is a tile on the
// strip or a row in the rail; any other place is measured by splitting a copy of the tab, as a drop of a
// pane is (pane_drop_preview).
@(private = "file", require_results)
file_drop_preview :: proc(app: ^App, w: ^Window, drop: Pane_Drop) -> (layout.Rect, Drop_Fit) {
	switch drop.place {
	case .New_Tab:
		panes := [?]layout.Pane_Rect{{content = PANE_MEASUREMENT_CONTENT, rect = window_content_area(app, w)}}
		if !pane_minimum_allows(app, w, panes[:], nil, notify_failure = false) {return {}, .Too_Small}
		return pane_new_tab_ghost(app, w), .Fits
	case .Beside, .Edge:
		tab := drop.tab
		result := pane_trial_split(
			app,
			w,
			drop.direction,
			0.5,
			tree = &tab.tree,
			node = drop.target,
			notify_failure = false,
			edge = drop.place == .Edge,
		)
		#partial switch result.error {
		case .None:
			return result.rect, .Fits
		case .Minimum:
			return result.rect, .Too_Small
		}
	case .Swap, .Region:
	}
	return {}, .Refused
}

// Opens the files the event names where they land: at the drop point, found afresh so a drop needs no
// drag before it.
files_dropped :: proc(app: ^App, w: ^Window, event: platform.Files_Drop_Event) {
	if !gesture_cancel(app, w) {return}
	files_drag_leave_keep_tab(w)
	x, y := f32(event.x), f32(event.y)
	tabs := pane_drop_tabs(app, w, x, y, false)
	drop, placed := file_drop_place(app, w, x, y, tabs).(Pane_Drop)
	if !placed {return}
	_, drop.fit = file_drop_preview(app, w, drop)
	if drop.fit != .Fits {
		pane_drop_refused(app, drop.fit)
		return
	}
	limit := app.settings.pane.drop_limit
	editor := FILE_DROP_EDITOR
	editor_found: Maybe(bool)
	total, opened, unavailable := 0, 0, 0
	rest := event.paths
	for path in strings.split_iterator(&rest, "\n") {
		if path == "" {continue}
		total += 1
		if total > limit {continue}
		switch file_drop_one(app, w, drop, opened == 0, path, &editor, &editor_found) {
		case .Opened:
			opened += 1
		case .Started:
		case .Unavailable:
			unavailable += 1
		case .Refused:
		}
	}
	if unavailable > 0 {target_unavailable(app)}
	if total > limit {
		notify(app, .Warning, fmt.tprintf("Opened the first %d of %d dropped files.", limit, total))
	}
}

// Ends the drag's preview for a drop, which keeps the tab a rest switched to: the user chose to land there.
@(private = "file")
files_drag_leave_keep_tab :: proc(w: ^Window) {
	if _, dragging := w.file_drag.(File_Drag); dragging {
		w.file_drag = nil
		w.dirty = true
	}
}

@(private = "file")
file_drop_one :: proc(
	app: ^App,
	w: ^Window,
	drop: Pane_Drop,
	first: bool,
	path: string,
	editor: ^settings.Opener,
	editor_found: ^Maybe(bool),
) -> File_Drop_Result {
	file, ok := localpath.prepare_open(path)
	if !ok {return .Unavailable}
	defer localpath.open_file_destroy(&file)
	content: layout.Content
	switch {
	case os.is_dir(file.target):
		id, started := session_open(app, "", file.target, file_drop_profile(app, w, drop))
		if !started {
			notify(app, .Error, "Could not open a shell.")
			return .Refused
		}
		content = {.Terminal, id}
	case !file.confirm && markdown_is_path(file.target):
		pane := markdown_pane_create(app, file.target, true)
		if pane == nil {
			notify(app, .Error, "Could not open the file.")
			return .Refused
		}
		content = {.Markdown, pane.id}
	case !file.confirm && html_opens_in_web(app, file.target):
		url, converted := html_file_url(file.target, "")
		pane := converted ? web_pane_create(app, url) : nil
		if pane == nil {
			notify(app, .Error, "Could not open the web pane.")
			return .Refused
		}
		content = {.Web, pane.id}
	case:
		// The first Link Programs entry offered for files, as the link menu lists them (D-088); Neovim when
		// there is none.
		program := file_drop_program(app)
		if program == nil {
			program = editor
			if !file_drop_editor_found(app, editor, editor_found) {return .Refused}
		}
		line, ready := link_program_line(app, program, file.path)
		if !ready {return .Refused}
		directory := filepath.dir(file.path)
		// A program that runs as a window of its own has no pane to place at the outline.
		if program != editor && program.placement == .Own_Window {
			if app.opener.program == nil || !app.opener.program(line, directory) {
				notify(app, .Error, fmt.tprintf("Could not start %s.", program.name))
				return .Refused
			}
			return .Started
		}
		id, started := session_open(app, line, directory, "")
		if !started {
			notify(app, .Error, fmt.tprintf("Could not start %s.", program.name))
			return .Refused
		}
		content = {.Terminal, id}
	}
	if !file_drop_attach(app, w, content, drop, first) {
		pane_content_discard(app, content)
		notify(app, .Error, "Could not open the file.")
		return .Refused
	}
	layout_state_touch(app)
	return .Opened
}

// Shows `content`, which no pane shows yet, at `drop` for the first file, as a dropped pane lands there
// (pane_drop_commit); each further file opens beside the one before it, below it when the drop is above or
// below a pane and to its right otherwise, so the files read in the order they were dropped. A file that
// has no room for a split opens in a new tab.
@(private = "file", require_results)
file_drop_attach :: proc(
	app: ^App,
	w: ^Window,
	content: layout.Content,
	drop: Pane_Drop,
	first: bool,
) -> bool {
	workspace := w.workspace
	if first {
		switch drop.place {
		case .Beside, .Edge:
			tab_index := workspace.selected
			for tab, i in workspace.tabs {if tab == drop.tab {tab_index = i}}
			failure := pane_split_insert(
				app,
				w,
				workspace,
				tab_index,
				drop.target,
				drop.direction,
				0.5,
				true,
				content,
				true,
				drop.place == .Edge,
			)
			return failure == .None
		case .New_Tab:
			return pane_new_tab(app, w, workspace, content, true)
		case .Swap, .Region:
			return false
		}
	}
	tree := window_tree(w)
	if tree == nil {return false}
	below := drop.direction == .Up || drop.direction == .Down
	placement: Pane_Placement = drop.place == .New_Tab ? .Tab : (below ? .Split_Down : .Split_Right)
	return pane_place(
		app,
		w,
		workspace,
		workspace.selected,
		tree.focus,
		content,
		placement,
		true,
		direction = below ? layout.Direction.Down : layout.Direction.Right,
	)
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

// The shell profile of the terminal pane a folder is dropped beside, so it opens in the shell it was dropped
// on; empty for any other pane or none.
@(private = "file")
file_drop_profile :: proc(app: ^App, w: ^Window, drop: Pane_Drop) -> string {
	for shown in w.panes {
		if shown.node != drop.target {continue}
		if entry := workspace_session_for_content(app, shown.content); entry != nil {return entry.profile_id}
	}
	return ""
}

when AIO_CONTROL {
	// The drop target of files being dragged over the window, in the terms the header drag's keys use.
	file_drag_state_report :: proc(r: ^State_Report, w: ^Window) {
		files, dragging := w.file_drag.(File_Drag)
		drop, placed := files.carry.destination.(Pane_Drop)
		target, tab := layout.INVALID_NODE, -1
		ghost: [4]f32
		if dragging && placed {
			target = drop.target
			for t, i in w.workspace.tabs {if t == drop.tab {tab = i}}
			for m, i in files.carry.ghost {ghost[i] = m.target}
			state_word(r, "files.drop.place", drop.place)
			state_word(r, "files.drop.direction", drop.direction)
		} else {
			state_text(r, "files.drop.place", "none")
			state_text(r, "files.drop.direction", "none")
		}
		state_value(r, "files.dragging", dragging)
		state_value(r, "files.drop.shown", dragging && placed && drop.fit == .Fits)
		state_value(r, "files.drop.target", target)
		state_value(r, "files.drop.tab", tab)
		state_value(r, "files.drop.root", dragging && placed && drop.place == .Edge)
		state_value(r, "files.drop.new_tab", dragging && placed && drop.place == .New_Tab)
		state_valuef(r, "files.drop.rect", "%g,%g,%g,%g", ghost[0], ghost[1], ghost[2], ghost[3])
	}
}
