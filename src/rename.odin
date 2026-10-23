package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"

rename_open :: proc(app: ^App, w: ^Window, tab_name: bool) {
	tab := selected_tab(w.workspace)
	if tab == nil || settings_active(w) {return}
	target, value := Rename_Target{.Tab, tab.id}, tab.name
	if !tab_name {
		entry := focused_session(app, w)
		if entry == nil {return}
		target, value = {.Pane, entry.id}, entry.name
	}
	if !gesture_cancel(app, w) {return}
	palette_close(app, w)
	ui.field_set(&w.rename, value)
	ui.field_select_all(&w.rename)
	w.rename_target, w.rename_open, w.dirty = target, true, true
}

rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	if save {_ = rename_target_commit(app, w, w.rename_target, ui.field_string(&w.rename))}
	w.rename_open, w.dirty = false, true
}

rename_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	if e.key == .Escape {rename_finish(app, w, false); return}
	if e.key == .Enter || e.key == .Numpad_Enter {rename_finish(app, w, true); return}
	field_edit_key(app, &w.rename, e)
	w.dirty = true
}

rename_rect :: proc(w: ^Window) -> render.Rect {
	width := min(440 * w.scale, f32(w.width) - 24 * w.scale)
	return {
		(f32(w.width) - width) / 2,
		max(12 * w.scale, (f32(w.height) - 156 * w.scale) / 2),
		width,
		156 * w.scale,
	}
}

rename_field_rect :: proc(w: ^Window) -> render.Rect {
	r, s := rename_rect(w), w.scale
	return {r.x + 16 * s, r.y + 45 * s, max(1, r.width - 32 * s), 36 * s}
}

rename_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	field := rename_field_rect(w)
	available := max(1, field.width - 20 * w.scale)
	start := ui.field_view_start(&w.rename, &w.ui_text, available)
	at := ui.field_offset_at(&w.rename, &w.ui_text, start, field.x + 10 * w.scale, x)
	ui.field_pointer(&w.rename, at, pressed, extend)
	w.dirty = true
}

rename_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	s := w.scale
	r := rename_rect(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(
		   &w.list,
		   {rect = {0, 0, f32(w.width), f32(w.height)}, color = {0, 0, 0, 0.35}},
	   ) !=
	   .None {
		return .Ok
	}
	if render.push_rect(&w.list, {rect = r, color = app.theme.surface, radius = 10 * s}) !=
	   .None {return .Ok}
	title := w.rename_target.kind == .Tab ? "Rename Tab" : "Rename Pane"
	if result := ui.draw_text(
		&w.ui_text,
		&w.list,
		title,
		r.x + 16 * s,
		r.y + 28 * s,
		app.theme.text,
	); result != .Ok {return result}
	field := rename_field_rect(w)
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = 5 * s}) !=
	   .None {return .Ok}
	if render.push_rect(
		   &w.list,
		   {rect = field, color = app.theme.accent, radius = 5 * s, stroke = s},
	   ) !=
	   .None {
		return .Ok
	}
	if render.push_layer(&w.list, field, 5 * s) != .None {return .Ok}
	if result := ui.field_draw(
		&w.rename,
		&w.list,
		&w.ui_text,
		app.theme,
		field.x + 10 * s,
		field.y + (field.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
		max(1, field.width - 20 * s),
		true,
		"Automatic title",
		app.theme.text,
		s,
	); result != .Ok {return result}
	if render.push_layer(&w.list, r) != .None {return .Ok}
	hint := "Enter saves · Esc cancels · Empty restores automatic titles"
	return ui.draw_text(
		&w.ui_text,
		&w.list,
		hint,
		r.x + 16 * s,
		r.y + 112 * s,
		app.theme.muted,
		max(1, r.width - 32 * s),
	)
}
