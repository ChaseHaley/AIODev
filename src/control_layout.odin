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
	file: commands.Layout_File
	source := invocation.file
	if .Layout in invocation.given {
		source = "--layout"
		invalid: Maybe(commands.Layout_Error)
		file, invalid = commands.layout_file_parse(transmute([]u8)invocation.layout, invocation.directory,
			invocation.directory, context.temp_allocator)
		if problem, failed := invalid.?; failed {
			return outcome_failure(.Usage, fmt.tprintf("--layout: %s: %s", problem.field, problem.advice))
		}
	} else {
		failure: Outcome
		file, failure = layout_file_read(invocation.file, invocation.directory)
		if failure.status != .Ok {return failure}
	}
	specs := layout_document_panes(file)
	for spec in specs {
		pane := spec.pane
		if pane.profile != "" {
			if _, found := settings.profile_resolve(&app.settings, pane.profile); !found {
				return outcome_failure(.Failed,
					fmt.tprintf("%s: %s.profile: no shell profile has that id", source, spec.field))
			}
		}
		if _, refused := local_launch_directory(pane.directory); refused {
			return outcome_failure(.Failed,
				fmt.tprintf("%s: %s: %s is not a local directory", source, spec.field, pane.directory))
		}
	}
	// Cell bounds need window geometry; reject before creating any pane.
	bounds := make([]layout.Rect, len(file.floats), context.temp_allocator)
	for floating, i in file.floats {
		failure: Outcome
		bounds[i], failure = control_float_bounds(w, floating.bounds, floating.cells)
		if failure.status != .Ok {return failure}
	}
	if w != nil && !pane_minimum_single(app, w, notify_failure = false) {
		return outcome_failure(.Failed, "the window is too small for a new pane")
	}
	first := specs[0].pane
	id, created := tab_create(app, workspace, first.program, first.directory, first.profile)
	if !created {return outcome_failure(.Failed, "could not create a tab")}
	index := len(workspace.tabs) - 1
	opened := make([dynamic]u32, 0, commands.LAYOUT_PANES_MAX, context.temp_allocator)
	message: string
	if file.root != nil {
		message = layout_tree_build(app, w, workspace, index, file.root, id, &opened)
	} else {
		ids := make([][]u32, len(file.columns), context.temp_allocator)
		for column, c in file.columns {ids[c] = make([]u32, len(column), context.temp_allocator)}
		ids[0][0] = id
		message = layout_build(app, w, workspace, index, file, ids)
		for column in ids {append(&opened, ..column)}
	}
	if message == "" {
		for floating, i in file.floats {
			launch := Pane_Launch{floating.pane.program, floating.pane.directory, floating.pane.profile}
			float_id, ok := floating_open(app, w, workspace, index, launch, false)
			if !ok {
				message = fmt.tprintf("floats[%d]: could not open a float", i)
				break
			}
			append(&opened, float_id)
			tree := &workspace.tabs[index].tree
			_ = layout.float_set_bounds(tree, layout.find_content(tree, {.Terminal, float_id}), bounds[i])
			if ready := layout_pane_ready(app, float_id, floating.pane.name); ready != "" {
				message = fmt.tprintf("floats[%d].pane: %s", i, ready)
				break
			}
		}
	}
	tab := workspace.tabs[index]
	if message == "" && file.tab != "" && !tab_name_set(app, workspace, tab, file.tab) {
		message = "could not name the tab"
	}
	if message != "" {
		workspace_close_tab(app, workspace, index)
		return outcome_failure(.Failed, fmt.tprintf("%s: %s", source, message))
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
	for pane in opened {
		for report in listed {if report.id == pane {append(&reports, report)}}
	}
	return {payload = Outcome_Layout(reports[:])}
}

// Reads the local layout file before application validates its profiles and launch directories.
// Without a document cwd, caller supplies the layout's directory (WORK-367).
@(private = "file", require_results)
layout_file_read :: proc(path, caller: string) -> (commands.Layout_File, Outcome) {
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
			fmt.tprintf(
				"%s: a layout file holds at most %s",
				path,
				size_limit_text(commands.LAYOUT_FILE_SIZE_MAX),
			),
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
		return 0,
			`the window is too small for this layout; change "Minimum pane width" and "Minimum pane height" ` +
			"in Settings"
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

@(private = "file")
Layout_Pane_Spec :: struct {
	pane:  commands.Layout_Pane,
	field: string,
}

@(private = "file")
layout_document_panes :: proc(file: commands.Layout_File) -> []Layout_Pane_Spec {
	specs := make([dynamic]Layout_Pane_Spec, 0, commands.LAYOUT_PANES_MAX, context.temp_allocator)
	if file.root != nil {
		layout_tree_panes(file.root, "root", &specs)
	} else {
		for column, c in file.columns {
			for pane, r in column {append(&specs, Layout_Pane_Spec{pane, fmt.tprintf("columns[%d][%d]", c, r)})}
		}
	}
	for floating, i in file.floats {
		append(&specs, Layout_Pane_Spec{floating.pane, fmt.tprintf("floats[%d].pane", i)})
	}
	return specs[:]
}

@(private = "file")
layout_tree_panes :: proc(node: ^commands.Layout_Node, field: string, specs: ^[dynamic]Layout_Pane_Spec) {
	if !node.split {
		append(specs, Layout_Pane_Spec{node.pane, field})
		return
	}
	layout_tree_panes(node.first, fmt.tprintf("%s.first", field), specs)
	layout_tree_panes(node.second, fmt.tprintf("%s.second", field), specs)
}

@(private = "file")
layout_tree_first :: proc(node: ^commands.Layout_Node) -> commands.Layout_Pane {
	at := node
	for at.split {at = at.first}
	return at.pane
}

// Wrap before descending, so each document ratio belongs to the corresponding whole subtree.
@(private = "file", require_results)
layout_tree_build :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: ^commands.Layout_Node,
	first: u32,
	opened: ^[dynamic]u32,
) -> string {
	if !node.split {
		append(opened, first)
		return layout_pane_ready(app, first, node.pane.name)
	}
	second, message := layout_pane_open(app, w, workspace, tab_index, first, node.direction,
		1 - node.ratio, layout_tree_first(node.second))
	if message != "" {return message}
	if failed := layout_tree_build(app, w, workspace, tab_index, node.first, first, opened); failed != "" {
		return failed
	}
	return layout_tree_build(app, w, workspace, tab_index, node.second, second, opened)
}

