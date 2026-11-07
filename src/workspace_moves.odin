package main

import "aio:layout"
import "core:slice"

Workspace_Move_Request :: struct {
	workspace, tab: u32,
	node: layout.Node_Id,
	whole_tab: bool,
}

// Where moved content goes: a workspace that exists, or one the move creates.
Workspace_Move_Destination :: union {
	Workspace_Move_Existing,
	Workspace_Move_New,
}

Workspace_Move_Existing :: struct {
	id: u32,
}

// A new workspace, which takes a suggested name to edit in its chip once the content is in it.
Workspace_Move_New :: struct {}

// Tabs leaving `source` for `destination`. `tabs` names source tabs in source order and is borrowed for the
// call; they land at `at` in that order, and the destination selects the record of `selected`, else the
// first. `replacing` is a destination record the tabs take the place of: a tear-off preview's placeholder,
// which borrows the dragged tab's own content until they arrive.
Workspace_Tab_Transfer :: struct {
	source, destination: ^Workspace,
	tabs:                []u32,
	at:                  int,
	selected:            u32,
	replacing:           ^Tab,
}

// What a workspace operation changed, for workspace_mutation_finish.
Workspace_Change :: enum {
	// Tabs or panes joined or left the workspace.
	Structure,
	// Workspaces, or what their picker rows show, were added, removed or renamed.
	Names,
	// Workspaces changed places in the list.
	Order,
}

// What moving tabs out of a window's workspace did. Moving its last tabs can close that window, so a caller
// may use the window again only after Moved.
Tab_Move_Result :: enum {
	Failed,
	Moved,
	Moved_Window_Closed,
}

// Moves tab `index`, or its focused pane when whole_tab is false.
workspace_move_request :: proc(w: ^Window, whole_tab: bool, index: int) -> Workspace_Move_Request {
	tab := w.workspace.tabs[index]
	return {w.workspace.id, tab.id, tab.tree.focus, whole_tab}
}

workspace_move_open :: proc(app: ^App, w: ^Window, whole_tab: bool, index: int) {
	request := workspace_move_request(w, whole_tab, index)
	workspace_picker_open(app, w)
	if _, listing := w.workspace_picker.state.(Workspace_Picker_List); !listing {return}
	workspace_picker_list_set(w, Workspace_Move_Target{request = request})
	workspace_picker_filter(app, w)
}

workspace_move_new :: proc(app: ^App, w: ^Window, whole_tab: bool, index: int) {
	request := workspace_move_request(w, whole_tab, index)
	workspace_move_choose(app, w, request, Workspace_Move_New{})
}

workspace_move_choose :: proc(
	app: ^App,
	w: ^Window,
	request: Workspace_Move_Request,
	destination: Workspace_Move_Destination,
) {
	workspace, created := workspace_move_destination(app, destination)
	if workspace == nil {
		notify(app, .Error, "The destination workspace is unavailable.")
		return
	}
	moved := workspace_move_content(app, w, request, workspace)
	workspace_move_destination_settle(app, workspace, created, moved)
	if !moved {notify(app, .Error, "Could not move the content. The source was preserved.")}
}

// The workspace a move goes to, creating the one a Workspace_Move_New asks for; nil when it is unavailable.
@(require_results)
workspace_move_destination :: proc(
	app: ^App,
	destination: Workspace_Move_Destination,
) -> (
	workspace: ^Workspace,
	created: bool,
) {
	switch d in destination {
	case nil:
	case Workspace_Move_Existing: workspace = workspace_find(app, d.id)
	case Workspace_Move_New: workspace, created = workspace_create_empty(app), true
	}
	return workspace, created && workspace != nil
}

