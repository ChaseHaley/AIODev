package main

import "aio:input"
import "core:time"
import "aio:render"
import "aio:ui"

Workspace_Row_Action :: enum { Rename, Icon, Open_Window, Delete, Move_Up, Move_Down }

// One row of a workspace row's menu. Open Window's title depends on the workspace; see
// workspace_row_menu_title.
Workspace_Row_Menu_Item :: struct {
	action: Workspace_Row_Action,
	title:  string,
}

@(rodata)
WORKSPACE_ROW_MENU := [?]Workspace_Row_Menu_Item {
	{.Rename, "Rename"},
	{.Icon, "Change Icon"},
	{.Open_Window, "Open in New Window"},
	{.Move_Up, "Move Up"},
	{.Move_Down, "Move Down"},
	{.Delete, "Delete…"},
}

workspace_row_menu_title :: proc(app: ^App, item: Workspace_Row_Menu_Item, id: u32) -> string {
	if item.action == .Open_Window {return workspace_row_window_title(app, id)}
	return item.title
}

// Whether `action` can run on row `id` from window `w`: what the menu shows and what choosing it does.
workspace_row_action_enabled :: proc(app: ^App, w: ^Window, id: u32, action: Workspace_Row_Action) -> bool {
	if workspace_row_target(app, id) == nil {return false}
	switch action {
	case .Rename, .Icon, .Delete: return true
	case .Open_Window: return workspace_row_window_enabled(app, w, id)
	case .Move_Up: return workspace_order_neighbor(app, id, -1) != 0
	case .Move_Down: return workspace_order_neighbor(app, id, 1) != 0
	}
	return false
}

workspace_row_window_enabled :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	target := workspace_row_target(app, id)
	return w != nil && w.phase != .Preparing && window_find(app, w.id) == w &&
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
	workspace_picker_transition(w, Workspace_Picker_Menu{id})
	w.workspace_picker.menu_selected = 0
	workspace_row_reveal(w, id)
	w.dirty = true
}

workspace_row_menu_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	id, selected := workspace_picker_menu_id(p), p.menu_selected
	w.dirty = true
	if selected < 0 || selected >= len(WORKSPACE_ROW_MENU) { return }
	action := WORKSPACE_ROW_MENU[selected].action
	if !workspace_row_action_enabled(app, w, id, action) { return }
	if action == .Open_Window {
		_ = workspace_open_window(app, w, id)
		return
	}
	workspace_picker_transition(w, Workspace_Picker_List{})
	switch action {
	case .Rename: workspace_row_rename_open(app, w, id)
	case .Icon: workspace_row_icon_open(app, w, id)
	case .Open_Window:
	case .Delete: workspace_delete_request(app, w, workspace_row_target(app, id))
	case .Move_Up, .Move_Down:
		step := action == .Move_Up ? -1 : 1
		_ = workspace_reorder(app, id, workspace_order_neighbor(app, id, step))
		workspace_row_reveal(w, id)
	}
}

workspace_row_rename_open :: proc(app: ^App, w: ^Window, id: u32) {
	target := workspace_row_target(app, id)
	if target == nil { return }
	if workspace_picker_icons(&w.workspace_picker) {workspace_picker_return(app, w)}
	workspace_picker_transition(w, Workspace_Picker_Rename{id = id})
	p := &w.workspace_picker
	workspace_row_rename_target(p, app.animations, time.tick_now())
	ui.field_set(&p.rename, target.name)
	ui.field_select_all(&p.rename)
	workspace_row_reveal(w, id)
	w.dirty = true
}

// Ends the row editor. Saving refuses an empty name, keeping the editor open with its error, as it does a
// name that could not be stored.
workspace_row_rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	p := &w.workspace_picker
	id := workspace_picker_rename_id(p)
	if id == 0 { return }
	if save {
		value := ui.field_string(&p.rename)
		outcome := rename_target_commit(app, Rename_Workspace_Target{id}, value, .Workspace_Row)
		if outcome == .Empty || outcome == .Failed {
			workspace_row_rename_error_set(w, true)
			return
		}
	}
	workspace_picker_transition(w, Workspace_Picker_List{})
	workspace_picker_layout_changed(w)
}

workspace_row_rename_error_set :: proc(w: ^Window, error: bool) {
	if rename, renaming := &w.workspace_picker.state.(Workspace_Picker_Rename); renaming {
		rename.error, w.dirty = error, true
	}
}