// Bounds in cells are relative to the floating area, not the terminal's padded content box.
@(private, require_results)
control_float_bounds :: proc(w: ^Window, bounds: layout.Rect, cells: bool) -> (layout.Rect, Outcome) {
	if !cells {return layout.float_bounds_clamp(bounds), {}}
	if w == nil {return {}, outcome_failure(.Failed, "cell bounds need a window showing the workspace")}
	area := floating_area(w)
	if area.width <= 0 || area.height <= 0 || w.metrics.cell_width <= 0 || w.metrics.cell_height <= 0 {
		return {}, outcome_failure(.Failed, "the window has no cell geometry")
	}
	return layout.float_bounds_clamp({
		bounds.x * w.metrics.cell_width / area.width,
		bounds.y * w.metrics.cell_height / area.height,
		bounds.width * w.metrics.cell_width / area.width,
		bounds.height * w.metrics.cell_height / area.height,
	}), {}
}

// A background edit changes the tab, not the selected tab or the window's focus.
@(private)
control_layout_changed :: proc(app: ^App, w: ^Window, workspace: ^Workspace, tab: int, floats: bool) {
	layout_state_touch(app)
	if w == nil || w.workspace != workspace || workspace.selected != tab {return}
	if floats {window_floats_layout(app, w)} else {window_relayout(app, w)}
}

@(private)
control_float_change :: proc(
	app: ^App,
	target: Pane_Target,
	invocation: commands.Invocation,
	action: Action,
) -> Outcome {
	tree := &target.workspace.tabs[target.pane.tab].tree
	node := target.pane.node
	if !layout.is_floating(tree, node) {
		return outcome_failure(.Failed, fmt.tprintf("%d is not floating", target.pane.content.id))
	}
	w := window_for_workspace(app, target.workspace)
	bounds: layout.Rect
	if action == .Float_Set_Bounds {
		failure: Outcome
		bounds, failure = control_float_bounds(w, invocation.bounds, invocation.unit == "cells")
		if failure.status != .Ok {return failure}
	}
	shown := w != nil && target.workspace.selected == target.pane.tab
	if shown {focus_leave(app, w)}
	#partial switch action {
	case .Float_Set_Bounds:
		_ = layout.float_set_bounds(tree, node, bounds)
	case .Float_Raise:
		_ = layout.float_restack(tree, node, true)
	case .Float_Lower:
		_ = layout.float_restack(tree, node, false)
	case .Float_Dock:
		if !layout.set_floating(tree, node, false) {
			if shown {focus_enter(app, w)}
			return outcome_failure(.Failed, "could not dock the float")
		}
	case .Float_Minimize:
		_ = layout.float_minimize(tree, node, true)
	case .Float_Restore:
		_ = layout.float_minimize(tree, node, false)
	}
	control_layout_changed(app, w, target.workspace, target.pane.tab, action != .Float_Dock)
	if shown {focus_enter(app, w)}
	// Focusing a minimized float would immediately undo the explicit minimize.
	if invocation.focus && action != .Float_Minimize {return control_pane_focus(app, target)}
	return {}
}

@(private)
control_pane_layout_change :: proc(
	app: ^App,
	target: Pane_Target,
	invocation: commands.Invocation,
	action: Action,
) -> Outcome {
	tree := &target.workspace.tabs[target.pane.tab].tree
	w := window_for_workspace(app, target.workspace)
	node := target.pane.node
	#partial switch action {
	case .Pane_Move:
		beside, failure := pane_target_resolve(app, invocation.beside, 0)
		if failure.status != .Ok {return failure}
		if beside.workspace != target.workspace || beside.pane.tab != target.pane.tab {
			return outcome_failure(.Failed, "panes must be in the same tab")
		}
		moved, ok := layout.move_pane(tree, node, beside.pane.node, invocation.direction)
		if !ok {return outcome_failure(.Failed, "could not move the pane")}
		node = moved
	case .Pane_Resize:
		if w == nil {return outcome_failure(.Failed, "cell resizing needs a window showing the workspace")}
		axis, before := layout.direction_parts(invocation.direction)
		pixels := f32(invocation.cells) * (axis == .Horizontal ? w.metrics.cell_width : w.metrics.cell_height)
		if before {pixels = -pixels}
		dividers := make([dynamic]layout.Divider, context.temp_allocator)
		layout.dividers_shown(tree, window_geometry(app, w, .None), false, &dividers)
		if !layout.resize_pixels(tree, node, axis, pixels, dividers[:]) {
			return outcome_failure(.Failed, "the pane has no border in that direction")
		}
	case .Pane_Set_Ratio:
		if !layout.set_ratio(tree, node, invocation.ratio) {
			return outcome_failure(.Failed, "the pane has no parent split")
		}
	}
	control_layout_changed(app, w, target.workspace, target.pane.tab, false)
	if invocation.focus {
		focused := target
		focused.pane.node = node
		return control_pane_focus(app, focused)
	}
	return {}
}
