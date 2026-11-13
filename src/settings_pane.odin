package main

import "aio:layout"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "aio:input"

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
	content, ok := window_focused_content(w)
	return ok && content.kind == .Settings
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
// Composition fits the editor before input/drawing; ui.editor_layout remains a pure geometry query.
settings_layout_for :: proc(w: ^Window, pane: layout.Pane_Rect) -> ui.Editor_Layout {
	l := ui.editor_layout(pane_body_rect(w, pane), w.scale, len(w.editor.sections) > 0)
	ui.editor_fit(&w.editor, l)
	return l
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

// The settings page inside its pane; pane_draw draws the card, header and outline around it.
@(require_results)
settings_pane_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) -> render.Build_Status {
	if result := settings_page_icons(app, &w.editor, w.scale); result != .Ok {return result}
	return ui.editor_draw(
		&w.editor,
		settings_layout_for(w, pane),
		&w.list,
		&w.ui_text,
		app.theme,
		pane_shows_focus(w, pane) && !palette_active(app, w),
		w.pointer,
	)
}

// Gives each shown link program line and Icon row the program's icon once it is ready. Rows scrolled
// away or filtered out ask nothing, so they hold no slot in the program icon cache.
@(private = "file", require_results)
settings_page_icons :: proc(app: ^App, p: ^ui.Editor, scale: f32) -> render.Build_Status {
	for &row in p.rows {
		if row.opener != "" {row.icon_atlas = {}}
	}
	last := min(len(p.items), p.scroll + max(1, p.visible_rows) + 1)
	for item in p.items[min(p.scroll, last):last] {
		if item.row < 0 {continue}
		row := &p.rows[item.row]
		if row.opener == "" {continue}
		field, is_field := row.opener_field.?
		if row.kind != .Opener && !(is_field && field == .Icon) {continue}
		opener := settings.opener_find(&app.settings.openers, row.opener)
		if opener == nil {continue}
		atlas, result := link_program_icon(app, opener, ui.ICON_BUTTON * scale)
		if result != .Ok {return result}
		row.icon_atlas = atlas
	}
	return .Ok
}

// Keeps the window's settings page matching its workspace: load one when a settings pane arrives
// from another workspace, and release it when the last settings pane leaves.
workspace_settings_sync :: proc(app: ^App, workspace: ^Workspace) {
	if workspace == nil {return}
	present := workspace_has_content(workspace, {.Settings, 0})
	if !present {
		workspace.settings_scroll = 0
		ui.editor_view_destroy(&workspace.settings_view)
	}
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

// Settings page pointer surface

@(private)
settings_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, found := settings_pane_under_pointer(w, x, y)
	return found
}

@(private)
settings_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Settings_Page {
		if ui.editor_hover_clear(&w.editor) {w.dirty = true}
		return
	}
	x, y := f32(e.x), f32(e.y)
	pane, found := settings_pane_under_pointer(w, x, y)
	if !found {
		// A held scrollbar follows the pointer anywhere, as it does on every other surface, and
		// collapses on release because the pointer is no longer over it.
		if w.editor.popup_bar_hover {w.editor.popup_bar_hover, w.dirty = false, true}
		if w.editor.page_bar_hover {w.editor.page_bar_hover, w.dirty = false, true}
		if ui.editor_scrollbar_dragging(&w.editor) && .Left in e.buttons &&
		   ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y) {w.dirty = true}
		pointer_set(app, w, .Arrow)
		return
	}
	l := settings_layout_for(w, pane)
	changed := ui.editor_hover(&w.editor, l, x, y, &w.ui_text)
	if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) {changed = true}
	if changed {w.dirty = true}
	pointer_set(app, w, ui.editor_pointer(&w.editor, l, x, y, &w.ui_text))
}

@(private)
settings_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	return w.editor.hover_reset >= 0 ? "Reset setting" : ""
}

@(private)
settings_pointer_cancel :: proc(_: ^App, w: ^Window) {
	ui.editor_hover_clear(&w.editor)
	ui.editor_pointer_cancel(&w.editor)
}

@(private)
settings_leave :: proc(_: ^App, w: ^Window) {
	ui.editor_hover_clear(&w.editor)
}

// A press on a settings pane focuses it, then reaches the page.
@(private)
settings_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	pane_press_focus(app, w, f32(e.x), f32(e.y))
	settings_page_press(app, w, e)
}

// The focused page takes a Left press.
@(private)
settings_page_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button != .Left || !settings_active(w) {return}
	x, y := f32(e.x), f32(e.y)
	press := ui.editor_press(&w.editor, settings_layout(w), &w.ui_text, x, y, .Shift in e.modifiers)
	editor_outcome(app, w, press)
}

// The release of a page press. A confirmation or the palette that opened since takes it first, in the
// shared completion (gesture_finish). Otherwise a held process-group row drops where it is released,
// then the focused page finishes its press.
@(private)
settings_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || confirmation_current(w) != nil || palette_active(app, w) {return false}
	w.dirty = true
	x, y := f32(e.x), f32(e.y)
	if ui.editor_order_dragging(&w.editor, .Process_Groups) {
		_ = ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y)
		editor_outcome(app, w, ui.editor_release(&w.editor))
		return true
	}
	if !settings_active(w) {return false}
	editor_outcome(app, w, ui.editor_release(&w.editor))
	return true
}
