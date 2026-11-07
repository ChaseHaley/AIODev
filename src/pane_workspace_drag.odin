package main

import "aio:layout"

// Holds w's workspace dropdown open while the pane drag is on it; Shift, which swaps panes, never holds it.
pane_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32, swap: bool) -> bool {
	a, carry := pane_drag_state(source)
	if a == nil {return false}
	held, on := Drop_Workspace_Dropdown{}, false
	if !swap {
		home, _, found := pane_link_origin(app, carry.source, carry.node)
		if !found {return false}
		request := Workspace_Move_Request{home.workspace.id, home.tab.id, home.node, false}
		allowed := pane_window_source_can_lose(app, carry.source, carry.node)
		held, on = workspace_picker_drag_hover(app, a, w, x, y, request, allowed)
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
		pane_workspace_drop_move(app, source, a, carry, row.request, Workspace_Move_Existing{row.id})
		return
	case Workspace_Drop_New_Workspace:
		pane_workspace_drop_move(app, source, a, carry, row.request, Workspace_Move_New{})
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
	carry: ^Pane_Carry,
	request: Workspace_Move_Request,
	destination: Workspace_Move_Destination,
) {
	drag_let_go(app, source, a)
	workspace_move_choose(app, pane_link_acting_window(app, source), request, destination)
	if window_linked(source) {
		pane, is_pane := carry.source.tree.nodes[carry.node].(layout.Pane)
		if is_pane {pane_link_refresh_source(app, source, pane.content)}
	}
}
