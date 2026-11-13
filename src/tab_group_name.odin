package main

import "aio:render"
import "aio:ui"

// The new-group editor's width, and the room its colour swatches take.
GROUP_EDITOR_WIDTH :: f32(256)
GROUP_SWATCH :: f32(20)
// While a group names in place its chip keeps at least this much room for the field.
GROUP_NAME_MIN_WIDTH :: f32(120)

// Names group `id` in its chip, with the whole name selected, as the workspace chip names its workspace. A
// group just made names in an editor below its chip instead, which also picks its colour.
tab_group_name_begin :: proc(app: ^App, w: ^Window, id: u32, editor: bool) {
	group := tab_group_find(w.workspace, id)
	if group == nil || !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Group_Name{group = id, editor = editor})
	ui.field_set(&w.rename, group.name)
	ui.field_select_all(&w.rename)
}

// The group naming now, in place or in the editor, or nil.
group_name_editing :: proc(w: ^Window) -> (^Tab_Group, bool) {
	naming, shown := w.overlay.(Overlay_Group_Name)
	if !shown {return nil, false}
	return tab_group_find(w.workspace, naming.group), naming.editor
}

// Stores the typed name; an empty one leaves the chip as a dot of its colour. False, storing nothing, when
// another group of the workspace has the name in this group's colour (WORK-460).
group_name_save :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	target := Rename_Group_Target{w.workspace.id, id}
	return rename_target_commit(app, target, ui.field_string(&w.rename), .Automatic_Title) != .Taken
}

// Whether colour `color` would give the group being named a name and colour another group has, with the
// name as typed.
@(private = "file")
group_name_color_taken :: proc(w: ^Window, group: ^Tab_Group, color: int) -> bool {
	return tab_group_taken(w.workspace, rename_clean(ui.field_string(&w.rename)), color, group.id)
}

// In place, the chip; in the editor, a panel below the chip aligned with its left edge, kept in the window.
group_name_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	naming, _ := w.overlay.(Overlay_Group_Name)
	chip := tab_group_chip_rect(app, w, naming.group)
	if !naming.editor {return chip}
	s := w.scale
	pad := ui.OVERLAY_PADDING * s + ui.SPACE_2 * s
	width := min(GROUP_EDITOR_WIDTH * s, f32(w.width) - 16 * s)
	height := 2 * pad + ui.HEIGHT_STANDARD * s + ui.SPACE_3 * s + GROUP_SWATCH * s
	x := clamp(chip.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s))
	y := min(chip.y + chip.height + ui.SPACE_1 * s, f32(w.height) - height - 8 * s)
	return {x, y, width, height}
}

group_name_field_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	naming, _ := w.overlay.(Overlay_Group_Name)
	r, s := group_name_rect(app, w), w.scale
	if !naming.editor {
		height := ui.HEIGHT_COMPACT * s
		return {r.x, r.y + (r.height - height) / 2, max(r.width, GROUP_NAME_MIN_WIDTH * s), height}
	}
	pad := ui.OVERLAY_PADDING * s + ui.SPACE_2 * s
	return {r.x + pad, r.y + pad, r.width - 2 * pad, ui.HEIGHT_STANDARD * s}
}

// The editor's swatch for colour `color`, from 1, in a row below the field.
group_name_swatch_rect :: proc(app: ^App, w: ^Window, color: int) -> render.Rect {
	field, s := group_name_field_rect(app, w), w.scale
	size := GROUP_SWATCH * s
	x := field.x + f32(color - 1) * (size + ui.SPACE_2 * s)
	return {x, field.y + field.height + ui.SPACE_3 * s, size, size}
}

// A press on one of the editor's swatches colours the group, unless another group has the typed name in that
// colour; true when it landed on one.
group_name_swatch_press :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	group, editor := group_name_editing(w)
	if group == nil || !editor {return false}
	for color in 1 ..< len(WORKSPACE_ICON_COLORS) {
		if !render.rect_contains(group_name_swatch_rect(app, w, color), x, y) {continue}
		if !group_name_color_taken(w, group, color) {
			group.color = color
			tab_groups_changed(app, w)
			if naming, ok := &w.overlay.(Overlay_Group_Name); ok {naming.error = false}
		}
		return true
	}
	return false
}

group_name_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	group, editor := group_name_editing(w)
	if group == nil {return .Ok}
	s := w.scale
	radius := ui.RADIUS_CONTROL * s
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if editor {
		if ui.panel_draw(&w.list, ui.popover_panel(group_name_rect(app, w), s), app.theme) != .None {return .Ok}
	}
	field := group_name_field_rect(app, w)
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = radius}) != .None {return .Ok}
	color := tab_group_color(app, group)
	outline := render.Rect_Instance{rect = field, color = color, radius = radius, stroke = s}
	if render.push_rect(&w.list, outline) != .None {return .Ok}
	box := rename_field_box(app, w)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true, "Name this group");
	   result != .Ok {return result}
	if naming, _ := w.overlay.(Overlay_Group_Name); naming.error {
		message := "Another group of this colour has that name."
		detail := ui.text_styled(&w.ui_text, .Detail)
		pad := ui.SPACE_2 * s
		below := editor ? group_name_rect(app, w) : field
		panel := render.Rect {
			below.x,
			below.y + below.height + ui.SPACE_1 * s,
			ui.text_width(&detail, message) + 2 * pad,
			detail.line_height + 2 * pad,
		}
		if ui.panel_draw(&w.list, ui.popover_panel(panel, s), app.theme) != .None {return .Ok}
		baseline := panel.y + pad + detail.ascent
		if result := ui.draw_text(&detail, &w.list, message, panel.x + pad, baseline, app.theme.error);
		   result != .Ok {return result}
	}
	if !editor {return .Ok}
	for index in 1 ..< len(WORKSPACE_ICON_COLORS) {
		r := group_name_swatch_rect(app, w, index)
		if index == group.color {
			ring := render.Rect{r.x - 2 * s, r.y - 2 * s, r.width + 4 * s, r.height + 4 * s}
			if render.push_rect(&w.list, {rect = ring, color = app.theme.text, radius = ring.width / 2, stroke = s}) !=
			   .None {return .Ok}
		}
		// A colour another group has with the typed name is taken, and draws disabled (WORK-460).
		swatch := workspace_icon_tint(index, app.theme.text)
		if group_name_color_taken(w, group, index) {swatch.a *= 0.45}
		if render.push_rect(&w.list, {rect = r, color = swatch, radius = r.width / 2}) != .None {return .Ok}
	}
	return .Ok
}
