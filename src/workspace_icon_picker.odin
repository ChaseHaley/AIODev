package main

import "aio:input"
import "aio:render"
import "aio:ui"

Workspace_Icon_Layout :: struct {
	panel, grid, divider, field, apply: render.Rect,
	columns, rows, visible_rows: int,
}

workspace_icon_picker_layout :: proc(w: ^Window) -> Workspace_Icon_Layout {
	s := w.scale
	width := min(272 * s, max(0, f32(w.width) - 2 * ui.SPACE_1 * s))
	columns := clamp(int((width - 20 * s) / (48 * s)), 1, 5)
	count := workspace_picker_tint(&w.workspace_picker) ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)
	rows := (count + columns - 1) / columns
	available := max(0, f32(w.height) - (ui.TITLE_BAR_HEIGHT + ui.SPACE_1) * s)
	height := min(available, (136 + f32(rows) * 48) * s)
	panel := render.Rect{ui.SPACE_1 * s, ui.TITLE_BAR_HEIGHT * s, width, height}
	grid_height := max(0, height - 140 * s)
	visible := clamp(int((grid_height + 4 * s) / (48 * s)), 0, rows)
	grid_width := max(0, min(width - 24 * s, f32(columns) * 48 * s - 4 * s))
	grid := render.Rect{panel.x + (width - grid_width) / 2, panel.y + 40 * s, grid_width,
		max(0, f32(visible) * 48 * s - 4 * s)}
	footer_y := max(panel.y, panel.y + height - (12 + 2 * ui.HEIGHT_STANDARD + 8 + 12) * s)
	field := render.Rect{panel.x + 12 * s, footer_y + 12 * s, max(0, width - 24 * s), ui.HEIGHT_STANDARD * s}
	return {panel = panel, grid = grid, columns = columns, rows = rows, visible_rows = visible,
		divider = {field.x, footer_y, field.width, s}, field = field,
		apply = {field.x, field.y + field.height + 8 * s, field.width, ui.HEIGHT_STANDARD * s}}
}

// The grid cell a preset icon or colour occupies; false for the field and buttons around the grid.
@(private = "file")
workspace_icon_picker_grid_cell :: proc(target: Workspace_Picker_Target) -> (int, bool) {
	#partial switch t in target {
	case Picker_Icon: return t.preset, true
	case Picker_Tint: return t.tint, true
	}
	return -1, false
}

workspace_icon_picker_cell :: proc(w: ^Window, g: Workspace_Icon_Layout, index: int) -> render.Rect {
	target := workspace_picker_target_at(w, index)
	#partial switch _ in target {
	case Picker_Emoji_Field: return g.field
	case Picker_Emoji_Apply, Picker_Tint_Back: return g.apply
	case Picker_Tint_Open: return workspace_icon_color_button(w)
	}
	cell, in_grid := workspace_icon_picker_grid_cell(target)
	if !in_grid { return {} }
	s := w.scale
	return {g.grid.x + f32(cell % g.columns) * 48 * s,
		g.grid.y + f32(cell / g.columns - w.workspace_picker.scroll) * 48 * s, 44 * s, 44 * s}
}

workspace_icon_picker_reveal :: proc(w: ^Window, g: Workspace_Icon_Layout) {
	p := &w.workspace_picker
	cell, in_grid := workspace_icon_picker_grid_cell(workspace_picker_selection(w))
	if in_grid && g.visible_rows > 0 {
		row := cell / g.columns
		p.scroll = clamp(p.scroll, row - g.visible_rows + 1, row)
	}
	p.scroll = clamp(p.scroll, 0, max(0, g.rows - max(1, g.visible_rows)))
}

