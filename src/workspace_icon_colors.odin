package main

import "aio:glyphs"
import "aio:platform"
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
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, foreground.a}
}

@(require_results)
workspace_icon_color_set :: proc(app: ^App, workspace: ^Workspace, tint: int) -> bool {
	if !workspace_registered(app, workspace) { return false }
	if tint < 0 || tint >= len(WORKSPACE_ICON_COLORS) { return false }
	workspace.icon.tint = tint
	mark_all_dirty(app)
	return true
}

workspace_icon_color_open :: proc(app: ^App, w: ^Window) {
	defer workspace_picker_layout_changed(w)
	target := workspace_row_target(app, workspace_picker_target(&w.workspace_picker, .Icons))
	if target == nil { workspace_picker_return(app, w); return }
	p := &w.workspace_picker
	workspace_picker_transition(w, .Tint, p.target_id)
	p.selected, p.scroll = target.icon.tint, 0
	p.query.dragging, w.dirty = false, true
}

workspace_icon_color_back :: proc(w: ^Window) {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	workspace_picker_transition(w, .Icons, p.target_id)
	p.selected, p.scroll = len(WORKSPACE_ICONS) + 2, 0
	w.dirty = true
}

workspace_icon_color_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	if p.selected == len(WORKSPACE_ICON_COLORS) { workspace_icon_color_back(w); return }
	target := workspace_row_target(app, p.target_id)
	if target == nil { workspace_picker_return(app, w); return }
	if !workspace_icon_color_set(app, target, p.selected) { return }
	workspace_picker_return(app, w)
}

workspace_icon_color_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	n := len(WORKSPACE_ICON_COLORS)
	columns := workspace_icon_picker_layout(w).columns
	if step := ui.list_step(e); step != 0 && e.key != .Arrow_Up && e.key != .Arrow_Down {
		p.selected = (p.selected + n + 1 + step) % (n + 1)
	} else {
		#partial switch e.key {
		case .Escape: workspace_icon_color_back(w)
		case .Enter, .Numpad_Enter: workspace_icon_color_choose(app, w)
		case .Tab: p.selected = (p.selected + n + 1 + (.Shift in e.modifiers ? -1 : 1)) % (n + 1)
		case .Arrow_Right, .Arrow_Left:
			if p.selected < n { p.selected = (p.selected + n + (e.key == .Arrow_Left ? -1 : 1)) % n }
		case .Arrow_Down: p.selected = p.selected < n ? min(n, p.selected + columns) : 0
		case .Arrow_Up:
			if p.selected == n {
				p.selected = n - 1
			} else if p.selected < columns {
				p.selected = n
			} else {
				p.selected -= columns
			}
		case .Home: p.selected = 0
		case .End: p.selected = n - 1
		}
	}
	w.dirty = true
}

workspace_icon_color_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p, s := &w.workspace_picker, w.scale
	g := workspace_icon_picker_layout(w)
	target := workspace_row_target(app, p.target_id)
	if target == nil { return .Ok }
	if result := ui.draw_text(&w.ui_text, &w.list, "Preset icon color", g.panel.x + 12 * s, g.panel.y + 26 * s,
		app.theme.text, max(0, g.panel.width - 24 * s)); result != .Ok { return result }
	if render.push_layer(&w.list, g.grid) != .None { return .Ok }
	for i in 0..<len(WORKSPACE_ICON_COLORS) {
		row := i / g.columns - p.scroll
		if row < 0 || row >= g.visible_rows { continue }
		cell := workspace_icon_picker_cell(w, g, i)
		if i == p.selected {
			hover := render.Rect_Instance{rect = cell, color = app.theme.selection, radius = 5 * s}
	if render.push_rect(&w.list, hover) != .None { return .Ok }
		}
		icon := render.Rect{cell.x + 10 * s, cell.y + 8 * s, 24 * s, 24 * s}
		if result := workspace_icon_draw(w, {preset = target.icon.preset, tint = i}, icon,
			app.theme.text); result != .Ok { return result }
		if target.icon.tint == i {
			if render.push_rect(&w.list, {rect = {cell.x + 14 * s, cell.y + 38 * s, 16 * s, 2 * s},
				color = app.theme.accent, radius = s}) != .None { return .Ok }
		}
	}
	if render.push_layer(&w.list, g.panel, 7 * s) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = g.divider, color = app.theme.border}) != .None { return .Ok }
	@(static, rodata) colors := WORKSPACE_ICON_COLORS
	label := p.selected < len(colors) ? colors[p.selected].name : "Emoji keep their original colors"
	if result := ui.draw_fading_text(&w.ui_text, &w.list, label, g.field.x + 8 * s,
		g.field.y + 22 * s, app.theme.text, max(0, g.field.width - 16 * s)); result != .Ok { return result }
	fill := p.selected == len(colors) ? app.theme.selection : app.theme.pane
	if render.push_rect(&w.list, {rect = g.apply, color = fill, radius = 5 * s}) != .None { return .Ok }
	return ui.draw_text(&w.ui_text, &w.list, "Back to icons", g.apply.x + 8 * s,
		g.apply.y + (g.apply.height - w.ui_text.line_height) / 2 + w.ui_text.ascent, app.theme.text,
		max(0, g.apply.width - 16 * s))
}
