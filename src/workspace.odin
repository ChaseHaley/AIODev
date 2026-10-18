package main

import "core:fmt"
import "core:log"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

Tab :: struct {
	id: u32,
	tree: layout.Layout,
	title: string,
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
	tab_update_title(app, tab)
	append(&workspace.tabs, tab)
	return true
}

session_close :: proc(app: ^App, id: u32) {
	for &entry, i in app.sessions {
		if entry.id == id {
			pane_header_destroy(&entry.header)
			term.destroy(entry.session)
			ordered_remove(&app.sessions, i)
			return
		}
	}
}

workspace_destroy :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs {
		layout.destroy(&tab.tree)
		delete(tab.title)
		free(tab)
	}
	delete(workspace.tabs)
	free(workspace)
}

focus_leave :: proc(app: ^App, w: ^Window) {
	leader_cancel(w)
	if entry := focused_session(app, w); entry != nil {
		term.send_focus(entry.session, false)
		if w.find.open { find_close(w, entry) }
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
	if w.tree.focus == node { return }
	focus_leave(app, w)
	w.tree.focus = node
	if w.tree.zoomed { window_relayout(app, w) }
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

pane_split :: proc(app: ^App, w: ^Window, direction: layout.Direction, ratio: f32 = 0.5, focus := true) {
	if settings_active(w) { return }
	if !session_open(app) { notify(app, .Error, "Could not create a pane."); return }
	id := app.next_session_id
	node, err := layout.split_direction(w.tree, w.tree.focus, direction, ratio, {.Terminal, id})
	if err != nil {
		session_close(app, id)
		notify(app, .Error, "Could not split the pane.")
		return
	}
	if focus { pane_focus(app, w, node) }
	window_relayout(app, w)
}

pane_zoom :: proc(app: ^App, w: ^Window) {
	w.tree.zoomed = !w.tree.zoomed
	w.dragging = {}
	window_relayout(app, w)
}

pane_keep_open :: proc(app: ^App, w: ^Window) {
	entry := focused_session(app, w)
	if entry == nil { return }
	entry.keep_open = !entry.keep_open
	notify(app, .Info, entry.keep_open ? "Pane will stay open after exit." : "Pane will close after exit.")
	if !entry.keep_open && entry.status == .Exited { _ = close_exited_session(app, entry.id) }
}

tab_close :: proc(app: ^App, w: ^Window, index: int) {
	workspace_close_tab(app, w.workspace, index)
}

pane_close :: proc(app: ^App, w: ^Window) {
	pane_remove(app, w.workspace, w.workspace.selected, w.tree.focus)
}

@(private)
workspace_close_tab :: proc(app: ^App, workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) { return }
	for w in app.windows { if w.workspace == workspace { arrange_cancel(app, w) } }
	tab := workspace.tabs[index]
	was_selected := index == workspace.selected
	if was_selected {
		for w in app.windows { if w.workspace == workspace { focus_leave(app, w) } }
	}
	for node in tab.tree.nodes {
		pane, ok := node.(layout.Pane)
		if !ok { continue }
		if pane.content.kind == .Terminal { session_close(app, pane.content.id); continue }
		for w in app.windows { if w.workspace == workspace { ui.editor_destroy(&w.editor) } }
	}
	ordered_remove(&workspace.tabs, index)
	layout.destroy(&tab.tree)
	delete(tab.title)
	free(tab)
	if index < workspace.selected { workspace.selected -= 1 }
	workspace.selected = clamp(workspace.selected, 0, max(0, len(workspace.tabs)-1))
	for i := len(app.windows)-1; i >= 0; i -= 1 {
		w := app.windows[i]
		if w.workspace != workspace { continue }
		if len(workspace.tabs) == 0 {
			w.tree = nil
			hide_to_tray(app, w)
		} else {
			w.tree = &selected_tab(workspace).tree
			window_relayout(app, w)
			if was_selected { focus_enter(app, w) }
		}
	}
}

@(private)
pane_remove :: proc(app: ^App, workspace: ^Workspace, tab_index: int, node: layout.Node_Id) {
	for w in app.windows { if w.workspace == workspace { arrange_cancel(app, w) } }
	tab := workspace.tabs[tab_index]
	pane, is_pane := tab.tree.nodes[node].(layout.Pane)
	if !is_pane { return }
	if tab.tree.root == node { workspace_close_tab(app, workspace, tab_index); return }
	visible := tab_index == workspace.selected
	was_focused := visible && tab.tree.focus == node
	if was_focused {
		for w in app.windows { if w.workspace == workspace { focus_leave(app, w) } }
	}
	if !layout.remove(&tab.tree, node) { return }
	session_close(app, pane.content.id)
	tab_update_title(app, tab)
	if visible {
		for w in app.windows {
			if w.workspace != workspace { continue }
			window_relayout(app, w)
			if was_focused { focus_enter(app, w) }
		}
	}
}

@(require_results)
close_exited_session :: #force_no_inline proc(app: ^App, id: u32) -> bool {
	if entry := session_find(app, id); entry != nil && entry.keep_open { return false }
	for workspace in app.workspaces {
		for tab, tab_index in workspace.tabs {
			for node, node_index in tab.tree.nodes {
				if pane, ok := node.(layout.Pane); ok && pane.content == {.Terminal, id} {
					if len(workspace.tabs) == 1 && tab.tree.root == layout.Node_Id(node_index) {
						return false
					}
					pane_remove(app, workspace, tab_index, layout.Node_Id(node_index))
					return true
				}
			}
		}
	}
	return false
}

@(private)
tab_update_title :: proc(app: ^App, tab: ^Tab) {
	pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if pane.content.kind == .Settings { return }
	title: string
	if entry := session_find(app, pane.content.id); entry != nil {
		title = term.title(entry.session)
	}
	delete(tab.title)
	tab.title = title
}

session_titles_changed :: #force_no_inline proc(app: ^App, id: u32) {
	for workspace in app.workspaces {
		for tab in workspace.tabs {
			pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
			if pane.content == {.Terminal, id} { tab_update_title(app, tab) }
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
