package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:time"

// The rail's presentation in vertical tab view; nil is Hidden. A docked rail takes pane space; an
// overlay slides over the panes and is removed when its closing slide ends. Only this file writes it.
//
// The automatic policy is Window.rail_wide: the window is wide enough to dock. A manual toggle
// survives resizes on the same side of that threshold; crossing it returns to automatic, so a docked
// rail docks again when the window widens and a narrow window hides it again.
Rail_Presentation :: union {
	Rail_Docked,
	Rail_Overlay,
}

Rail_Docked :: struct {}

// The slide targets 1 while Opening or Open and 0 while Closing.
Rail_Overlay :: struct {
	slide: ui.Motion,
}

Rail_Overlay_Phase :: enum {
	Opening,
	Open,
	Closing,
}

@(private = "file")
RAIL_SLIDE :: 140 * time.Millisecond

rail_auto_at :: proc(width: i32, scale: f32) -> bool {
	return f32(width) >= ui.RAIL_DOCK_MIN_WIDTH * scale
}

rail_adaptive_update :: proc(w: ^Window) {
	if w.tabs_horizontal {return}
	wide := rail_auto_at(w.width, w.scale)
	if wide == w.rail_wide {return}
	rail_auto_reset(w)
}

// Automatic presentation: docked when wide and hidden when narrow. Nothing of the previous
// presentation survives, so a docked rail hidden by a crossing cannot linger as an overlay.
rail_auto_reset :: proc(w: ^Window) {
	rail_resize_cancel(w)
	w.rail_wide = rail_auto_at(w.width, w.scale)
	if w.rail_wide {w.rail = Rail_Docked{}} else {w.rail = nil}
}

rail_overlay_phase :: proc(w: ^Window) -> (Rail_Overlay_Phase, bool) {
	overlay, ok := w.rail.(Rail_Overlay)
	if !ok {return {}, false}
	if overlay.slide.target == 0 {return .Closing, true}
	return ui.motion_active(overlay.slide) ? .Opening : .Open, true
}

when AIO_CONTROL {
	// How far the rail is out: 1 docked, 0 hidden, and the slide's position for an overlay.
	rail_slide_value :: proc(w: ^Window) -> f32 {
		switch r in w.rail {
		case Rail_Docked: return 1
		case Rail_Overlay: return r.slide.value
		}
		return 0
	}
}

rail_sliding :: proc(w: ^Window) -> bool {
	overlay, ok := w.rail.(Rail_Overlay)
	return ok && ui.motion_active(overlay.slide)
}

// Advances the overlay slide; a finished closing slide hides the rail.
rail_slide_update :: proc(w: ^Window, now: time.Tick) -> bool {
	overlay, ok := &w.rail.(Rail_Overlay)
	if !ok {return false}
	changed := ui.motion_update(&overlay.slide, now)
	rail_overlay_settle(w)
	return changed
}

@(private = "file")
rail_overlay_settle :: proc(w: ^Window) {
	overlay, ok := w.rail.(Rail_Overlay)
	if ok && overlay.slide.target == 0 && !ui.motion_active(overlay.slide) {w.rail = nil}
}

@(private = "file")
rail_overlay_slide :: proc(app: ^App, w: ^Window, target: f32) {
	if _, ok := w.rail.(Rail_Overlay); !ok {w.rail = Rail_Overlay{}}
	overlay := &w.rail.(Rail_Overlay)
	ui.motion_target(&overlay.slide, target, RAIL_SLIDE, .Decelerate, app.animations, time.tick_now())
	rail_overlay_settle(w)
}

rail_visible :: proc(w: ^Window) -> bool {
	return rail_visible_in(w, w.pane_fill)
}

// Whether the rail shows when the window's pane fill is `fill`; a filling pane covers it.
rail_visible_in :: proc(w: ^Window, fill: layout.Pane_Fill) -> bool {
	if w.tabs_horizontal || fill != .None {return false}
	phase, overlay := rail_overlay_phase(w)
	return overlay ? phase != .Closing : w.rail != nil
}

rail_docked :: proc(w: ^Window) -> bool {
	return rail_docked_in(w, w.pane_fill)
}

rail_docked_in :: proc(w: ^Window, fill: layout.Pane_Fill) -> bool {
	_, docked := w.rail.(Rail_Docked)
	return docked && rail_visible_in(w, fill)
}

rail_overlay :: proc(w: ^Window) -> bool {
	_, overlay := w.rail.(Rail_Overlay)
	return overlay && rail_visible(w)
}

rail_area :: proc(w: ^Window) -> render.Rect {
	return {
		w.dock_left_width,
		ui.TITLE_BAR_HEIGHT * w.scale,
		rail_width_pixels(w),
		max(0, f32(w.height) - ui.TITLE_BAR_HEIGHT * w.scale),
	}
}

