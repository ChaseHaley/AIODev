package main

import "aio:glyphs"
import "aio:input"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:time"

RAIL_NEW_TAB_ROW :: -2
RAIL_PROFILE_ROW :: -3

Rail_Row :: struct {
	workspace: ^Workspace,
	tab:       int,
}

// A manual visibility choice survives resizes on the same side of the dock threshold. Crossing
// the threshold returns the window to automatic behaviour, so a docked rail docks again when
// the window widens and a narrow window hides it again.
Rail_Override :: enum {
	Auto,
	Shown,
	Hidden,
}

@(require_results)
rail_rows_build :: proc(w: ^Window, rows: ^[dynamic]Rail_Row) -> bool {
	clear(rows)
	if w == nil || w.workspace == nil {return true}
	for _, tab in w.workspace.tabs {
		if _, err := append(rows, Rail_Row{w.workspace, tab}); err != nil {
			clear(rows)
			return false
		}
	}
	return true
}

rail_auto_at :: proc(width: i32, scale: f32) -> bool {
	return f32(width) >= ui.RAIL_DOCK_MIN_WIDTH * scale
}

rail_adaptive_update :: proc(w: ^Window) {
	if w.tabs_horizontal {return}
	auto := rail_auto_at(w.width, w.scale)
	if auto == w.rail_auto {return}
	rail_resize_cancel(w)
	w.rail_auto, w.rail_override = auto, .Auto
	w.rail_was_overlay = false
	// A crossing must not leave the previous presentation behind: wide turns the docked rail on,
	// narrow turns every rail state off until the toggle asks for an overlay.
	if auto {
		w.rail_slide.value, w.rail_slide.target = 1, 1
	} else {
		w.rail_slide.value, w.rail_slide.target = 0, 0
	}
}

rail_visible :: proc(w: ^Window) -> bool {
	if w.tabs_horizontal {return false}
	switch w.rail_override {
	case .Hidden:
		return false
	case .Shown:
		return true
	case .Auto:
		return w.rail_auto
	}
	return false
}

rail_docked :: proc(w: ^Window) -> bool {
	return rail_visible(w) && w.rail_auto
}

rail_overlay :: proc(w: ^Window) -> bool {
	return rail_visible(w) && !w.rail_auto
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
	width := w.rail_width > 0 ? w.rail_width : ui.RAIL_WIDTH
	return ui.rail_pixel_width(w.scale, width, f32(w.width))
}

rail_resize_rect :: proc(w: ^Window) -> render.Rect {
	if w.preparing || !rail_visible(w) {return {}}
	area := rail_area(w)
	return {area.x + area.width - 3 * w.scale, area.y, 6 * w.scale, area.height}
}

rail_resize_cancel :: proc(w: ^Window) {
	if w.rail_resizing {w.gesture.cancelled += {.Left}}
	if w.rail_resizing {w.dragging = {}}
	w.rail_resizing = false
}

@(require_results)
rail_current_layout :: proc(w: ^Window) -> (layout: ui.Rail_Layout, ok: bool) {
	if w.tabs_horizontal {return {}, false}
	if !rail_rows_build(w, &w.rail_rows) {return {}, false}
	area := rail_area(w)
	area.height = max(0, area.height - w.status_rail_reserve)
	layout = ui.rail_layout(area, w.scale, len(w.rail_rows), w.rail_scroll)
	w.rail_scroll = layout.scroll
	return layout, true
}

rail_row_index_for_tab :: proc(rows: []Rail_Row, workspace: ^Workspace, tab: int) -> int {
	for row, i in rows {
		if row.workspace == workspace && row.tab == tab {return i}
	}
	return -1
}

rail_reveal_active :: proc(w: ^Window) {
	if w.tabs_horizontal {return}
	layout, ok := rail_current_layout(w)
	if !ok {return}
	index := rail_row_index_for_tab(w.rail_rows[:], w.workspace, w.workspace.selected)
	if index < 0 {return}
	scroll := ui.rail_reveal_row(layout, index)
	if scroll != w.rail_scroll {
		w.rail_scroll, w.dirty = scroll, true
	}
}

