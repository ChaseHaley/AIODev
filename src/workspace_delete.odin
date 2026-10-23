package main

import "aio:layout"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:strings"

@(private)
workspace_delete_destination :: proc(app: ^App, workspace: ^Workspace) -> ^Workspace {
	index := -1
	for current, i in app.workspaces {if current == workspace {index = i; break}}
	if index < 0 {return nil}
	for offset in 1 ..< len(app.workspaces) {
		candidate := app.workspaces[(index + offset) % len(app.workspaces)]
		if !candidate.provisional && window_for_workspace(app, candidate) == nil {return candidate}
	}
	return nil
}

workspace_delete_request :: proc(app: ^App, w: ^Window, workspace: ^Workspace) {
	if w == nil || workspace == nil || w.preparing || workspace.provisional {return}
	if workspace_find(app, workspace.id) != workspace {return}
	owner := window_for_workspace(app, workspace)
	if owner != nil && owner.preparing {return}
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	name, err := strings.clone(workspace.name)
	if err != nil {notify(app, .Error, "Could not prepare workspace deletion."); return}
	destination_name: string
	if destination != nil {
		destination_name, err = strings.clone(destination.name)
		if err !=
		   nil {delete(name); notify(app, .Error, "Could not prepare workspace deletion."); return}
	}
	if !gesture_cancel(app, w) {delete(name); delete(destination_name); return}
	window_overlays_cancel(app, w)
	delete(w.close_confirm_workspace_name)
	delete(w.close_confirm_destination_name)
	w.close_confirm_workspace_name = name
	w.close_confirm_destination_name = destination_name
	w.close_confirm_workspace = workspace.id
	w.close_confirm_destination = destination != nil ? destination.id : 0
	w.close_confirm_owner = owner != nil ? owner.id : 0
	w.close_confirm_tab = 0
	w.close_confirm_tabs, w.close_confirm_panes, w.close_confirm_sessions =
		workspace_delete_counts(workspace)
	ui.confirm_open(&w.close_confirm)
	w.close_confirm.extended = true
	w.dirty = true
}

@(private)
workspace_delete_counts :: proc(workspace: ^Workspace) -> (tabs, panes, sessions: int) {
	tabs = len(workspace.tabs)
	for tab in workspace.tabs {
		for node in tab.tree.nodes {
			if pane, ok := node.(layout.Pane); ok {
				panes += 1
				if pane.content.kind == .Terminal {sessions += 1}
			}
		}
	}
	return
}

@(private)
workspace_delete_text :: proc(app: ^App, w: ^Window) -> (title, body, note: string) {
	name := w.close_confirm_workspace_name
	if workspace := workspace_find(app, w.close_confirm_workspace);
	   w.close_confirm.open && workspace != nil {
		name = workspace.name
		w.close_confirm_tabs, w.close_confirm_panes, w.close_confirm_sessions =
			workspace_delete_counts(workspace)
	}
	title = fmt.tprintf("Delete #%d “%s”?", w.close_confirm_workspace, name)
	body = fmt.tprintf(
		"Close %d tabs (%d panes); stop %d sessions.",
		w.close_confirm_tabs,
		w.close_confirm_panes,
		w.close_confirm_sessions,
	)
	if w.close_confirm_owner != 0 {
		if w.close_confirm_destination != 0 {
			note = fmt.tprintf(
				"Switch its window to #%d “%s”.",
				w.close_confirm_destination,
				w.close_confirm_destination_name,
			)
		} else {note = "Replace it with a fresh default workspace and shell."}
	} else {note = "Other workspaces and their sessions stay open."}
	return
}

@(private)
workspace_delete_release :: proc(app: ^App, workspace: ^Workspace) {
	for tab in workspace.tabs {
		for node in tab.tree.nodes {
			if pane, ok := node.(layout.Pane); ok && pane.content.kind == .Terminal {
				session_close(app, pane.content.id)
			}
		}
	}
	for current, i in app.workspaces {
		if current == workspace {ordered_remove(&app.workspaces, i); break}
	}
	workspace_destroy(workspace)
}

@(private)
@(require_results)
workspace_delete_commit :: proc(app: ^App, workspace: ^Workspace) -> bool {
	owner := window_for_workspace(app, workspace)
	if workspace.provisional || (owner != nil && owner.preparing) {return false}
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	fresh := destination == nil && (owner != nil || len(app.workspaces) == 1)
	if fresh {
		destination = workspace_create_empty(app)
		if destination == nil {return false}
	}
	committed := false
	defer if fresh &&
	   !committed {workspace_delete_release(app, destination); workspace_pickers_refresh(app)}
	prepared: Workspace_View_Resources
	defer workspace_view_destroy(&prepared)
	created_tab := destination != nil && len(destination.tabs) == 0
	if created_tab && !tab_create(app, destination) {return false}
	defer if created_tab && !fresh && !committed {workspace_close_tab(app, destination, 0)}
	if created_tab {
		entry := session_find(app, app.next_session_id)
		if entry == nil || term.status(entry.session).kind == .Failed {return false}
	}
	if owner != nil && !workspace_view_prepare(app, &prepared, destination) {return false}
	if owner != nil {
		if !gesture_cancel(app, owner) {return false}
		focus_leave(app, owner)
		tab_close_restore(owner)
		workspace_view_move(&owner.resources, &prepared)
		owner.close_confirm = {}
		owner.close_confirm_workspace = 0
		owner.tab_hover, owner.tab_close_pressed, owner.tab_pressed = -1, -1, false
		owner.tab_underline = {
			value  = f32(destination.selected),
			target = f32(destination.selected),
		}
		if destination.selection_anchor == 0 {tab_select_one(destination, destination.selected)}
		window_relayout(app, owner)
		focus_enter(app, owner)
	}
	workspace_delete_release(app, workspace)
	committed = true
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	return true
}

@(private)
workspace_delete_finish :: proc(app: ^App, w: ^Window, accept: bool) {
	ui.confirm_close(&w.close_confirm)
	w.dirty = true
	if !accept {return}
	workspace := workspace_find(app, w.close_confirm_workspace)
	if workspace == nil {return}
	owner := window_for_workspace(app, workspace)
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	owner_id := owner != nil ? owner.id : 0
	destination_id := destination != nil ? destination.id : 0
	if owner_id != w.close_confirm_owner || destination_id != w.close_confirm_destination {
		workspace_delete_request(app, w, workspace)
		return
	}
	if !workspace_delete_commit(app, workspace) {
		notify(app, .Error, "Could not prepare the replacement. The workspace was preserved.")
	}
}
