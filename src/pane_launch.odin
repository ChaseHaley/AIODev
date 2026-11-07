package main

import "aio:layout"
import "aio:localpath"
import "aio:procinfo"
import "aio:pty"
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

// A linked window's copy only arranges its slot, so its new pane joins the slot in the tab's tree.
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
	if w != nil && window_linked(w) {return pane_link_split(app, w, node, direction, ratio, focus, content)}
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
local_launch_directory :: proc(candidate: string) -> (directory: string, refused: bool) {
	if candidate != "" {
		if pty.working_directory_is_local(candidate) {return candidate, false}
		refused = true
	}
	return "", refused
}

// Where a split or duplicate of the pane starts. As in kitty, a running program's own directory
// wins over the shell's last OSC 7 report, which predates the program; then the shell process's
// directory, which cmd and bash keep current, and finally where the pane was launched. `refused`
// reports a reported directory that was remote or unavailable.
@(require_results)
pane_directory :: proc(app: ^App, entry: ^Session_Entry) -> (directory: string, refused: bool) {
	return pane_directory_of(entry, pane_program(app, entry))
}

// pane_directory for a pane whose running program, if any, is already known.
@(require_results)
pane_directory_of :: proc(entry: ^Session_Entry, program: u32) -> (directory: string, refused: bool) {
	root := term.process_id(entry.session)
	if program != 0 {
		path, found := procinfo.process_directory(program, root, context.temp_allocator)
		if found && pty.working_directory_is_local(path) {return path, false}
	}
	raw := term.working_directory(entry.session, context.temp_allocator)
	if reported, err := localpath.directory_label(raw, context.temp_allocator); err == nil && reported != "" {
		if pty.working_directory_is_local(reported) {return reported, false}
		refused = true
	}
	path, ok := procinfo.process_directory(root, root, context.temp_allocator)
	if ok && pty.working_directory_is_local(path) {return path, refused}
	if launch := entry.header.launch_directory; launch != "" && pty.working_directory_is_local(launch) {
		directory = launch
	}
	return directory, refused
}

@(private)
notify_directory_refused :: proc(app: ^App) {
	notify(app, .Warning, "The pane's reported directory is remote or unavailable; using a local fallback.")
}