// The rename field eases open below its row while the rename lasts; true when it moved this frame.
workspace_row_rename_animate :: proc(w: ^Window, enabled: bool, now: time.Tick) -> bool {
	p := &w.workspace_picker
	if _, renaming := p.state.(Workspace_Picker_Rename); !renaming {return false}
	workspace_row_rename_target(p, enabled, now)
	return ui.motion_update(&p.rename_motion, now)
}

@(private = "file")
workspace_row_rename_target :: proc(p: ^Workspace_Picker, enabled: bool, now: time.Tick) {
	ui.motion_target(&p.rename_motion, 1, 140 * time.Millisecond, .Decelerate, enabled, now)
}

// The inline rename: SPACE_2, a standard field, SPACE_2, one Detail hint line and SPACE_2.
WORKSPACE_RENAME_HEIGHT :: 72

workspace_row_rename_height :: proc(w: ^Window) -> f32 {
	if _, renaming := w.workspace_picker.state.(Workspace_Picker_Rename); !renaming {return 0}
	return WORKSPACE_RENAME_HEIGHT * w.scale * w.workspace_picker.rename_motion.value
}

workspace_row_rename_field_rect :: proc(w: ^Window) -> render.Rect {
	p := &w.workspace_picker
	index := workspace_row_index(w, workspace_picker_rename_id(p))
	if index < 0 { return {} }
	r, s := workspace_picker_row_rect(w, index), w.scale
	offset := WORKSPACE_RENAME_HEIGHT * s * (1 - p.rename_motion.value)
	return {r.x + 8 * s, r.y + r.height + 8 * s - offset, max(0, r.width - 16 * s), ui.HEIGHT_STANDARD * s}
}

workspace_row_rename_box :: proc(w: ^Window) -> ui.Field_Box {
	rect := workspace_row_rename_field_rect(w)
	return ui.field_box_standard(&w.workspace_picker.rename, &w.ui_text, rect, w.scale)
}

workspace_row_icon_open :: proc(app: ^App, w: ^Window, id: u32) {
	defer workspace_picker_layout_changed(w)
	target := workspace_row_target(app, id)
	if target == nil { return }
	p := &w.workspace_picker
	workspace_row_rename_finish(app, w, false)
	if !workspace_picker_icons(p) {ui.field_set(&p.saved_query, ui.field_string(&p.query))}
	workspace_picker_transition(w, Workspace_Picker_Icons{id})
	if target.icon.emoji == "" {
		workspace_picker_select_target(w, Picker_Icon{target.icon.preset})
	} else {
		workspace_picker_select_target(w, Picker_Emoji_Field{})
	}
	p.scroll = 0
	ui.field_set(&p.query, target.icon.emoji)
	ui.field_select_all(&p.query)
	w.dirty = true
}

workspace_picker_return :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	if !workspace_picker_icons(p) {return}
	id := workspace_picker_icon_id(p)
	workspace_picker_transition(w, Workspace_Picker_List{})
	ui.field_set(&p.query, ui.field_string(&p.saved_query))
	workspace_picker_filter(app, w)
	workspace_row_reveal(w, id)
	w.dirty = true
}

