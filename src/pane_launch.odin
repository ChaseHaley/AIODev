package main

import "aio:layout"
import "aio:localpath"
import "aio:pty"
import "aio:settings"
import "aio:term"

pane_split :: proc(
	app: ^App,
	w: ^Window,
	direction: layout.Direction,
	ratio: f32 = 0.5,
	focus := true,
) {
	tab := w.workspace.selected
	launch: Pane_Launch
	if entry := focused_session(app, w); entry != nil {
		refused: bool
		launch.directory, refused = pane_directory(app, entry)
		if refused {notify_directory_refused(app)}
	}
	switch _, err := pane_split_at(
		app, w, w.workspace, tab, window_tree(w).focus, direction, ratio, focus, launch, true,
	); err {
	case .None:
		if window_linked(w) {pane_link_store(app, w)}
	case .Minimum:
	case .Check:
		notify(app, .Error, "Could not check the new pane size.")
	case .Session:
		notify(app, .Error, "Could not create a pane.")
	case .Layout:
		notify(app, .Error, "Could not split the pane.")
	}
}

// What a new pane runs; empty fields take the profile's or settings' values.
Pane_Launch :: struct {
	command, directory, profile: string,
}

Pane_Split_Error :: enum {
	None,
	Minimum, // The new pane would be smaller than the minimum pane size.
	Check,   // The size check itself failed.
	Session,
	Layout,
}

// Splits `node` of the workspace's tab at `tab_index` and returns the new pane's session id. w shows
// the workspace, or is nil when no window does; only a shown tab is relaid out, and focus selects the
// tab first.
@(require_results)
pane_split_at :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	direction: layout.Direction,
	ratio: f32,
	focus: bool,
	launch: Pane_Launch,
	notify_minimum: bool,
) -> (
	u32,
	Pane_Split_Error,
) {
	tab := workspace.tabs[tab_index]
	if failure := pane_split_check(app, w, tab, node, direction, ratio, notify_minimum); failure != .None {
		return 0, failure
	}
	id, opened := session_open(app, launch.command, launch.directory, launch.profile)
	if !opened {return 0, .Session}
	if !pane_split_attach(app, w, workspace, tab_index, node, direction, ratio, focus, {.Terminal, id}) {
		session_close(app, id)
		return 0, .Layout
	}
	return id, .None
}

// Splits `node` with content that exists already. See pane_split_at for how w and focus apply.
@(require_results)
pane_split_insert :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	direction: layout.Direction,
	ratio: f32,
	focus: bool,
	content: layout.Content,
	notify_minimum: bool,
) -> Pane_Split_Error {
	tab := workspace.tabs[tab_index]
	if failure := pane_split_check(app, w, tab, node, direction, ratio, notify_minimum); failure != .None {
		return failure
	}
	if !pane_split_attach(app, w, workspace, tab_index, node, direction, ratio, focus, content) {return .Layout}
	return .None
}

@(private, require_results)
pane_split_check :: proc(
	app: ^App,
	w: ^Window,
	tab: ^Tab,
	node: layout.Node_Id,
	direction: layout.Direction,
	ratio: f32,
	notify_minimum: bool,
) -> Pane_Split_Error {
	if w == nil {return .None}
	trial := pane_trial_split(app, w, direction, ratio, tree = &tab.tree, node = node,
		notify_failure = notify_minimum)
	if trial.error == .Minimum {return .Minimum}
	if trial.error != .None {return .Check}
	return .None
}

@(private, require_results)
pane_split_attach :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	direction: layout.Direction,
	ratio: f32,
	focus: bool,
	content: layout.Content,
) -> bool {
	tab := workspace.tabs[tab_index]
	added, err := layout.split_direction(&tab.tree, node, direction, ratio, content)
	if err != nil {return false}
	if w == nil {return true}
	visible := workspace.selected == tab_index
	if focus {
		if !visible {tab_select(app, w, tab_index)}
		pane_focus(app, w, added)
	}
	if visible || focus {window_relayout(app, w)}
	return true
}