rail_width_pixels :: proc(w: ^Window) -> f32 {
	width := w.rail_width > 0 ? w.rail_width : w.rail_default_width
	return ui.rail_pixel_width(w.scale, width > 0 ? width : ui.RAIL_WIDTH, f32(w.width))
}

rail_resize_rect :: proc(w: ^Window) -> render.Rect {
	if w.phase == .Preparing || !rail_visible(w) {return {}}
	area := rail_area(w)
	return {area.x + area.width - 3 * w.scale, area.y, 6 * w.scale, area.height}
}

rail_resize_cancel :: proc(w: ^Window) {
	if !rail_resizing(w) {return}
	gesture_cancel_button(w, .Left)
	divider_cancel(w)
}

// The rail shows one row per tab of the window's workspace, in tab order.
rail_tab_count :: proc(w: ^Window) -> int {
	return w.tabs_horizontal || w.workspace == nil ? 0 : len(w.workspace.tabs)
}

@(require_results)
rail_current_layout :: proc(w: ^Window) -> (layout: ui.Rail_Layout, ok: bool) {
	if w.tabs_horizontal {return {}, false}
	area := rail_area(w)
	area.height = max(0, area.height - w.status_rail_reserve)
	layout = ui.rail_layout(area, w.scale, rail_tab_count(w) + w.tab_incoming.count, w.rail_scroll)
	w.rail_scroll = layout.scroll
	return layout, true
}

rail_reveal_active :: proc(w: ^Window) {
	if w.tabs_horizontal {return}
	layout, ok := rail_current_layout(w)
	if !ok {return}
	index := w.workspace.selected
	if index < 0 || index >= rail_tab_count(w) {return}
	scroll := ui.rail_reveal_row(layout, index)
	if scroll != w.rail_scroll {
		w.rail_scroll, w.dirty = scroll, true
	}
}

tab_orientation_button_rect :: proc(w: ^Window) -> render.Rect {
	s := w.scale
	return {4 * s, 4 * s, ui.TITLE_BUTTON_WIDTH * s, ui.HEIGHT_STANDARD * s}
}

tab_orientation_button_hit :: proc(w: ^Window, x, y: f32) -> bool {
	r := tab_orientation_button_rect(w)
	return r.width >= 24 * w.scale && render.rect_contains(r, x, y)
}

rail_toggle :: proc(app: ^App, w: ^Window) {
	if w.tabs_horizontal {return}
	rail_resize_cancel(w)
	was_docked := rail_docked(w)
	if rail_visible(w) {
		if rail_overlay(w) {rail_overlay_slide(app, w, 0)} else {w.rail = nil}
	} else if w.rail_wide {
		w.rail = Rail_Docked{}
	} else {
		rail_overlay_slide(app, w, 1)
	}
	if was_docked != rail_docked(w) {window_relayout(app, w)} else {window_dividers(app, w)}
	w.dirty = true
}

rail_overlay_dismiss :: proc(app: ^App, w: ^Window) {
	if !rail_overlay(w) {return}
	rail_resize_cancel(w)
	rail_overlay_slide(app, w, 0)
	window_dividers(app, w)
	w.dirty = true
}

rail_row_rect_for_tab :: proc(w: ^Window, tab: int) -> render.Rect {
	layout, ok := rail_current_layout(w)
	if !ok || tab < 0 || tab >= rail_tab_count(w) {return {}}
	return rail_tab_rect(w, layout, tab)
}

@(private)
rail_tab_rect :: proc(w: ^Window, layout: ui.Rail_Layout, index: int) -> render.Rect {
	r := ui.rail_row_rect(layout, index)
	if index < 0 || index >= rail_tab_count(w) {return r}
	r.y += (tab_position(w, index) - f32(index)) * layout.row_height
	return r
}

@(private)
rail_tab_close_rect :: proc(w: ^Window, layout: ui.Rail_Layout, index: int) -> render.Rect {
	r := ui.rail_close_rect(layout, index, w.scale)
	if index < 0 || index >= rail_tab_count(w) {return r}
	r.y += (tab_position(w, index) - f32(index)) * layout.row_height
	return r
}

// The tab whose row is under the point, or -1. Dragged tabs draw above the rest, so they hit first.
rail_tab_hit :: proc(w: ^Window, layout: ui.Rail_Layout, x, y: f32) -> int {
	if !render.rect_contains(layout.list, x, y) {return -1}
	for pass in 0 ..< 2 {
		for index := rail_tab_count(w) - 1; index >= 0; index -= 1 {
			foreground := tab_drag_active(w) && w.workspace.tabs[index].marked
			if foreground != (pass == 0) {continue}
			if render.rect_contains(rail_tab_rect(w, layout, index), x, y) {return index}
		}
	}
	return -1
}

