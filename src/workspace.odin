package main

import "aio:layout"
import "aio:platform"
import "aio:pty"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:strings"

Tab :: struct {
	id: u32,
	marked: bool,
	tree: layout.Layout,
	title: string,
	name: string,
}

Workspace :: struct {
	provisional: bool, // A tear-off preview borrows a runtime until the drop commits.
	id: u32,
	name: string,
	icon: Workspace_Icon,
	tabs: [dynamic]^Tab,
	selected: int,
	next_tab_id: u32,
	selection_anchor: u32,
	settings_scroll: int,
}

@(require_results)
workspace_default_name :: proc(app: ^App) -> string {
	adjectives := [?]string{
		"Quiet", "Bright", "Gentle", "Brave", "Curious", "Happy", "Misty", "Sunny",
		"Calm", "Clever", "Cozy", "Daring", "Distant", "Dreamy", "Eager", "Fair",
		"Friendly", "Hidden", "Jolly", "Kind", "Lively", "Lucky", "Merry", "Nimble",
		"Peaceful", "Playful", "Quick", "Soft", "Still", "Swift", "Warm", "Wild",
	}
	colors := [?]string{
		"Amber", "Azure", "Blue", "Bronze", "Coral", "Crimson", "Emerald", "Golden",
		"Green", "Indigo", "Ivory", "Jade", "Lavender", "Lilac", "Lime", "Maroon",
		"Mint", "Olive", "Orange", "Peach", "Pearl", "Pink", "Plum", "Purple",
		"Rose", "Ruby", "Saffron", "Scarlet", "Silver", "Teal", "Violet", "White",
	}
	nouns := [?]string{
		"Badger", "Brook", "Canyon", "Cedar", "Cloud", "Comet", "Cove", "Dawn",
		"Dune", "Falcon", "Fern", "Finch", "Forest", "Fox", "Glen", "Grove",
		"Harbor", "Heron", "Hill", "Island", "Lake", "Lark", "Maple", "Meadow",
		"Moon", "Otter", "Panda", "Pine", "River", "Sparrow", "Star", "Willow",
	}
	// Probe from a random phrase: even repeated collisions terminate without numbered suffixes.
	count := len(adjectives) * len(colors) * len(nouns)
	start := rand.int_max(count)
	for offset in 0 ..< count {
		index := (start + offset) % count
		noun := index % len(nouns)
		index /= len(nouns)
		candidate := fmt.tprintf("%s %s %s", adjectives[index / len(colors)],
			colors[index % len(colors)], nouns[noun])
		occupied := false
		for workspace in app.workspaces {
			if !workspace.provisional && strings.equal_fold(workspace.name, candidate) {
				occupied = true
				break
			}
		}
		if occupied {continue}
		owned, err := strings.clone(candidate)
		if err != nil {return ""}
		return owned
	}
	return ""
}

selected_tab :: proc(workspace: ^Workspace) -> ^Tab {
	if workspace == nil || len(workspace.tabs) == 0 {return nil}
	return workspace.tabs[workspace.selected]
}

@(require_results)
tab_create :: proc(
	app: ^App,
	workspace: ^Workspace,
	command: string = "",
	directory: string = "",
	profile_id: string = "",
) -> bool {
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return false}
	if !session_open(app, command, directory, profile_id) {
		tab_record_free(tab)
		return false
	}
	id := app.next_session_id
	if layout.init(&tab.tree, {.Terminal, id}) != nil {
		session_close(app, id)
		tab_record_free(tab)
		return false
	}
	tab_record_commit(app, workspace, tab)
	return true
}

session_close :: proc(app: ^App, id: u32) {
	for &entry, i in app.sessions {
		if entry.id == id {
			status := term.status(entry.session)
			app.closed_sessions[app.closed_next] = {id, status.kind, status.exit_code}
			app.closed_next = (app.closed_next + 1) % len(app.closed_sessions)
			session_entry_destroy(&entry)
			ordered_remove(&app.sessions, i)
			return
		}
	}
}