workspace_icon_picker_hit :: proc(w: ^Window, x, y: f32) -> int {
	g := workspace_icon_picker_layout(w)
	if !render.rect_contains(g.panel, x, y) { return -1 }
	tint := workspace_picker_tint(&w.workspace_picker)
	hit: Workspace_Picker_Target
	if !tint && render.rect_contains(workspace_icon_color_button(w), x, y) {
		hit = Picker_Tint_Open{}
	} else if render.rect_contains(g.apply, x, y) {
		if tint { hit = Picker_Tint_Back{} } else { hit = Picker_Emoji_Apply{} }
	}
	if hit != nil {
		index, _ := workspace_picker_target_index(w, hit)
		return index
	}
	if !render.rect_contains(g.grid, x, y) { return -1 }
	for i in 0..<(tint ? len(WORKSPACE_ICON_COLORS) : len(WORKSPACE_ICONS)) {
		if render.rect_contains(workspace_icon_picker_cell(w, g, i), x, y) { return i }
	}
	return -1
}

// Arrows move through the grid, then down through the emoji field, Apply and the colour button, and back
// to the top. Left, Right, Home and End stay in the grid; on the colour button they do nothing, and on the
// field or Apply they are the field's.
workspace_icon_picker_key :: proc(w: ^Window, e: input.Key_Event) -> bool {
	defer workspace_picker_layout_changed(w)
	g := workspace_icon_picker_layout(w)
	count := len(WORKSPACE_ICONS)
	current := workspace_picker_selection(w)
	icon, on_icon := current.(Picker_Icon)
	next: Workspace_Picker_Target
	#partial switch e.key {
	case .Arrow_Down:
		#partial switch t in current {
		case Picker_Icon:
			if t.preset + g.columns < count { next = Picker_Icon{t.preset + g.columns} }
			else { next = Picker_Emoji_Field{} }
		case Picker_Emoji_Field: next = Picker_Emoji_Apply{}
		case Picker_Emoji_Apply: next = Picker_Tint_Open{}
		case Picker_Tint_Open: next = Picker_Icon{0}
		}
	case .Arrow_Up:
		#partial switch t in current {
		case Picker_Icon:
			if t.preset < g.columns { next = Picker_Tint_Open{} } else { next = Picker_Icon{t.preset - g.columns} }
		case Picker_Emoji_Field: next = Picker_Icon{count - 1}
		case Picker_Emoji_Apply: next = Picker_Emoji_Field{}
		case Picker_Tint_Open: next = Picker_Emoji_Apply{}
		}
	case .Arrow_Left, .Arrow_Right:
		if !on_icon {
			_, on_button := current.(Picker_Tint_Open)
			return on_button
		}
		next = Picker_Icon{(icon.preset + count + (e.key == .Arrow_Left ? -1 : 1)) % count}
	case .Home, .End:
		if !on_icon {
			_, on_button := current.(Picker_Tint_Open)
			return on_button
		}
		next = Picker_Icon{e.key == .Home ? 0 : count - 1}
	case: return false
	}
	workspace_picker_select_target(w, next)
	return true
}

