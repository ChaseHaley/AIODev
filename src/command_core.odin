package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:layout"
import "aio:localpath"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:strings"

// The control side of the command core (WORK-038): what a CLI request names and gets back. Every
// interface runs commands through command_execute; a control request passes Control_Request.

// What an invocation produced. Key, palette and pointer invocations report through notices instead.
// Strings and slices are temporary.
Outcome :: struct {
	status:    commands.Status,
	message:   string,
	// The pane a command created, or 0.
	pane:      u32,
	text:      string,
	panes:     []cli_protocol.Pane_Report,
	catalogue: []cli_protocol.Command_Report,
}

// A pane a control invocation acts on, with the identity mutation needs.
Pane_Target :: struct {
	workspace: ^Workspace,
	pane:      Workspace_Pane,
}

@(private)
outcome_failure :: proc(status: commands.Status, message: string) -> Outcome {
	return {status = status, message = message}
}

// Shows a control target's tab in the window showing its workspace.
@(private, require_results)
control_show :: proc(app: ^App, target: Pane_Target) -> (^Window, Outcome) {
	window := window_for_workspace(app, target.workspace)
	if window == nil {
		return nil, outcome_failure(.Failed, "the pane's workspace is not open in a window")
	}
	if window.workspace.selected != target.pane.tab {tab_select(app, window, target.pane.tab)}
	return window, {}
}

// Focuses a control target in its window, as a person would before running `action` there, and
// returns the window that runs it: the linked window when one shows the pane. Nil with an Ok outcome
// means the window declined to run it.
@(private, require_results)
control_focus :: proc(app: ^App, target: Pane_Target, action: Action) -> (^Window, Outcome) {
	window, failure := control_show(app, target)
	if window == nil {return nil, failure}
	pane_focus(app, window, target.pane.node)
	if linked := pane_link_window_of(app, target.pane.content); linked != nil {window = linked}
	return command_window(app, window, action), {}
}

// A pane's status, or how it ended when it has closed since.
@(private)
control_pane_status :: proc(
	app: ^App,
	request: Control_Request,
	invocation: commands.Invocation,
) -> Outcome {
	target, failure := pane_target_resolve(app, invocation.pane, request.caller)
	if failure.status == .Target {
		if closed, found := closed_pane_report(app, invocation.pane, request.caller); found {
			return {panes = closed}
		}
	}
	if failure.status != .Ok {return failure}
	if target.pane.session == nil {return outcome_failure(.Failed, "that pane does not show a terminal")}
	return {panes = pane_reports(app, &target)}
}

// Focuses a pane and brings its window forward; a linked pane's own window takes the focus instead.
@(private)
control_pane_focus :: proc(app: ^App, target: Pane_Target) -> Outcome {
	window, failure := control_show(app, target)
	if window == nil {return failure}
	pane_focus(app, window, target.pane.node)
	if pane_link_window_of(app, target.pane.content) != nil {return {}}
	if !window_activate(app, window) {return outcome_failure(.Failed, "could not bring the window forward")}
	return {}
}

@(private)
control_rename :: proc(app: ^App, target: Pane_Target, name: string) -> Outcome {
	if window_for_workspace(app, target.workspace) == nil {
		return outcome_failure(.Failed, "the pane's workspace is not open in a window")
	}
	entry := target.pane.session
	if entry == nil ||
	   rename_target_commit(app, Rename_Pane_Target{entry.id}, name, .Automatic_Title) != .Saved {
		return outcome_failure(.Failed, "could not rename the pane")
	}
	return {}
}

// Resolves a target: empty means the caller, else the focused pane; `here` is the caller, `focused`
// the focused pane; digits name a pane id, anything else a pane name. An ambiguous name changes
// nothing and lists its matches (D-046).
@(require_results)
pane_target_resolve :: proc(app: ^App, text: string, caller: u32) -> (Pane_Target, Outcome) {
	switch {
	case text == "here", text == "" && caller != 0:
		if caller == 0 {
			return {}, outcome_failure(.Target, "no calling pane: run aio inside an AIODev pane or pass --pane")
		}
		if target, found := pane_target_session(app, caller); found {return target, {}}
		return {}, outcome_failure(.Target, "the calling pane no longer exists; pass --pane")
	case text == "", text == "focused":
		w: ^Window
		for window in app.windows {if window.focused {w = window; break}}
		if w == nil {w = window_primary(app)}
		tree := window_tree(w)
		if w == nil || w.workspace == nil || tree == nil {
			return {}, outcome_failure(.Target, "no window is open")
		}
		// A linked window's workspace is only a view; the pane's identity is in its tab.
		if window_linked(w) {
			if target, found := pane_target_session(app, pane_link_content(w).id); found {return target, {}}
			return {}, outcome_failure(.Target, "the focused window has no pane")
		}
		pane, found := workspace_pane_at(app, w.workspace, w.workspace.selected, tree.focus)
		if !found {return {}, outcome_failure(.Target, "the focused window has no pane")}
		return {w.workspace, pane}, {}
	}
	if id, numeric := pane_id_parse(text); numeric {
		if target, found := pane_target_session(app, id); found {return target, {}}
		return {}, outcome_failure(.Target, "no pane has that id; use aio pane.list")
	}
	match: Pane_Target
	ids := make([dynamic]u32, context.temp_allocator)
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.session == nil || pane.session.name != text {continue}
			match = {workspace, pane}
			append(&ids, pane.session.id)
		}
	}
	switch len(ids) {
	case 0:
		return {}, outcome_failure(.Target, "no pane has that name; use aio pane.list")
	case 1:
		return match, {}
	}
	return {}, outcome_failure(.Target, fmt.tprintf("panes %v share that name; pass an id", ids[:]))
}

