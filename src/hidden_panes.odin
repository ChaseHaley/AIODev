package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:term_view"
import "aio:ui"
import "core:log"
import "core:time"

// While Zoom, Fill window or Fullscreen shows one tiled pane of a tab that has others, that pane's header
// carries a glyph of the tab's tiled layout. Hovering the glyph shows a map of every tiled pane, each card
// labelled with the pane's badge, title and status dot and previewing a terminal's screen as cell blocks;
// clicking one shows it in the same view (D-087, D-089). The glyph only answers "here are your other panes":
// it looks the same in every view and does not leave it. The map stays while the pointer heads from the
// glyph to it (ui.Hover_Reveal).

// The map's reveal from the glyph, the map cell under the pointer, and while the map shows, a render state
// for each hidden terminal it previews.
Hidden_Panes_State :: struct {
	reveal:   ui.Hover_Reveal,
	hovered:  Maybe(int),
	previews: [dynamic]Hidden_Pane_Preview,
}

// A hidden terminal's own view of its screen, read only for the map's preview.
@(private)
Hidden_Pane_Preview :: struct {
	content: layout.Content,
	view:    term_view.View,
	// Drawn by the frame being built, so the pass that ends the frame keeps it.
	used:    bool,
}

// The glyph and map of the pane a window's view shows alone, built in temporary memory.
@(private = "file")
Hidden_Panes :: struct {
	glyph, surface: render.Rect,
	panes:          []ui.Hidden_Pane,
	nodes:          []layout.Node_Id,
	contents:       []layout.Content,
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
		h.contents = make([]layout.Content, len(rects), context.temp_allocator)
		for placed, i in rects {
			r := placed.rect
			entry := workspace_session_for_content(app, placed.content)
			status, _ := pane_status_line(app, entry)
			h.panes[i] = {
				rect   = {(r.x - area.x) / area.width, (r.y - area.y) / area.height,
					r.width / area.width, r.height / area.height},
				title  = content_pane_title(app, entry, placed.content),
				status = status,
				shown  = placed.node == pane.node,
			}
			h.nodes[i] = placed.node
			h.contents[i] = placed.content
		}
		h.surface = ui.hidden_panes_map_rect(
			h.glyph, {area.width, area.height}, f32(w.width), f32(w.height), w.scale,
		)
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
	ui.hidden_panes_glyph_draw(&w.list, app.theme, box, h.panes, w.hidden_panes.reveal.open, w.scale)
}

// Draws the map above the panes while it shows: the cards, a cell-block preview of each hidden terminal,
// then each card's label.
hidden_panes_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !w.hidden_panes.reveal.open {return .Ok}
	h, ok := hidden_panes_of(app, w)
	if !ok {return .Ok}
	for &pane, i in h.panes {
		entry := workspace_session_for_content(app, h.contents[i])
		badge, result := content_badge(app, entry, h.contents[i].kind, ui.ICON_INDICATOR * w.scale)
		if result != .Ok {return result}
		pane.icon, pane.glyph, pane.atlas = badge.icon, badge.glyph, badge.atlas
	}
	width, height := f32(w.width), f32(w.height)
	if !ui.hidden_panes_map_open(&w.list, app.theme, h.surface, h.cells, h.panes, width, height, w.scale) {
		return .Ok
	}
	for &preview in w.hidden_panes.previews {preview.used = false}
	for pane, i in h.panes {
		if pane.shown {continue}
		entry := workspace_session_for_content(app, h.contents[i])
		if entry == nil {continue}
		view := hidden_panes_preview(w, h.contents[i])
		if view == nil {continue}
		card := h.cells[i]
		if render.push_layer(&w.list, card, ui.hidden_panes_card_radius(card, w.scale)) != .None {return .Ok}
		g := term.geometry(entry.session)
		_ = term_view.blocks_build(view, entry.session, &w.list, card, {f32(g.cell_width), f32(g.cell_height)})
	}
	hidden_panes_previews_prune(w)
	hovered := w.hidden_panes.hovered.? or_else -1
	return ui.hidden_panes_map_labels(
		&w.list, &w.ui_text, app.theme, h.surface, h.cells, h.panes, hovered, w.scale,
	)
}

// The preview render state for `content`, made the first time the map shows it; nil when it cannot be made.
@(private = "file")
hidden_panes_preview :: proc(w: ^Window, content: layout.Content) -> ^term_view.View {
	previews := &w.hidden_panes.previews
	for &preview in previews {
		if preview.content == content {
			preview.used = true
			return &preview.view
		}
	}
	preview := Hidden_Pane_Preview{content = content, used = true}
	if !term_view.create(&preview.view) {
		log.error("creating a hidden pane preview failed")
		return nil
	}
	if _, err := append(previews, preview); err != nil {
		term_view.destroy(&preview.view)
		log.error("storing a hidden pane preview failed")
		return nil
	}
	return &previews[len(previews) - 1].view
}

