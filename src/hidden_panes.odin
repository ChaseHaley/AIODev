package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"

// While Zoom, Fill window or Fullscreen shows one tiled pane of a tab that has others, that pane's header
// carries a glyph of the tab's tiled layout. Hovering the glyph shows a map of every tiled pane, named with
// its program status; clicking one shows it in the same view (D-087). The glyph only answers "here are your
// other panes": it looks the same in every view and does not leave it.

// Whether the map shows, and the map cell under the pointer.
Hidden_Panes_State :: struct {
	open:    bool,
	hovered: Maybe(int),
}

// The glyph and map of the pane a window's view shows alone, built in temporary memory.
@(private = "file")
Hidden_Panes :: struct {
	glyph, surface: render.Rect,
	panes:          []ui.Hidden_Pane,
	nodes:          []layout.Node_Id,
	cells:          []render.Rect,
}

// A tiled pane its window's view shows alone, in a tab with other tiled panes.
hidden_panes_glyph_shown :: proc(w: ^Window, pane: layout.Pane_Rect) -> bool {
	if pane.floating || !pane_view_solo(w) {return false}
	tree := window_tree(w)
	return tree != nil && pane.node == layout.focus_tiled(tree) && layout.shown_pane_count(tree) > 1
}

// Every tiled pane of the tab, placed as the split view would place it; false while no pane carries the
// glyph.
@(private = "file")
hidden_panes_of :: proc(app: ^App, w: ^Window) -> (h: Hidden_Panes, ok: bool) {
	for pane in window_tiled_rects(w) {
		if !hidden_panes_glyph_shown(w, pane) {continue}
		h.glyph = pane_header_layout(w, pane).widget
		area := window_content_area(app, w)
		if h.glyph.width <= 0 || area.width <= 0 || area.height <= 0 {return}
		rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
		layout.compute(window_tree(w), area, window_gap(app, w), &rects)
		h.panes = make([]ui.Hidden_Pane, len(rects), context.temp_allocator)
		h.nodes = make([]layout.Node_Id, len(rects), context.temp_allocator)
		for placed, i in rects {
			r := placed.rect
			entry := workspace_session_for_content(app, placed.content)
			status, status_text := pane_status_line(app, entry)
			h.panes[i] = {
				rect        = {(r.x - area.x) / area.width, (r.y - area.y) / area.height,
					r.width / area.width, r.height / area.height},
				title       = content_pane_title(app, entry, placed.content),
				status      = status,
				status_text = status_text,
				shown       = placed.node == pane.node,
			}
			h.nodes[i] = placed.node
		}
		h.surface = ui.hidden_panes_map_rect(h.glyph, f32(w.width), f32(w.height), w.scale)
		h.cells = make([]render.Rect, len(h.panes), context.temp_allocator)
		ui.hidden_panes_map_cells(h.surface, h.panes, w.scale, h.cells)
		return h, true
	}
	return
}

// Draws the glyph into its place in the shown pane's header.
hidden_panes_glyph_draw :: proc(app: ^App, w: ^Window, box: render.Rect) {
	h, ok := hidden_panes_of(app, w)
	if !ok {return}
	ui.hidden_panes_glyph_draw(&w.list, app.theme, box, h.panes, w.hidden_panes.open, w.scale)
}

// Draws the map above the panes while it shows.
hidden_panes_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !w.hidden_panes.open {return .Ok}
	h, ok := hidden_panes_of(app, w)
	if !ok {return .Ok}
	hovered := w.hidden_panes.hovered.? or_else -1
	return ui.hidden_panes_map_draw(
		&w.list, &w.ui_text, app.theme, h.surface, h.panes, hovered, f32(w.width), f32(w.height), w.scale,
	)
}

// Whether the point is on the glyph, or on the open map or the gap above it, and the map cell under it,
// or -1.
@(private = "file")
hidden_panes_hit :: proc(app: ^App, w: ^Window, x, y: f32) -> (h: Hidden_Panes, cell: int, on: bool) {
	cell = -1
	ok: bool
	if h, ok = hidden_panes_of(app, w); !ok {return}
	if render.rect_contains(h.glyph, x, y) {return h, cell, true}
	if !w.hidden_panes.open {return}
	below := h.glyph.y + h.glyph.height
	gap := render.Rect{h.glyph.x, below, h.glyph.width, h.surface.y - below}
	if render.rect_contains(gap, x, y) {return h, cell, true}
	if !render.rect_contains(h.surface, x, y) {return}
	for r, i in h.cells {
		if render.rect_contains(r, x, y) {cell = i; break}
	}
	return h, cell, true
}

@(private = "file")
hidden_panes_set :: proc(w: ^Window, open: bool, hovered: Maybe(int)) {
	next := Hidden_Panes_State{open, open ? hovered : nil}
	if next == w.hidden_panes {return}
	w.hidden_panes, w.dirty = next, true
}

// Hidden panes pointer surface: the glyph opens the map while the pointer is on either, and a pane on the
// map shows on press.

@(private)
hidden_panes_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, on := hidden_panes_hit(app, w, x, y)
	return on
}

@(private)
hidden_panes_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Hidden_Panes {
		hidden_panes_set(w, false, nil)
		return
	}
	h, cell, on := hidden_panes_hit(app, w, f32(e.x), f32(e.y))
	choosable := cell >= 0 && !h.panes[cell].shown
	hidden_panes_set(w, on, choosable ? cell : nil)
	pointer_set(app, w, choosable ? .Hand : .Arrow)
}

// The map takes both halves of a click; a press on another pane shows it in the same view.
@(private)
hidden_panes_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	gesture_swallow(w, e.button, .Hidden_Panes)
	if e.button != .Left {return}
	h, cell, _ := hidden_panes_hit(app, w, f32(e.x), f32(e.y))
	if cell < 0 || h.panes[cell].shown {return}
	hidden_panes_set(w, false, nil)
	pane_focus(app, w, h.nodes[cell])
}

@(private)
hidden_panes_leave :: proc(_: ^App, w: ^Window) {
	hidden_panes_set(w, false, nil)
}

when AIO_CONTROL {
	hidden_panes_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		h, ok := hidden_panes_of(app, w)
		state_rect(r, "panes.hidden_glyph", ok ? h.glyph : {})
		state_rect(r, "panes.hidden_map", ok && w.hidden_panes.open ? h.surface : {})
		state_value(r, "panes.hidden_map_hover", w.hidden_panes.hovered.? or_else -1)
	}
}
