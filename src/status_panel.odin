package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:math"
import "core:strings"

// The docked Activity panel: where it sits, what it lists and how its rows respond.

status_panel_visible :: proc(app: ^App, w: ^Window) -> bool {
	s := &app.settings.status
	if !s.enabled || !s.panel || w.preparing || w.linked || pane_fill_active(w) {return false}
	return true
}

// Vertical view puts a left panel under the tabs in the docked rail.
status_panel_in_rail :: proc(app: ^App, w: ^Window) -> bool {
	return status_panel_visible(app, w) && app.settings.status.panel_side == .Left && rail_docked(w)
}

// The rail gives the bottom of its height to the panel in vertical view.
status_panel_rail_height :: proc(app: ^App, w: ^Window) -> f32 {
	if !status_panel_in_rail(app, w) {return 0}
	share := w.status.panel_height > 0 ? w.status.panel_height : f32(app.settings.status.panel_height) / 100
	return status_panel_rail_clamp(w, rail_area(w).height * share)
}

// Whole-pixel panel height that leaves both the panel and the tab list usable.
status_panel_rail_clamp :: proc(w: ^Window, height: f32) -> f32 {
	area := rail_area(w)
	lowest := min(STATUS_PANEL_RAIL_MIN * w.scale, area.height / 2)
	highest := max(lowest, area.height - STATUS_RAIL_TABS_MIN * w.scale)
	return math.round(clamp(height, lowest, highest))
}

status_panel_dock_width :: proc(app: ^App, w: ^Window) -> f32 {
	if !status_panel_visible(app, w) || status_panel_in_rail(app, w) {return 0}
	width := w.status.panel_width > 0 ? w.status.panel_width : f32(app.settings.status.panel_width)
	available := f32(w.width) - (rail_docked(w) ? rail_width_pixels(w) : 0)
	return ui.rail_pixel_width(w.scale, width, available)
}

status_panel_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	if !status_panel_visible(app, w) {return {}}
	if status_panel_in_rail(app, w) {
		area := rail_area(w)
		height := status_panel_rail_height(app, w)
		return {area.x, area.y + area.height - height, area.width, height}
	}
	content := window_content_area(app, w)
	gap := window_gap(app, w)
	width := status_panel_dock_width(app, w) - gap
	if app.settings.status.panel_side == .Left {
		return {gap, content.y, max(0, width), content.height}
	}
	return {content.x + content.width + gap, content.y, max(0, width), content.height}
}

status_panel_side_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	r := status_panel_rect(app, w)
	if r.width <= 0 {return {}}
	size := ui.HEIGHT_COMPACT * w.scale
	top := (STATUS_PANEL_HEADER * w.scale - size) / 2
	return {r.x + r.width - ui.SPACE_1 * w.scale - size, r.y + top, size, size}
}

status_panel_side_toggle :: proc(app: ^App) {
	next := app.settings.status.panel_side == .Right ? "left" : "right"
	if _, has_file := settings_save_value(app, "status.panel_side", next, "Could not save Activity side.");
	   !has_file {
		app.settings.status.panel_side = next == "left" ? .Left : .Right
		for window in app.windows {window_relayout(app, window)}
	}
}

@(private)
status_panel_list :: proc(app: ^App, w: ^Window, panel: render.Rect) -> render.Rect {
	s := w.scale
	header, pad := STATUS_PANEL_HEADER * s, ui.OVERLAY_PADDING * s
	return {panel.x + pad, panel.y + header, max(0, panel.width - 2 * pad), max(0, panel.height - header - pad)}
}

@(private)
status_panel_offsets :: proc(w: ^Window, items: []Status_Item) -> (offsets: []f32, total: f32) {
	offsets = make([]f32, len(items), context.temp_allocator)
	for item, i in items {
		offsets[i] = total
		total += status_item_height(w, item)
	}
	return offsets, total
}