// The app's one launch-directory choice: session open, restore, shell switch and pane directories pick
// through it, without touching a remote path twice. `refused` reports that a nonempty candidate was
// rejected, so the caller can say why a different directory is used; each caller words that itself.
// An empty result means the profile's own directory. pty.spawn still checks again (defense in depth).
@(require_results)
local_launch_directory :: proc(candidate, fallback: string) -> (directory: string, refused: bool) {
	if candidate != "" {
		if pty.working_directory_is_local(candidate) {return candidate, false}
		refused = true
	}
	if fallback != "" && pty.working_directory_is_local(fallback) {return fallback, refused}
	return "", refused
}

// Where a split or duplicate of the pane starts. As in kitty, a running program's own directory
// wins over the shell's last OSC 7 report, which predates the program; then the shell process's
// directory, which cmd and bash keep current, and finally where the pane was launched. `refused`
// reports a reported directory that was remote or unavailable.
@(require_results)
pane_directory :: proc(app: ^App, entry: ^Session_Entry) -> (directory: string, refused: bool) {
	return pane_directory_of(entry, pane_program(app, entry, term.process_id(entry.session)))
}

// pane_directory for a pane whose running program, if any, is already known.
@(require_results)
pane_directory_of :: proc(entry: ^Session_Entry, program: u32) -> (directory: string, refused: bool) {
	root := term.process_id(entry.session)
	if program != 0 {
		path, found := pty.process_directory(program, root, context.temp_allocator)
		if found && pty.working_directory_is_local(path) {return path, false}
	}
	raw := term.working_directory(entry.session, context.temp_allocator)
	if reported, err := localpath.directory_label(raw, context.temp_allocator); err == nil && reported != "" {
		if pty.working_directory_is_local(reported) {return reported, false}
		refused = true
	}
	path, ok := pty.process_directory(root, root, context.temp_allocator)
	if ok && pty.working_directory_is_local(path) {return path, refused}
	directory, _ = local_launch_directory("", entry.header.launch_directory)
	return directory, refused
}

// The pane's running program. Icon polling already tracks it, including one seen once but not yet
// adopted; without polling it is chosen the same way from a snapshot taken now (about 10 ms).
@(private)
pane_program :: proc(app: ^App, entry: ^Session_Entry, root: u32) -> u32 {
	if app.settings.tabs.program_icons {
		return program_polled(entry)
	}
	processes, err := pty.process_snapshot(context.temp_allocator)
	if err != .None {return 0}
	program, _ := pane_running(app, entry, processes)
	return program
}

// The processes to read running programs from when a pane is remembered: nil while icon polling
// tracks them, otherwise one snapshot taken now, in temporary memory.
pane_processes :: proc(app: ^App) -> []pty.Process_Info {
	if app.settings.tabs.program_icons || len(app.sessions) == 0 {return nil}
	processes, err := pty.process_snapshot(context.temp_allocator)
	return err == .None ? processes : nil
}

// The pane's running program and how it was started, in temporary memory: polling's choice, or the
// one `processes` names; none without either.
pane_running :: proc(
	app: ^App,
	entry: ^Session_Entry,
	processes: []pty.Process_Info,
) -> (
	program: u32,
	command: string,
) {
	if app.settings.tabs.program_icons {
		if adopted := program_adopted(entry); adopted != nil {command = adopted.command}
		return program_polled(entry), command
	}
	root := term.process_id(entry.session)
	index := pty.process_program(processes, root, program_reporters(entry), 0)
	if index < 0 {return}
	program = processes[index].id
	arguments, _ := pty.process_arguments(program, root, context.temp_allocator)
	stem := settings.executable_stem(processes[index].executable)
	return program, program_command(arguments, stem, context.temp_allocator)
}

@(private)
notify_directory_refused :: proc(app: ^App) {
	notify(app, .Warning, "The pane's reported directory is remote or unavailable; using a local fallback.")
}