workspace_destroy :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs {tab_record_free(tab)}
	delete(workspace.tabs)
	delete(workspace.name)
	delete(workspace.icon.emoji)
	free(workspace)
}

focus_leave :: proc(app: ^App, w: ^Window) {
	window_overlays_cancel(app, w)
	status_focus_leave(app, w)
	leader_cancel(w)
	if entry := focused_session(app, w); entry != nil {
		term.send_focus(entry.session, false)
		if w.find.open {find_close(app, w, entry)}
	}
	w.selecting, w.autoscrolling = false, false
	w.dragging = {}
	w.wheel_remainder = 0
	paste_confirm_cancel(app, w)
}

focus_enter :: proc(app: ^App, w: ^Window) {
	if entry := focused_session(app, w); entry != nil {
		term.send_focus(entry.session, w.focused)
	}
	reset_blink(w)
	status_focus_enter(app, w)
	w.dirty = true
	window_update_title(app, w)
}

pane_focus :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	if w.tree.focus == node || int(node) >= len(w.tree.nodes) {return}
	// Status, jumps and scripts name a pane wherever it is; a linked one takes focus in its own window.
	pane, is_pane := w.tree.nodes[node].(layout.Pane)
	if is_pane && layout.link_root(w.tree, node) != layout.INVALID_NODE {
		if linked := pane_link_window_of(app, pane.content); linked != nil {
			pane_focus(app, linked, layout.find_content(linked.tree, pane.content))
			linked.link_activate = true
		}
		return
	}
	focus_leave(app, w)
	w.tree.focus = node
	if pane_view_solo(w) {window_relayout(app, w)}
	focus_enter(app, w)
}

tab_select :: proc(app: ^App, w: ^Window, index: int, preserve_selection := false) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !preserve_selection {tab_select_one(w.workspace, index); mark_all_dirty(app)}
	focus_leave(app, w)
	w.workspace.selected = index
	w.tree = &selected_tab(w.workspace).tree
	window_relayout(app, w)
	rail_reveal_active(w)
	focus_enter(app, w)
}

tab_select_one :: proc(workspace: ^Workspace, index: int) {
	for tab, i in workspace.tabs {tab.marked = i == index}
	workspace.selection_anchor = workspace.tabs[index].id
}

tab_pointer_select :: proc(app: ^App, w: ^Window, index: int, toggle, range: bool) {
	tabs := w.workspace.tabs
	if index < 0 || index >= len(tabs) {return}
	if toggle || range || !tabs[index].marked {
		marked, err := make([]bool, len(tabs), context.temp_allocator)
		if err != nil {notify(app, .Error, "Could not select tabs."); return}
		anchor := w.workspace.selected
		for tab, i in tabs {
			marked[i] = tab.marked
			if tab.id == w.workspace.selection_anchor {anchor = i}
		}
		ui.tab_selection_update(marked, index, anchor, toggle = toggle, range = range)
		for tab, i in tabs {tab.marked = marked[i]}
	}
	if !range {w.workspace.selection_anchor = tabs[index].id}
	tab_select(app, w, index, true)
	mark_all_dirty(app)
}

tab_new :: proc(app: ^App, w: ^Window) {
	if !pane_minimum_single(app, w) {return}
	if !tab_create(app, w.workspace) {
		notify(app, .Error, "Could not create a tab.")
		return
	}
	tab_select(app, w, len(w.workspace.tabs) - 1)
	rail_overlay_dismiss(app, w)
}