// Plain decimal digits that fit a pane id; anything else is a pane name.
@(private, require_results)
pane_id_parse :: proc(text: string) -> (u32, bool) {
	if text == "" || len(text) > 10 {return 0, false}
	value: u64
	for c in transmute([]u8)text {
		if c < '0' || c > '9' {return 0, false}
		value = value * 10 + u64(c - '0')
	}
	return u32(value), value <= u64(max(u32))
}

@(private, require_results)
pane_target_session :: proc(app: ^App, id: u32) -> (Pane_Target, bool) {
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if pane, found := workspace_first_session(app, workspace, id); found {return {workspace, pane}, true}
	}
	return {}, false
}

// Every terminal pane in workspace and tab order, or only `only`'s.
@(private)
pane_reports :: proc(app: ^App, only: ^Pane_Target) -> []cli_protocol.Pane_Report {
	reports := make([dynamic]cli_protocol.Pane_Report, context.temp_allocator)
	for workspace in app.workspaces {
		if workspace.provisional || only != nil && only.workspace != workspace {continue}
		w := window_for_workspace(app, workspace)
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			entry := pane.session
			if entry == nil || only != nil && only.pane.content != pane.content {continue}
			status := term.status(entry.session)
			linked := pane_link_window_of(app, pane.content)
			linked_focus := linked != nil && linked.focused && pane_link_content(linked) == pane.content
			report := cli_protocol.Pane_Report {
				id             = entry.id,
				name           = entry.name,
				title          = pane_header_title(&entry.header),
				process        = string(entry.process_name[:entry.process_name_length]),
				workspace      = workspace.id,
				workspace_name = workspace.name,
				tab            = pane.tab + 1,
				focused        = linked != nil ? linked_focus : w != nil && w.focused &&
					workspace.selected == pane.tab && window_tree(w).focus == pane.node,
				status         = cli_protocol.PANE_STATUS_WORDS[PANE_STATUS[status.kind]],
				exit_code      = status.exit_code,
				directory      = entry.header.launch_directory,
			}
			raw := term.working_directory(entry.session, context.temp_allocator)
			if label, err := localpath.directory_label(raw, context.temp_allocator); err == nil && label != "" {
				report.directory = label
			}
			append(&reports, report)
		}
	}
	return reports[:]
}

// The CLI's word for each terminal status; a pane closed while running reports Closed instead.
@(private, rodata)
PANE_STATUS := [term.Status_Kind]cli_protocol.Pane_Status {
	.Running = .Running,
	.Exited  = .Exited,
	.Failed  = .Failed,
}

// How a pane named by id, or the caller's own, ended after it closed: exited or failed with its
// program, or closed while the program still ran.
@(private)
closed_pane_report :: proc(app: ^App, text: string, caller: u32) -> ([]cli_protocol.Pane_Report, bool) {
	id, valid := pane_id_parse(text)
	if text == "" || text == "here" {id, valid = caller, caller != 0}
	if !valid {return nil, false}
	closed, found := closed_session_find(&app.closed_sessions, id)
	if !found {return nil, false}
	report := make([]cli_protocol.Pane_Report, 1, context.temp_allocator)
	status := closed.status == .Running ? cli_protocol.Pane_Status.Closed : PANE_STATUS[closed.status]
	report[0] = {
		id        = id,
		status    = cli_protocol.PANE_STATUS_WORDS[status],
		exit_code = closed.exit_code,
	}
	return report, true
}

// The pane's visible rows, or its last `lines` rows when lines is positive.
@(private)
pane_read :: proc(entry: ^Session_Entry, lines: int) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane does not show a terminal")}
	rows, err := term.screen_rows(entry.session, context.temp_allocator)
	if err != .None {return outcome_failure(.Failed, "could not read the pane's screen")}
	if lines > 0 && lines < len(rows) {rows = rows[len(rows) - lines:]}
	return {text = strings.join(rows, "\n", context.temp_allocator)}
}

