package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:strings"

Name_Dialog_Mode :: enum {Rename, New_Workspace, New_Window, Move_Workspace, Tearoff}

rename_open :: proc(app: ^App, w: ^Window, tab_name: bool) {
	tab := selected_tab(w.workspace)
	if tab == nil {return}
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

workspace_name_open :: proc(app: ^App, w: ^Window, mode: Name_Dialog_Mode) {
	if !gesture_cancel(app, w) {return}
	if w.rename_open {rename_finish(app, w, false)}
	name := workspace_default_name(app)
	if name == "" {notify(app, .Error, "Could not generate a workspace name."); return}
	defer delete(name)
	palette_close(app, w)
	workspace_picker_cancel(w)
	ui.field_set(&w.rename, name)
	ui.field_select_all(&w.rename)
	w.rename_mode, w.rename_open, w.dirty = mode, true, true
}

rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	mode := w.rename_mode
	drag := w.rename_drag
	if save && mode != .Rename {
		name := settings.display_title(strings.trim_space(ui.field_string(&w.rename)), context.temp_allocator)
		if name == "" {return}
		for workspace in app.workspaces {
			if !workspace.provisional && strings.equal_fold(workspace.name, name) {
				notify(app, .Error, "A workspace already uses that name.")
				return
			}
		}
		w.rename_open, w.rename_mode, w.dirty = false, .Rename, true
		if mode == .Tearoff {
			if !pane_to_window(app, w, drag.source, drag.node, drag.preview_window, name) {
				pane_window_preview_discard(app, drag.preview_window)
				pane_drag_restore(app, w, drag)
				notify(app, .Error, "Could not move the pane. The source was preserved.")
			}
		} else if mode == .Move_Workspace {
			workspace_move_choose(app, w, w.rename_move, 0, name)
		} else {
			workspace_new_commit(app, w, mode == .New_Window, name)
		}
		return
	}
	w.rename_open, w.rename_mode, w.dirty = false, .Rename, true
	if !save && mode == .Tearoff {
		pane_window_preview_discard(app, drag.preview_window)
		pane_drag_restore(app, w, drag)
	}
	if save {_ = rename_target_commit(app, w, w.rename_target, ui.field_string(&w.rename))}
}

rename_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	if e.key == .Escape {rename_finish(app, w, false); return}
	if e.key == .Enter || e.key == .Numpad_Enter {rename_finish(app, w, true); return}
	field_edit_key(app, &w.rename, e)
	w.dirty = true
}

// Title, field and hint stacked inside the dialog padding, so the height follows the text.
@(private = "file")
rename_metrics :: proc(w: ^Window) -> (heading, hint: ui.Text) {
	return ui.text_styled(&w.ui_text, .Heading), ui.text_styled(&w.ui_text, .Small)
}

rename_rect :: proc(w: ^Window) -> render.Rect {
	s := w.scale
	heading, hint := rename_metrics(w)
	height :=
		2 * ui.DIALOG_PADDING * s +
		heading.line_height +
		ui.CONTROL_HEIGHT * s +
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
	heading, _ := rename_metrics(w)
	pad := ui.DIALOG_PADDING * s
	return {
		r.x + pad,
		r.y + pad + heading.line_height + 8 * s,
		max(1, r.width - 2 * pad),
		ui.CONTROL_HEIGHT * s,
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
		style = .Input,
		scale = w.scale,
	}
}

rename_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	box := rename_field_box(w)
	ui.field_pointer(&w.rename, ui.field_box_offset(box, x), pressed, extend)
	w.dirty = true
}

rename_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
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
	if w.rename_mode != .Rename {title = "New Workspace"}
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
		w.rename_mode == .Rename ? "Automatic title" : "Workspace name",
	); result != .Ok {return result}
	if render.push_layer(&w.list, r) != .None {return .Ok}
	message := "Enter saves · Esc cancels · Empty restores automatic titles"
	if w.rename_mode != .Rename {message = "Enter creates · Esc cancels"}
	return ui.draw_text(
		&hint,
		&w.list,
		message,
		r.x + pad,
		field.y + field.height + 8 * s + hint.ascent,
		app.theme.muted,
		max(1, r.width - 2 * pad),
	)
}