// The footer control under the point: the profile chevron or the new-tab tile around it.
@(private)
rail_footer_target :: proc(layout: ui.Rail_Layout, x, y: f32) -> Tab_Chrome_Target {
	if !ui.rail_footer_hit(layout, x, y) {return nil}
	if ui.rail_profile_hit(layout, x, y) {return Tab_Chrome_Profiles{}}
	return Tab_Chrome_New{}
}

rail_tab_interaction_hit :: proc(w: ^Window, x, y: f32, button: input.Mouse_Button) -> Tab_Interaction_Hit {
	if !rail_visible(w) || !render.rect_contains(rail_area(w), x, y) {return {}}
	layout, ok := rail_current_layout(w)
	if !ok {return {inside = true}}
	if ui.rail_footer_hit(layout, x, y) {
		if button == .Left && ui.rail_profile_hit(layout, x, y) {
			tile := rail_profile_rect(w)
			anchor := [2]f32{tile.x, tile.y + tile.height}
			return {target = Tab_Chrome_Profiles{}, inside = true, menu_anchor = anchor}
		}
		tile := ui.rail_footer_tile(layout)
		return {target = Tab_Chrome_New{}, inside = true, menu_anchor = {tile.x, tile.y + tile.height}}
	}
	index := rail_tab_hit(w, layout, x, y)
	if index < 0 {return {inside = true}}
	close := render.rect_contains(rail_tab_close_rect(w, layout, index), x, y)
	return {target = Tab_Chrome_Tab{index}, inside = true, close = close}
}

@(require_results)
rail_pane_target :: proc(w: ^Window, x, y: f32) -> (tab: int, new_tab, ok: bool) {
	if !rail_visible(w) {return -1, false, false}
	if !render.rect_contains(rail_area(w), x, y) {
		return -1, false, false
	}
	layout, built := rail_current_layout(w)
	if !built {return -1, false, false}
	if ui.rail_footer_hit(layout, x, y) {return -1, true, true}
	index := rail_tab_hit(w, layout, x, y)
	if index < 0 {return -1, true, true}
	return index, false, true
}

@(require_results)
rail_new_tab_rect :: proc(w: ^Window) -> render.Rect {
	layout, ok := rail_current_layout(w)
	if !ok {return {}}
	return ui.rail_new_tab_tile(layout)
}

rail_profile_rect :: proc(w: ^Window) -> render.Rect {
	layout, ok := rail_current_layout(w)
	if !ok {return {}}
	return ui.rail_profile_rect(layout)
}

@(private)
rail_text_baseline :: proc(w: ^Window, row: render.Rect) -> f32 {
	return row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
}

@(private)
rail_row_draw :: proc(
	app: ^App,
	w: ^Window,
	layout: ui.Rail_Layout,
	index: int,
	moving: bool,
) -> render.Build_Status {
	s := w.scale
	hover := w.tab_hover == Tab_Chrome_Tab{index}
	pressed := gesture_tab_pressed(w) == Tab_Chrome_Tab{index}
	tile := rail_tab_rect(w, layout, index)
	list_bottom := layout.list.y + layout.list.height
	if tile.width <= 0 || tile.y + tile.height <= layout.list.y || tile.y >= list_bottom {
		return .Ok
	}
	if moving {
		if render.push_layer(&w.list, layout.list) != .None {return .Ok}
		if rail_docked(w) {ui.draw_rect(&w.list, {rect = tile, color = app.theme.tab_bar})}
	}
	t, built := tab_tile(app, w, index)
	if built != .Ok {return built}
	has_badge := ui.tab_badge_shown(t.badge)
	close := rail_tab_close_rect(w, layout, index)
	show_close := hover || pressed || ui.armed_is(w.tab_close_armed, index)
	leading := has_badge ? (ui.ICON_BUTTON + ui.SPACE_2) * s : 0
	trailing := show_close ? tile.x + tile.width - close.x - 4 * s : 0
	// Status sits at the right, before Close when it shows, with its place kept while tab status is on.
	status_right := show_close ? close.x : tile.x + tile.width - 4 * s
	if t.status_slot || t.status.glyph != .None {
		trailing = tile.x + tile.width - status_right + (ui.ICON_INDICATOR + ui.SPACE_1) * s
	}
	if result := ui.navigation_row_draw(&w.list, &w.ui_text, app.theme, tile,
		{title = t.title, selected = t.selected, marked = t.marked, hovered = hover, pressed = pressed,
		 leading = leading, trailing = trailing}, s, w.pointer); result != .Ok {return result}
	if t.status.glyph != .None {
		band := render.Rect{tile.x, tile.y + s, tile.width, tile.height - 3 * s}
		ui.tab_progress_draw(&w.list, app.theme, band, t.status, s)
		size := ui.ICON_INDICATOR * s
		mark := render.Rect{status_right - ui.SPACE_1 * s - size, tile.y + (tile.height - size) / 2, size, size}
		if result := ui.status_glyph_draw(&w.list, &w.ui_text, app.theme, mark, t.status, t.status_phase, s);
		   result != .Ok {return result}
	}
	if has_badge {
		badge := ui.tab_badge_draw(&w.list, &w.ui_text, app.theme, tile, t, s)
		if badge != .Ok {return badge}
	}
	if show_close {
		ui.icon_draw(&w.list, .Close, close, app.theme.tab_text, ui.ICON_INDICATOR, s)
	}
	return .Ok
}

