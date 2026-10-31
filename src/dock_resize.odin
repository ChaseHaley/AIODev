package main

import "aio:layout"
import "aio:ui"

RAIL_DIVIDER :: layout.Node_Id(max(u32) - 1)
ACTIVITY_DIVIDER :: layout.Node_Id(max(u32) - 2)

window_dividers :: proc(app: ^App, w: ^Window) {
	if w.tree == nil {return}
	area, gap := window_content_area(app, w), window_gap(app, w)
	layout.dividers(w.tree, area, gap, &w.dividers)
	if rail_visible(w) {
		r := rail_resize_rect(w)
		d := layout.Divider{node = RAIL_DIVIDER, axis = .Horizontal,
			rect = {r.x + 3 * w.scale, r.y, max(1, gap), r.height}}
		inject_at(&w.dividers, 0, d)
	}
	if status_panel_visible(app, w) && !status_panel_in_rail(app, w) {
		r := status_panel_rect(app, w)
		x := app.settings.status.panel_side == .Left ? r.x + r.width : r.x - gap
		d := layout.Divider{node = ACTIVITY_DIVIDER, axis = .Horizontal,
			rect = {x, r.y, max(1, gap), r.height}}
		inject_at(&w.dividers, 0, d)
	}
}

dock_divider :: proc(node: layout.Node_Id) -> bool {
	return node == RAIL_DIVIDER || node == ACTIVITY_DIVIDER
}

dock_divider_drag :: proc(app: ^App, w: ^Window, node: layout.Node_Id, x: f32) {
	width := x
	if node == RAIL_DIVIDER {width -= rail_area(w).x}
	if node == ACTIVITY_DIVIDER && app.settings.status.panel_side == .Right {width = f32(w.width) - x}
	available := f32(w.width)
	if node == ACTIVITY_DIVIDER && rail_docked(w) {available -= rail_width_pixels(w)}
	width = ui.rail_pixel_width(w.scale, width / w.scale, available) / w.scale
	if node == RAIL_DIVIDER {w.rail_width = width} else {w.status.panel_width = width}
}