// Opens the Nth visible profile from profile.order, matching the profile.open_N shortcuts.
tab_new_profile :: proc(app: ^App, w: ^Window, index: int) {
	if !pane_minimum_single(app, w) {return}
	indices: [settings.PROFILE_LIMIT]int
	count := settings.profiles_in_order(&app.settings.profiles, indices[:], visible_only = true)
	if index < 0 || index >= count {
		notify(app, .Error, "That shell profile is not available.")
		return
	}
	profile := &app.settings.profiles.items[indices[index]]
	if !tab_create(app, w.workspace, profile_id = profile.id) {
		notify(app, .Error, "Could not create a tab.")
		return
	}
	tab_select(app, w, len(w.workspace.tabs) - 1)
	rail_overlay_dismiss(app, w)
}

// One-per-workspace content must never show in two panes at once. Other content is keyed by its own
// id and cannot collide.
@(require_results)
pane_content_can_join :: proc(content: layout.Content, destination: ^Workspace, source: ^Tab) -> bool {
	if !CONTENT_POLICY[content.kind].one_per_workspace {return true}
	return !workspace_content_outside_tab(destination, content, source)
}

@(require_results)
pane_to_tab :: proc(app: ^App, w: ^Window, source: ^Tab, node: layout.Node_Id) -> bool {
	source_workspace := pane_source_workspace(app, source)
	if source_workspace == nil || int(node) >= len(source.tree.nodes) {return false}
	if node == source.tree.root && source_workspace == w.workspace {
		for tab, index in w.workspace.tabs {
			if tab != source {continue}
			tab_move(app, w, index, len(w.workspace.tabs) - 1)
			tab_select(app, w, len(w.workspace.tabs) - 1)
			return true
		}
		return false
	}
	pane, valid := source.tree.nodes[node].(layout.Pane)
	if !valid {return false}
	destination_workspace := w.workspace
	if !pane_content_can_join(pane.content, destination_workspace, source) {return false}
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = window_content_area(app, w)}}
	if !pane_minimum_allows(app, w, panes[:], nil, notify_failure = true) {return false}
	tab, record_error := tab_record_reserve(w.workspace)
	if record_error != .None {
		notify(app, .Error, "Could not create a tab. The pane was preserved.")
		return false
	}
	move := pane_move_begin(app, w, source, source_workspace)
	tree, separated := layout.separate_pane(&source.tree, node)
	if !separated {
		pane_move_abort(app, move)
		tab_record_free(tab)
		notify(app, .Error, "Could not move the pane. The layout was preserved.")
		return false
	}
	tab.tree = tree
	tab_record_commit(app, w.workspace, tab)
	pane_move_finish(app, move, tab)
	return true
}

@(require_results)
pane_transfer :: proc(
	app: ^App,
	w: ^Window,
	source, destination: ^Tab,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	root: bool,
) -> bool {
	source_workspace := pane_source_workspace(app, source)
	destination_index := -1
	for tab, index in w.workspace.tabs {if tab == destination {destination_index = index; break}}
	if source_workspace == nil || destination_index < 0 || source == destination {return false}
	if int(node) >= len(source.tree.nodes) || int(target) >= len(destination.tree.nodes) {return false}
	pane, valid := source.tree.nodes[node].(layout.Pane)
	if !valid || !pane_content_can_join(pane.content, w.workspace, source) {return false}
	move := pane_move_begin(app, w, source, source_workspace)
	_, moved := layout.transfer_pane(
		&source.tree,
		&destination.tree,
		node,
		target,
		direction,
		root,
	)
	if !moved {
		pane_move_abort(app, move)
		return false
	}
	pane_move_finish(app, move, destination)
	return true
}

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
		app, w, w.workspace, tab, w.tree.focus, direction, ratio, focus, launch, true,
	); err {
	case .None:
		if w.linked {pane_link_store(app, w)}
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
	if w != nil {
		trial := pane_trial_split(app, w, direction, ratio, tree = &tab.tree, node = node,
			notify_failure = notify_minimum)
		if trial.error == .Minimum {return 0, .Minimum}
		if trial.error != .None {return 0, .Check}
	}
	if !session_open(app, launch.command, launch.directory, launch.profile) {return 0, .Session}
	id := app.next_session_id
	added, err := layout.split_direction(&tab.tree, node, direction, ratio, {.Terminal, id})
	if err != nil {
		session_close(app, id)
		return 0, .Layout
	}
	if w == nil {return id, .None}
	visible := workspace.selected == tab_index
	if focus {
		if !visible {tab_select(app, w, tab_index)}
		pane_focus(app, w, added)
	}
	if visible || focus {window_relayout(app, w)}
	return id, .None
}

