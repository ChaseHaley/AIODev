package main

import "aio:commands"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:strings"

// The shared command core (WORK-038). Keys, the palette, pointer controls, the CLI and, later, Lua
// all run commands through command_invoke, so a command behaves the same from every interface.

@(private)
Action_Arguments :: struct {
	accepted, required: commands.Arguments,
	hidden:             bool,
}

// What each command takes beyond its target pane; commands not listed take nothing. Hidden commands
// answer the CLI and scripts and stay out of the palette and shortcut lists.
@(private)
ACTION_ARGUMENTS :: #partial [Action]Action_Arguments {
	.New_Tab      = {accepted = {.Focus, .Directory, .Name, .Profile, .Program}},
	.Split        = {accepted = {.Direction, .Ratio, .Focus, .Directory, .Name, .Profile, .Program}},
	.Rename_Pane  = {accepted = {.Text}},
	.Pane_List    = {hidden = true},
	.Pane_Status  = {hidden = true},
	.Pane_Read    = {accepted = {.Lines}, hidden = true},
	.Pane_Send    = {accepted = {.Text, .Enter}, required = {.Text}, hidden = true},
	.Pane_Focus   = {hidden = true},
	.App_Commands = {accepted = {.Text}, hidden = true},
}

// One terminal pane as the CLI reports it. Strings are temporary.
Pane_Report :: struct {
	id:             u32,
	name, title:    string,
	process:        string,
	workspace:      u32,
	workspace_name: string,
	// The tab's position in its workspace, from 1.
	tab:            int,
	// Whether a window shows this pane focused and that window has keyboard focus.
	focused:        bool,
	status:         string,
	exit_code:      u32,
	directory:      string,
}

Command_Report :: struct {
	name, title, usage: string,
}

// What an invocation produced. Key, palette and pointer invocations report through notices instead.
// Strings and slices are temporary.
Outcome :: struct {
	status:    commands.Status,
	message:   string,
	// The pane a command created, or 0.
	pane:      u32,
	text:      string,
	panes:     []Pane_Report,
	catalogue: []Command_Report,
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

// Runs an action from a window's own controls. Those report failures as notices, so the outcome
// carries nothing for them.
command_run :: proc(app: ^App, w: ^Window, action: Action, origin: commands.Origin) {
	_ = command_invoke(app, w, commands.invocation(commands.Command_Id(action), origin))
}

// Runs one command for any interface. Key, palette and pointer invocations act on the focus of `w`.
// Control invocations name a target pane, defaulting to `caller`, the pane the request came from, and
// need no window; commands with no targeted form first focus their target in its window.
@(require_results)
command_invoke :: proc(
	app: ^App,
	w: ^Window,
	invocation: commands.Invocation,
	caller: u32 = 0,
) -> Outcome {
	action := Action(invocation.id)
	if invocation.origin != .Control {
		run_action(app, w, action, invocation.direction, invocation.ratio, invocation.focus)
		return {}
	}
	if commands.find(&app.registry, invocation.id) == nil {
		return outcome_failure(.Usage, "unknown command; use aio commands")
	}
	#partial switch action {
	case .App_Commands:
		return command_catalogue(app, invocation.text)
	case .Pane_List:
		return {panes = pane_reports(app, nil)}
	}
	target, failure := pane_target_resolve(app, invocation.pane, caller)
	if failure.status == .Target && action == .Pane_Status {
		if closed, found := closed_pane_report(app, invocation.pane, caller); found {return {panes = closed}}
	}
	if failure.status != .Ok {return failure}
	window := window_for_workspace(app, target.workspace)
	entry := target.pane.session
	#partial switch action {
	case .Pane_Status:
		if entry == nil {return outcome_failure(.Failed, "that pane shows Settings, not a terminal")}
		return {panes = pane_reports(app, &target)}
	case .Pane_Read:
		return pane_read(entry, invocation.lines)
	case .Pane_Send:
		return pane_send(entry, invocation.text, invocation.enter)
	case .Close_Pane:
		pane_remove(app, target.workspace, target.pane.tab, target.pane.node)
		return {}
	case .New_Tab:
		return control_tab_new(app, window, target.workspace, invocation)
	case .Split:
		return control_split(app, window, target, invocation)
	}
	if window == nil {return outcome_failure(.Failed, "the pane's workspace is not open in a window")}
	if action == .Rename_Pane && .Text in invocation.given {
		if rename_target_commit(app, window, {.Pane, target.pane.content.id}, invocation.text) != .Saved {
			return outcome_failure(.Failed, "could not rename the pane")
		}
		return {}
	}
	if window.workspace.selected != target.pane.tab {tab_select(app, window, target.pane.tab)}
	pane_focus(app, window, target.pane.node)
	if action == .Pane_Focus {
		if !window_activate(app, window) {return outcome_failure(.Failed, "could not bring the window forward")}
		return {}
	}
	run_action(app, window, action, invocation.direction, invocation.ratio, invocation.focus)
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
		if w == nil && len(app.windows) > 0 {w = app.windows[0]}
		if w == nil || w.workspace == nil || w.tree == nil {
			return {}, outcome_failure(.Target, "no window is open")
		}
		pane, found := workspace_pane_at(app, w.workspace, w.workspace.selected, w.tree.focus)
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
pane_reports :: proc(app: ^App, only: ^Pane_Target) -> []Pane_Report {
	reports := make([dynamic]Pane_Report, context.temp_allocator)
	for workspace in app.workspaces {
		if workspace.provisional || only != nil && only.workspace != workspace {continue}
		w := window_for_workspace(app, workspace)
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			entry := pane.session
			if entry == nil || only != nil && only.pane.content != pane.content {continue}
			status := term.status(entry.session)
			report := Pane_Report {
				id             = entry.id,
				name           = entry.name,
				title          = pane_header_title(&entry.header),
				process        = string(entry.process_name[:entry.process_name_length]),
				workspace      = workspace.id,
				workspace_name = workspace.name,
				tab            = pane.tab + 1,
				focused        = w != nil && w.focused && workspace.selected == pane.tab &&
					w.tree.focus == pane.node,
				status         = PANE_STATUS_WORDS[status.kind],
				exit_code      = status.exit_code,
				directory      = entry.header.launch_directory,
			}
			raw := term.working_directory(entry.session, context.temp_allocator)
			if label, err := settings.directory_label(raw, context.temp_allocator); err == nil && label != "" {
				report.directory = label
			}
			append(&reports, report)
		}
	}
	return reports[:]
}

