package main

import "core:time"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"

Workspace_Row_Action :: enum { Rename, Icon, Open_Window, Delete }
WORKSPACE_ROW_ACTIONS :: [?]Workspace_Row_Action{.Rename, .Icon, .Open_Window, .Delete}

workspace_row_window_enabled :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	target := workspace_row_target(app, id)
	return w != nil && !w.preparing && window_find(app, w.id) == w &&
		target != nil && target != w.workspace
}

workspace_row_window_title :: proc(app: ^App, id: u32) -> string {
	target := workspace_row_target(app, id)
	if target != nil && window_for_workspace(app, target) != nil {return "Show Existing Window"}
	return "Open in New Window"
}

@(require_results)
workspace_open_window :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	if !workspace_row_window_enabled(app, w, id) {return false}
	target := workspace_row_target(app, id)
	if !window_open(app, target) {
		notify(app, .Error, "Could not open the workspace window.")
		return false
	}
	workspace_picker_cancel(w)
	mark_all_dirty(app)
	return true
}

workspace_row_target :: proc(app: ^App, id: u32) -> ^Workspace {
	workspace := workspace_find(app, id)
	if !workspace_eligible(app, workspace) { return nil }
	return workspace
}

workspace_row_index :: proc(w: ^Window, id: u32) -> int {
	if id != 0 { for row, i in w.workspace_picker.rows { if row.id == id { return i } } }
	return -1
}

workspace_row_reveal :: proc(w: ^Window, id: u32) {
	p := &w.workspace_picker
	if index := workspace_row_index(w, id); index >= 0 { p.selected = index }
	workspace_picker_layout_changed(w)
}

workspace_row_menu_open :: proc(app: ^App, w: ^Window, id: u32) {
	if workspace_row_target(app, id) == nil { return }
	if workspace_picker_icons(&w.workspace_picker) {workspace_picker_return(app, w)}
	workspace_row_rename_finish(app, w, false)
	workspace_picker_transition(w, .Menu, id)
	w.workspace_picker.menu_selected = 0
	workspace_row_reveal(w, id)
	w.dirty = true
}

workspace_row_menu_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	id, selected := workspace_picker_target(p, .Menu), p.menu_selected
	w.dirty = true
	target := workspace_row_target(app, id)
	if target == nil || selected < 0 || selected >= len(WORKSPACE_ROW_ACTIONS) { return }
	@(static, rodata) actions := WORKSPACE_ROW_ACTIONS
	if actions[selected] == .Open_Window {
		_ = workspace_open_window(app, w, id)
		return
	}
	workspace_picker_transition(w, .List)
	#partial switch actions[selected] {
	case .Rename: workspace_row_rename_open(app, w, id)
	case .Icon: workspace_row_icon_open(app, w, id)
	case .Delete: workspace_delete_request(app, w, target)
	}
}

workspace_row_rename_open :: proc(app: ^App, w: ^Window, id: u32) {
	target := workspace_row_target(app, id)
	if target == nil { return }
	if workspace_picker_icons(&w.workspace_picker) {workspace_picker_return(app, w)}
	p := &w.workspace_picker
	workspace_picker_transition(w, .Rename, id)
	ui.motion_target(&p.rename_motion, 1, 140 * time.Millisecond, .Decelerate, app.animations, time.tick_now())
	ui.field_set(&w.rename, target.name)
	ui.field_select_all(&w.rename)
	workspace_row_reveal(w, id)
	w.dirty = true
}

workspace_row_rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	p := &w.workspace_picker
	if p.mode != .Rename { return }
	if save {
		outcome := rename_target_commit(app, w, Rename_Target{.Workspace, p.target_id},
			ui.field_string(&w.rename))
		if outcome == .Empty || outcome == .Failed {
			p.rename_error, w.dirty = true, true
			return
		}
	}
	workspace_picker_transition(w, .List)
	workspace_picker_layout_changed(w)
}

