package main

import "aio:layout"
import "aio:term_view"
import "aio:ui"
import "core:math"

// The space a pane reserves inside its rectangle before terminal content.
Pane_Insets :: struct {
	padding: f32,
	header:  f32,
}

// One pane's terminal grid coordinates: the pane rectangle, its insets, the grid
// that fits and the top-left pixel the grid is drawn from.
Pane_Box :: struct {
	rect:    layout.Rect,
	padding: f32,
	header:  f32,
	columns: u16,
	rows:    u16,
	origin:  [2]f32,
}

// D-050 keeps a header on every pane, and Settings can turn headers off. A
// Settings pane fills its rectangle instead of drawing a header.
pane_header_height :: proc(scale: f32, show_headers: bool, kind: layout.Content_Kind) -> f32 {
	if !show_headers || kind == .Settings {return 0}
	return math.round(ui.HEADER_HEIGHT * scale)
}

pane_insets :: proc(
	app: ^App,
	scale: f32,
	entry: ^Session_Entry,
	kind: layout.Content_Kind,
) -> Pane_Insets {
	return {
		padding = pane_padding(app, scale, entry),
		header = pane_header_height(scale, app.settings.pane.show_headers, kind),
	}
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

// The client size that gives a single pane the requested grid, and the box that
// pane will then receive. Inverse of pane_box across window_content_area.
pane_box_for_grid :: proc(
	app: ^App,
	scale: f32,
	metrics: term_view.Metrics,
	columns, rows: u16,
	insets: Pane_Insets,
) -> (
	box: Pane_Box,
	width, height: i32,
) {
	inset := math.round(f32(app.settings.pane.gap) * scale)
	tab := ui.TAB_HEIGHT * scale
	box.rect = {
		x      = inset,
		y      = tab + inset,
		width  = f32(columns) * metrics.cell_width + 2 * insets.padding,
		height = f32(rows) * metrics.cell_height + 2 * insets.padding + insets.header,
	}
	width = i32(box.rect.width + 2 * inset)
	// A fractional DPI tab bar would otherwise truncate the client height below
	// the requested row count.
	height = i32(math.ceil(box.rect.height + tab + 2 * inset))
	box.rect.height = f32(height) - tab - 2 * inset
	box.padding = insets.padding
	box.header = insets.header
	box.columns = columns
	box.rows = rows
	box.origin = {box.rect.x + insets.padding, box.rect.y + insets.header + insets.padding}
	return
}
