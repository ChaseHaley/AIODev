package main

import "aio:commands"
import "aio:layout"
import "aio:term"
import "aio:ui"

palette_active :: proc(app: ^App, w: ^Window) -> bool {
	return w != nil && w.id != 0 && app.palette_window == w.id && app.palette.open
}

palette_visible :: proc(app: ^App, w: ^Window) -> bool {
	return(
		w != nil &&
		w.id != 0 &&
		app.palette_window == w.id &&
		ui.presence_visible(app.palette.presence) \
	)
}

palette_close :: proc(app: ^App, w: ^Window) {
	if w == nil || w.id == 0 || app.palette_window != w.id {return}
	ui.palette_close(&app.palette)
	w.dirty = true
}

palette_release :: proc(app: ^App, w: ^Window) {
	if w == nil || w.id == 0 || app.palette_window != w.id {return}
	palette_close(app, w)
	ui.presence_reset(&app.palette.presence)
	app.palette_window = 0
}

palette_open :: proc(app: ^App, w: ^Window) {
	palette_open_mode(app, w, .All)
}

palette_open_mode :: proc(app: ^App, w: ^Window, mode: ui.Palette_Mode) {
	if w == nil || w.id == 0 {return}
	if previous := window_find(app, app.palette_window); previous != nil && previous != w {
		palette_release(app, previous)
	}
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	entry := focused_session(app, w)
	has_selection := entry != nil && term.has_selection(entry.session)
	registered := commands.set_enabled(
		&app.registry,
		commands.Command_Id(Action.Copy),
		has_selection,
	)
	assert(registered)
	app.palette_window = w.id
	ui.palette_open_mode(&app.palette, &app.registry, mode)
	ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// A tab's second identity: the focused pane's terminal title, which can differ from a user name.
@(require_results)
palette_tab_detail :: proc(app: ^App, tab: ^Tab) -> string {
	if tab == nil || tab.tree.root == layout.INVALID_NODE || tab.tree.focus == layout.INVALID_NODE {
		return ""
	}
	pane, is_pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if !is_pane {return ""}
	if pane.content.kind == .Settings {return "Settings"}
	if entry := session_find(app, pane.content.id); entry != nil {
		return pane_header_title(&entry.header)
	}
	return ""
}

@(private)
palette_tab_key :: proc(workspace: ^Workspace, tab: ^Tab) -> u64 {
	return u64(workspace.id) << 32 | u64(tab.id)
}

@(private)
palette_tab_count :: proc(user: rawptr) -> int {
	app := cast(^App)user
	count := 0
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		count += len(workspace.tabs)
	}
	return count
}

@(private)
palette_tab_at :: proc(user: rawptr, index: int) -> ui.Palette_Item {
	app := cast(^App)user
	remaining := index
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if remaining < len(workspace.tabs) {
			tab := workspace.tabs[remaining]
			return {
				label  = tab.title,
				detail = palette_tab_detail(app, tab),
				owner  = workspace.name,
				id     = palette_tab_key(workspace, tab),
			}
		}
		remaining -= len(workspace.tabs)
	}
	return {}
}

@(private)
palette_workspace_count :: proc(user: rawptr) -> int {
	app := cast(^App)user
	count := 0
	for workspace in app.workspaces {
		if !workspace.provisional {count += 1}
	}
	return count
}

@(private)
palette_workspace_at :: proc(user: rawptr, index: int) -> ui.Palette_Item {
	app := cast(^App)user
	remaining := index
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if remaining == 0 {
			detail := ""
			if tab := selected_tab(workspace); tab != nil {
				detail = palette_tab_detail(app, tab)
			}
			return {label = workspace.name, detail = detail, id = u64(workspace.id)}
		}
		remaining -= 1
	}
	return {}
}

palette_set_sources :: proc(app: ^App) {
	ui.palette_set_sources(
		&app.palette,
		{user = app, count = palette_tab_count, item = palette_tab_at},
		{user = app, count = palette_workspace_count, item = palette_workspace_at},
	)
}

// Selecting a tab follows its workspace's exclusive window ownership (D-051): an owned workspace
// reuses and focuses its window, an unowned one is adopted by the requesting window first.
palette_activate_tab :: proc(app: ^App, w: ^Window, key: u64) -> bool {
	workspace := workspace_find(app, u32(key >> 32))
	if workspace == nil {return false}
	tab_id := u32(key)
	tab_index := -1
	for tab, index in workspace.tabs {
		if tab.id == tab_id {
			tab_index = index
			break
		}
	}
	if tab_index < 0 {return false}
	owner := window_for_workspace(app, workspace)
	if owner == nil {
		if !workspace_select(app, w, workspace) {return false}
		owner = window_for_workspace(app, workspace)
	}
	if owner == nil {return false}
	tab_select(app, owner, tab_index)
	if owner != w {return window_activate(app, owner)}
	return true
}

palette_activate_workspace :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	workspace := workspace_find(app, id)
	if workspace == nil {return false}
	return workspace_select(app, w, workspace)
}

window_overlays_cancel :: proc(app: ^App, w: ^Window, focus_lost := false) {
	palette_release(app, w)
	workspace_picker_cancel(w, focus_lost)
	w.tab_menu.open = false
	w.profile_menu.open = false
	w.rename.dragging = false
	if w.rename_open {rename_finish(app, w, false)}
	confirmation_cancel(app, w)
	rail_overlay_dismiss(app, w)
	status_overview_cancel(w)
	w.dirty = true
}