workspace_row_rename_height :: proc(w: ^Window) -> f32 {
	return w.workspace_picker.mode != .Rename ? 0 : 68 * w.scale * w.workspace_picker.rename_motion.value
}

workspace_row_rename_field_rect :: proc(w: ^Window) -> render.Rect {
	p := &w.workspace_picker
	index := workspace_row_index(w, workspace_picker_target(p, .Rename))
	if index < 0 { return {} }
	r, s := workspace_picker_row_rect(w, index), w.scale
	offset := 68 * s * (1 - p.rename_motion.value)
	return {r.x + 8 * s, r.y + r.height + 8 * s - offset, max(0, r.width - 16 * s), 32 * s}
}

workspace_row_rename_box :: proc(w: ^Window) -> ui.Field_Box {
	return {
		field = &w.rename,
		text = &w.ui_text,
		rect = workspace_row_rename_field_rect(w),
		inset = 8,
		caret_width = 1,
		radius = 5,
		style = .Body,
		scale = w.scale,
	}
}

workspace_row_icon_open :: proc(app: ^App, w: ^Window, id: u32) {
	defer workspace_picker_layout_changed(w)
	target := workspace_row_target(app, id)
	if target == nil { return }
	p := &w.workspace_picker
	workspace_row_rename_finish(app, w, false)
	if !workspace_picker_icons(p) {ui.field_set(&p.saved_query, ui.field_string(&p.query))}
	workspace_picker_transition(w, .Icons, id)
	p.selected = target.icon.emoji == "" ? target.icon.preset : len(WORKSPACE_ICONS)
	p.scroll = 0
	ui.field_set(&p.query, target.icon.emoji)
	ui.field_select_all(&p.query)
	w.dirty = true
}

workspace_picker_return :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	if !workspace_picker_icons(p) {return}
	id := workspace_picker_target(p, .Icons)
	workspace_picker_transition(w, .List)
	ui.field_set(&p.query, ui.field_string(&p.saved_query))
	workspace_picker_filter(app, w)
	workspace_row_reveal(w, id)
	w.dirty = true
}

workspace_row_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> bool {
	p := &w.workspace_picker
	if workspace_picker_icons(p) { return false }
	if p.mode == .Menu {
		w.dirty = true
		if workspace_row_target(app, p.target_id) == nil { workspace_picker_transition(w, .List); return true }
		if step := ui.list_step(e); step != 0 {
			p.menu_selected = (p.menu_selected + len(WORKSPACE_ROW_ACTIONS) + step) % len(WORKSPACE_ROW_ACTIONS)
			return true
		}
		#partial switch e.key {
		case .Escape, .Arrow_Left, .Context_Menu: workspace_picker_transition(w, .List)
		case .Tab:
			step := .Shift in e.modifiers ? -1 : 1
			p.menu_selected = (p.menu_selected + len(WORKSPACE_ROW_ACTIONS) + step) % len(WORKSPACE_ROW_ACTIONS)
		case .Home: p.menu_selected = 0
		case .End: p.menu_selected = len(WORKSPACE_ROW_ACTIONS) - 1
		case .Enter, .Numpad_Enter, .Space: workspace_row_menu_choose(app, w)
		}
		return true
	}
	if p.mode == .Rename {
		w.dirty = true
		if workspace_row_target(app, p.target_id) == nil {
			workspace_row_rename_finish(app, w, false)
			return true
		}
		#partial switch e.key {
		case .Escape: workspace_row_rename_finish(app, w, false)
		case .Enter, .Numpad_Enter: workspace_row_rename_finish(app, w, true)
		case .Tab:
			workspace_row_rename_finish(app, w, true)
			if p.mode != .Rename {
				p.selected = (p.selected + workspace_picker_count(w) + (.Shift in e.modifiers ? -1 : 1))%
					workspace_picker_count(w)
			}
		case:
			field_edit_key(app, &w.rename, e)
			p.rename_error = false
		}
		return true
	}
	if p.selected < 0 || p.selected >= len(p.rows) { return false }
	if e.key == .Arrow_Right || e.key == .Context_Menu || e.key == .F10 && e.modifiers == {.Shift} {
		workspace_row_menu_open(app, w, p.rows[p.selected].id)
		return true
	}
	if e.key == .F2 && e.modifiers == {} {
		workspace_row_rename_open(app, w, p.rows[p.selected].id)
		return true
	}
	return false
}

