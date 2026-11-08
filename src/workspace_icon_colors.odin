package main

import "aio:input"
import "aio:colour"
import "aio:render"
import "aio:settings"
import "aio:ui"

Workspace_Icon_Color :: struct {
	name: string,
	light, dark: settings.Color,
}

WORKSPACE_ICON_COLORS :: [?]Workspace_Icon_Color {
	{"Theme default", {}, {}},
	{"Red", {185, 28, 28}, {248, 113, 113}},
	{"Orange", {194, 65, 12}, {251, 146, 60}},
	{"Yellow", {133, 77, 14}, {250, 204, 21}},
	{"Green", {21, 128, 61}, {74, 222, 128}},
	{"Teal", {15, 118, 110}, {45, 212, 191}},
	{"Blue", {29, 78, 216}, {96, 165, 250}},
	{"Purple", {109, 40, 217}, {167, 139, 250}},
	{"Pink", {190, 24, 93}, {244, 114, 182}},
}

workspace_icon_tint :: proc(index: int, foreground: render.Color) -> render.Color {
	if index <= 0 || index >= len(WORKSPACE_ICON_COLORS) { return foreground }
	@(static, rodata) colors := WORKSPACE_ICON_COLORS
	color := colors[index].light
	if foreground.r + foreground.g + foreground.b > 1.5 { color = colors[index].dark }
	return colour.rgba(color, foreground.a)
}

@(require_results)
workspace_icon_color_set :: proc(app: ^App, workspace: ^Workspace, tint: int) -> bool {
	if !workspace_registered(app, workspace) { return false }
	if !workspace_icon_valid_value({tint = tint}) { return false }
	workspace.icon.tint = tint
	workspace_mutation_finish(app, workspace, {.Appearance})
	return true
}

workspace_icon_color_open :: proc(app: ^App, w: ^Window) {
	defer workspace_picker_layout_changed(w)
	target := workspace_row_target(app, workspace_picker_icon_id(&w.workspace_picker))
	if target == nil { workspace_picker_return(app, w); return }
	p := &w.workspace_picker
	workspace_picker_transition(w, Workspace_Picker_Tint{target.id})
	p.scroll = 0
	workspace_picker_select_target(w, Picker_Tint{target.icon.tint})
	ui.field_release(&p.query)
	w.dirty = true
}

workspace_icon_color_back :: proc(w: ^Window) {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	workspace_picker_transition(w, Workspace_Picker_Icons{workspace_picker_icon_id(p)})
	p.scroll = 0
	workspace_picker_select_target(w, Picker_Tint_Open{})
	w.dirty = true
}

workspace_icon_color_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	tint: int
	#partial switch t in workspace_picker_selection(w) {
	case Picker_Tint_Back: workspace_icon_color_back(w); return
	case Picker_Tint: tint = t.tint
	case: return
	}
	target := workspace_row_target(app, workspace_picker_icon_id(p))
	if target == nil { workspace_picker_return(app, w); return }
	if !workspace_icon_color_set(app, target, tint) { return }
	workspace_picker_return(app, w)
}

