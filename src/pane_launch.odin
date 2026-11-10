package main

import "aio:commands"
import "aio:layout"
import "aio:localpath"
import "aio:procinfo"
import "aio:pty"
import "aio:term"

pane_split :: proc(
	app: ^App,
	w: ^Window,
	direction: layout.Direction,
	ratio: f32 = commands.SPLIT_DEFAULT.ratio,
	focus := commands.SPLIT_DEFAULT.focus,
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

// Where new content opens beside the pane that asked for it.
Pane_Placement :: enum u8 {
	// A split beside the pane, or a new tab when the pane is too small to split.
	Split_Right,
	Split_Down,
	// A floating pane above the tab.
	Float,
	Tab,
	// A split that moves straight into a linked window of its own.
	Linked_Window,
}

// The window that places beside the pane at `node` of w, and the pane there to place beside. A split stays
// in w, linked or not; anything else belongs to the window showing the tab, beside its focused pane.
@(require_results)
pane_placement_window :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	placement: Pane_Placement,
) -> (
	acting: ^Window,
	beside: layout.Node_Id,
	found: bool,
) {
	if !window_linked(w) || placement == .Split_Right || placement == .Split_Down {return w, node, true}
	acting = pane_link_acting_window(app, w)
	if window_linked(acting) {return nil, layout.INVALID_NODE, false}
	return acting, window_tree(acting).focus, true
}

// Starts a shell with `launch` at `placement` beside the pane at `node` of w, as pane_placement_window
// chooses the window.
@(require_results)
shell_open_placed :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	launch: Pane_Launch,
	placement: Pane_Placement,
) -> bool {
	acting, beside, found := pane_placement_window(app, w, node, placement)
	if !found {return false}
	id, opened := session_open(app, launch.command, launch.directory, launch.profile)
	if !opened {return false}
	tab := acting.workspace.selected
	if pane_place(app, acting, acting.workspace, tab, beside, {.Terminal, id}, placement, true) {return true}
	session_close(app, id)
	return false
}

// Shows `content`, which no pane shows yet, beside `node` of the workspace's tab at `tab_index`. A split
// goes toward `direction` when given, else the side its placement names. w is the window showing the
// workspace, or nil; a linked window placement needs w showing that tab.
@(require_results)
pane_place :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	content: layout.Content,
	placement: Pane_Placement,
	focus: bool,
	ratio := commands.SPLIT_DEFAULT.ratio,
	direction: Maybe(layout.Direction) = nil,
) -> bool {
	tree := &workspace.tabs[tab_index].tree
	// A floating pane does not split, so the content opens beside the tiled pane below it.
	anchor := node
	if layout.is_floating(tree, anchor) {anchor = layout.focus_tiled(tree)}
	side := direction.? or_else (placement == .Split_Down ? layout.Direction.Down : layout.Direction.Right)
	opened := false
	switch placement {
	case .Split_Right, .Split_Down:
		failure := pane_split_insert(app, w, workspace, tab_index, anchor, side, ratio, focus, content, false)
		#partial switch failure {
		case .None:
			opened = true
		case .Minimum:
			opened = pane_new_tab(app, w, workspace, content, focus)
		}
	case .Float:
		opened = floating_attach(app, w, workspace, tab_index, content, focus)
	case .Tab:
		opened = pane_new_tab(app, w, workspace, content, focus)
	case .Linked_Window:
		if w == nil || window_linked(w) || w.workspace != workspace || workspace.selected != tab_index {break}
		// The new pane leaves for its own window at once, so it needs no room in this one.
		failure := pane_split_insert(app, nil, workspace, tab_index, anchor, side, ratio, false, content, false)
		if failure != .None {break}
		// A refused link leaves the content showing in the split, which the notice explains.
		opened = true
		if !pane_link_open(app, w, layout.find_content(tree, content)) {window_relayout(app, w)}
	}
	if opened {layout_state_touch(app)}
	return opened
}

// A new tab holding `content`, which no pane shows yet; with focus, w shows it.
@(private, require_results)
pane_new_tab :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	content: layout.Content,
	focus: bool,
) -> bool {
	tab, reserved := tab_record_reserve(workspace)
	if !reserved {return false}
	if layout.init(&tab.tree, content) != nil {
		tab_record_free(tab)
		return false
	}
	tab_record_commit(app, workspace, tab)
	if focus && w != nil {tab_select(app, w, len(workspace.tabs) - 1)}
	return true
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
	// The panes of a tab in view ease apart to make room; a split that switches tabs shows at once.
	if visible {pane_motion_arm(w, .Split)}
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
