package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"

Workspace_Icon_Layout :: struct {
	panel, grid, divider, field, apply: render.Rect,
	columns, rows, visible_rows: int,
}

workspace_icon_picker_layout :: proc(w: ^Window) -> Workspace_Icon_Layout {
	s := w.scale
	width := min(272 * s, max(0, f32(w.width) - 10 * s))
	columns := clamp(int((width - 20 * s) / (48 * s)), 1, 5)
	count := (w.workspace_picker.mode == .Tint) ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)
	rows := (count + columns - 1) / columns
	available := max(0, f32(w.height) - (ui.TAB_HEIGHT + 5) * s)
	height := min(available, (146 + f32(rows) * 48) * s)
	panel := render.Rect{5 * s, ui.TAB_HEIGHT * s, width, height}
	grid_height := max(0, height - 150 * s)
	visible := clamp(int((grid_height + 4 * s) / (48 * s)), 0, rows)
	grid_width := max(0, min(width - 24 * s, f32(columns) * 48 * s - 4 * s))
	grid := render.Rect{panel.x + (width - grid_width) / 2, panel.y + 40 * s, grid_width,
		max(0, f32(visible) * 48 * s - 4 * s)}
	footer_y := max(panel.y, panel.y + height - 102 * s)
	field := render.Rect{panel.x + 12 * s, footer_y + 12 * s, max(0, width - 24 * s), 32 * s}
	return {panel = panel, grid = grid, columns = columns, rows = rows, visible_rows = visible,
		divider = {field.x, footer_y, field.width, s}, field = field,
		apply = {field.x, field.y + 40 * s, field.width, 34 * s}}
}

workspace_icon_picker_cell :: proc(w: ^Window, g: Workspace_Icon_Layout, index: int) -> render.Rect {
	count := (w.workspace_picker.mode == .Tint) ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)
	if w.workspace_picker.mode == .Tint {
		if index == count { return g.apply }
	} else {
		if index == count { return g.field }
		if index == count + 1 { return g.apply }
		if index == count + 2 { return workspace_icon_color_button(w) }
	}
	if index < 0 || index >= count { return {} }
	s := w.scale
	return {g.grid.x + f32(index % g.columns) * 48 * s,
		g.grid.y + f32(index / g.columns - w.workspace_picker.scroll) * 48 * s, 44 * s, 44 * s}
}

workspace_icon_picker_reveal :: proc(w: ^Window, g: Workspace_Icon_Layout) {
	p := &w.workspace_picker
	count := (p.mode == .Tint) ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)
	if p.selected >= 0 && p.selected < count && g.visible_rows > 0 {
		row := p.selected / g.columns
		p.scroll = clamp(p.scroll, row - g.visible_rows + 1, row)
	}
	p.scroll = clamp(p.scroll, 0, max(0, g.rows - max(1, g.visible_rows)))
}

workspace_icon_picker_hit :: proc(w: ^Window, x, y: f32) -> int {
	g := workspace_icon_picker_layout(w)
	if !workspace_rect_contains(g.panel, x, y) { return -1 }
	colors := (w.workspace_picker.mode == .Tint)
	count := colors ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)
	if !colors && workspace_rect_contains(workspace_icon_color_button(w), x, y) { return count + 2 }
	if workspace_rect_contains(g.apply, x, y) { return count + (colors ? 0 : 1) }
	if !workspace_rect_contains(g.grid, x, y) { return -1 }
	for i in 0..<count {
		if workspace_rect_contains(workspace_icon_picker_cell(w, g, i), x, y) { return i }
	}
	return -1
}

workspace_icon_picker_key :: proc(w: ^Window, e: platform.Key_Event) -> bool {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	g := workspace_icon_picker_layout(w)
	count := len(WORKSPACE_ICONS)
	#partial switch e.key {
	case .Arrow_Down:
		p.selected = p.selected < count ? min(count, p.selected + g.columns) : (p.selected + 1) % (count + 3)
	case .Arrow_Up:
		if p.selected == count { p.selected = count - 1 }
		else if p.selected == count + 1 { p.selected = count }
		else if p.selected == count + 2 { p.selected = count + 1 }
		else { p.selected = p.selected < g.columns ? count + 2 : p.selected - g.columns }
	case .Arrow_Left, .Arrow_Right:
		if p.selected >= count { return p.selected == count + 2 }
		p.selected = (p.selected + count + (e.key == .Arrow_Left ? -1 : 1)) % count
	case .Home, .End:
		if p.selected >= count { return p.selected == count + 2 }
		p.selected = e.key == .Home ? 0 : count - 1
	case: return false
	}
	return true
}