workspace_row_menu_rect :: proc(w: ^Window) -> render.Rect {
	p, s := &w.workspace_picker, w.scale
	index := workspace_row_index(w, workspace_picker_target(p, .Menu))
	if index < 0 { return {} }
	row := workspace_picker_row_rect(w, index)
	width := min(196 * s, max(0, f32(w.width) - 10 * s))
	height := min((8 + 34 * f32(len(WORKSPACE_ROW_ACTIONS))) * s, max(0, f32(w.height) - 10 * s))
	return {clamp(row.x + row.width - width, 5 * s, max(5 * s, f32(w.width) - width - 5 * s)),
		clamp(row.y + row.height, 5 * s, max(5 * s, f32(w.height) - height - 5 * s)), width, height}
}

workspace_row_menu_item_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r, s := workspace_row_menu_rect(w), w.scale
	height := max(0, (r.height - 8 * s) / f32(len(WORKSPACE_ROW_ACTIONS)))
	return {r.x + 4 * s, r.y + 4 * s + f32(index) * height, max(0, r.width - 8 * s), height}
}

workspace_row_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	if workspace_picker_target(&w.workspace_picker, .Menu) == 0 { return -1 }
	for i in 0..<len(WORKSPACE_ROW_ACTIONS) {
		if workspace_rect_contains(workspace_row_menu_item_rect(w, i), x, y) { return i }
	}
	return -1
}

workspace_row_click :: proc(app: ^App, w: ^Window, x, y: f32, extend: bool) -> bool {
	p := &w.workspace_picker
	if p.mode == .Menu {
		if hit := workspace_row_menu_hit(w, x, y); hit >= 0 {
			p.menu_selected = hit
			workspace_row_menu_choose(app, w)
		} else { workspace_picker_transition(w, .List) }
		return true
	}
	if p.mode == .Rename {
		row := workspace_picker_row_rect(w, workspace_row_index(w, workspace_picker_target(p, .Rename)))
		if y >= row.y + row.height && workspace_rect_contains(workspace_row_rename_field_rect(w), x, y) {
			workspace_picker_pointer(app, w, x, true, extend)
			return true
		}
		workspace_row_rename_finish(app, w, false)
	}
	return false
}

workspace_row_hover :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) -> bool {
	p := &w.workspace_picker
	if p.mode == .Menu {
		if hit := workspace_row_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 {
			p.menu_selected, w.dirty = hit, true
		}
		pointer_set(app, w, .Arrow)
		return true
	}
	if p.mode == .Rename {
		if w.rename.dragging && .Left in e.buttons {
			workspace_picker_pointer(app, w, f32(e.x), false, true)
		}
		inside := workspace_rect_contains(workspace_row_rename_field_rect(w), f32(e.x), f32(e.y))
		pointer_set(app, w, inside ? .Text : .Arrow)
		return true
	}
	return false
}

workspace_button_indicator_rect :: proc(w: ^Window) -> render.Rect {
	width := workspace_button_width(w)
	return {max(0, width - 34 * w.scale), 6 * w.scale, min(width, 28 * w.scale), 28 * w.scale}
}

workspace_chevron_draw :: proc(list: ^render.Draw_List, area: render.Rect, color: render.Color, scale: f32) {
	for i in 0..<6 {
		for direction in ([?]f32{-1, 1}) {
			r := render.Rect{area.x + area.width / 2 + direction * f32(i) * scale - scale,
				area.y + area.height / 2 + (2 - f32(i)) * scale, 2 * scale, 2 * scale}
			if render.push_rect(list, {rect = r, color = color, radius = 0.8 * scale}) != .None { return }
		}
	}
}

