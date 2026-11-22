package main

import "aio:layout"
import "cosmos:render"
import "aio:term"
import "aio:term_view"
import "aio:ui"
import "core:math"

Pane_Insets :: struct {
	padding: f32,
	header:  f32,
	footer:  f32,
}

// One pane's grid geometry: rectangle, insets, fitting grid and draw origin.
Pane_Box :: struct {
	rect:    layout.Rect,
	padding: f32,
	header:  f32,
	footer:  f32,
	columns: u16,
	rows:    u16,
	origin:  [2]f32,
}

// Every pane, tiled or floating, has a header row (D-050); content kind never changes the geometry a
// pane receives.
pane_header_height :: proc(scale: f32) -> f32 {
	return math.round(ui.HEADER_HEIGHT * scale)
}

// A shown pane's padding, header and optional shell-mode footer strip.
pane_insets :: proc(app: ^App, w: ^Window, entry: ^Session_Entry) -> Pane_Insets {
	return {
		padding = pane_padding(app, w.scale, entry),
		header = pane_header_height(w.scale),
		footer = pane_footer_height(app, w.scale, entry),
	}
}

// The pane below its header; a pane shorter than its header has no body.
pane_body_rect :: proc(w: ^Window, pane: layout.Pane_Rect) -> render.Rect {
	r, header := pane.rect, pane_header_height(w.scale)
	return {r.x, r.y + header, r.width, max(0, r.height - header)}
}

pane_box :: proc(metrics: term_view.Metrics, rect: layout.Rect, insets: Pane_Insets) -> Pane_Box {
	columns, rows := term_view.grid_size(
		metrics,
		rect.width,
		max(0, rect.height - insets.header - insets.footer),
		insets.padding,
	)
	return {
		rect = rect,
		padding = insets.padding,
		header = insets.header,
		footer = insets.footer,
		columns = columns,
		rows = rows,
		origin = {
			rect.x + insets.padding,
			rect.y + min(rect.height, insets.header) + insets.padding,
		},
	}
}

// The terminal geometry of a box in a `width` × `height` surface: the one conversion the first window's
// size and every live fit share, so the two cannot drift.
pane_box_geometry :: proc(box: Pane_Box, metrics: term_view.Metrics, width, height: i32) -> term.Geometry {
	return {
		columns = box.columns,
		rows = box.rows,
		cell_width = u32(metrics.cell_width),
		cell_height = u32(metrics.cell_height),
		surface_width = u32(width),
		surface_height = u32(height),
		padding_left = u32(box.origin.x),
		padding_top = u32(box.origin.y),
	}
}

// How many sizes pane_box_for_grid tries before giving up.
@(private = "file")
PANE_BOX_SOLVE_STEPS :: 32

// The client size at which `w` gives a single pane `columns` × `rows`, and the box the pane then receives:
// the inverse of pane_box across window_content_area_in. Each step resizes a copy of `w` by what its content
// area lacks, through the forward geometry, since whether the rail docks and how wide the Activity panel
// is follow the window's width. Not solved when the steps run out; the size is then the last tried.
pane_box_for_grid :: proc(
	app: ^App,
	w: Window,
	columns, rows: u16,
	insets: Pane_Insets,
) -> (
	box: Pane_Box,
	width, height: i32,
	solved: bool,
) {
	want_width := f32(columns) * w.metrics.cell_width + 2 * insets.padding
	want_height := f32(rows) * w.metrics.cell_height + 2 * insets.padding + insets.header + insets.footer
	candidate := w
	area := window_content_area_in(app, &candidate, candidate.pane_fill)
	for _ in 0 ..< PANE_BOX_SOLVE_STEPS {
		candidate.width += i32(math.ceil(want_width - area.width))
		candidate.height += i32(math.ceil(want_height - area.height))
		rail_adaptive_update(&candidate)
		area = window_content_area_in(app, &candidate, candidate.pane_fill)
		box = pane_box(w.metrics, area, insets)
		if box.columns == columns && box.rows == rows {return box, candidate.width, candidate.height, true}
	}
	return box, candidate.width, candidate.height, false
}