workspace_icon_picker_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p, s := &w.workspace_picker, w.scale
	if p.mode == .Tint { return workspace_icon_color_draw(app, w) }
	g := workspace_icon_picker_layout(w)
	target := workspace_row_target(app, p.target_id)
	if target == nil { return .Ok }
	if result := ui.draw_text(&w.ui_text, &w.list, "Icon", g.panel.x + 12 * s, g.panel.y + 26 * s,
		app.theme.text, max(0, g.panel.width - 106 * s)); result != .Ok { return result }
	color_button := workspace_icon_color_button(w)
	color_fill := p.selected == len(WORKSPACE_ICONS) + 2 ? app.theme.selection : app.theme.pane
	button := render.Rect_Instance{rect = color_button, radius = 5 * s, color = color_fill}
	if render.push_rect(&w.list, button) != .None { return .Ok }
	if result := ui.draw_text(&w.ui_text, &w.list, "Color...", color_button.x + 8 * s, color_button.y + 20 * s,
		app.theme.text, max(0, color_button.width - 16 * s)); result != .Ok { return result }
	if render.push_layer(&w.list, g.grid) != .None { return .Ok }
	for i in 0..<len(WORKSPACE_ICONS) {
		row := i / g.columns - p.scroll
		if row < 0 || row >= g.visible_rows { continue }
		cell := workspace_icon_picker_cell(w, g, i)
		if i == p.selected {
			if render.push_rect(&w.list, {rect = cell, color = app.theme.selection, radius = 5 * s}) != .None {
				return .Ok
			}
		}
		icon := render.Rect{cell.x + 10 * s, cell.y + 8 * s, 24 * s, 24 * s}
		tint := target != nil ? target.icon.tint : 0
		preset := Workspace_Icon{preset = i, tint = tint}
		if result := workspace_icon_draw(w, preset, icon, app.theme.text);
		   result != .Ok { return result }
		if target != nil && target.icon.emoji == "" && target.icon.preset == i {
			mark := render.Rect{cell.x + 14 * s, cell.y + 38 * s, 16 * s, 2 * s}
			if render.push_rect(&w.list, {rect = mark, color = app.theme.accent, radius = s}) != .None { return .Ok }
		}
	}
	if render.push_layer(&w.list, g.panel, 7 * s) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = g.divider, color = app.theme.border}) != .None { return .Ok }
	field_fill := render.Rect_Instance{rect = g.field, color = app.theme.pane, radius = 5 * s}
	if render.push_rect(&w.list, field_fill) != .None { return .Ok }
	if result := ui.field_draw(&p.query, &w.list, &w.ui_text, app.theme, g.field.x + 8 * s,
		g.field.y + (g.field.height - w.ui_text.line_height) / 2 + w.ui_text.ascent, max(1, g.field.width - 16 * s),
		p.selected == len(WORKSPACE_ICONS), "Custom emoji", app.theme.text, s); result != .Ok { return result }
	fill := p.selected == len(WORKSPACE_ICONS) + 1 ? app.theme.selection : app.theme.pane
	if render.push_rect(&w.list, {rect = g.apply, color = fill, radius = 5 * s}) != .None { return .Ok }
	color := workspace_icon_valid(ui.field_string(&p.query)) ? app.theme.text : app.theme.muted
	apply_baseline := g.apply.y + (g.apply.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
	return ui.draw_text(&w.ui_text, &w.list, "Apply Custom Emoji", g.apply.x + 8 * s,
		apply_baseline, color, max(0, g.apply.width - 16 * s))
}

workspace_icon_color_button :: proc(w: ^Window) -> render.Rect {
	g := workspace_icon_picker_layout(w)
	s := w.scale
	return {g.panel.x + max(0, g.panel.width - 82 * s), g.panel.y + 6 * s, min(70 * s, g.panel.width), 28 * s}
}