pane_keep_open :: proc(app: ^App, w: ^Window) {
	entry := focused_session(app, w)
	if entry == nil {return}
	entry.keep_open = !entry.keep_open
	notify(
		app,
		.Info,
		entry.keep_open ? "Pane will stay open after exit." : "Pane will close after exit.",
	)
	if !entry.keep_open && entry.status == .Exited {_ = close_exited_session(app, entry.id)}
}

tab_close :: proc(app: ^App, w: ^Window, index: int) {
	workspace := w.workspace
	if index < 0 || index >= len(workspace.tabs) {return}
	group := workspace.tabs[index].marked
	if group {
		// Closing one tab can clear the marks on the rest, so the group is named by id before any close.
		ids := make([dynamic]u32, 0, len(workspace.tabs), context.temp_allocator)
		for tab in workspace.tabs {if tab.marked {_ = append(&ids, tab.id)}}
		for id in ids {
			if current := tab_index_by_id(workspace, id); current >= 0 {
				closed_record_tab(app, workspace, current)
				workspace_close_tab(app, workspace, current)
			}
		}
	} else {
		closed_record_tab(app, workspace, index)
		workspace_close_tab(app, workspace, index)
	}
	if group && len(workspace.tabs) > 0 {tab_select_one(workspace, workspace.selected)}
	workspace_close_empty(app, workspace)
}

// The tabs a close of `index` affects, its whole selected group when marked, and their panes.
@(private)
tab_close_scope :: proc(workspace: ^Workspace, index: int) -> (tabs, panes: int, split: bool) {
	if index < 0 || index >= len(workspace.tabs) {return}
	group := workspace.tabs[index].marked
	for tab, i in workspace.tabs {
		if group ? !tab.marked : i != index {continue}
		count := tab_pane_count(tab)
		tabs, panes = tabs + 1, panes + count
		split ||= count > 1
	}
	return
}

// Reported running or blocked work always needs confirmation, including in selected groups.
tab_close_has_work :: proc(app: ^App, workspace: ^Workspace, index: int) -> bool {
	if index < 0 || index >= len(workspace.tabs) {return false}
	group := workspace.tabs[index].marked
	for tab, i in workspace.tabs {
		if group ? !tab.marked : i != index {continue}
		walk := tab_session_panes(app, &tab.tree, i)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.session == nil {continue}
			for record in pane.session.statuses {
				if record.state == .Working || record.state == .Blocked {return true}
			}
		}
	}
	return false
}

// The split-tab preference does not disable protection for explicitly reported ongoing work.
tab_close_request :: proc(app: ^App, w: ^Window, index: int) {
	_, _, split := tab_close_scope(w.workspace, index)
	if !tab_close_has_work(app, w.workspace, index) && (!split || !app.settings.tab.confirm_close) {
		tab_close(app, w, index)
		return
	}
	pending_close_open_tab(app, w, index)
}

