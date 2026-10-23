package main

import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
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
}

@(require_results)
workspace_default_name :: proc(app: ^App) -> (name: string, number: u32) {
	number = app.next_workspace_number
	for number < max(u32) {
		number += 1
		candidate := fmt.tprintf("Workspace %d", number)
		occupied := false
		for workspace in app.workspaces {
			if !workspace.provisional && workspace.name == candidate {occupied = true; break}
		}
		if occupied {continue}
		owned, err := strings.clone(candidate)
		if err != nil {return "", 0}
		return owned, number
	}
	return "", 0
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
) -> bool {
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return false}
	if !session_open(app, command, directory) {
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
			pane_header_destroy(&entry.header)
			delete(entry.name)
			term.destroy(entry.session)
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
	leader_cancel(w)
	if entry := focused_session(app, w); entry != nil {
		term.send_focus(entry.session, false)
		if w.find.open {find_close(w, entry)}
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
	w.dirty = true
	window_update_title(app, w)
}

pane_focus :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	if w.tree.focus == node {return}
	focus_leave(app, w)
	w.tree.focus = node
	if w.tree.zoomed {window_relayout(app, w)}
	focus_enter(app, w)
}

tab_select :: proc(app: ^App, w: ^Window, index: int, preserve_selection := false) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !preserve_selection {tab_select_one(w.workspace, index); mark_all_dirty(app)}
	focus_leave(app, w)
	w.workspace.selected = index
	w.tree = &selected_tab(w.workspace).tree
	window_relayout(app, w)
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
	if !valid || pane.content.kind != .Terminal {return false}
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
	if settings_active(w) {return}
	if !pane_minimum_split(app, w, direction, ratio) {return}
	if !session_open(app) {notify(app, .Error, "Could not create a pane."); return}
	id := app.next_session_id
	node, err := layout.split_direction(w.tree, w.tree.focus, direction, ratio, {.Terminal, id})
	if err != nil {
		session_close(app, id)
		notify(app, .Error, "Could not split the pane.")
		return
	}
	if focus {pane_focus(app, w, node)}
	window_relayout(app, w)
}

pane_zoom :: proc(app: ^App, w: ^Window) {
	w.tree.zoomed = !w.tree.zoomed
	w.dragging = {}
	window_relayout(app, w)
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
		for i := len(workspace.tabs) - 1; i >= 0; i -= 1 {
			if workspace.tabs[i].marked {workspace_close_tab(app, workspace, i)}
		}
	} else {workspace_close_tab(app, workspace, index)}
	if group && len(workspace.tabs) > 0 {tab_select_one(workspace, workspace.selected)}
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

// Closes a tab, or its selected group, after asking when that would end more than one pane in a tab.
tab_close_request :: proc(app: ^App, w: ^Window, index: int) {
	_, _, split := tab_close_scope(w.workspace, index)
	if !split || !app.settings.tab.confirm_close {tab_close(app, w, index); return}
	pending_close_open_tab(app, w, index)
}

tab_duplicate :: proc(app: ^App, w: ^Window) {
	entry := focused_session(app, w)
	if entry == nil || !pane_minimum_single(app, w) {return}
	raw := term.working_directory(entry.session, context.temp_allocator)
	directory, err := settings.directory_label(raw, context.temp_allocator)
	if err != nil {notify(app, .Error, "Could not resolve the pane directory."); return}
	if directory == "" {directory = entry.header.launch_directory}
	if !tab_create(app, w.workspace, entry.header.command, directory) {
		notify(app, .Error, "Could not duplicate the tab.")
		return
	}
	tab_select(app, w, len(w.workspace.tabs) - 1)
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

tab_close_restore :: proc(w: ^Window) {
	if len(w.close_restore) == 0 {return}
	for tab in w.workspace.tabs {
		tab.marked = false
		for id in w.close_restore {tab.marked ||= tab.id == id}
	}
	clear(&w.close_restore)
	w.dirty = true
}

tab_close_subset :: proc(app: ^App, w: ^Window, right: bool) {
	clear(&w.close_restore)
	if reserve(&w.close_restore, len(w.workspace.tabs)) != nil {
		notify(app, .Error, "Could not select tabs to close.")
		return
	}
	for tab in w.workspace.tabs {if tab.marked {append(&w.close_restore, tab.id)}}
	first := -1
	for tab, i in w.workspace.tabs {
		tab.marked = right ? i > w.workspace.selected : !tab.marked
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
	pane_remove(app, w.workspace, w.workspace.selected, w.tree.focus)
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
	other := tab_other_panes(app, &tab.tree, index)
	for _, ok := workspace_pane_next(&other); ok; _, ok = workspace_pane_next(&other) {
		for w in app.windows {if w.workspace == workspace {ui.editor_destroy(&w.editor)}}
	}
	ordered_remove(&workspace.tabs, index)
	for w in app.windows {
		if w.workspace == workspace {tab_presentation_remove(&w.presentation, index)}
	}
	tab_record_free(tab)
	workspace.selected =
		tab_presentation_selected_after_remove(workspace.selected, index, len(workspace.tabs))
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		w := app.windows[i]
		if w.workspace != workspace {continue}
		if len(workspace.tabs) == 0 {
			w.tree = nil
			hide_to_tray(app, w)
		} else {
			w.tree = &selected_tab(workspace).tree
			window_relayout(app, w)
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
	if tab.tree.root == node {workspace_close_tab(app, workspace, tab_index); return}
	visible := tab_index == workspace.selected
	was_focused := visible && tab.tree.focus == node
	if was_focused {
		for w in app.windows {if w.workspace == workspace {focus_leave(app, w)}}
	}
	if !layout.remove(&tab.tree, node) {return}
	session_close(app, pane.content.id)
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
		pane_remove(app, workspace, pane.tab, pane.node)
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
