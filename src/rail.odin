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
		0,
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

rail_resize_hit :: proc(w: ^Window, x, y: f32) -> bool {
	r := rail_resize_rect(w)
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

rail_resize_cancel :: proc(w: ^Window) {
	if w.rail_resizing {w.gesture.cancelled += {.Left}}
	w.rail_resizing = false
}

rail_resize_move :: proc(app: ^App, w: ^Window, x: f32) {
	width := ui.rail_pixel_width(w.scale, (x - w.rail_resize_offset) / w.scale, f32(w.width))
	if width == rail_width_pixels(w) {return}
	w.rail_width = width / w.scale
	window_relayout(app, w)
}

@(require_results)
rail_current_layout :: proc(w: ^Window) -> (layout: ui.Rail_Layout, ok: bool) {
	if w.tabs_horizontal {return {}, false}
	if !rail_rows_build(w, &w.rail_rows) {return {}, false}
	layout = ui.rail_layout(rail_area(w), w.scale, len(w.rail_rows), w.rail_scroll)
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
	if was_docked != rail_docked(w) {window_relayout(app, w)}
	w.dirty = true
}

rail_overlay_dismiss :: proc(app: ^App, w: ^Window) {
	if !rail_overlay(w) {return}
	rail_resize_cancel(w)
	w.rail_override = .Auto
	w.rail_was_overlay = true
	ui.motion_target(&w.rail_slide, 0, 140 * time.Millisecond, .Decelerate, app.animations, time.tick_now())
	w.dirty = true
}

rail_row_rect_for_tab :: proc(w: ^Window, tab: int) -> render.Rect {
	layout, ok := rail_current_layout(w)
	if !ok {return {}}
	index := rail_row_index_for_tab(w.rail_rows[:], w.workspace, tab)
	return ui.rail_row_rect(layout, index)
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
	row := ui.rail_row_hit(layout, x, y)
	if row < 0 {return {kind = .Empty}}
	entry := w.rail_rows[row]
	if entry.workspace != w.workspace || entry.tab < 0 || entry.tab >= len(w.workspace.tabs) {
		return {kind = .Empty}
	}
	kind: Tab_Interaction_Kind = ui.rail_close_hit(layout, x, y, w.scale) >= 0 ? .Close : .Tab
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
	row := ui.rail_row_hit(layout, x, y)
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
rail_tab_rows :: proc(rows: []Rail_Row, workspace: ^Workspace, out: ^[dynamic]int) {
	clear(out)
	for row, i in rows {
		if row.workspace == workspace {append(out, i)}
	}
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
) -> glyphs.Result {
	row := w.rail_rows[index]
	s := w.scale
	hover := w.rail_hover == index
	pressed := w.rail_pressed == index
	rect := ui.rail_row_rect(layout, index)
	if rect.width <= 0 || rect.y + rect.height <= layout.list.y || rect.y >= layout.list.y + layout.list.height {
		return .Ok
	}
	tile := ui.rail_tab_tile(layout, rect)
	selected := row.workspace == w.workspace && row.tab == w.workspace.selected
	marked := row.workspace == w.workspace && row.workspace.tabs[row.tab].marked
	if selected {
		ui.draw_rect(&w.list, {rect = {tile.x, tile.y + 1 * s, tile.width, tile.height - 2 * s},
			color = app.theme.selection, radius = 6 * s})
		ui.draw_rect(&w.list, {rect = {tile.x + 1 * s, tile.y + 8 * s, 2 * s, tile.height - 16 * s},
			color = app.theme.accent, radius = s})
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
	has_badge := icon != "" || atlas.width > 0
	label_x := tile.x + 8 * s
	if has_badge {
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
	close := ui.rail_close_rect(layout, index, s)
	show_close := current && (hover || pressed || ui.armed_is(w.tab_close_armed, row.tab))
	if show_close {
		large := w.ui_text
		ui.text_set_size(&large, w.ui_text.size_px * 1.35)
		if result := ui.draw_glyph_centered(&large, &w.list, '×', close, app.theme.muted);
		   result != .Ok {return result}
	}
	label_right := show_close ? close.x - 4 * s : tile.x + tile.width - 8 * s
	if result := ui.draw_fading_text(
		&w.ui_text,
		&w.list,
		title,
		label_x,
		rail_text_baseline(w, tile),
		selected ? app.theme.text : app.theme.muted,
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

@(private)
rail_drop_indicator_draw :: proc(app: ^App, w: ^Window, layout: ui.Rail_Layout) -> glyphs.Result {
	if !w.tab_drag.active || w.tab_drag.elsewhere {return .Ok}
	positions := make([dynamic]int, context.temp_allocator)
	rail_tab_rows(w.rail_rows[:], w.workspace, &positions)
	if len(positions) == 0 {return .Ok}
	s := w.scale
	y: f32
	if w.tab_drag.slot >= len(positions) {
		last := ui.rail_row_rect(layout, positions[len(positions) - 1])
		y = last.y + last.height
	} else {
		y = ui.rail_row_rect(layout, positions[w.tab_drag.slot]).y
	}
	first := ui.rail_row_rect(layout, positions[0])
	ui.draw_rect(
		&w.list,
		{
			rect = {first.x + ui.RAIL_TAB_INDENT * s, y - s, max(0, first.width - ui.RAIL_TAB_INDENT * s), 2 * s},
			color = app.theme.accent,
			radius = s,
		},
	)
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
		ui.draw_rect(&w.list, {rect = area, color = app.theme.chrome})
		ui.draw_rect(
			&w.list,
			{rect = {area.x + area.width - w.scale, area.y, w.scale, area.height}, color = app.theme.border},
		)
	}
	if render.push_layer(&w.list, layout.list) != .None {return .Ok}
	for index in 0 ..< len(w.rail_rows) {
		if result := rail_row_draw(app, w, layout, index); result != .Ok {return result}
	}
	if result := rail_drop_indicator_draw(app, w, layout); result != .Ok {return result}
	if render.push_layer(&w.list, layout.footer) != .None {return .Ok}
	tile := ui.rail_new_tab_tile(layout)
	hover := w.rail_hover == RAIL_NEW_TAB_ROW
	pressed := w.rail_pressed == RAIL_NEW_TAB_ROW
	if hover || pressed {
		fill := pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = tile, color = fill, radius = 6 * w.scale})
	}
	plus := ui.text_styled(&w.ui_text, .Strong)
	baseline := rail_text_baseline(w, tile)
	plus_width := ui.text_width(&plus, "+")
	if result := ui.draw_text(
		&plus,
		&w.list,
		"+",
		tile.x + 8 * w.scale,
		baseline,
		app.theme.accent,
	); result != .Ok {return result}
	if result := ui.draw_fading_text(
		&w.ui_text,
		&w.list,
		"New tab",
		tile.x + 8 * w.scale + plus_width + 6 * w.scale,
		baseline,
		app.theme.muted,
		max(0, tile.width - 28 * w.scale - plus_width),
	); result != .Ok {return result}
	if hover {
		if ui.hover_rim_draw(&w.list, app.theme, tile, 6 * w.scale, 1, w.scale, w.pointer) != .None {
			return .Ok
		}
	}
	chevron := ui.rail_profile_rect(layout)
	profile_hover := w.rail_hover == RAIL_PROFILE_ROW
	profile_pressed := w.rail_pressed == RAIL_PROFILE_ROW
	if profile_hover || profile_pressed {
		fill := profile_pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = chevron, color = fill, radius = 6 * w.scale})
	}
	if result := ui.draw_glyph_centered(&w.ui_text, &w.list, '▾', chevron, app.theme.muted);
	   result != .Ok {return result}
	if profile_hover {
		if ui.hover_rim_draw(&w.list, app.theme, chevron, 6 * w.scale, 1, w.scale, w.pointer) != .None {
			return .Ok
		}
	}
	return .Ok
}

tab_orientation_button_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	r := tab_orientation_button_rect(w)
	if r.width < 24 * w.scale {return .Ok}
	if render.push_layer(
		   &w.list,
		   {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * w.scale},
	   ) != .None {return .Ok}
	hover := w.tab_orientation_button_hovered
	pressed := ui.armed_down(w.tab_orientation_button_armed)
	if hover || pressed {
		fill := pressed ? app.theme.pressed : app.theme.hover
		ui.draw_rect(&w.list, {rect = r, color = fill, radius = 6 * w.scale})
	}
	icon := render.Rect{r.x + (r.width - 16 * w.scale) / 2, r.y + 8 * w.scale, 16 * w.scale, 16 * w.scale}
	ink := app.theme.text
	ui.draw_rect(
		&w.list,
		{rect = {icon.x, icon.y + w.scale, icon.width, icon.height - 2 * w.scale},
			color = ink, radius = 3 * w.scale, stroke = w.scale},
	)
	divider := render.Rect{icon.x + 5 * w.scale, icon.y + 4 * w.scale, w.scale, icon.height - 8 * w.scale}
	if w.tabs_horizontal {
		divider = {icon.x + 3 * w.scale, icon.y + 5 * w.scale, icon.width - 6 * w.scale, w.scale}
	}
	ui.draw_rect(&w.list, {rect = divider, color = ink})
	if hover {
		if result := ui.hover_rim_draw(
			&w.list,
			app.theme,
			r,
			6 * w.scale,
			1,
			w.scale,
			w.pointer,
		); result != .None {return .Ok}
	}
	return .Ok
}
