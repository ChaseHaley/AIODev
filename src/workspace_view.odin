package main

import "aio:layout"
import "aio:render"
import "aio:term_view"
import "aio:ui"

Workspace_View_Resources :: struct {
	workspace: ^Workspace,
	tree: ^layout.Layout,
	editor: ui.Editor,
	views: [dynamic]Pane_View,
	tab_controls: [dynamic]ui.Control_Motion,
	tab_positions: [dynamic]ui.Motion,
	panes: [dynamic]layout.Pane_Rect,
	dividers: [dynamic]layout.Divider,
}

@(require_results)
workspace_view_init :: proc(app: ^App, resources: ^Workspace_View_Resources, workspace: ^Workspace) -> bool {
	resources.workspace, resources.tree = workspace, &selected_tab(workspace).tree
	resources.views = make([dynamic]Pane_View)
	resources.panes = make([dynamic]layout.Pane_Rect)
	resources.tab_controls = make([dynamic]ui.Control_Motion)
	if settings_tab_index(workspace) >= 0 && !settings_load(app, &resources.editor) {
		workspace_view_destroy(resources)
		return false
	}
	return true
}

// Deletion must finish every fallible allocation before it releases the old workspace.
// Preview windows use init alone: they must not create views or resize borrowed sessions.
@(require_results)
workspace_view_prepare :: proc(
	app: ^App,
	resources: ^Workspace_View_Resources,
	workspace: ^Workspace,
) -> bool {
	if !workspace_view_init(app, resources, workspace) {return false}
	prepared := false
	defer if !prepared {workspace_view_destroy(resources)}
	if resize(&resources.tab_controls, len(workspace.tabs) + 1) != nil ||
	   resize(&resources.tab_positions, len(workspace.tabs)) != nil ||
	   reserve(&resources.panes, len(resources.tree.nodes)) != nil ||
	   reserve(&resources.dividers, len(resources.tree.nodes)) != nil ||
	   reserve(&resources.views, len(resources.tree.nodes)) != nil {return false}
	for &position, i in resources.tab_positions {position.value, position.target = f32(i), f32(i)}
	for node in resources.tree.nodes {
		pane, ok := node.(layout.Pane)
		if !ok || pane.content.kind != .Terminal {continue}
		view: term_view.View
		if !term_view.create(&view) {return false}
		append(&resources.views, Pane_View{content = pane.content, view = view, cache = render.draw_list_init()})
	}
	prepared = true
	return true
}

workspace_view_destroy :: proc(resources: ^Workspace_View_Resources) {
	for &pane in resources.views {
		term_view.destroy(&pane.view)
		render.draw_list_destroy(&pane.cache)
	}
	delete(resources.views)
	delete(resources.tab_controls)
	delete(resources.tab_positions)
	delete(resources.panes)
	delete(resources.dividers)
	ui.editor_destroy(&resources.editor)
	resources^ = {}
}

workspace_view_move :: proc(destination, source: ^Workspace_View_Resources) {
	assert(destination != source)
	workspace_view_destroy(destination)
	destination^, source^ = source^, {}
}

// Ordinary selection retains geometry/view storage until relayout reconciles its contents.
workspace_view_rebind :: proc(destination, prepared: ^Workspace_View_Resources) {
	assert(destination != prepared)
	destination.editor, prepared.editor = prepared.editor, destination.editor
	destination.workspace, destination.tree = prepared.workspace, prepared.tree
	clear(&destination.tab_positions)
	clear(&destination.tab_controls)
	workspace_view_destroy(prepared)
}

// How much of the incoming workspace is prepared before the window stops showing the old one.
Workspace_Adoption :: enum {
	// Selection keeps view and geometry storage; relayout reconciles it with the new workspace.
	Retain,
	// Deletion pre-flights every view, so the replacement is complete before the old workspace
	// is released, and then moves the prepared storage over the old view.
	Replace,
}

// Adopts workspace into w as its displayed workspace. Preparation depth, the presentation
// reset, storage handover, anchor repair, relayout and focus re-entry happen in the one order
// both selection and deletion need. The caller has already established that no other window
// displays workspace and that it has a selected tab. A failure before the old view is released
// leaves w displaying and holding its previous workspace.
@(require_results)
workspace_adopt :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	adoption: Workspace_Adoption,
) -> bool {
	prepared: Workspace_View_Resources
	switch adoption {
	case .Retain:
		if !workspace_view_init(app, &prepared, workspace) {return false}
	case .Replace:
		if !workspace_view_prepare(app, &prepared, workspace) {return false}
	}
	defer workspace_view_destroy(&prepared)
	if !gesture_cancel(app, w) {return false}
	focus_leave(app, w)
	tab_close_restore(w)
	w.tab_menu.open, w.rename_open = false, false
	workspace_picker_cancel(w)
	pending_close_clear(&w.pending_close)
	clear(&w.close_restore)
	switch adoption {
	case .Retain:
		workspace_view_rebind(&w.resources, &prepared)
	case .Replace:
		workspace_view_move(&w.resources, &prepared)
	}
	if workspace.selection_anchor == 0 {tab_select_one(workspace, workspace.selected)}
	w.tab_underline = {
		value  = f32(workspace.selected),
		target = f32(workspace.selected),
	}
	w.tab_hover, w.tab_close_pressed, w.tab_pressed = -1, -1, false
	window_relayout(app, w)
	focus_enter(app, w)
	return true
}
