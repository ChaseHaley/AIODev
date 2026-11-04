package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:strings"

// A tab or pane renames in a dialog; a workspace names in place, in its chip.
Rename_Mode :: enum {Rename, Workspace}

@(private = "file")
CHIP_FIELD_WIDTH :: f32(256)

// Renames tab `index`, or the focused pane when tab_name is false.
rename_open :: proc(app: ^App, w: ^Window, tab_name: bool, index: int) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	tab := w.workspace.tabs[index]
	target, value := Rename_Target{.Tab, tab.id}, tab.name
	if !tab_name {
		entry := focused_session(app, w)
		if entry == nil {return}
		target, value = {.Pane, entry.id}, entry.name
	}
	if !gesture_cancel(app, w) {return}
	if w.rename_open {rename_finish(app, w, false)}
	palette_close(app, w)
	ui.field_set(&w.rename, value)
	ui.field_select_all(&w.rename)
	w.rename_mode = .Rename
	w.rename_target, w.rename_open, w.dirty = target, true, true
}

// Opens the window's workspace name for editing in its chip, with the whole name selected.
workspace_name_begin :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	if w.rename_open {rename_finish(app, w, false)}
	palette_close(app, w)
	workspace_picker_cancel(w)
	ui.field_set(&w.rename, w.workspace.name)
	ui.field_select_all(&w.rename)
	w.rename_target = {.Workspace, w.workspace.id}
	w.rename_mode, w.rename_error = .Workspace, false
	w.rename_open, w.dirty = true, true
}

// Saving a workspace name keeps the field open while the name is in use, and an empty field keeps the
// existing name. Not saving always leaves the workspace with the name it has.
rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	mode := w.rename_mode
	if save && mode == .Workspace {
		name := settings.display_title(strings.trim_space(ui.field_string(&w.rename)), context.temp_allocator)
		if name != "" {
			for workspace in app.workspaces {
				if !workspace.provisional &&
				   workspace.id != w.rename_target.id &&
				   strings.equal_fold(workspace.name, name) {
					w.rename_error, w.dirty = true, true
					return
				}
			}
			_ = rename_target_commit(app, w, w.rename_target, name)
		}
	} else if save {
		_ = rename_target_commit(app, w, w.rename_target, ui.field_string(&w.rename))
	}
	w.rename_open, w.rename_mode, w.rename_error, w.dirty = false, .Rename, false, true
}

rename_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	if e.key == .Escape {rename_finish(app, w, false); return}
	if e.key == .Enter || e.key == .Numpad_Enter {rename_finish(app, w, true); return}
	field_edit_key(app, &w.rename, e)
	w.rename_error, w.dirty = false, true
}

// Title, field and hint stacked inside the dialog padding, so the height follows the text.
@(private = "file")
rename_metrics :: proc(w: ^Window) -> (heading, hint: ui.Text) {
	return ui.text_styled(&w.ui_text, .Title), ui.text_styled(&w.ui_text, .Detail)
}

rename_rect :: proc(w: ^Window) -> render.Rect {
	s := w.scale
	if w.rename_mode == .Workspace {
		chip := workspace_button_rect(w)
		chip.width = max(chip.width, min(CHIP_FIELD_WIDTH * s, f32(w.width) - chip.x - ui.SPACE_2 * s))
		return chip
	}
	heading, hint := rename_metrics(w)
	height :=
		2 * ui.DIALOG_PADDING * s +
		heading.line_height +
		ui.HEIGHT_STANDARD * s +
		hint.line_height +
		(8 + 8) * s
	width := min(440 * s, f32(w.width) - 24 * s)
	return {
		(f32(w.width) - width) / 2,
		max(12 * s, (f32(w.height) - height) / 2),
		width,
		height,
	}
}