// A workspace the move created starts naming in its chip once the content is in it, and goes away again
// when the move failed.
workspace_move_destination_settle :: proc(app: ^App, workspace: ^Workspace, created, moved: bool) {
	if !created {return}
	if !moved {
		_ = workspace_discard_empty(app, workspace)
	} else if owner := window_for_workspace(app, workspace); owner != nil {
		workspace_name_begin(app, owner)
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
	if source_workspace == nil || w.workspace != source_workspace {return false}
	if request.whole_tab {
		tabs := [1]u32{request.tab}
		return workspace_tabs_move(app, w, destination, tabs[:], request.tab, len(destination.tabs)) != .Failed
	}
	if !workspace_eligible(app, destination) || destination == source_workspace {return false}
	index := tab_index_by_id(source_workspace, request.tab)
	if index < 0 {return false}
	source := source_workspace.tabs[index]
	if int(request.node) >= len(source.tree.nodes) {return false}
	pane, valid := source.tree.nodes[request.node].(layout.Pane)
	if !valid || !pane_content_can_join(pane.content, destination, source) {return false}
	tab, reserved := tab_record_reserve(destination)
	if !reserved {return false}
	focus_leave(app, w)
	owner := window_for_workspace(app, destination)
	if owner != nil {focus_leave(app, owner)}
	tree, separated := layout.separate_pane(&source.tree, request.node)
	if !separated {
		tab_record_free(tab)
		focus_enter(app, w)
		if owner != nil {focus_enter(app, owner)}
		return false
	}
	tab.tree = tree
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
		window_relayout(app, owner)
		focus_enter(app, owner)
	}
	if !workspace_select(app, w, destination) {
		notify(app, .Error, "Content moved, but the destination could not be displayed.")
	}
	workspace_close_empty(app, source_workspace, replace_window = owner == nil)
	workspace_mutation_finish(app, destination, {.Names})
	return true
}

// Moves the tabs `tabs` names from w's workspace into another workspace at `at`; the menu, the keyboard
// and a drag onto a window or a workspace row all come here. Everything that can fail is checked before
// focus leaves, so a failure changes nothing. A destination shown in a window of its own takes focus
// first, so Windows does not hand it to another app as the source closes; otherwise w adopts the
// destination. A source left without tabs retires.
@(require_results)
workspace_tabs_move :: proc(
	app: ^App,
	w: ^Window,
	destination: ^Workspace,
	tabs: []u32,
	selected: u32,
	at: int,
) -> Tab_Move_Result {
	source := w.workspace
	transfer := Workspace_Tab_Transfer{source, destination, tabs, at, selected, nil}
	if window_linked(w) ||
	   !workspace_eligible(app, destination) ||
	   !workspace_tabs_transfer_reserve(app, transfer) {
		return .Failed
	}
	owner := window_for_workspace(app, destination)
	if owner != nil {
		_ = window_activate(app, owner)
		focus_leave(app, owner)
	}
	kept := tab_kept_index(source, tabs)
	if kept < 0 {
		// Every tab goes, so the window stays left until it adopts the destination or closes with its
		// emptied workspace.
		focus_leave(app, w)
	} else {
		tab_select(app, w, kept, .Preserve_Marks)
	}
	workspace_tabs_transfer(app, transfer)
	if kept >= 0 {
		marked := false
		for tab in source.tabs {if tab.marked {marked = true}}
		if !marked {tab_select_one(source, source.selected)}
		window_relayout(app, w)
		rail_reveal_active(w)
	}
	if owner != nil {
		tab_incoming_set(app, owner.id, {})
		if owner.tabs_horizontal {owner.tab_hover = nil}
		window_relayout(app, owner)
		rail_reveal_active(owner)
		focus_enter(app, owner)
	} else if !workspace_select(app, w, destination) {
		notify(app, .Error, "The tabs moved, but their workspace could not be displayed.")
	}
	workspace_mutation_finish(app, source, {.Structure})
	workspace_mutation_finish(app, destination, {.Structure, .Names})
	id := w.id
	workspace_close_empty(app, source, replace_window = owner == nil)
	return window_find(app, id) == w ? .Moved : .Moved_Window_Closed
}