tab_orientation_button_rect :: proc(w: ^Window) -> render.Rect {
	s := w.scale
	return {4 * s, 4 * s, ui.RAIL_TOGGLE_WIDTH * s, 32 * s}
}

tab_orientation_button_hit :: proc(w: ^Window, x, y: f32) -> bool {
	r := tab_orientation_button_rect(w)
	return r.width >= 24 * w.scale && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

rail_toggle :: proc(app: ^App, w: ^Window) {
	if w.tabs_horizontal {return}
	rail_resize_cancel(w)
	was_docked := rail_docked(w)
	now := time.tick_now()
	if rail_visible(w) {
		was_overlay := rail_overlay(w)
		w.rail_override = .Hidden
		if was_overlay {
			w.rail_was_overlay = true
			ui.motion_target(&w.rail_slide, 0, 140 * time.Millisecond, .Decelerate, app.animations, now)
		} else {
			w.rail_was_overlay = false
			w.rail_slide.value, w.rail_slide.target = 0, 0
		}
	} else {
		w.rail_override = .Shown
		if !w.rail_auto {
			w.rail_was_overlay = true
			ui.motion_target(&w.rail_slide, 1, 140 * time.Millisecond, .Decelerate, app.animations, now)
		} else {
			w.rail_was_overlay = false
			w.rail_slide.value, w.rail_slide.target = 1, 1
		}
	}
	if was_docked != rail_docked(w) {window_relayout(app, w)} else {window_dividers(app, w)}
	w.dirty = true
}

rail_overlay_dismiss :: proc(app: ^App, w: ^Window) {
	if !rail_overlay(w) {return}
	rail_resize_cancel(w)
	w.rail_override = .Auto
	window_dividers(app, w)
	w.rail_was_overlay = true
	ui.motion_target(&w.rail_slide, 0, 140 * time.Millisecond, .Decelerate, app.animations, time.tick_now())
	w.dirty = true
}

rail_row_rect_for_tab :: proc(w: ^Window, tab: int) -> render.Rect {
	layout, ok := rail_current_layout(w)
	if !ok {return {}}
	index := rail_row_index_for_tab(w.rail_rows[:], w.workspace, tab)
	return rail_tab_rect(w, layout, index)
}

@(private)
rail_tab_rect :: proc(w: ^Window, layout: ui.Rail_Layout, index: int) -> render.Rect {
	r := ui.rail_row_rect(layout, index)
	if index < 0 || index >= len(w.rail_rows) {return r}
	r.y += (tab_position(w, w.rail_rows[index].tab) - f32(index)) * layout.row_height
	return r
}

@(private)
rail_tab_close_rect :: proc(w: ^Window, layout: ui.Rail_Layout, index: int) -> render.Rect {
	r := ui.rail_close_rect(layout, index, w.scale)
	if index < 0 || index >= len(w.rail_rows) {return r}
	r.y += (tab_position(w, w.rail_rows[index].tab) - f32(index)) * layout.row_height
	return r
}

rail_tab_hit :: proc(w: ^Window, layout: ui.Rail_Layout, x, y: f32) -> int {
	if x < layout.list.x || x >= layout.list.x + layout.list.width ||
	   y < layout.list.y || y >= layout.list.y + layout.list.height {return -1}
	for pass in 0 ..< 2 {
		for index := len(w.rail_rows) - 1; index >= 0; index -= 1 {
			row := w.rail_rows[index]
			foreground := w.tab_drag.active && row.workspace.tabs[row.tab].marked
			if foreground != (pass == 0) {continue}
			r := rail_tab_rect(w, layout, index)
			if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {return index}
		}
	}
	return -1
}

rail_tab_interaction_hit :: proc(w: ^Window, x, y: f32, button: input.Mouse_Button) -> Tab_Interaction_Hit {
	area := rail_area(w)
	if !rail_visible(w) || x < area.x || x >= area.x + area.width ||
	   y < area.y || y >= area.y + area.height {return {}}
	layout, ok := rail_current_layout(w)
	if !ok {return {kind = .Empty}}
	if ui.rail_footer_hit(layout, x, y) {
		if button == .Left && ui.rail_profile_hit(layout, x, y) {
			tile := rail_profile_rect(w)
			return {kind = .Profiles, menu_anchor = {tile.x, tile.y + tile.height}}
		}
		tile := ui.rail_footer_tile(layout)
		return {kind = .New_Tab, menu_anchor = {tile.x, tile.y + tile.height}}
	}
	row := rail_tab_hit(w, layout, x, y)
	if row < 0 {return {kind = .Empty}}
	entry := w.rail_rows[row]
	if entry.workspace != w.workspace || entry.tab < 0 || entry.tab >= len(w.workspace.tabs) {
		return {kind = .Empty}
	}
	close := rail_tab_close_rect(w, layout, row)
	on_close := x >= close.x && x < close.x + close.width && y >= close.y && y < close.y + close.height
	kind: Tab_Interaction_Kind = on_close ? .Close : .Tab
	return {kind = kind, index = entry.tab}
}

@(require_results)
rail_pane_target :: proc(w: ^Window, x, y: f32) -> (tab: int, new_tab, ok: bool) {
	if !rail_visible(w) {return -1, false, false}
	area := rail_area(w)
	if x < area.x || x >= area.x + area.width || y < area.y || y >= area.y + area.height {
		return -1, false, false
	}
	layout, built := rail_current_layout(w)
	if !built {return -1, false, false}
	if ui.rail_footer_hit(layout, x, y) {return -1, true, true}
	row := rail_tab_hit(w, layout, x, y)
	if row < 0 {return -1, true, true}
	entry := w.rail_rows[row]
	if entry.workspace == w.workspace {return entry.tab, false, true}
	return -1, false, false
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
) -> glyphs.Result {
	row := w.rail_rows[index]
	s := w.scale
	hover := w.rail_hover == index
	pressed := w.rail_pressed == index
	rect := rail_tab_rect(w, layout, index)
	if rect.width <= 0 || rect.y + rect.height <= layout.list.y || rect.y >= layout.list.y + layout.list.height {
		return .Ok
	}
	if moving {
		if render.push_layer(&w.list, layout.list) != .None {return .Ok}
		if rail_docked(w) {ui.draw_rect(&w.list, {rect = rect, color = app.theme.tab_bar})}
	}
	tile := ui.rail_tab_tile(layout, rect)
	selected := row.workspace == w.workspace && row.tab == w.workspace.selected
	marked := row.workspace == w.workspace && row.workspace.tabs[row.tab].marked
	if selected {
		ui.draw_rect(&w.list, {rect = {tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			color = app.theme.rail_active, radius = 6 * s})
		ui.draw_rect(&w.list, {rect = {tile.x + 1 * s, tile.y + 8 * s, 2 * s, tile.height - 16 * s},
			color = app.theme.tab_indicator, radius = s})
	} else if marked {
		ui.draw_rect(&w.list, {rect = {tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			color = app.theme.selection, radius = 6 * s})
		ui.draw_rect(&w.list, {rect = {tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			color = app.theme.accent, radius = 6 * s, stroke = s})
	} else if hover || pressed {
		fill := pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = {tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			color = fill, radius = 6 * s})
	}
	title := fmt.tprintf("Tab %d", row.tab + 1)
	if row.tab < len(row.workspace.tabs) && row.workspace.tabs[row.tab].title != "" {
		title = row.workspace.tabs[row.tab].title
	}
	icon: string
	atlas := render.Rect{}
	if pane, terminal := workspace_focused_session_pane(app, row.workspace, row.tab); terminal {
		if pane.session != nil {icon = pane.session.header.icon}
		result: glyphs.Result
		atlas, result = shell_icon_atlas(app)
		if result != .Ok {return result}
	}
	status := status_tab_mark(app, w, row.workspace, row.tab)
	has_badge := icon != "" || atlas.width > 0
	label_x := tile.x + 8 * s
	if status.glyph != .None {
		label_x = tile.x + 28 * s
		ui.status_progress_draw(
			&w.list,
			app.theme,
			{tile.x + 8 * s, tile.y + s, max(0, tile.width - 16 * s), tile.height - 3 * s},
			status,
			s,
		)
		if result := status_mark_draw(app, w, {tile.x + 9 * s, tile.y + 9 * s, 14 * s, 14 * s}, status);
		   result != .Ok {return result}
	} else if has_badge {
		label_x = tile.x + 28 * s
		if result := ui.shell_badge_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			{tile.x + 8 * s, tile.y + 8 * s, 16 * s, 16 * s},
			icon,
			s,
			atlas,
		); result != .Ok {return result}
	}
	current := row.workspace == w.workspace
	close := rail_tab_close_rect(w, layout, index)
	show_close := current && (hover || pressed || ui.armed_is(w.tab_close_armed, row.tab))
	if show_close {
		ui.icon_draw(&w.list, .Close, close, app.theme.tab_text, ui.ICON_INDICATOR, s)
	}
	label_right := show_close ? close.x - 4 * s : tile.x + tile.width - 8 * s
	if result := ui.draw_fading_text(
		&w.ui_text,
		&w.list,
		title,
		label_x,
		rail_text_baseline(w, tile),
		selected ? app.theme.tab_active_text : app.theme.tab_text,
		max(0, label_right - label_x),
	); result != .Ok {return result}
	if hover && !selected {
		if result := ui.hover_rim_draw(
			&w.list,
			app.theme,
			{tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			6 * s,
			1,
			s,
			w.pointer,
		); result != .None {return .Ok}
	}
	return .Ok
}

rail_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if w.tabs_horizontal {return .Ok}
	draw_overlay :=
		rail_overlay(w) ||
		(w.rail_was_overlay && !rail_docked(w) && w.rail_slide.value > 0)
	if !rail_docked(w) && !draw_overlay {return .Ok}
	layout, ok := rail_current_layout(w)
	if !ok {return .Ok}
	area := layout.area
	if draw_overlay {
		area.x -= (1 - w.rail_slide.value) * area.width
		layout = ui.rail_layout(area, w.scale, len(w.rail_rows), w.rail_scroll)
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
			border   = .Stroked,
		}
		if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	} else {
		ui.draw_rect(&w.list, {rect = area, color = app.theme.tab_bar})
		ui.draw_rect(
			&w.list,
			{rect = {area.x + area.width - w.scale, area.y, w.scale, area.height}, color = app.theme.border},
		)
	}
	if render.push_layer(&w.list, layout.list) != .None {return .Ok}
	moving := w.tab_drag.active
	for position in w.tab_positions {moving ||= ui.motion_active(position)}
	for pass in 0 ..< (w.tab_drag.active ? 2 : 1) {
		foreground := pass == 1
		for row, index in w.rail_rows {
			if (w.tab_drag.active && row.workspace.tabs[row.tab].marked) != foreground {continue}
			if result := rail_row_draw(app, w, layout, index, moving); result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, layout.footer) != .None {return .Ok}
	tile := ui.rail_new_tab_tile(layout)
	hover := w.rail_hover == RAIL_NEW_TAB_ROW
	pressed := w.rail_pressed == RAIL_NEW_TAB_ROW
	if hover || pressed {
		fill := pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = tile, color = fill, radius = 6 * w.scale})
	}
	plus := render.Rect{tile.x + 8 * w.scale, tile.y, ui.ICON_INDICATOR * w.scale, tile.height}
	ui.icon_draw(&w.list, .Add, plus, app.theme.muted, ui.ICON_INDICATOR, w.scale)
	if result := ui.draw_fading_text(
		&w.ui_text,
		&w.list,
		"New tab",
		plus.x + plus.width + 6 * w.scale,
		rail_text_baseline(w, tile),
		app.theme.muted,
		max(0, tile.width - 40 * w.scale),
	); result != .Ok {return result}
	if hover {
		if ui.hover_rim_draw(&w.list, app.theme, tile, 6 * w.scale, 1, w.scale, w.pointer) != .None {
			return .Ok
		}
	}
	chevron := ui.rail_profile_rect(layout)
	profile_hover := f32(int(w.rail_hover == RAIL_PROFILE_ROW))
	profile_press := f32(int(w.rail_pressed == RAIL_PROFILE_ROW))
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

tab_orientation_button_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
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
