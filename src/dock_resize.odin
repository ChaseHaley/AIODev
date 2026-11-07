package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:math"

// The edges of the docked chrome the pointer drags: the Activity panel's top where it shares the rail,
// its side beside the panes, and the rail's side. Declared in hit order, ahead of the layout's dividers.
Dock_Edge :: enum u8 {
	Activity_Height,
	Activity_Width,
	Rail_Width,
}

@(private = "file", rodata)
DOCK_EDGE_AXIS := [Dock_Edge]layout.Axis {
	.Activity_Height = .Vertical,
	.Activity_Width  = .Horizontal,
	.Rail_Width      = .Horizontal,
}

// The setting that names each edge's default size.
@(private = "file", rodata)
DOCK_EDGE_SETTING := [Dock_Edge]string {
	.Activity_Height = "status.panel_height",
	.Activity_Width  = "status.panel_width",
	.Rail_Width      = "tabs.rail_width",
}

// The dock edges a window shows, in hit order: `bars[i]` is where `edges[i]` lies.
Dock_Edges_Shown :: struct {
	edges: [len(Dock_Edge)]Dock_Edge,
	bars:  [len(Dock_Edge)]layout.Edge,
	count: int,
}

window_dividers :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil {return}
	g := window_geometry(app, w, w.pane_fill)
	layout.dividers_shown(tree, g, pane_view_solo(w), &w.dividers)
	w.dock_edges = {}
	for edge in Dock_Edge {
		rect, shown := dock_edge_rect(app, w, edge, g.gap)
		if !shown {continue}
		shown_edges := &w.dock_edges
		shown_edges.edges[shown_edges.count] = edge
		shown_edges.bars[shown_edges.count] = {DOCK_EDGE_AXIS[edge], rect}
		shown_edges.count += 1
	}
}

// The bar a dock edge shows as, a pane gap wide, while the edge shows.
@(private = "file")
dock_edge_rect :: proc(app: ^App, w: ^Window, edge: Dock_Edge, gap: f32) -> (layout.Rect, bool) {
	switch edge {
	case .Activity_Height:
		if !status_panel_in_rail(app, w) {return {}, false}
		r := status_panel_rect(app, w)
		return {r.x, r.y, r.width, max(1, w.scale)}, true
	case .Activity_Width:
		if status_panel_in_rail(app, w) || !status_panel_visible(app, w) {return {}, false}
		r := status_panel_rect(app, w)
		x := app.settings.status.panel_side == .Left ? r.x + r.width : r.x - gap
		return {x, r.y, max(1, gap), r.height}, true
	case .Rail_Width:
		if w.phase == .Preparing || !rail_visible(w) {return {}, false}
		area := rail_area(w)
		return {area.x + area.width, area.y, max(1, gap), area.height}, true
	}
	return {}, false
}

// The pointer coordinate a dock edge follows on its own axis.
dock_edge_along :: proc(edge: Dock_Edge, x, y: f32) -> f32 {
	return DOCK_EDGE_AXIS[edge] == .Vertical ? y : x
}

// Where a dock edge sits on its own axis: x for the side edges, y for the panel's top in the rail.
dock_edge_position :: proc(app: ^App, w: ^Window, edge: Dock_Edge) -> f32 {
	switch edge {
	case .Activity_Height:
		return status_panel_rect(app, w).y
	case .Activity_Width:
		width := status_panel_dock_width(app, w)
		return app.settings.status.panel_side == .Left ? width : f32(w.width) - width
	case .Rail_Width:
		return rail_area(w).x + rail_width_pixels(w)
	}
	return 0
}

dock_edge_drag :: proc(app: ^App, w: ^Window, edge: Dock_Edge, position: f32) {
	switch edge {
	case .Activity_Height:
		area := rail_area(w)
		if area.height <= 0 {return}
		height := status_panel_rail_clamp(w, area.y + area.height - position)
		w.status.panel_height = height / area.height
	case .Activity_Width:
		width := app.settings.status.panel_side == .Right ? f32(w.width) - position : position
		available := f32(w.width) - (rail_docked(w) ? rail_width_pixels(w) : 0)
		w.status.panel_width = ui.rail_pixel_width(w.scale, width / w.scale, available) / w.scale
	case .Rail_Width:
		width := position - rail_area(w).x
		w.rail_width = ui.rail_pixel_width(w.scale, width / w.scale, f32(w.width)) / w.scale
	}
}

// Double-clicking a dock edge returns it to the size its setting names.
dock_edge_reset :: proc(w: ^Window, edge: Dock_Edge) {
	switch edge {
	case .Activity_Height:
		w.status.panel_height = 0
	case .Activity_Width:
		w.status.panel_width = 0
	case .Rail_Width:
		w.rail_width = 0
	}
}

// What a dock edge's menu offers; each row's payload names one.
Dock_Divider_Choice :: enum u32 {
	Save_Default,
}

@(private = "file", rodata)
DOCK_DIVIDER_CHOICE_LABELS := [Dock_Divider_Choice]string {
	.Save_Default = "Set as Default Size",
}

dock_divider_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Divider_Menu)
	return shown
}

dock_divider_menu_open :: proc(app: ^App, w: ^Window, x, y: f32) {
	hits: [DIVIDER_HITS_MAX]Divider_Hit
	count := divider_hits(w, x, y, hits[:])
	for hit in hits[:count] {
		edge := hit.target.(Dock_Edge) or_continue
		if !gesture_cancel(app, w) {return}
		overlay_open(app, w, Overlay_Divider_Menu{edge = edge})
		menu := &w.divider_menu
		ui.menu_clear(menu)
		ui.menu_anchor(menu, x, y)
		for choice in Dock_Divider_Choice {
			label := DOCK_DIVIDER_CHOICE_LABELS[choice]
			item := ui.Menu_Item{label = label, enabled = true, payload = u32(choice)}
			if added, err := ui.menu_add(menu, item); !added {
				log.errorf("adding a dock edge menu row failed: %v", err)
				overlay_close(app, w)
				return
			}
		}
		return
	}
}

dock_divider_menu_choose :: proc(app: ^App, w: ^Window) {
	divider, shown := w.overlay.(Overlay_Divider_Menu)
	index := ui.menu_selected(&w.divider_menu)
	if !shown || index < 0 {return}
	item := w.divider_menu.items[index]
	if !item.enabled || item.separator {return}
	overlay_close(app, w)
	switch Dock_Divider_Choice(item.payload) {
	case .Save_Default:
		dock_edge_save_default(app, w, divider.edge)
	}
}

dock_divider_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	switch ui.menu_key(&w.divider_menu, e) {
	case .None:
	case .Changed: ui.menu_reveal(&w.divider_menu, f32(w.width), f32(w.height), w.scale)
	case .Chosen: dock_divider_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

dock_divider_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.divider_menu, rows)
	ui.menu_reveal(&w.divider_menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

dock_divider_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.divider_menu, x, y, f32(w.width), f32(w.height), w.scale)
}

dock_divider_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.divider_menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

dock_edge_save_default :: proc(app: ^App, w: ^Window, edge: Dock_Edge) {
	size: f32
	switch edge {
	case .Activity_Height:
		area := rail_area(w)
		if area.height <= 0 {return}
		size = 100 * status_panel_rail_height(app, w) / area.height
	case .Activity_Width:
		size = status_panel_dock_width(app, w) / w.scale
	case .Rail_Width:
		size = rail_width_pixels(w) / w.scale
	}
	value := fmt.tprintf("%d", int(math.round(size)))
	settings_save_value(app, DOCK_EDGE_SETTING[edge], value, "Could not save default size.")
}