workspace_row_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	p := &w.workspace_picker
	#partial switch _ in p.state {
	case Workspace_Picker_List: if !workspace_picker_browsing(p) { return false }
	case Workspace_Picker_Menu, Workspace_Picker_Rename:
	case: return false
	}
	if id := workspace_picker_menu_id(p); id != 0 {
		w.dirty = true
		if workspace_row_target(app, id) == nil {
			workspace_picker_transition(w, Workspace_Picker_List{})
			return true
		}
		if step := ui.list_step(e); step != 0 {
			p.menu_selected = (p.menu_selected + len(WORKSPACE_ROW_MENU) + step) % len(WORKSPACE_ROW_MENU)
			return true
		}
		#partial switch e.key {
		case .Escape, .Arrow_Left, .Context_Menu: workspace_picker_transition(w, Workspace_Picker_List{})
		case .Tab:
			step := .Shift in e.modifiers ? -1 : 1
			p.menu_selected = (p.menu_selected + len(WORKSPACE_ROW_MENU) + step) % len(WORKSPACE_ROW_MENU)
		case .Home: p.menu_selected = 0
		case .End: p.menu_selected = len(WORKSPACE_ROW_MENU) - 1
		case .Enter, .Numpad_Enter, .Space: workspace_row_menu_choose(app, w)
		}
		return true
	}
	if id := workspace_picker_rename_id(p); id != 0 {
		w.dirty = true
		if workspace_row_target(app, id) == nil {
			workspace_row_rename_finish(app, w, false)
			return true
		}
		#partial switch e.key {
		case .Escape: workspace_row_rename_finish(app, w, false)
		case .Enter, .Numpad_Enter: workspace_row_rename_finish(app, w, true)
		case .Tab:
			workspace_row_rename_finish(app, w, true)
			if _, renaming := p.state.(Workspace_Picker_Rename); !renaming {
				p.selected = (p.selected + workspace_picker_count(w) + (.Shift in e.modifiers ? -1 : 1))%
					workspace_picker_count(w)
			}
		case:
			field_edit_key(app, &p.rename, e)
			workspace_row_rename_error_set(w, false)
		}
		return true
	}
	row, on_row := workspace_picker_selection(w).(Picker_Workspace)
	if !on_row { return false }
	if e.key == .Arrow_Right || e.key == .Context_Menu || e.key == .F10 && e.modifiers == {.Shift} {
		workspace_row_menu_open(app, w, row.id)
		return true
	}
	if e.key == .F2 && e.modifiers == {} {
		workspace_row_rename_open(app, w, row.id)
		return true
	}
	return false
}

workspace_row_menu_rect :: proc(w: ^Window) -> render.Rect {
	p, s := &w.workspace_picker, w.scale
	index := workspace_row_index(w, workspace_picker_menu_id(p))
	if index < 0 { return {} }
	row := workspace_picker_row_rect(w, index)
	width := min(196 * s, max(0, f32(w.width) - 10 * s))
	rows := f32(len(WORKSPACE_ROW_MENU))
	height := min((2 * ui.OVERLAY_PADDING + ui.HEIGHT_STANDARD * rows) * s, max(0, f32(w.height) - 10 * s))
	return {clamp(row.x + row.width - width, 5 * s, max(5 * s, f32(w.width) - width - 5 * s)),
		clamp(row.y + row.height, 5 * s, max(5 * s, f32(w.height) - height - 5 * s)), width, height}
}

workspace_row_menu_item_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r, s := workspace_row_menu_rect(w), w.scale
	pad := ui.OVERLAY_PADDING * s
	height := max(0, (r.height - 2 * pad) / f32(len(WORKSPACE_ROW_MENU)))
	return {r.x + pad, r.y + pad + f32(index) * height, max(0, r.width - 2 * pad), height}
}

workspace_row_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	if workspace_picker_menu_id(&w.workspace_picker) == 0 { return -1 }
	for i in 0..<len(WORKSPACE_ROW_MENU) {
		if render.rect_contains(workspace_row_menu_item_rect(w, i), x, y) { return i }
	}
	return -1
}

workspace_row_click :: proc(app: ^App, w: ^Window, x, y: f32, extend: bool) -> bool {
	p := &w.workspace_picker
	#partial switch _ in p.state {
	case Workspace_Picker_Menu:
		if hit := workspace_row_menu_hit(w, x, y); hit >= 0 {
			p.menu_selected = hit
			workspace_row_menu_choose(app, w)
		} else { workspace_picker_transition(w, Workspace_Picker_List{}) }
		return true
	case Workspace_Picker_Rename:
		row := workspace_picker_row_rect(w, workspace_row_index(w, workspace_picker_rename_id(p)))
		if y >= row.y + row.height && render.rect_contains(workspace_row_rename_field_rect(w), x, y) {
			workspace_picker_pointer(app, w, x, true, extend)
			return true
		}
		workspace_row_rename_finish(app, w, false)
	}
	return false
}

workspace_row_hover :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) -> bool {
	p := &w.workspace_picker
	#partial switch _ in p.state {
	case Workspace_Picker_Menu:
		hit := workspace_row_menu_hit(w, f32(e.x), f32(e.y))
		if hit >= 0 {p.menu_selected, w.dirty = hit, true}
		pointer_set(app, w, hit >= 0 ? .Hand : .Arrow)
		return true
	case Workspace_Picker_Rename:
		if p.rename.dragging && .Left in e.buttons {
			workspace_picker_pointer(app, w, f32(e.x), false, true)
		}
		inside := render.rect_contains(workspace_row_rename_field_rect(w), f32(e.x), f32(e.y))
		pointer_set(app, w, inside ? .Text : .Arrow)
		return true
	}
	return false
}

