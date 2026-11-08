package main

import "aio:layout"
import "aio:term_view"
import "aio:ui"
import "core:math"

Pane_Insets :: struct {
	padding: f32,
	header:  f32,
}

// One pane's grid geometry: rectangle, insets, fitting grid and draw origin.
Pane_Box :: struct {
	rect:    layout.Rect,
	padding: f32,
	header:  f32,
	columns: u16,
	rows:    u16,
	origin:  [2]f32,
}

// D-050 keeps a header on every pane unless headers are off; content kind never changes the
// geometry a pane receives. A floating pane keeps its header either way, since it moves by it.
pane_header_height :: proc(scale: f32, show_headers: bool) -> f32 {
	if !show_headers {return 0}
	return math.round(ui.HEADER_HEIGHT * scale)
}

pane_insets :: proc(
	app: ^App,
	scale: f32,
	entry: ^Session_Entry,
	floating := false,
) -> Pane_Insets {
	return {
		padding = pane_padding(app, scale, entry),
		header = pane_header_height(scale, floating || app.settings.pane.show_headers),
	}
}

// The header height of a pane the window shows: a header row's, or none under an overlay.
pane_header_of :: proc(w: ^Window, pane: layout.Pane_Rect) -> f32 {
	return pane_header_height(w.scale, pane_header_row(w, pane))
}

pane_box :: proc(metrics: term_view.Metrics, rect: layout.Rect, insets: Pane_Insets) -> Pane_Box {
	columns, rows := term_view.grid_size(
		metrics,
		rect.width,
		max(0, rect.height - insets.header),
		insets.padding,
	)
	return {
		rect = rect,
		padding = insets.padding,
		header = insets.header,
		columns = columns,
		rows = rows,
		origin = {
			rect.x + insets.padding,
			rect.y + min(rect.height, insets.header) + insets.padding,
		},
	}
}

// How many sizes pane_box_for_grid tries before giving up.
@(private = "file")
PANE_BOX_SOLVE_STEPS :: 32

// The client size at which `w` gives a single pane `columns` × `rows`, and the box the pane then receives:
// the inverse of pane_box across window_content_area_in. Each step resizes a copy of `w` by what its content
// area lacks, through the forward geometry, since whether the rail docks and how wide the Activity panel
// is follow the window's width. Without `activity_dock` the size leaves out a docked Activity panel's width,
// so the panel then takes its width from the pane. Not solved when the steps run out; the size is then the
// last tried.
pane_box_for_grid :: proc(
	app: ^App,
	w: Window,
	columns, rows: u16,
	insets: Pane_Insets,
	activity_dock: bool,
) -> (
	box: Pane_Box,
	width, height: i32,
	solved: bool,
) {
	want_width := f32(columns) * w.metrics.cell_width + 2 * insets.padding
	want_height := f32(rows) * w.metrics.cell_height + 2 * insets.padding + insets.header
	candidate := w
	area := window_content_area_in(app, &candidate, candidate.pane_fill, activity_dock)
	for _ in 0 ..< PANE_BOX_SOLVE_STEPS {
		candidate.width += i32(math.ceil(want_width - area.width))
		candidate.height += i32(math.ceil(want_height - area.height))
		rail_adaptive_update(&candidate)
		area = window_content_area_in(app, &candidate, candidate.pane_fill, activity_dock)
		box = pane_box(w.metrics, area, insets)
		if box.columns == columns && box.rows == rows {return box, candidate.width, candidate.height, true}
	}
	return box, candidate.width, candidate.height, false
}