// Arrows move through the colour grid, down to Back and round to the top; Left and Right stay in the grid.
workspace_icon_color_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	n := len(WORKSPACE_ICON_COLORS)
	count := workspace_picker_count(w)
	columns := workspace_icon_picker_layout(w).columns
	current := workspace_picker_selection(w)
	_, on_back := current.(Picker_Tint_Back)
	cell, on_cell := current.(Picker_Tint)
	if step := ui.list_step(e); step != 0 && e.key != .Arrow_Up && e.key != .Arrow_Down {
		p.selected = (p.selected + count + step) % count
	} else {
		#partial switch e.key {
		case .Escape: workspace_icon_color_back(w)
		case .Enter, .Numpad_Enter: workspace_icon_color_choose(app, w)
		case .Tab: p.selected = (p.selected + count + (.Shift in e.modifiers ? -1 : 1)) % count
		case .Arrow_Right, .Arrow_Left:
			if on_cell {
				delta := e.key == .Arrow_Left ? -1 : 1
				workspace_picker_select_target(w, Picker_Tint{(cell.tint + n + delta) % n})
			}
		case .Arrow_Down:
			if on_cell && cell.tint + columns < n {
				workspace_picker_select_target(w, Picker_Tint{cell.tint + columns})
			} else if on_cell {
				workspace_picker_select_target(w, Picker_Tint_Back{})
			} else {
				workspace_picker_select_target(w, Picker_Tint{0})
			}
		case .Arrow_Up:
			if on_back {
				workspace_picker_select_target(w, Picker_Tint{n - 1})
			} else if cell.tint < columns {
				workspace_picker_select_target(w, Picker_Tint_Back{})
			} else {
				workspace_picker_select_target(w, Picker_Tint{cell.tint - columns})
			}
		case .Home: workspace_picker_select_target(w, Picker_Tint{0})
		case .End: workspace_picker_select_target(w, Picker_Tint{n - 1})
		}
	}
	w.dirty = true
}

workspace_icon_color_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	p, s := &w.workspace_picker, w.scale
	g := workspace_icon_picker_layout(w)
	target := workspace_row_target(app, workspace_picker_icon_id(p))
	if target == nil { return .Ok }
	if result := workspace_icon_picker_title(app, w, g, "Preset icon color"); result != .Ok { return result }
	if render.push_layer(&w.list, g.grid) != .None { return .Ok }
	for i in 0..<len(WORKSPACE_ICON_COLORS) {
		row := i / g.columns - p.scroll
		if row < 0 || row >= g.visible_rows { continue }
		cell := workspace_icon_picker_cell(w, g, i)
		if i == p.selected {
			hover := render.Rect_Instance{rect = cell, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s}
	if render.push_rect(&w.list, hover) != .None { return .Ok }
		}
		size := ui.ICON_BUTTON * s
		icon := render.Rect{cell.x + (cell.width - size) / 2, cell.y + 12 * s, size, size}
		if result := workspace_icon_draw(w, {preset = target.icon.preset, tint = i}, icon,
			app.theme.text); result != .Ok { return result }
		if target.icon.tint == i {
			mark := render.Rect{cell.x + 14 * s, cell.y + 38 * s, 16 * s, 2 * s}
			if render.push_rect(&w.list, {rect = mark, color = app.theme.accent, radius = ui.pill_radius(mark)}) !=
			   .None { return .Ok }
		}
	}
	if render.push_layer(&w.list, g.panel, ui.RADIUS_OVERLAY * s) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = g.divider, color = app.theme.border}) != .None { return .Ok }
	@(static, rodata) colors := WORKSPACE_ICON_COLORS
	chosen := workspace_picker_selection(w)
	label := "Emoji keep their original colors"
	if cell, on_cell := chosen.(Picker_Tint); on_cell { label = colors[cell.tint].name }
	inset := ui.CONTROL_INSET * s
	middle := proc(r: render.Rect, t: ^ui.Text) -> f32 {return r.y + (r.height - t.line_height) / 2 + t.ascent}
	if result := ui.draw_fading_text(&w.ui_text, &w.list, label, g.field.x + inset,
		middle(g.field, &w.ui_text), app.theme.text, max(0, g.field.width - 2 * inset)); result != .Ok {
		return result
	}
	_, on_back := chosen.(Picker_Tint_Back)
	fill := on_back ? app.theme.selection : app.theme.pane
	apply := render.Rect_Instance{rect = g.apply, color = fill, radius = ui.RADIUS_CONTROL * s}
	if render.push_rect(&w.list, apply) != .None { return .Ok }
	back := "Back to icons"
	back_x := g.apply.x + max(inset, (g.apply.width - ui.text_width(&w.ui_text, back)) / 2)
	return ui.draw_text(&w.ui_text, &w.list, back, back_x, middle(g.apply, &w.ui_text), app.theme.text,
		max(0, g.apply.width - 2 * inset))
}
