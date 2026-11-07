package main

import "aio:layout"
import "aio:ui"
import "core:fmt"
import "core:math"

RAIL_DIVIDER :: layout.Node_Id(max(u32) - 1)
ACTIVITY_DIVIDER :: layout.Node_Id(max(u32) - 2)
// The edge between the tab list and an activity panel sharing the rail.
ACTIVITY_HEIGHT_DIVIDER :: layout.Node_Id(max(u32) - 3)

window_dividers :: proc(app: ^App, w: ^Window) {
	if w.tree == nil {return}
	area, gap := window_content_area(app, w), window_gap(app, w)
	if pane_view_solo(w) {clear(&w.dividers)} else {layout.dividers(w.tree, area, gap, &w.dividers)}
	layout.floats_dividers(w.tree, floating_area(w), gap, floating_header_height(w), &w.dividers)
	if rail_visible(w) {
		r := rail_resize_rect(w)
		d := layout.Divider{node = RAIL_DIVIDER, axis = .Horizontal,
			rect = {r.x + 3 * w.scale, r.y, max(1, gap), r.height}}
		inject_at(&w.dividers, 0, d)
	}
	if status_panel_in_rail(app, w) {
		r := status_panel_rect(app, w)
		d := layout.Divider{node = ACTIVITY_HEIGHT_DIVIDER, axis = .Vertical,
			rect = {r.x, r.y, r.width, max(1, w.scale)}}
		inject_at(&w.dividers, 0, d)
	} else if status_panel_visible(app, w) {
		r := status_panel_rect(app, w)
		x := app.settings.status.panel_side == .Left ? r.x + r.width : r.x - gap
		d := layout.Divider{node = ACTIVITY_DIVIDER, axis = .Horizontal,
			rect = {x, r.y, max(1, gap), r.height}}
		inject_at(&w.dividers, 0, d)
	}
}

dock_divider :: proc(node: layout.Node_Id) -> bool {
	return node == RAIL_DIVIDER || node == ACTIVITY_DIVIDER || node == ACTIVITY_HEIGHT_DIVIDER
}

// Where a dock edge sits on its own axis: x for the side edges, y for the panel's top in the rail.
dock_divider_position :: proc(app: ^App, w: ^Window, node: layout.Node_Id) -> f32 {
	switch node {
	case RAIL_DIVIDER:
		return rail_area(w).x + rail_width_pixels(w)
	case ACTIVITY_HEIGHT_DIVIDER:
		return status_panel_rect(app, w).y
	}
	width := status_panel_dock_width(app, w)
	return app.settings.status.panel_side == .Left ? width : f32(w.width) - width
}

dock_divider_drag :: proc(app: ^App, w: ^Window, node: layout.Node_Id, position: f32) {
	if node == ACTIVITY_HEIGHT_DIVIDER {
		area := rail_area(w)
		if area.height <= 0 {return}
		height := status_panel_rail_clamp(w, area.y + area.height - position)
		w.status.panel_height = height / area.height
		return
	}
	width := position
	if node == RAIL_DIVIDER {width -= rail_area(w).x}
	if node == ACTIVITY_DIVIDER && app.settings.status.panel_side == .Right {width = f32(w.width) - position}
	available := f32(w.width)
	if node == ACTIVITY_DIVIDER && rail_docked(w) {available -= rail_width_pixels(w)}
	width = ui.rail_pixel_width(w.scale, width / w.scale, available) / w.scale
	if node == RAIL_DIVIDER {w.rail_width = width} else {w.status.panel_width = width}
}

// Double-clicking a dock edge returns it to the size its setting names.
dock_divider_reset :: proc(w: ^Window, node: layout.Node_Id) {
	switch node {
	case RAIL_DIVIDER:
		w.rail_width = 0
	case ACTIVITY_DIVIDER:
		w.status.panel_width = 0
	case ACTIVITY_HEIGHT_DIVIDER:
		w.status.panel_height = 0
	}
}

dock_divider_menu_open :: proc(app: ^App, w: ^Window, x, y: f32) {
	hits: [4]layout.Divider
	count := divider_hits(w, x, y, hits[:])
	for hit in hits[:count] {
		if !dock_divider(hit.node) {continue}
		if !gesture_cancel(app, w) {return}
		overlay_open(app, w, Overlay_Divider_Menu{node = hit.node})
		w.tab_menu = {count = 1, position = {x, y}}
		return
	}
}

dock_divider_save_default :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	key: string
	size: f32
	switch node {
	case RAIL_DIVIDER:
		key, size = "tabs.rail_width", rail_width_pixels(w) / w.scale
	case ACTIVITY_DIVIDER:
		key, size = "status.panel_width", status_panel_dock_width(app, w) / w.scale
	case ACTIVITY_HEIGHT_DIVIDER:
		area := rail_area(w)
		if area.height <= 0 {return}
		key, size = "status.panel_height", 100 * status_panel_rail_height(app, w) / area.height
	case: return
	}
	value := int(math.round(size))
	_, has_file := settings_save_value(app, key, fmt.tprintf("%d", value), "Could not save default size.")
	if has_file {return}
	switch node {
	case RAIL_DIVIDER: app.settings.tabs.rail_width = value
	case ACTIVITY_DIVIDER: app.settings.status.panel_width = value
	case ACTIVITY_HEIGHT_DIVIDER: app.settings.status.panel_height = value
	}
	for window in app.windows {window_apply_settings(app, window); window_relayout(app, window)}
}