// Picks a usable launch directory without touching a remote path twice. `refused` reports that a
// nonempty candidate was rejected, so the caller can tell the user why a different shell started.
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
	if reported, err := settings.directory_label(raw, context.temp_allocator); err == nil && reported != "" {
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
		return entry.program_candidate != 0 ? entry.program_candidate : entry.program_id
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
		program = entry.program_candidate != 0 ? entry.program_candidate : entry.program_id
		return program, entry.program_command
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

tab_duplicate :: proc(app: ^App, w: ^Window, index: int) {
	pane, _ := workspace_focused_session_pane(app, w.workspace, index)
	entry := pane.session
	if entry == nil || !pane_minimum_single(app, w) {return}
	directory, refused := pane_directory(app, entry)
	if refused {notify_directory_refused(app)}
	if !tab_create(app, w.workspace, entry.header.command, directory, entry.profile_id) {
		notify(app, .Error, "Could not duplicate the tab.")
		return
	}
	tab_select(app, w, len(w.workspace.tabs) - 1)
	rail_overlay_dismiss(app, w)
}

tab_move_group :: proc(app: ^App, w: ^Window, end: bool) {
	order := slice.clone(w.workspace.tabs[:], context.temp_allocator)
	marked := make([]bool, len(order), context.temp_allocator)
	indices := make([]int, len(order), context.temp_allocator)
	slot := 0
	for tab, i in order {marked[i] = tab.marked; if end && !tab.marked {slot += 1}}
	if !ui.tab_group_order(marked, slot, indices) {return}
	for original, to in indices {
		for current, from in w.workspace.tabs {
			if current == order[original] {tab_move(app, w, from, to); break}
		}
	}
}

// Puts back the marks a subset close replaced, falling back to the active tab when all of them closed.
tab_close_restore :: proc(w: ^Window) {
	if len(w.close_restore) == 0 {return}
	kept := false
	for tab in w.workspace.tabs {
		tab.marked = false
		for id in w.close_restore {tab.marked ||= tab.id == id}
		kept ||= tab.marked
	}
	if !kept && len(w.workspace.tabs) > 0 {tab_select_one(w.workspace, w.workspace.selected)}
	clear(&w.close_restore)
	w.dirty = true
}

// Closes the tabs right of `anchor`, or every tab outside it: its marked group when it is marked,
// otherwise every other tab.
tab_close_subset :: proc(app: ^App, w: ^Window, right: bool, anchor: int) {
	if anchor < 0 || anchor >= len(w.workspace.tabs) {return}
	group := w.workspace.tabs[anchor].marked
	clear(&w.close_restore)
	if reserve(&w.close_restore, len(w.workspace.tabs)) != nil {
		notify(app, .Error, "Could not select tabs to close.")
		return
	}
	for tab in w.workspace.tabs {if tab.marked {append(&w.close_restore, tab.id)}}
	first := -1
	for tab, i in w.workspace.tabs {
		tab.marked = right ? i > anchor : (group ? !tab.marked : i != anchor)
		if tab.marked && first < 0 {first = i}
	}
	if first >= 0 {tab_close_request(app, w, first)}
	if !w.pending_close.confirm.open {tab_close_restore(w)}
}

tab_index_by_id :: proc(workspace: ^Workspace, id: u32) -> int {
	for tab, i in workspace.tabs {if tab.id == id {return i}}
	return -1
}

pane_close :: proc(app: ^App, w: ^Window) {
	if w.linked {
		home, found := pane_link_home(app, pane_link_content(w))
		if found {
			pane_close_at(app, home.workspace, tab_index_by_id(home.workspace, home.tab.id), home.node)
		}
		return
	}
	pane_close_at(app, w.workspace, w.workspace.selected, w.tree.focus)
}

// A close Reopen Closed can undo, by request or because the shell exited.
pane_close_at :: proc(app: ^App, workspace: ^Workspace, tab_index: int, node: layout.Node_Id) {
	closed_record_pane(app, workspace, tab_index, node)
	pane_remove(app, workspace, tab_index, node)
}

@(private)
workspace_close_tab :: proc(app: ^App, workspace: ^Workspace, original_index: int) {
	index := original_index
	if index < 0 || index >= len(workspace.tabs) {return}
	tab := workspace.tabs[index]
	for w in app.windows {if w.workspace == workspace {_ = gesture_cancel(app, w)}}
	for current, i in workspace.tabs {if current == tab {index = i; break}}
	was_selected := index == workspace.selected
	if was_selected {
		for w in app.windows {if w.workspace == workspace {focus_leave(app, w)}}
	}
	terminal := tab_session_panes(app, &tab.tree, index)
	for pane, ok := workspace_pane_next(&terminal); ok; pane, ok = workspace_pane_next(&terminal) {
		session_close(app, pane.content.id)
	}
	ordered_remove(&workspace.tabs, index)
	tab_record_free(tab)
	workspace_settings_sync(app, workspace)
	workspace.selected = tab_selected_after_remove(workspace.selected, index, len(workspace.tabs))
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		w := app.windows[i]
		if w.workspace != workspace {continue}
		tab_presentation_remove(&w.presentation, index)
		if len(workspace.tabs) == 0 {
			w.tree = nil
		} else {
			w.tree = &selected_tab(workspace).tree
			window_relayout(app, w)
			rail_reveal_active(w)
			if was_selected {focus_enter(app, w)}
		}
	}
}

