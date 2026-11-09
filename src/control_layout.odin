package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:layout"
import "aio:localpath"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:os"
import "core:path/filepath"

// Opens the tab a layout file describes (WORK-365) in `workspace`, which w shows, or nil when no window
// does, and reports its panes in the file's order. Focus stays put unless --focus. The whole file is
// checked before anything opens, and a pane that cannot open or start its program closes the tab again,
// so a failure leaves nothing behind.
@(private)
control_layout_apply :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	invocation: commands.Invocation,
) -> Outcome {
	file, failure := layout_file_read(app, invocation.file, invocation.directory)
	if failure.status != .Ok {return failure}
	if w != nil && !pane_minimum_single(app, w, notify_failure = false) {
		return outcome_failure(.Failed, "the window is too small for a new pane")
	}
	first := file.columns[0][0]
	id, created := tab_create(app, workspace, first.program, first.directory, first.profile)
	if !created {return outcome_failure(.Failed, "could not create a tab")}
	index := len(workspace.tabs) - 1
	ids := make([][]u32, len(file.columns), context.temp_allocator)
	for column, c in file.columns {ids[c] = make([]u32, len(column), context.temp_allocator)}
	ids[0][0] = id
	message := layout_build(app, w, workspace, index, file, ids)
	tab := workspace.tabs[index]
	if message == "" && file.tab != "" && !tab_name_set(app, workspace, tab, file.tab) {
		message = "could not name the tab"
	}
	if message != "" {
		workspace_close_tab(app, workspace, index)
		return outcome_failure(.Failed, fmt.tprintf("%s: %s", invocation.file, message))
	}
	if w != nil {
		if invocation.focus {
			tab_show(app, w, index)
		} else {
			window_relayout(app, w)
		}
	}
	listed := pane_reports(app, nil)
	reports := make([dynamic]cli_protocol.Pane_Report, 0, commands.LAYOUT_PANES_MAX, context.temp_allocator)
	for column in ids {
		for pane in column {
			for report in listed {if report.id == pane {append(&reports, report)}}
		}
	}
	return {payload = Outcome_Layout(reports[:])}
}

// The layout in the file at `path`, checked against this app: its profiles exist and its directories
// are local. `caller` is the layout's directory when the file names none (WORK-367). Grammar problems
// are usage errors; a missing file, profile or directory fails.
@(private = "file", require_results)
layout_file_read :: proc(app: ^App, path, caller: string) -> (commands.Layout_File, Outcome) {
	if !localpath.local_absolute(path) {
		return {}, outcome_failure(.Usage, fmt.tprintf("%s: use a file on a local drive", path))
	}
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil || info.type != .Regular {
		return {}, outcome_failure(.Failed, fmt.tprintf("%s: no such file", path))
	}
	if info.size > commands.LAYOUT_FILE_SIZE_MAX {
		return {}, outcome_failure(
			.Usage,
			fmt.tprintf("%s: a layout file holds at most %d bytes", path, commands.LAYOUT_FILE_SIZE_MAX),
		)
	}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return {}, outcome_failure(.Failed, fmt.tprintf("%s: could not read the file", path))
	}
	file, invalid := commands.layout_file_parse(data, filepath.dir(path), caller, context.temp_allocator)
	if problem, failed := invalid.?; failed {
		at := problem.field != "" ? fmt.tprintf("%s: %s", path, problem.field) : path
		return {}, outcome_failure(.Usage, fmt.tprintf("%s: %s", at, problem.advice))
	}
	for column, c in file.columns {
		for pane, r in column {
			if pane.profile != "" {
				if _, found := settings.profile_resolve(&app.settings, pane.profile); !found {
					return {}, outcome_failure(
						.Failed,
						fmt.tprintf("%s: columns[%d][%d].profile: no shell profile has that id", path, c, r),
					)
				}
			}
			if _, refused := local_launch_directory(pane.directory); refused {
				return {}, outcome_failure(
					.Failed,
					fmt.tprintf("%s: columns[%d][%d]: %s is not a local directory", path, c, r, pane.directory),
				)
			}
		}
	}
	return file, {}
}

// Opens the rest of a layout's panes in the tab at `tab_index`, whose first pane is ids[0][0], and
// fills in their ids; the message says which pane failed and why. The columns open first, each split
// off the one before; then each column's panes, each split off the one above. Each split gives its new
// pane the share of the panes still to come, so the columns, and the panes of each column, come out
// even, as balancing their runs would leave them.
@(private = "file", require_results)
layout_build :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	file: commands.Layout_File,
	ids: [][]u32,
) -> string {
	if message := layout_pane_ready(app, ids[0][0], file.columns[0][0].name); message != "" {
		return fmt.tprintf("columns[0][0]: %s", message)
	}
	columns := len(file.columns)
	for c in 1 ..< columns {
		share := f32(columns - c) / f32(columns - c + 1)
		message: string
		ids[c][0], message = layout_pane_open(app, w, workspace, tab_index, ids[c - 1][0], .Right, share,
			file.columns[c][0])
		if message != "" {return fmt.tprintf("columns[%d][0]: %s", c, message)}
	}
	for column, c in file.columns {
		for r in 1 ..< len(column) {
			share := f32(len(column) - r) / f32(len(column) - r + 1)
			message: string
			ids[c][r], message = layout_pane_open(app, w, workspace, tab_index, ids[c][r - 1], .Down, share,
				column[r])
			if message != "" {return fmt.tprintf("columns[%d][%d]: %s", c, r, message)}
		}
	}
	return ""
}

// Opens `pane` beside the pane showing session `beside`, giving the new pane `share` of their space;
// the message says why it could not open or start, or be named.
@(private = "file", require_results)
layout_pane_open :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	beside: u32,
	direction: layout.Direction,
	share: f32,
	pane: commands.Layout_Pane,
) -> (
	u32,
	string,
) {
	node := layout.find_content(&workspace.tabs[tab_index].tree, {.Terminal, beside})
	launch := Pane_Launch{pane.program, pane.directory, pane.profile}
	id, err := pane_split_at(app, w, workspace, tab_index, node, direction, share, false, launch, false)
	switch err {
	case .None:
	case .Minimum:
		return 0, "the window is too small for this layout; change Minimum Pane Width and Height"
	case .Check, .Layout:
		return 0, "could not split the pane"
	case .Session:
		return 0, "could not create a pane"
	}
	return id, layout_pane_ready(app, id, pane.name)
}

// Names a layout's new pane; the message says why its program did not start, or it could not be named.
@(private = "file", require_results)
layout_pane_ready :: proc(app: ^App, id: u32, name: string) -> string {
	entry := session_find(app, id)
	if entry == nil {return "could not create a pane"}
	if status := term.status(entry.session); status.kind == .Failed {return status.message}
	if name != "" && rename_target_commit(app, Rename_Pane_Target{id}, name, .Automatic_Title) != .Saved {
		return "could not name the pane"
	}
	return ""
}
