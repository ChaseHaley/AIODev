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
// geometry a pane receives.
pane_header_height :: proc(scale: f32, show_headers: bool) -> f32 {
	if !show_headers {return 0}
	return math.round(ui.HEADER_HEIGHT * scale)
}

pane_insets :: proc(
	app: ^App,
	scale: f32,
	entry: ^Session_Entry,
) -> Pane_Insets {
	return {
		padding = pane_padding(app, scale, entry),
		header = pane_header_height(scale, app.settings.pane.show_headers),
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

// The client size for a single pane's requested grid, and the box it then receives; inverse of
// pane_box across window_content_area.
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
	top := ui.TITLE_BAR_HEIGHT * scale
	box.rect = {
		x      = inset,
		y      = top + inset,
		width  = f32(columns) * metrics.cell_width + 2 * insets.padding,
		height = f32(rows) * metrics.cell_height + 2 * insets.padding + insets.header,
	}
	base_width := box.rect.width + 2 * inset
	rail := f32(0)
	// Include the rail only when the resulting window would dock it. The rule is the same one
	// the window applies after the resize, so the requested grid is not widened by a hidden rail.
	if app.settings.tabs.orientation == .Vertical &&
	   f32(i32(base_width)) >= ui.RAIL_DOCK_MIN_WIDTH * scale {
		rail = ui.rail_pixel_width(scale)
		box.rect.x += rail
	}
	width = i32(box.rect.width + 2 * inset + rail)
	// A fractional DPI tab bar would otherwise truncate the client height below
	// the requested row count.
	height = i32(math.ceil(box.rect.height + top + 2 * inset))
	box.rect.height = f32(height) - top - 2 * inset
	box.padding = insets.padding
	box.header = insets.header
	box.columns = columns
	box.rows = rows
	box.origin = {box.rect.x + insets.padding, box.rect.y + insets.header + insets.padding}
	return
}
