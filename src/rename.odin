package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:strings"

// The dialog or the chip's name field shows.
rename_shown :: proc(w: ^Window) -> bool {
	#partial switch _ in w.overlay {
	case Overlay_Rename, Overlay_Chip_Name: return true
	}
	return false
}

chip_name_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Chip_Name)
	return shown
}

// Opens the dialog naming a tab or pane, holding its current name with the whole name selected. A workspace
// names in place instead, in the chip of the window that shows it (Overlay_Chip_Name).
rename_open :: proc(app: ^App, w: ^Window, target: Rename_Target) {
	if workspace, naming := target.(Rename_Workspace_Target); naming {
		owner := window_for_workspace(app, workspace_find(app, workspace.workspace))
		if owner != nil {workspace_name_begin(app, owner)}
		return
	}
	destination := rename_target_destination(app, target)
	if destination == nil {return}
	value := destination^
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Rename{target})
	ui.field_set(&w.rename, value)
	ui.field_select_all(&w.rename)
}

// Opens the window's workspace name for editing in its chip, with the whole name selected.
workspace_name_begin :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Chip_Name{workspace = w.workspace.id})
	ui.field_set(&w.rename, w.workspace.name)
	ui.field_select_all(&w.rename)
}

// Stores the chip's text as the workspace's name. An empty field keeps the existing name, which
// rename_target_commit's .Workspace_Chip intent decides. False when another workspace already uses the
// name, which leaves the workspace's name as it was.
chip_name_save :: proc(app: ^App, w: ^Window, workspace_id: u32) -> bool {
	value := ui.field_string(&w.rename)
	if name := rename_clean(value); name != "" {
		for workspace in app.workspaces {
			if !workspace.provisional && workspace.id != workspace_id && strings.equal_fold(workspace.name, name) {
				return false
			}
		}
	}
	_ = rename_target_commit(app, Rename_Workspace_Target{workspace_id}, value, .Workspace_Chip)
	return true
}

// The rename's own exit, from Enter and Escape. Saving a name already in use keeps the chip open with
// its error, which is the one way out of a save that stays; every other path closes the field. Not
// saving always leaves the target with the name it has.
rename_finish :: proc(app: ^App, w: ^Window, save: bool) {
	#partial switch &current in w.overlay {
	case Overlay_Rename:
		if save {_ = rename_target_commit(app, current.target, ui.field_string(&w.rename), .Automatic_Title)}
	case Overlay_Chip_Name:
		if save && !chip_name_save(app, w, current.workspace) {
			current.error, w.dirty = true, true
			return
		}
	case:
		return
	}
	overlay_close(app, w)
}

rename_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	if e.key == .Escape {rename_finish(app, w, false); return}
	if e.key == .Enter || e.key == .Numpad_Enter {rename_finish(app, w, true); return}
	field_edit_key(app, &w.rename, e)
	if chip, ok := &w.overlay.(Overlay_Chip_Name); ok {chip.error = false}
	w.dirty = true
}

// Title, field and hint stacked inside the dialog padding, so the height follows the text.
@(private = "file")
rename_metrics :: proc(w: ^Window) -> (heading, hint: ui.Text) {
	return ui.text_styled(&w.ui_text, .Title), ui.text_styled(&w.ui_text, .Detail)
}

rename_rect :: proc(w: ^Window) -> render.Rect {
	s := w.scale
	if chip_name_shown(w) {return workspace_button_rect(w)}
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
	if chip_name_shown(w) {
		// The field's inset puts the text exactly where the chip draws its label.
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
	return ui.field_box_standard(&w.rename, &w.ui_text, rename_field_rect(w), w.scale)
}

rename_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	box := rename_field_box(w)
	ui.field_pointer(&w.rename, ui.field_box_offset(box, x), pressed, extend)
	w.dirty = true
}

// The chip keeps its shape and size: its chevron gives way to a field holding the name.
@(private = "file")
workspace_name_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	s := w.scale
	r := rename_rect(w)
	radius := ui.RADIUS_CONTROL * s
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(&w.list, {rect = r, color = app.theme.pane, radius = radius}) != .None {return .Ok}
	size := ui.ICON_BUTTON * s
	icon := render.Rect{r.x + ui.CONTROL_INSET * s, r.y + (r.height - size) / 2, size, size}
	if result := workspace_icon_draw(w, w.workspace.icon, icon, app.theme.text); result != .Ok {return result}
	box := rename_field_box(w)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true, "Workspace name");
	   result != .Ok {return result}
	if chip, _ := w.overlay.(Overlay_Chip_Name); !chip.error {return .Ok}
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

rename_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	dialog, shown := w.overlay.(Overlay_Rename)
	if !shown {return workspace_name_draw(app, w)}
	s := w.scale
	r := rename_rect(w)
	pad := ui.DIALOG_PADDING * s
	heading, hint := rename_metrics(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(&w.list, {rect = {0, 0, f32(w.width), f32(w.height)}, color = app.theme.scrim}) !=
	   .None {return .Ok}
	frame := ui.dialog_panel(r, s)
	if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	_, tab := dialog.target.(Rename_Tab_Target)
	title := tab ? "Rename Tab" : "Rename Pane"
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

when AIO_CONTROL {
	rename_state_report :: proc(r: ^State_Report, w: ^Window) {
		chip, _ := w.overlay.(Overlay_Chip_Name)
		state_value(r, "rename.open", rename_shown(w))
		state_value(r, "rename.error", chip.error)
		state_text(r, "rename.value", ui.field_string(&w.rename))
	}
}