status_panel_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	panel := status_panel_rect(app, w)
	if panel.width <= 0 || panel.height <= 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, panel) != .None {return .Ok}
	if !status_panel_in_rail(app, w) {
		radius := f32(app.settings.pane.corner_radius) * s
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.pane, radius = radius})
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.pane_border, radius = radius, stroke = max(1, s)})
	} else {
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.tab_bar})
		ui.draw_rect(&w.list, {rect = {panel.x, panel.y, panel.width - s, s}, color = app.theme.border})
		ui.draw_rect(
			&w.list,
			{rect = {panel.x + panel.width - s, panel.y, s, panel.height}, color = app.theme.border},
		)
	}
	items := status_items(app, w, true)
	small := ui.text_styled(&w.ui_text, .Detail)
	strong := ui.text_styled(&w.ui_text, .Strong)
	if result := ui.draw_text(
		&strong,
		&w.list,
		"Activity",
		panel.x + ui.SPACE_3 * s,
		panel.y + (STATUS_PANEL_HEADER * s - strong.line_height) / 2 + strong.ascent,
		app.theme.text,
	); result != .Ok {return result}
	button := status_panel_side_rect(app, w)
	hover := f32(int(w.status.panel_side_hover))
	press := f32(int(ui.armed_down(w.status.panel_side_armed)))
	icon: ui.Icon = app.settings.status.panel_side == .Left ? .Layout_Left : .Layout_Right
	_ = ui.icon_button_draw(&w.list, app.theme, button, icon, hover, press, s, w.pointer)
	list := status_panel_list(app, w, panel)
	if render.push_layer(&w.list, list) != .None {return .Ok}
	if len(items) == 0 {
		return ui.draw_fading_text(
			&small,
			&w.list,
			"Nothing is reporting status.",
			list.x + 8 * s,
			list.y + 8 * s + small.ascent,
			app.theme.faint,
			max(0, list.width - 16 * s),
		)
	}
	offsets, total := status_panel_offsets(w, items)
	w.status.panel_scroll = clamp(w.status.panel_scroll, 0, max(0, total - list.height))
	for item, i in items {
		top := list.y + offsets[i] - w.status.panel_scroll
		r := render.Rect{list.x, top, list.width, status_item_height(w, item)}
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		if item.group {
			if result := status_group_draw(app, w, r, item); result != .Ok {return result}
			continue
		}
		depth := f32(min(3, strings.count(item.record.id, "/") + (item.record.id != "" ? 1 : 0)))
		highlighted := w.status.hover_surface == .Panel && w.status.hover == i
		if result := status_row_draw(app, w, r, item, highlighted, false, depth * 12 * s); result != .Ok {
			return result
		}
	}
	return .Ok
}

@(private)
status_panel_hit :: proc(
	app: ^App,
	w: ^Window,
	items: []Status_Item,
	x, y: f32,
) -> (
	index: int,
	row: render.Rect,
) {
	panel := status_panel_rect(app, w)
	list := status_panel_list(app, w, panel)
	if !status_rect_contains(list, x, y) {return -1, {}}
	offsets, _ := status_panel_offsets(w, items)
	for item, i in items {
		top := list.y + offsets[i] - w.status.panel_scroll
		r := render.Rect{list.x, top, list.width, status_item_height(w, item)}
		if !item.group && status_rect_contains(r, x, y) {return i, r}
	}
	return -1, {}
}

status_panel_contains :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return status_rect_contains(status_panel_rect(app, w), x, y)
}

// Panel clicks open the pane a row came from; the panel takes every press inside it.
status_panel_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	if !e.pressed || !status_panel_contains(app, w, x, y) {return false}
	w.header_buttons += {e.button}
	if e.button != .Left {return true}
	if status_rect_contains(status_panel_side_rect(app, w), x, y) {
		ui.armed_press(&w.status.panel_side_armed, true)
		return true
	}
	items := status_items(app, w, true)
	index, row := status_panel_hit(app, w, items, x, y)
	if index < 0 {return true}
	if status_dismissable(items[index].record) && status_rect_contains(status_dismiss_rect(w, row), x, y) {
		status_dismiss_item(app, items[index])
		w.dirty = true
		return true
	}
	status_open_item(app, w, items[index])
	return true
}

status_panel_wheel :: proc(app: ^App, w: ^Window, x, y, delta: f32) -> bool {
	if !status_panel_contains(app, w, x, y) {return false}
	step := f32(math.sign(delta)) * 2 * STATUS_ROW_HEIGHT * w.scale
	w.status.panel_scroll = max(0, w.status.panel_scroll - step)
	w.dirty = true
	return true
}