@(private)
pane_remove :: proc(
	app: ^App,
	workspace: ^Workspace,
	original_tab_index: int,
	node: layout.Node_Id,
) {
	tab_index := original_tab_index
	tab := workspace.tabs[tab_index]
	for w in app.windows {if w.workspace == workspace {_ = gesture_cancel(app, w)}}
	for current, i in workspace.tabs {if current == tab {tab_index = i; break}}
	pane, is_pane := tab.tree.nodes[node].(layout.Pane)
	if !is_pane {return}
	if tab.tree.root == node {
		workspace_close_tab(app, workspace, tab_index)
		workspace_close_empty(app, workspace)
		return
	}
	visible := tab_index == workspace.selected
	was_focused := visible && tab.tree.focus == node
	if was_focused {
		for w in app.windows {if w.workspace == workspace {focus_leave(app, w)}}
	}
	if !layout.remove(&tab.tree, node) {return}
	if pane_owns_session(pane.content.kind) {session_close(app, pane.content.id)}
	workspace_settings_sync(app, workspace)
	tab_update_title(app, tab)
	if visible {
		for w in app.windows {
			if w.workspace != workspace {continue}
			window_relayout(app, w)
			if was_focused {focus_enter(app, w)}
		}
	}
}

@(require_results)
close_exited_session :: #force_no_inline proc(app: ^App, id: u32) -> bool {
	if entry := session_find(app, id); entry != nil && entry.keep_open {return false}
	for workspace in app.workspaces {
		pane, found := workspace_first_session(app, workspace, id)
		if !found {continue}
		if len(workspace.tabs) == 1 &&
		   workspace.tabs[pane.tab].tree.root == pane.node {return false}
		pane_close_at(app, workspace, pane.tab, pane.node)
		return true
	}
	return false
}

session_titles_changed :: #force_no_inline proc(app: ^App, id: u32) {
	for workspace in app.workspaces {
		for tab in workspace.tabs {
			pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
			if pane.content == {.Terminal, id} {tab_update_title(app, tab)}
		}
	}
	for window in app.windows {
		window.dirty = true
		if focused := focused_session(app, window); focused != nil && focused.id == id {
			window_update_title(app, window)
		}
	}
}

window_update_title :: proc(app: ^App, w: ^Window) {
	tab := selected_tab(w.workspace)
	tab_update_title(app, tab)
	title := tab.title != "" ? tab.title : app.app_id
	if !app.platform_ready {return}
	if platform.window_set_title(&app.platform, w.id, title) != .None {
		log.error("setting the window title failed")
	}
}

session_message :: proc(status: term.Status) -> string {
	switch status.kind {
	case .Running:
		return ""
	case .Exited:
		return fmt.tprintf(
			"The shell exited with code %d. Press Enter to restart it.",
			status.exit_code,
		)
	case .Failed:
		reason := status.message != "" ? status.message : "Could not start the shell."
		return fmt.tprintf(
			"%s Check shell.command and shell.directory in settings, " +
			"then press Enter to try again.",
			reason,
		)
	}
	return ""
}