rename_field_rect :: proc(w: ^Window) -> render.Rect {
	r, s := rename_rect(w), w.scale
	if w.rename_mode == .Workspace {
		lead := (ui.CONTROL_INSET + ui.ICON_BUTTON) * s
		return {r.x + lead, r.y, max(1, r.width - lead), r.height}
	}
	heading, _ := rename_metrics(w)
	pad := ui.DIALOG_PADDING * s
	return {
		r.x + pad,
		r.y + pad + heading.line_height + 8 * s,
		max(1, r.width - 2 * pad),
		ui.HEIGHT_STANDARD * s,
	}
}

rename_field_box :: proc(w: ^Window) -> ui.Field_Box {
	return {
		field = &w.rename,
		text = &w.ui_text,
		rect = rename_field_rect(w),
		inset = ui.CONTROL_INSET,
		caret_width = 1,
		radius = ui.RADIUS_CONTROL,
		style = .Body,
		scale = w.scale,
	}
}

rename_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	box := rename_field_box(w)
	ui.field_pointer(&w.rename, ui.field_box_offset(box, x), pressed, extend)
	w.dirty = true
}

// The chip grows in place over the tab strip, so nothing else in the window moves while naming.
@(private = "file")
workspace_name_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	s := w.scale
	r := rename_rect(w)
	radius := ui.RADIUS_CONTROL * s
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(&w.list, {rect = r, color = app.theme.pane, radius = radius}) != .None {return .Ok}
	frame := render.Rect_Instance{rect = r, color = app.theme.accent, radius = radius, stroke = s}
	if render.push_rect(&w.list, frame) != .None {return .Ok}
	size := ui.ICON_BUTTON * s
	icon := render.Rect{r.x + ui.CONTROL_INSET * s, r.y + (r.height - size) / 2, size, size}
	if result := workspace_icon_draw(w, w.workspace.icon, icon, app.theme.text); result != .Ok {return result}
	box := rename_field_box(w)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true, "Workspace name");
	   result != .Ok {return result}
	if !w.rename_error {return .Ok}
	message := "A workspace already uses that name."
	detail := ui.text_styled(&w.ui_text, .Detail)
	pad := ui.SPACE_2 * s
	panel := render.Rect {
		r.x,
		r.y + r.height + ui.SPACE_1 * s,
		ui.text_width(&detail, message) + 2 * pad,
		detail.line_height + 2 * pad,
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, ui.popover_panel(panel, s), app.theme) != .None {return .Ok}
	baseline := panel.y + pad + detail.ascent
	return ui.draw_text(&detail, &w.list, message, panel.x + pad, baseline, app.theme.error)
}

rename_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if w.rename_mode == .Workspace {return workspace_name_draw(app, w)}
	s := w.scale
	r := rename_rect(w)
	pad := ui.DIALOG_PADDING * s
	heading, hint := rename_metrics(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(&w.list, {rect = {0, 0, f32(w.width), f32(w.height)}, color = app.theme.scrim}) !=
	   .None {return .Ok}
	frame := ui.dialog_panel(r, s)
	if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	title := w.rename_target.kind == .Tab ? "Rename Tab" : "Rename Pane"
	if result := ui.draw_text(
		&heading,
		&w.list,
		title,
		r.x + pad,
		r.y + pad + heading.ascent,
		app.theme.text,
	); result != .Ok {return result}
	field := rename_field_rect(w)
	radius := ui.RADIUS_CONTROL * s
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = radius}) != .None {return .Ok}
	if render.push_rect(&w.list, {rect = field, color = app.theme.accent, radius = radius, stroke = s}) !=
	   .None {return .Ok}
	box := rename_field_box(w)
	if result := ui.field_box_draw(
		box,
		&w.list,
		app.theme,
		ui.field_box_baseline(box),
		true,
		"Automatic title",
	); result != .Ok {return result}
	if render.push_layer(&w.list, r) != .None {return .Ok}
	return ui.draw_text(
		&hint,
		&w.list,
		"Enter saves · Esc cancels · Empty restores automatic titles",
		r.x + pad,
		field.y + field.height + 8 * s + hint.ascent,
		app.theme.muted,
		max(1, r.width - 2 * pad),
	)
}
