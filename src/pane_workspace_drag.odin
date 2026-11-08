package main


// Holds w's workspace dropdown open while the pane drag is on it; Shift, which swaps panes, never holds it.
pane_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32, swap: bool) -> bool {
	a, carry := pane_drag_state(source)
	if a == nil {return false}
	held, on := Drop_Workspace_Dropdown{}, false
	if !swap {
		home, _, _ := pane_source_leaves(app, carry.source, carry.node)
		if home.workspace == nil {return false}
		request := Workspace_Move_Request{home.workspace.id, home.tab.id, home.node, false}
		move_allowed := workspace_pane_move_allowed(app, carry.source, carry.node)
		new_window_allowed := pane_window_source_can_lose(app, carry.source, carry.node)
		held, on = workspace_picker_drag_hover(app, a, w, x, y, request, move_allowed, new_window_allowed)
	}
	if !on {
		if _, holding := carry.destination.(Drop_Workspace_Dropdown); holding {
			pane_drag_retarget(app, source, a, nil)
		}
		return false
	}
	carry.visit.hover = nil
	pane_drag_retarget(app, source, a, held)
	source.dirty, w.dirty = true, true
	return true
}

pane_workspace_drag_release :: proc(
	app: ^App,
	source: ^Window,
	a: ^Drag_Active,
	held: Drop_Workspace_Dropdown,
) {
	carry := &a.carry.(Pane_Carry)
	drop := workspace_picker_drag_drop(app, held)
	if _, new_window := drop.(Workspace_Drop_New_Window); !new_window {tear_off_preview_discard(app, a)}
	switch row in drop {
	case nil:
		drag_let_go(app, source, a)
		pane_drag_restore(app, source, carry)
		return
	case Workspace_Drop_Row:
		pane_workspace_drop_move(app, source, a, row.request, Workspace_Move_Existing{row.id})
		return
	case Workspace_Drop_New_Workspace:
		pane_workspace_drop_move(app, source, a, row.request, Workspace_Move_New{})
		return
	case Workspace_Drop_New_Window:
	}
	if tear_off_preview_ensure(app, a, false) != nil && tear_off_commit(app, source, a) {
		drag_free(app, a)
		return
	}
	drag_let_go(app, source, a)
	pane_drag_restore(app, source, carry)
	notify(app, .Error, "Could not move the pane to a new window. The source was preserved.")
}

@(private = "file")
pane_workspace_drop_move :: proc(
	app: ^App,
	source: ^Window,
	a: ^Drag_Active,
	request: Workspace_Move_Request,
	destination: Workspace_Move_Destination,
) {
	drag_let_go(app, source, a)
	workspace_move_choose(app, pane_link_acting_window(app, source), request, destination)
}