rail_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if w.tabs_horizontal {return .Ok}
	// An overlay draws while open or sliding; a docked rail only in its own presentation.
	overlay, draw_overlay := w.rail.(Rail_Overlay)
	draw_overlay &&= rail_overlay(w) || overlay.slide.value > 0
	if !rail_docked(w) && !draw_overlay {return .Ok}
	layout, ok := rail_current_layout(w)
	if !ok {return .Ok}
	area := layout.area
	if draw_overlay {
		area.x -= (1 - overlay.slide.value) * area.width
		layout = ui.rail_layout(area, w.scale, rail_tab_count(w) + w.tab_incoming.count, w.rail_scroll)
	}
	if area.x + area.width <= 0 {return .Ok}
	if render.push_layer(&w.list, area) != .None {return .Ok}
	if draw_overlay {
		frame := ui.Panel {
			rect     = area,
			radius   = 0,
			scale    = w.scale,
			shadow_x = 2,
			softness = 14,
		}
		if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	} else {
		ui.draw_rect(&w.list, {rect = area, color = app.theme.tab_bar})
	}
	if render.push_layer(&w.list, layout.list) != .None {return .Ok}
	dragging := tab_drag_active(w)
	moving := dragging
	for position in w.tab_positions {moving ||= ui.motion_active(position)}
	for pass in 0 ..< (dragging ? 2 : 1) {
		foreground := pass == 1
		for tab, index in w.workspace.tabs {
			if (dragging && tab.marked) != foreground {continue}
			if result := rail_row_draw(app, w, layout, index, moving); result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, layout.footer) != .None {return .Ok}
	tile := ui.rail_new_tab_tile(layout)
	hover := w.tab_hover == Tab_Chrome_New{}
	pressed := gesture_tab_pressed(w) == Tab_Chrome_New{}
	if hover || pressed {
		fill := pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = tile, color = fill, radius = ui.RADIUS_CONTROL * w.scale})
	}
	// The plus takes a leading icon's column so its label lines up with the tab titles.
	plus := render.Rect{tile.x + ui.CONTROL_INSET * w.scale, tile.y, ui.ICON_BUTTON * w.scale, tile.height}
	ui.icon_draw(&w.list, .Add, plus, app.theme.muted, ui.ICON_INDICATOR, w.scale)
	if result := ui.draw_fading_text(
		&w.ui_text,
		&w.list,
		"New tab",
		plus.x + plus.width + ui.SPACE_2 * w.scale,
		rail_text_baseline(w, tile),
		app.theme.muted,
		max(0, tile.width - 40 * w.scale),
	); result != .Ok {return result}
	if hover {
		radius := ui.RADIUS_CONTROL * w.scale
		if ui.hover_rim_draw(&w.list, app.theme, tile, radius, 1, w.scale, w.pointer) != .None {
			return .Ok
		}
	}
	chevron := ui.rail_profile_rect(layout)
	profile_hover := f32(int(w.tab_hover == Tab_Chrome_Profiles{}))
	profile_press := f32(int(gesture_tab_pressed(w) == Tab_Chrome_Profiles{}))
	_ = ui.icon_button_draw(
		&w.list,
		app.theme,
		chevron,
		.Chevron_Down,
		profile_hover,
		profile_press,
		w.scale,
		w.pointer,
		ui.ICON_INDICATOR,
	)
	return .Ok
}

tab_orientation_button_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	r := tab_orientation_button_rect(w)
	if r.width < 24 * w.scale {return .Ok}
	if render.push_layer(
		   &w.list,
		   {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * w.scale},
	   ) != .None {return .Ok}
	hover := f32(int(w.tab_orientation_button_hovered))
	press := f32(int(ui.armed_down(w.tab_orientation_button_armed)))
	icon: ui.Icon = w.tabs_horizontal ? .Layout_Top : .Layout_Left
	_ = ui.icon_button_draw(&w.list, app.theme, r, icon, hover, press, w.scale, w.pointer)
	return .Ok
}