// The tab that stays shown as `tabs` leave: the nearest that stays, preferring the right as a close does.
@(private, require_results)
tab_kept_index :: proc(workspace: ^Workspace, tabs: []u32) -> int {
	for i in workspace.selected ..< len(workspace.tabs) {
		if !slice.contains(tabs, workspace.tabs[i].id) {return i}
	}
	for i := workspace.selected - 1; i >= 0; i -= 1 {
		if !slice.contains(tabs, workspace.tabs[i].id) {return i}
	}
	return -1
}

// Checks everything a transfer needs and reserves its storage, so workspace_tabs_transfer cannot fail: the
// tabs exist, their content may join the destination, and the destination's tab list and the presentation
// of every window showing it have room. Nothing visible changes, so a caller can still give up.
@(require_results)
workspace_tabs_transfer_reserve :: proc(app: ^App, transfer: Workspace_Tab_Transfer) -> bool {
	source, destination := transfer.source, transfer.destination
	if source == nil || destination == nil || source == destination || len(transfer.tabs) == 0 {return false}
	for id in transfer.tabs {
		index := tab_index_by_id(source, id)
		if index < 0 {return false}
		for node in source.tabs[index].tree.nodes {
			pane := node.(layout.Pane) or_continue
			if !pane_content_can_join(pane.content, destination, transfer.replacing) {return false}
		}
	}
	count := len(destination.tabs) + len(transfer.tabs)
	if reserve(&destination.tabs, count) != nil {return false}
	for w in app.windows {
		if w.workspace == destination && !tab_presentation_reserve(&w.presentation, count) {return false}
	}
	return true
}

// Moves the tabs' complete records, so layout, name, title and pinned documents travel together and no
// session restarts. Each takes a fresh destination id, as a created tab does, and the destination marks
// exactly the moved tabs. Windows showing either workspace keep their tab presentation in step; focus and
// relayout stay with the caller. A source left without tabs keeps its emptied list for its retirement.
// workspace_tabs_transfer_reserve must have accepted the transfer, with nothing changed since.
workspace_tabs_transfer :: proc(app: ^App, transfer: Workspace_Tab_Transfer) {
	source, destination := transfer.source, transfer.destination
	at := clamp(transfer.at, 0, len(destination.tabs))
	for tab in destination.tabs {tab.marked = false}
	selected := -1
	for id, i in transfer.tabs {
		index := tab_index_by_id(source, id)
		tab := source.tabs[index]
		ordered_remove(&source.tabs, index)
		source.selected = tab_selected_after_remove(source.selected, index, len(source.tabs))
		for w in app.windows {if w.workspace == source {tab_presentation_remove(&w.presentation, index)}}
		destination.next_tab_id += 1
		tab.id = destination.next_tab_id
		tab.marked = true
		inject_at(&destination.tabs, at + i, tab)
		if selected < 0 || id == transfer.selected {selected = at + i}
	}
	for w in app.windows {
		if w.workspace == destination {tab_presentation_insert(&w.presentation, at, len(transfer.tabs))}
	}
	destination.selected = selected
	destination.selection_anchor = destination.tabs[selected].id
	if transfer.replacing == nil {return}
	index, _ := slice.linear_search(destination.tabs[:], transfer.replacing)
	ordered_remove(&destination.tabs, index)
	destination.selected = tab_selected_after_remove(destination.selected, index, len(destination.tabs))
	for w in app.windows {if w.workspace == destination {tab_presentation_remove(&w.presentation, index)}}
	tab_record_free(transfer.replacing)
}

// Completes a workspace operation once its focus has settled, calling each known follow-up directly: the
// workspace's Settings page follows its pane, open pickers show the changed rows (keeping their scroll when
// only the order changed), the layout is saved and every window redraws.
workspace_mutation_finish :: proc(app: ^App, workspace: ^Workspace, changes: bit_set[Workspace_Change]) {
	if .Structure in changes {workspace_settings_sync(app, workspace)}
	if .Names in changes {
		workspace_pickers_refresh(app)
	} else if .Order in changes {
		workspace_pickers_refresh(app, preserve_scroll = true)
	}
	layout_state_touch(app)
	mark_all_dirty(app)
}
