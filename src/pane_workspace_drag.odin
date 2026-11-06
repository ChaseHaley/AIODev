package main

import "aio:layout"

pane_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32, swap: bool) -> bool {
	d := &source.pane_drag
	home, _, found := pane_link_origin(app, d.source, d.node)
	if !found {return false}
	if swap {
		workspace_drag_close(app, &d.picker)
		return false
	}
	request := Workspace_Move_Request{home.workspace.id, home.tab.id, home.node, false}
	new_window_allowed := pane_window_source_can_lose(app, d.source, d.node)
	if !workspace_drag_hover(app, &d.picker, w, x, y, request, new_window_allowed) {return false}
	d.target, d.destination, d.hover = layout.INVALID_NODE, nil, nil
	d.hover_until = {}
	d.shown, d.new_tab, d.new_window, d.swap, d.root = false, false, false, false, false
	d.minimum_rejected = false
	source.dirty, w.dirty = true, true
	return true
}

pane_workspace_drag_wheel :: proc(app: ^App, source: ^Window, delta: f32) -> bool {
	d := &source.pane_drag
	if !d.active {return false}
	w := workspace_drag_scroll(app, &d.picker, delta)
	if w == nil {return false}
	return pane_workspace_drag_move(app, source, w, d.picker_pointer.x, d.picker_pointer.y, false)
}

pane_workspace_drag_release :: proc(app: ^App, source: ^Window, d: Pane_Drag) {
	w := window_find(app, d.picker_window)
	if d.preview_window != 0 {pane_window_preview_discard(app, d.preview_window)}
	if w == nil || !w.workspace_picker.drag {pane_drag_restore(app, source, d); return}
	p := &w.workspace_picker
	hit, count := d.picker_hit, len(p.rows)
	request := p.move
	id := hit >= 0 && hit < count ? p.rows[hit].id : 0
	picker := d.picker
	workspace_drag_close(app, &picker)
	if hit < 0 || hit > count + 1 {pane_drag_restore(app, source, d); return}
	if hit <= count {
		workspace_move_choose(app, pane_link_acting_window(app, source), request, id)
		if source.linked {
			pane, is_pane := d.source.tree.nodes[d.node].(layout.Pane)
			if is_pane {pane_link_refresh_source(app, source, pane.content)}
		}
		return
	}
	if preview := pane_window_preview_create(app, d.source, d.node); preview != nil {
		tear_off := d
		tear_off.preview_window = preview.id
		if pane_tear_off(app, source, tear_off) {return}
		pane_window_preview_discard(app, preview.id)
	}
	pane_drag_restore(app, source, d)
	notify(app, .Error, "Could not move the pane to a new window. The source was preserved.")
}
