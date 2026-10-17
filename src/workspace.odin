package main

import "core:fmt"
import "core:log"
import "aio:layout"
import "aio:platform"
import "aio:term"

Tab :: struct {
	id: u32,
	tree: layout.Layout,
}

Workspace :: struct {
	tabs: [dynamic]^Tab,
	selected: int,
	next_tab_id: u32,
}

selected_tab :: proc(workspace: ^Workspace) -> ^Tab {
	if workspace == nil || len(workspace.tabs) == 0 { return nil }
	return workspace.tabs[workspace.selected]
}

@(require_results)
tab_create :: proc(app: ^App, workspace: ^Workspace) -> bool {
	tab, err := new(Tab)
	if err != nil { return false }
	if reserve(&workspace.tabs, len(workspace.tabs)+1) != nil { free(tab); return false }
	if !session_open(app) { free(tab); return false }
	id := app.next_session_id
	if layout.init(&tab.tree, {.Terminal, id}) != nil {
		session_close(app, id)
		layout.destroy(&tab.tree)
		free(tab)
		return false
	}
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	append(&workspace.tabs, tab)
	return true
}

session_close :: proc(app: ^App, id: u32) {
	for entry, i in app.sessions {
		if entry.id == id {
			term.destroy(entry.session)
			ordered_remove(&app.sessions, i)
			return
		}
	}
}

workspace_destroy :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs {
		layout.destroy(&tab.tree)
		free(tab)
	}
	delete(workspace.tabs)
	free(workspace)
}

focus_leave :: proc(app: ^App, w: ^Window) {
	if entry := focused_session(app, w); entry != nil {
		term.send_focus(entry.session, false)
		if w.find.open { find_close(w, entry) }
	}
	w.selecting, w.autoscrolling = false, false
	w.dragging = nil
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
	if w.tree.focus == node { return }
	focus_leave(app, w)
	w.tree.focus = node
	focus_enter(app, w)
}

tab_select :: proc(app: ^App, w: ^Window, index: int) {
	if index < 0 || index >= len(w.workspace.tabs) { return }
	focus_leave(app, w)
	w.workspace.selected = index
	w.tree = &selected_tab(w.workspace).tree
	window_relayout(app, w)
	focus_enter(app, w)
}

tab_new :: proc(app: ^App, w: ^Window) {
	if !tab_create(app, w.workspace) {
		notify(app, .Error, "Could not create a tab.")
		return
	}
	tab_select(app, w, len(w.workspace.tabs)-1)
}

pane_split :: proc(app: ^App, w: ^Window, axis: layout.Axis) {
	if !session_open(app) { notify(app, .Error, "Could not create a pane."); return }
	id := app.next_session_id
	node, err := layout.split(w.tree, w.tree.focus, axis, 0.5, {.Terminal, id})
	if err != nil {
		session_close(app, id)
		notify(app, .Error, "Could not split the pane.")
		return
	}
	pane_focus(app, w, node)
	window_relayout(app, w)
}

tab_close :: proc(app: ^App, w: ^Window, index: int) {
	if index < 0 || index >= len(w.workspace.tabs) { return }
	workspace := w.workspace
	tab := workspace.tabs[index]
	focus_leave(app, w)
	for node in tab.tree.nodes {
		if pane, ok := node.(layout.Pane); ok { session_close(app, pane.content.id) }
	}
	ordered_remove(&workspace.tabs, index)
	layout.destroy(&tab.tree)
	free(tab)
	if len(workspace.tabs) == 0 {
		w.tree = nil
		hide_to_tray(app, w)
		return
	}
	if index < workspace.selected { workspace.selected -= 1 }
	workspace.selected = min(workspace.selected, len(workspace.tabs)-1)
	w.tree = &selected_tab(workspace).tree
	window_relayout(app, w)
	focus_enter(app, w)
}

pane_close :: proc(app: ^App, w: ^Window) {
	if len(w.panes) == 1 { tab_close(app, w, w.workspace.selected); return }
	entry := focused_session(app, w)
	if entry == nil { return }
	id := entry.id
	focus_leave(app, w)
	if !layout.remove(w.tree, w.tree.focus) { return }
	session_close(app, id)
	window_relayout(app, w)
	focus_enter(app, w)
}

window_update_title :: proc(app: ^App, w: ^Window) {
	title := app.app_id
	if entry := focused_session(app, w); entry != nil {
		if value := term.title(entry.session, context.temp_allocator); value != "" { title = value }
	}
	if platform.window_set_title(&app.platform, w.id, title) != .None {
		log.error("setting the window title failed")
	}
}

session_message :: proc(status: term.Status) -> string {
	switch status.kind {
	case .Running: return ""
	case .Exited:
		return fmt.tprintf("The shell exited with code %d. Press Enter to restart it.", status.exit_code)
	case .Failed:
		reason := status.message != "" ? status.message : "Could not start the shell."
		return fmt.tprintf("%s Check shell.command and shell.directory in settings, " +
			"then press Enter to try again.", reason)
	}
	return ""
}
