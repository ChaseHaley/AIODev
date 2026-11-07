package main

import "aio:layout"
import "aio:render"
import "aio:ui"

// Where the settings page lives in the window: the one settings pane, its layout and drawing, and
// opening it. The page's rows come from settings_editor.odin; its saves from settings_commit.odin.

settings_tab_index :: proc(workspace: ^Workspace) -> int {
	tab, _, found := settings_pane_location(workspace)
	return found ? tab : -1
}

// The layout node of the settings pane, wherever it sits in its tab.
settings_pane_node :: proc(workspace: ^Workspace) -> (layout.Node_Id, bool) {
	_, node, found := settings_pane_location(workspace)
	return node, found
}

@(private)
settings_pane_location :: proc(
	workspace: ^Workspace,
) -> (
	tab: int,
	node: layout.Node_Id,
	found: bool,
) {
	if workspace == nil {return -1, layout.INVALID_NODE, false}
	for candidate, tab_index in workspace.tabs {
		walk := tab_other_panes(nil, &candidate.tree, tab_index)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.content.kind == .Settings {return tab_index, pane.node, true}
		}
	}
	return -1, layout.INVALID_NODE, false
}

// Whether the window shows a focused settings pane, which then takes keyboard input.
settings_active :: proc(w: ^Window) -> bool {
	tree := window_tree(w)
	if tree == nil || tree.focus == layout.INVALID_NODE {return false}
	pane, ok := tree.nodes[tree.focus].(layout.Pane)
	return ok && pane.content.kind == .Settings
}

// The rectangle of the settings pane the window should address, preferring the focused one.
@(private)
settings_pane_rect :: proc(w: ^Window) -> layout.Pane_Rect {
	if tree := window_tree(w); tree != nil && tree.focus != layout.INVALID_NODE {
		for pane in w.panes {
			if pane.node == tree.focus && pane.content.kind == .Settings {return pane}
		}
	}
	for pane in w.panes {
		if pane.content.kind == .Settings {return pane}
	}
	return {}
}

@(require_results)
settings_layout_for :: proc(w: ^Window, pane: layout.Pane_Rect) -> ui.Editor_Layout {
	rect, header := pane.rect, pane_header_of(w, pane)
	return ui.editor_layout({rect.x, rect.y + header, rect.width, max(0, rect.height - header)}, w.scale)
}

settings_layout :: proc(w: ^Window) -> ui.Editor_Layout {
	return settings_layout_for(w, settings_pane_rect(w))
}

// The settings pane under a point, so pointer routing follows the pane rather than the focus.
settings_pane_under_pointer :: proc(
	w: ^Window,
	x, y: f32,
) -> (
	layout.Pane_Rect,
	bool,
) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || pane.content.kind != .Settings {return {}, false}
	return pane, true
}

@(require_results)
settings_pane_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, card: int) -> render.Build_Status {
	if card < len(w.list.rects) {w.list.rects[card].color = app.theme.pane}
	result := ui.editor_draw(
		&w.editor,
		settings_layout_for(w, pane),
		&w.list,
		&w.ui_text,
		app.theme,
		w.focused && pane.node == window_tree(w).focus && !palette_active(app, w),
		w.pointer,
	)
	if result != .Ok {return result}
	if header := pane_header_draw(app, w, pane, nil); header != .Ok {return header}
	window_card_dim(app, w, pane, app.theme.pane)
	window_card_outline(app, w, pane)
	return .Ok
}

// Keeps the window's settings page matching its workspace: load one when a settings pane arrives
// from another workspace, and release it when the last settings pane leaves.
workspace_settings_sync :: proc(app: ^App, workspace: ^Workspace) {
	if workspace == nil {return}
	present := workspace_has_content(workspace, {.Settings, 0})
	if !present {workspace.settings_scroll = 0}
	for w in app.windows {
		if w.workspace != workspace {continue}
		if present {
			if !ui.editor_loaded(&w.editor) && app.settings_path != "" {_ = settings_load(app, &w.editor)}
		} else if ui.editor_loaded(&w.editor) {ui.editor_destroy(&w.editor)}
	}
}

// The workspace holding the settings pane, preferring w's own. Layouts saved before the app kept to one
// settings pane may still hold several.
@(private = "file", require_results)
settings_workspace :: proc(app: ^App, w: ^Window) -> ^Workspace {
	if settings_tab_index(w.workspace) >= 0 {return w.workspace}
	for workspace in app.workspaces {
		if workspace_eligible(app, workspace) && settings_tab_index(workspace) >= 0 {return workspace}
	}
	return nil
}

// Focuses the settings pane in the window showing its workspace, which w takes over when none does.
@(private = "file")
settings_focus :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> ^Window {
	owner := window_for_workspace(app, workspace)
	if owner == nil {
		if !workspace_select(app, w, workspace) {
			notify(app, .Error, "Could not show the settings tab.")
			return nil
		}
		owner = w
	}
	tab_select(app, owner, settings_tab_index(workspace))
	if node, found := settings_pane_node(workspace); found {pane_focus(app, owner, node)}
	if owner != w {_ = window_activate(app, owner)}
	return owner
}

// Focuses the settings tab wherever it is, or creates one here and loads the settings file. The app keeps a
// single settings tab. Returns the window showing it, which may not be w, or nil if it could not be shown.
editor_open :: proc(app: ^App, w: ^Window) -> ^Window {
	if !gesture_cancel(app, w) {return nil}
	palette_close(app, w)
	find_close(app, w, find_target(app, w))
	if workspace := settings_workspace(app, w); workspace != nil {return settings_focus(app, w, workspace)}
	if !settings_load(app, &w.editor) {return nil}
	tab, reserved := tab_record_reserve(w.workspace)
	if !reserved {
		ui.editor_destroy(&w.editor)
		notify(app, .Error, "Could not open the settings tab.")
		return nil
	}
	if layout.init(&tab.tree, {.Settings, 0}) != nil {
		tab_record_free(tab)
		ui.editor_destroy(&w.editor)
		notify(app, .Error, "Could not open the settings tab.")
		return nil
	}
	tab_record_commit(app, w.workspace, tab)
	tab_select(app, w, len(w.workspace.tabs) - 1)
	return w
}