workspace_icon_picker_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	p, s := &w.workspace_picker, w.scale
	if workspace_picker_tint(p) { return workspace_icon_color_draw(app, w) }
	g := workspace_icon_picker_layout(w)
	target := workspace_row_target(app, workspace_picker_icon_id(p))
	if target == nil { return .Ok }
	if result := workspace_icon_picker_title(app, w, g, "Icon"); result != .Ok { return result }
	color_button := workspace_icon_color_button(w)
	chosen := workspace_picker_selection(w)
	if _, selected := chosen.(Picker_Tint_Open); selected {
		button := render.Rect_Instance{
			rect = color_button, radius = ui.RADIUS_CONTROL * s, color = app.theme.selection,
		}
		if render.push_rect(&w.list, button) != .None { return .Ok }
	}
	dot_size := ui.ICON_BUTTON * s
	dot := render.Rect{
		color_button.x + (color_button.width - dot_size) / 2,
		color_button.y + (color_button.height - dot_size) / 2,
		dot_size, dot_size,
	}
	wheel := render.Rect_Instance{
		rect = dot, radius = dot_size / 2, color = {1, 0, 0, 1}, fill = render.RECT_FILL_HUE_WHEEL,
	}
	if render.push_rect(&w.list, wheel) != .None { return .Ok }
	if render.push_layer(&w.list, g.grid) != .None { return .Ok }
	for i in 0..<len(WORKSPACE_ICONS) {
		row := i / g.columns - p.scroll
		if row < 0 || row >= g.visible_rows { continue }
		cell := workspace_icon_picker_cell(w, g, i)
		if i == p.selected {
			selection := render.Rect_Instance{rect = cell, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s}
			if render.push_rect(&w.list, selection) != .None {
				return .Ok
			}
		}
		size := ui.ICON_BUTTON * s
		icon := render.Rect{cell.x + (cell.width - size) / 2, cell.y + 12 * s, size, size}
		tint := target != nil ? target.icon.tint : 0
		preset := Workspace_Icon{preset = i, tint = tint}
		if result := workspace_icon_draw(w, preset, icon, app.theme.text);
		   result != .Ok { return result }
		if target != nil && target.icon.emoji == "" && target.icon.preset == i {
			mark := render.Rect{cell.x + 14 * s, cell.y + 38 * s, 16 * s, 2 * s}
			fill := render.Rect_Instance{rect = mark, color = app.theme.accent, radius = ui.pill_radius(mark)}
			if render.push_rect(&w.list, fill) != .None {
				return .Ok
			}
		}
	}
	if render.push_layer(&w.list, g.panel, ui.RADIUS_OVERLAY * s) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = g.divider, color = app.theme.border}) != .None { return .Ok }
	field_fill := render.Rect_Instance{rect = g.field, color = app.theme.pane, radius = ui.RADIUS_CONTROL * s}
	if render.push_rect(&w.list, field_fill) != .None { return .Ok }
	box := workspace_picker_query_box(w)
	_, on_field := chosen.(Picker_Emoji_Field)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box),
		on_field, "Custom emoji"); result != .Ok { return result }
	if render.push_layer(&w.list, g.panel, ui.RADIUS_OVERLAY * s) != .None { return .Ok }
	inset := ui.CONTROL_INSET * s
	_, on_apply := chosen.(Picker_Emoji_Apply)
	fill := on_apply ? app.theme.selection : app.theme.pane
	apply := render.Rect_Instance{rect = g.apply, color = fill, radius = ui.RADIUS_CONTROL * s}
	if render.push_rect(&w.list, apply) != .None { return .Ok }
	color := workspace_icon_valid(ui.field_string(&p.query)) ? app.theme.text : app.theme.muted
	apply_baseline := g.apply.y + (g.apply.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
	label := "Apply Custom Emoji"
	label_x := g.apply.x + max(inset, (g.apply.width - ui.text_width(&w.ui_text, label)) / 2)
	return ui.draw_text(&w.ui_text, &w.list, label, label_x, apply_baseline, color,
		max(0, g.apply.width - 2 * inset))
}

workspace_icon_color_button :: proc(w: ^Window) -> render.Rect {
	g := workspace_icon_picker_layout(w)
	s := w.scale
	size := ui.HEIGHT_COMPACT * s
	top := (WORKSPACE_ICON_HEADER * s - size) / 2
	x := g.panel.x + max(0, g.panel.width - ui.SPACE_2 * s - size)
	return {x, g.panel.y + top, min(size, g.panel.width), size}
}

// The picker's header band: its title, in Strong as overlay titles are, and the colour button.
WORKSPACE_ICON_HEADER :: 40

workspace_icon_picker_title :: proc(
	app: ^App, w: ^Window, g: Workspace_Icon_Layout, title: string,
) -> render.Build_Status {
	strong := ui.text_styled(&w.ui_text, .Strong)
	s := w.scale
	baseline := g.panel.y + (WORKSPACE_ICON_HEADER * s - strong.line_height) / 2 + strong.ascent
	return ui.draw_text(&strong, &w.list, title, g.panel.x + ui.SPACE_3 * s, baseline,
		app.theme.text, max(0, g.panel.width - (ui.SPACE_3 + 2 * ui.SPACE_2 + ui.HEIGHT_COMPACT) * s))
}