workspace_button_indicator_rect :: proc(w: ^Window) -> render.Rect {
	chip := workspace_button_rect(w)
	size := ui.ICON_INDICATOR * w.scale
	return {chip.x + chip.width - (ui.CONTROL_INSET * w.scale) - size, chip.y, size, chip.height}
}

workspace_row_ellipsis_draw :: proc(app: ^App, w: ^Window, index: int) {
	r, s := workspace_picker_menu_button_rect(w, index), w.scale
	p := &w.workspace_picker
	hover := p.rows[index].id == p.menu_hover ? p.menu_motion.hover.value : 0
	// The button sits inside the row, so an opaque paper fill would punch a hole in the row's
	// selection tint. It takes the light and keeps the tint instead.
	skip_fill := ui.hover_fill_opaque(app.theme) && index == p.selected
	if hover > 0 && !skip_fill {
		fill := app.theme.hover
		fill.a *= hover
		if render.push_rect(&w.list, {rect = r, color = fill, radius = ui.RADIUS_CONTROL * s}) != .None { return }
	}
	ink := hover > 0 ? app.theme.text : app.theme.muted
	ui.icon_draw(&w.list, .More, r, ink, ui.ICON_BUTTON, s)
	if hover > 0 {
		if ui.hover_rim_draw(
			&w.list,
			app.theme,
			r,
			ui.RADIUS_CONTROL * s,
			hover,
			s,
			w.pointer,
			!skip_fill,
		) != .None { return }
	}
}

workspace_row_rename_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	p, s := &w.workspace_picker, w.scale
	index := workspace_row_index(w, workspace_picker_rename_id(p))
	if index < 0 { return .Ok }
	row := workspace_picker_row_rect(w, index)
	clip := render.Rect{row.x, row.y + row.height, row.width, workspace_row_rename_height(w)}
	if render.push_layer(&w.list, clip) != .None { return .Ok }
	field := workspace_row_rename_field_rect(w)
	radius := ui.RADIUS_CONTROL * s
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = radius}) != .None { return .Ok }
	outline := render.Rect_Instance{rect = field, color = app.theme.accent, radius = radius, stroke = s}
	if render.push_rect(&w.list, outline) != .None {
		return .Ok
	}
	box := workspace_row_rename_box(w)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true,
		"Workspace name"); result != .Ok { return result }
	if render.push_layer(&w.list, clip) != .None { return .Ok }
	hint := "Enter saves · Esc cancels"
	if workspace_picker_rename_error(p) {hint = "Could not save name · Enter retries · Esc cancels"}
	detail := ui.text_styled(&w.ui_text, .Detail)
	baseline := field.y + field.height + ui.SPACE_2 * s + detail.ascent
	return ui.draw_fading_text(&detail, &w.list, hint, field.x, baseline,
		app.theme.muted, field.width)
}

workspace_row_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	p, s := &w.workspace_picker, w.scale
	id := workspace_picker_menu_id(p)
	if id == 0 { return .Ok }
	r := workspace_row_menu_rect(w)
	if !ui.popover_open(&w.list, r, app.theme, f32(w.width), f32(w.height), s) { return .Ok }
	for menu_item, i in WORKSPACE_ROW_MENU {
		title := workspace_row_menu_title(app, menu_item, id)
		enabled := workspace_row_action_enabled(app, w, id, menu_item.action)
		item := workspace_row_menu_item_rect(w, i)
		if i == p.menu_selected {
			selection := render.Rect_Instance{rect = item, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s}
			if render.push_rect(&w.list, selection) != .None {
				return .Ok
			}
		}
		inset := ui.CONTROL_INSET * s
		if result := ui.draw_text(&w.ui_text, &w.list, title, item.x + inset,
			item.y + (item.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			enabled ? app.theme.text : app.theme.muted, max(0, item.width - 2 * inset)); result != .Ok {
			return result
		}
		if i == p.menu_selected && render.rect_contains(item, w.pointer.x, w.pointer.y) {
			// The menu item carries the selection tint, so it takes no paper hairline.
			if ui.hover_rim_draw(&w.list, app.theme, item, ui.RADIUS_CONTROL * s, 1, s, w.pointer, false) != .None {
				return .Ok
			}
		}
	}
	return .Ok
}
