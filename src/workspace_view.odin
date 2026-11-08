package main

import "aio:layout"
import "aio:ui"

Workspace_View_Resources :: struct {
	workspace: ^Workspace,
	editor: ui.Editor,
	views: [dynamic]Pane_View,
	using presentation: Tab_Presentation,
	panes: [dynamic]layout.Pane_Rect,
	dividers: [dynamic]layout.Divider,
}

// The layout the view shows: always its workspace's selected tab, so it follows selection and membership.
// Nil while the workspace has no tab to show.
workspace_view_tree :: proc(resources: ^Workspace_View_Resources) -> ^layout.Layout {
	workspace := resources.workspace
	if workspace == nil || workspace.selected < 0 || workspace.selected >= len(workspace.tabs) {return nil}
	return &workspace.tabs[workspace.selected].tree
}

@(require_results)
workspace_view_init :: proc(app: ^App, resources: ^Workspace_View_Resources, workspace: ^Workspace) -> bool {
	resources.workspace = workspace
	resources.views = make([dynamic]Pane_View)
	resources.panes = make([dynamic]layout.Pane_Rect)
	tab_presentation_init(&resources.presentation)
	if settings_tab_index(workspace) >= 0 && !settings_load(app, &resources.editor) {
		workspace_view_destroy(resources)
		return false
	}
	resources.editor.scroll = workspace.settings_scroll
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
	tree := workspace_view_tree(resources)
	if !tab_presentation_resize(&resources.presentation, len(workspace.tabs)) ||
	   reserve(&resources.panes, len(tree.nodes)) != nil ||
	   reserve(&resources.dividers, len(tree.nodes)) != nil ||
	   reserve(&resources.views, len(tree.nodes)) != nil {return false}
	walk := workspace_tab_panes(app, tree, resources.workspace.selected)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		entry, created := pane_view_create(pane.content, pane.session != nil)
		if !created {return false}
		append(&resources.views, entry)
	}
	prepared = true
	return true
}

workspace_view_destroy :: proc(resources: ^Workspace_View_Resources) {
	for &pane in resources.views {pane_view_destroy(&pane)}
	delete(resources.views)
	tab_presentation_destroy(&resources.presentation)
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
	destination.workspace = prepared.workspace
	tab_presentation_clear(&destination.presentation)
	workspace_view_destroy(prepared)
}

// How much of the incoming workspace is prepared before the window stops showing the old one.
Workspace_Adoption :: enum {
	// Selection keeps view and geometry storage; relayout reconciles it with the new workspace.
	Retain,
	// Deletion pre-flights every view and then moves the prepared storage over the old one.
	Replace,
}

// The one order selection and deletion both need. The caller has established exclusive ownership
// and a selected tab; a failure before the handover leaves the previous workspace displayed.
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
	confirmation_workspace_depart(app, w)
	overlay_close(app, w)
	workspace_picker_cancel(w)
	// Editor storage belongs to the window; its reading position belongs to the workspace.
	w.workspace.settings_scroll = w.editor.scroll
	switch adoption {
	case .Retain:
		workspace_view_rebind(&w.resources, &prepared)
	case .Replace:
		workspace_view_move(&w.resources, &prepared)
	}
	if workspace.selection_anchor == 0 {tab_select_one(workspace, workspace.selected)}
	tab_chrome_reset(w)
	window_relayout(app, w)
	rail_reveal_active(w)
	focus_enter(app, w)
	return true
}