workspace_row_ellipsis_draw :: proc(app: ^App, w: ^Window, index: int) {
	r, s := workspace_picker_menu_button_rect(w, index), w.scale
	p := &w.workspace_picker
	hover := p.rows[index].id == p.menu_hover ? p.menu_motion.hover.value : 0
	if hover > 0 {
		fill := app.theme.hover
		fill.a *= hover
		if render.push_rect(&w.list, {rect = r, color = fill, radius = 5 * s}) != .None { return }
	}
	ink := hover > 0 ? app.theme.text : app.theme.muted
	for i in 0..<3 {
		dot := render.Rect{r.x + r.width / 2 - 1.5 * s, r.y + 8.5 * s + f32(i) * 6 * s, 3 * s, 3 * s}
		if render.push_rect(&w.list, {rect = dot, color = ink, radius = 1.5 * s}) != .None { return }
	}
	if hover > 0 {
		if ui.hover_rim_draw(&w.list, app.theme, r, 5 * s, hover, s, w.pointer) != .None { return }
	}
}

workspace_row_rename_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p, s := &w.workspace_picker, w.scale
	index := workspace_row_index(w, workspace_picker_target(p, .Rename))
	if index < 0 { return .Ok }
	row := workspace_picker_row_rect(w, index)
	clip := render.Rect{row.x, row.y + row.height, row.width, workspace_row_rename_height(w)}
	if render.push_layer(&w.list, clip) != .None { return .Ok }
	field := workspace_row_rename_field_rect(w)
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = 5 * s}) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = field, color = app.theme.accent, radius = 5 * s, stroke = s}) != .None {
		return .Ok
	}
	box := workspace_row_rename_box(w)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true,
		"Workspace name"); result != .Ok { return result }
	if render.push_layer(&w.list, clip) != .None { return .Ok }
	hint := p.rename_error ? "Could not save name · Enter retries · Esc cancels" : "Enter saves · Esc cancels"
	return ui.draw_fading_text(&w.ui_text, &w.list, hint, field.x, field.y + field.height + 19 * s,
		app.theme.muted, field.width)
}

workspace_row_menu_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p, s := &w.workspace_picker, w.scale
	if p.mode != .Menu { return .Ok }
	r := workspace_row_menu_rect(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	frame := ui.Panel {
		rect     = r,
		radius   = 6 * s,
		scale    = s,
		shadow_x = 2,
		shadow_y = 3,
		border   = .Stroked,
	}
	if ui.panel_draw(&w.list, frame, app.theme) != .None { return .Ok }
	if render.push_layer(&w.list, r, 6 * s) != .None { return .Ok }
	titles := [?]string{"Rename", "Change Icon", workspace_row_window_title(app, p.target_id), "Delete…"}
	@(static, rodata) actions := WORKSPACE_ROW_ACTIONS
	for title, i in titles {
		enabled := workspace_row_target(app, p.target_id) != nil &&
			(actions[i] != .Open_Window || workspace_row_window_enabled(app, w, p.target_id))
		item := workspace_row_menu_item_rect(w, i)
		if i == p.menu_selected {
			if render.push_rect(&w.list, {rect = item, color = app.theme.selection, radius = 4 * s}) != .None {
				return .Ok
			}
		}
		if result := ui.draw_text(&w.ui_text, &w.list, title, item.x + 8 * s,
			item.y + (item.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			enabled ? app.theme.text : app.theme.muted, max(0, item.width - 16 * s)); result != .Ok { return result }
		if i == p.menu_selected && workspace_rect_contains(item, w.pointer.x, w.pointer.y) {
			if ui.hover_rim_draw(&w.list, app.theme, item, 4 * s, 1, s, w.pointer) != .None {
				return .Ok
			}
		}
	}
	return .Ok
}