@(private, rodata)
PANE_STATUS_WORDS := [term.Status_Kind]string {
	.Running = "running",
	.Exited  = "exited",
	.Failed  = "failed",
}

// How a pane named by id, or the caller's own, ended after it closed: exited or failed with its
// program, or closed while the program still ran.
@(private)
closed_pane_report :: proc(app: ^App, text: string, caller: u32) -> ([]Pane_Report, bool) {
	id, valid := pane_id_parse(text)
	if text == "" || text == "here" {id, valid = caller, caller != 0}
	if !valid {return nil, false}
	for offset in 1 ..= len(app.closed_sessions) {
		index := (app.closed_next - offset + len(app.closed_sessions)) % len(app.closed_sessions)
		closed := app.closed_sessions[index]
		if closed.id != id || id == 0 {continue}
		report := make([]Pane_Report, 1, context.temp_allocator)
		report[0] = {
			id        = id,
			status    = closed.status == .Running ? "closed" : PANE_STATUS_WORDS[closed.status],
			exit_code = closed.exit_code,
		}
		return report, true
	}
	return nil, false
}

// The pane's visible rows, or its last `lines` rows when lines is positive.
@(private)
pane_read :: proc(entry: ^Session_Entry, lines: int) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane shows Settings, not a terminal")}
	rows, err := term.screen_rows(entry.session, context.temp_allocator)
	if err != .None {return outcome_failure(.Failed, "could not read the pane's screen")}
	if lines > 0 && lines < len(rows) {rows = rows[len(rows) - lines:]}
	return {text = strings.join(rows, "\n", context.temp_allocator)}
}

// Types text into the pane's program, then presses Enter when asked, as a person at the keyboard would.
@(private)
pane_send :: proc(entry: ^Session_Entry, text: string, enter: bool) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane shows Settings, not a terminal")}
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
	if !tab_create(app, workspace, invocation.program, invocation.directory, invocation.profile) {
		return outcome_failure(.Failed, "could not create a tab")
	}
	id := app.next_session_id
	if w != nil {
		if invocation.focus {
			tab_select(app, w, len(workspace.tabs) - 1)
			rail_overlay_dismiss(app, w)
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
	id, err := pane_split_at(
		app,
		w,
		target.workspace,
		target.pane.tab,
		target.pane.node,
		invocation.direction,
		invocation.ratio,
		invocation.focus,
		launch,
		false,
	)
	switch err {
	case .None:
	case .Minimum:
		return outcome_failure(.Failed, "the pane is too small to split; change Minimum Pane Width and Height")
	case .Check, .Layout:
		return outcome_failure(.Failed, "could not split the pane")
	case .Session:
		return outcome_failure(.Failed, "could not create a pane")
	}
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
	if w == nil || rename_target_commit(app, w, {.Pane, id}, name) != .Saved {
		result.status, result.message = .Failed, "the pane opened but could not be named"
	}
	return result
}

// Every command with its usage, or one command's when `name` is given.
@(private)
command_catalogue :: proc(app: ^App, name: string) -> Outcome {
	reports := make([dynamic]Command_Report, context.temp_allocator)
	for &command in app.registry.items {
		if name != "" && command.name != name {continue}
		usage := commands.usage(&command, context.temp_allocator)
		append(&reports, Command_Report{command.name, command.title, usage})
	}
	if name != "" && len(reports) == 0 {return outcome_failure(.Usage, "unknown command; use aio commands")}
	return {catalogue = reports[:]}
}
