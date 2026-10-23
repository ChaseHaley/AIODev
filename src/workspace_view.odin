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
workspace_view_prepare :: proc(app: ^App, resources: ^Workspace_View_Resources, workspace: ^Workspace) -> bool {
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
