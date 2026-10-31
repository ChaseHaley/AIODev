package main

import "aio:layout"

Workspace_Move_Request :: struct {
	workspace, tab: u32,
	node: layout.Node_Id,
	whole_tab: bool,
}

workspace_move_request :: proc(w: ^Window, whole_tab: bool) -> Workspace_Move_Request {
	return {w.workspace.id, selected_tab(w.workspace).id, w.tree.focus, whole_tab}
}

workspace_move_open :: proc(app: ^App, w: ^Window, whole_tab: bool) {
	request := workspace_move_request(w, whole_tab)
	workspace_picker_open(app, w)
	if w.workspace_picker.mode != .List {return}
	w.workspace_picker.move = request
	workspace_picker_filter(app, w)
}

workspace_move_new :: proc(app: ^App, w: ^Window, whole_tab: bool) {
	request := workspace_move_request(w, whole_tab)
	workspace_move_choose(app, w, request, 0)
}

workspace_move_choose :: proc(app: ^App, w: ^Window, request: Workspace_Move_Request, id: u32) {
	destination := id == 0 ? workspace_create_empty(app) : workspace_find(app, id)
	if destination == nil {
		notify(app, .Error, "The destination workspace is unavailable.")
		return
	}
	if !workspace_move_content(app, w, request, destination) {
		if id == 0 {_ = workspace_discard_empty(app, destination)}
		notify(app, .Error, "Could not move the content. The source was preserved.")
	}
}

@(require_results)
workspace_move_content :: proc(
	app: ^App,
	w: ^Window,
	request: Workspace_Move_Request,
	destination: ^Workspace,
) -> bool {
	source_workspace := workspace_find(app, request.workspace)
	if source_workspace == nil || w.workspace != source_workspace ||
	   !workspace_eligible(app, destination) || destination == source_workspace {return false}
	index := tab_index_by_id(source_workspace, request.tab)
	if index < 0 {return false}
	source := source_workspace.tabs[index]
	if request.whole_tab {
		if workspace_has_content(destination, {.Settings, 0}) {
			walk := workspace_tab_panes(app, &source.tree, index)
			for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
				if pane.content.kind == .Settings {return false}
			}
		}
	} else {
		if int(request.node) >= len(source.tree.nodes) {return false}
		pane, valid := source.tree.nodes[request.node].(layout.Pane)
		if !valid || !pane_content_can_join(pane.content, destination, source) {return false}
	}
	tab, err := tab_record_reserve(destination)
	if err != .None {return false}
	focus_leave(app, w)
	owner := window_for_workspace(app, destination)
	if owner != nil {focus_leave(app, owner)}
	if request.whole_tab {
		tab.tree, source.tree = source.tree, {root = layout.INVALID_NODE, focus = layout.INVALID_NODE}
		tab.name, source.name = source.name, ""
	} else {
		tree, ok := layout.separate_pane(&source.tree, request.node)
		if !ok {
			tab_record_free(tab)
			focus_enter(app, w)
			if owner != nil {focus_enter(app, owner)}
			return false
		}
		tab.tree = tree
	}
	tab_record_commit(app, destination, tab)
	tab_select_one(destination, len(destination.tabs) - 1)
	destination.selected = len(destination.tabs) - 1
	if source.tree.root == layout.INVALID_NODE {
		workspace_close_tab(app, source_workspace, index)
	} else {
		tab_update_title(app, source)
		workspace_settings_sync(app, source_workspace)
		window_relayout(app, w)
		focus_enter(app, w)
	}
	workspace_settings_sync(app, destination)
	if owner != nil {
		owner.tree = &tab.tree
		window_relayout(app, owner)
		focus_enter(app, owner)
	}
	if !workspace_select(app, w, destination) {
		notify(app, .Error, "Content moved, but the destination could not be displayed.")
	}
	workspace_close_empty(app, source_workspace, replace_window = owner == nil)
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	return true
}