// Drops the previews of panes the map no longer shows.
@(private = "file")
hidden_panes_previews_prune :: proc(w: ^Window) {
	previews := &w.hidden_panes.previews
	for i := len(previews) - 1; i >= 0; i -= 1 {
		if previews[i].used {continue}
		term_view.destroy(&previews[i].view)
		unordered_remove(previews, i)
	}
}

// Releases every preview, as the map closes, and their storage, as the window goes.
hidden_panes_previews_clear :: proc(w: ^Window) {
	for &preview in w.hidden_panes.previews {term_view.destroy(&preview.view)}
	clear(&w.hidden_panes.previews)
}

hidden_panes_destroy :: proc(w: ^Window) {
	hidden_panes_previews_clear(w)
	delete(w.hidden_panes.previews)
}

// Adds the generations of the hidden terminals the open map previews, so their output redraws it.
hidden_panes_generation :: proc(app: ^App, w: ^Window) -> (generation: u64) {
	for preview in w.hidden_panes.previews {
		if entry := workspace_session_for_content(app, preview.content); entry != nil {
			generation += term.generation(entry.session)
		}
	}
	return
}

// Whether the point is on the glyph, or on the open map, and the map cell under it, or -1.
@(private = "file")
hidden_panes_hit :: proc(app: ^App, w: ^Window, x, y: f32) -> (h: Hidden_Panes, cell: int, on: bool) {
	cell = -1
	ok: bool
	if h, ok = hidden_panes_of(app, w); !ok {return}
	if render.rect_contains(h.glyph, x, y) {return h, cell, true}
	if !w.hidden_panes.reveal.open || !render.rect_contains(h.surface, x, y) {return}
	for r, i in h.cells {
		if render.rect_contains(r, x, y) {cell = i; break}
	}
	return h, cell, true
}

@(private = "file")
hidden_panes_close :: proc(w: ^Window) {
	if !w.hidden_panes.reveal.open && w.hidden_panes.hovered == nil {return}
	ui.hover_reveal_close(&w.hidden_panes.reveal)
	hidden_panes_previews_clear(w)
	w.hidden_panes.hovered, w.dirty = nil, true
}

// An aim at the map that stopped short of it hides the map.
hidden_panes_tick :: proc(w: ^Window, now: time.Tick) {
	if !ui.hover_reveal_tick(&w.hidden_panes.reveal, now) {return}
	if !w.hidden_panes.reveal.open {hidden_panes_previews_clear(w)}
	w.hidden_panes.hovered, w.dirty = nil, true
}

hidden_panes_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	return ui.hover_reveal_deadline(w.hidden_panes.reveal)
}

// Hidden panes pointer surface: the glyph opens the map, which stays while the pointer is on it or heading
// to it, and a pane on the map shows on press.

@(private)
hidden_panes_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, on := hidden_panes_hit(app, w, x, y)
	return on
}

// Every move reaches the reveal, whichever surface owns it, so an aim crossing a pane can keep the map.
@(private)
hidden_panes_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	point := [2]f32{f32(e.x), f32(e.y)}
	h, cell, on := hidden_panes_hit(app, w, point.x, point.y)
	if h.glyph.width <= 0 {
		hidden_panes_close(w)
		return
	}
	mine := owner == .Hidden_Panes && on
	on_glyph := mine && render.rect_contains(h.glyph, point.x, point.y)
	reveal := &w.hidden_panes.reveal
	on_map := mine && !on_glyph
	slack := ui.HOVER_AIM_SLACK * w.scale
	now := clock_now(&app.clock)
	changed := ui.hover_reveal_move(reveal, point, on_glyph, on_map, false, h.glyph, h.surface, slack, now)
	hovered: Maybe(int)
	if reveal.open && mine && cell >= 0 && !h.panes[cell].shown {hovered = cell}
	if changed || hovered != w.hidden_panes.hovered {w.hidden_panes.hovered, w.dirty = hovered, true}
	if owner == .Hidden_Panes {pointer_set(app, w, hovered != nil ? .Hand : .Arrow)}
}

// The map takes both halves of a click; a press on another pane shows it in the same view.
@(private)
hidden_panes_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	gesture_swallow(w, e.button, .Hidden_Panes)
	if e.button != .Left {return}
	h, cell, _ := hidden_panes_hit(app, w, f32(e.x), f32(e.y))
	if cell < 0 || h.panes[cell].shown {return}
	hidden_panes_close(w)
	pane_focus(app, w, h.nodes[cell])
}

@(private)
hidden_panes_leave :: proc(_: ^App, w: ^Window) {
	hidden_panes_close(w)
}

when AIO_CONTROL {
	hidden_panes_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		h, ok := hidden_panes_of(app, w)
		state_rect(r, "panes.hidden_glyph", ok ? h.glyph : {})
		state_rect(r, "panes.hidden_map", ok && w.hidden_panes.reveal.open ? h.surface : {})
		state_value(r, "panes.hidden_map_hover", w.hidden_panes.hovered.? or_else -1)
		state_value(r, "panes.hidden_map_aiming", w.hidden_panes.reveal.aiming)
	}
}
