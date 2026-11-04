package main

import "aio:layout"
import "aio:ui"
import "core:math"

pane_workspace_drag_close :: proc(app: ^App, d: Pane_Drag) {
	if picker := window_find(app, d.picker_window); picker != nil && picker.workspace_picker.drag {
		workspace_picker_cancel(picker)
	}
}

pane_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32, swap: bool) -> bool {
	d := &source.pane_drag
	home, _, found := pane_link_origin(app, d.source, d.node)
	if !found {return false}
	p := &w.workspace_picker
	button := workspace_button_rect(w)
	on_button := workspace_rect_contains(button, x, y)
	panel, _ := workspace_picker_rect(w)
	// Keep the drag alive through the gap between the chip and its dropdown.
	in_panel := d.picker_window == w.id && p.drag && x >= panel.x && x < panel.x + panel.width &&
		y >= button.y && y < panel.y + panel.height
	if swap || (!on_button && !in_panel) {
		pane_workspace_drag_close(app, d^)
		d.picker_window = 0
		return false
	}
	if d.picker_window != w.id || !p.drag {
		window_overlays_cancel(app, w)
		workspace_picker_transition(w, .List)
		p.move = {home.workspace.id, home.tab.id, home.node, false}
		p.drag = true
		ui.field_set(&p.query, "")
		workspace_picker_filter(app, w)
		d.picker_window = w.id
	}
	d.picker_pointer = {x, y}
	d.picker_hit = workspace_picker_hit(w, x, y)
	if d.picker_hit == len(p.rows) + 1 && !pane_window_source_can_lose(app, d.source, d.node) {
		d.picker_hit = -1
	}
	p.selected = d.picker_hit
	d.target, d.destination, d.hover = layout.INVALID_NODE, nil, nil
	d.hover_until = {}
	d.shown, d.new_tab, d.new_window, d.swap, d.root = false, false, false, false, false
	d.minimum_rejected = false
	source.dirty, w.dirty = true, true
	return true
}

pane_workspace_drag_wheel :: proc(app: ^App, source: ^Window, delta: f32) -> bool {
	d := &source.pane_drag
	w := window_find(app, d.picker_window)
	if !d.active || w == nil || !w.workspace_picker.drag {return false}
	_, visible := workspace_picker_rect(w)
	p := &w.workspace_picker
	p.scroll = clamp(p.scroll - int(math.sign(delta)), 0, max(0, workspace_picker_count(w) - visible))
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
	pane_workspace_drag_close(app, d)
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