// Types text into the pane's program, then presses Enter when asked, as a person at the keyboard would.
@(private)
pane_send :: proc(entry: ^Session_Entry, text: string, enter: bool) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane does not show a terminal")}
	if entry.status != .Running {return outcome_failure(.Failed, "the pane's program is not running")}
	if text != "" && !term.send_text(entry.session, text) {
		return outcome_failure(.Failed, "the pane is not accepting input")
	}
	if !enter {return {}}
	buffer: [32]u8
	press, press_error := platform.synthesize_key(0, .Enter, {}, true, buffer[:])
	if press_error != .None || !term.send_key(entry.session, press) {
		return outcome_failure(.Failed, "the pane is not accepting input")
	}
	// Only win32-input-mode programs see the release; VT encodings send nothing for it, which
	// send_key reports as false.
	release, release_error := platform.synthesize_key(0, .Enter, {}, false, buffer[:])
	if release_error == .None {_ = term.send_key(entry.session, release)}
	return {}
}

@(private)
control_tab_new :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	invocation: commands.Invocation,
) -> Outcome {
	if failure, ok := control_profile_check(app, invocation.profile); !ok {return failure}
	if w != nil && !pane_minimum_single(app, w, notify_failure = false) {
		return outcome_failure(.Failed, "the window is too small for a new pane")
	}
	id, created := tab_create(app, workspace, invocation.program, invocation.directory, invocation.profile)
	if !created {
		return outcome_failure(.Failed, "could not create a tab")
	}
	if w != nil {
		if invocation.focus {
			tab_show(app, w, len(workspace.tabs) - 1)
		} else {
			window_relayout(app, w)
		}
	}
	return control_created(app, w, id, invocation.name)
}

@(private)
control_split :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	if failure, ok := control_profile_check(app, invocation.profile); !ok {return failure}
	launch := Pane_Launch{invocation.program, invocation.directory, invocation.profile}
	// A linked pane splits in the window showing it, whose tree is the one that decides the new pane's size.
	shown, workspace, tab, node := w, target.workspace, target.pane.tab, target.pane.node
	linked := pane_link_window_of(app, target.pane.content)
	if linked != nil {
		pane_link_reconcile(app, linked)
		shown, workspace, tab = linked, linked.workspace, 0
		node = layout.find_content(window_tree(linked), target.pane.content)
	}
	id, err := pane_split_at(
		app,
		shown,
		workspace,
		tab,
		node,
		invocation.direction,
		invocation.ratio,
		invocation.focus,
		launch,
		false,
	)
	switch err {
	case .None:
		if linked != nil {pane_link_store(app, linked)}
	case .Minimum:
		return outcome_failure(.Failed, "the pane is too small to split; change Minimum Pane Width and Height")
	case .Check, .Layout:
		return outcome_failure(.Failed, "could not split the pane")
	case .Session:
		return outcome_failure(.Failed, "could not create a pane")
	}
	return control_created(app, shown, id, invocation.name)
}

// A shell floating above the target pane's tab, in the target's directory unless one is given.
@(private)
control_floating_new :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	if failure, ok := control_profile_check(app, invocation.profile); !ok {return failure}
	launch := Pane_Launch{invocation.program, invocation.directory, invocation.profile}
	if launch.directory == "" && target.pane.session != nil {
		launch.directory, _ = pane_directory(app, target.pane.session)
	}
	id, ok := floating_open(app, w, target.workspace, target.pane.tab, launch, invocation.focus)
	if !ok {return outcome_failure(.Failed, "could not open a float")}
	return control_created(app, w, id, invocation.name)
}

@(private, require_results)
control_profile_check :: proc(app: ^App, profile: string) -> (Outcome, bool) {
	if profile == "" {return {}, true}
	if _, found := settings.profile_resolve(&app.settings, profile); found {return {}, true}
	return outcome_failure(.Failed, "no shell profile has that id"), false
}

// Names a new pane and reports it, failing when its program could not start; the pane stays open
// either way, so its id is always returned.
@(private)
control_created :: proc(app: ^App, w: ^Window, id: u32, name: string) -> Outcome {
	result := Outcome {
		pane = id,
	}
	entry := session_find(app, id)
	if entry != nil {
		if status := term.status(entry.session); status.kind == .Failed {
			result.status, result.message = .Failed, status.message
			return result
		}
	}
	if name == "" {return result}
	if w == nil || rename_target_commit(app, Rename_Pane_Target{id}, name, .Automatic_Title) != .Saved {
		result.status, result.message = .Failed, "the pane opened but could not be named"
	}
	return result
}

// Every command with its usage, or one command's when `name` is given.
@(private)
command_catalogue :: proc(app: ^App, name: string) -> Outcome {
	reports := make([dynamic]cli_protocol.Command_Report, context.temp_allocator)
	for &command in app.registry.items {
		if name != "" && command.name != name {continue}
		usage := commands.usage(&command, context.temp_allocator)
		append(&reports, cli_protocol.Command_Report{command.name, command.title, usage})
	}
	if name != "" && len(reports) == 0 {return outcome_failure(.Usage, "unknown command; use aio commands")}
	return {catalogue = reports[:]}
}
