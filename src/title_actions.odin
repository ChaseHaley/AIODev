package main

import "aio:input"
import "aio:render"
import "aio:ui"

// The title bar's own controls, left to right after the tab orientation toggle. None is no control,
// for hover and press state.
Title_Action :: enum {None, Settings, Palette}

// What a control draws, says, and runs.
@(private = "file")
Title_Control :: struct {
	icon:    ui.Icon,
	tooltip: string,
	action:  Action,
}

@(private = "file", rodata)
TITLE_CONTROLS := #partial [Title_Action]Title_Control {
	.Settings = {.Settings, "Settings", .Settings_UI},
	.Palette = {.Command, "Command palette", .Command_Palette},
}

// Every title control is one toggle wide: the orientation toggle, then each action after None.
@(private = "file")
TITLE_SLOTS :: 1 + len(Title_Action) - 1

title_actions_end :: proc(w: ^Window) -> f32 {
	return (TITLE_SLOTS * ui.TITLE_BUTTON_WIDTH + 8) * w.scale
}

// Empty title bar kept beside the caption buttons since the title-bar tabs arrived (e2d9708).
@(private = "file")
CAPTION_CLEAR_MARGIN :: 80

// The title-bar width at the right that the workspace chip and the tab bar leave free: the native
// caption buttons and the empty margin beside them.
window_caption_reserve :: proc(w: ^Window) -> f32 {
	return (ui.CAPTION_WIDTH + CAPTION_CLEAR_MARGIN) * w.scale
}

title_action_rect :: proc(w: ^Window, action: Title_Action) -> render.Rect {
	if action == .None {return {}}
	r := tab_orientation_button_rect(w)
	slot := 1 + int(action) - int(Title_Action.Settings)
	r.x += f32(slot) * ui.TITLE_BUTTON_WIDTH * w.scale
	return r
}

title_action_hit :: proc(w: ^Window, x, y: f32) -> Title_Action {
	for action in Title_Action {
		if action != .None && render.rect_contains(title_action_rect(w, action), x, y) {return action}
	}
	return .None
}

title_actions_draw :: proc(app: ^App, w: ^Window) {
	if render.push_layer(&w.list, {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * w.scale}) != .None {return}
	for action in Title_Action {
		if action == .None {continue}
		_ = ui.icon_button_draw(
			&w.list, app.theme, title_action_rect(w, action), TITLE_CONTROLS[action].icon,
			f32(int(w.title_action_hover == action)),
			f32(int(ui.armed_is(w.title_action_armed, action))), w.scale, w.pointer,
		)
	}
}

when AIO_CONTROL {
	title_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_rect(r, "title.settings", title_action_rect(w, .Settings))
		state_rect(r, "title.palette", title_action_rect(w, .Palette))
		state_valuef(r, "title.height", "%g", ui.TITLE_BAR_HEIGHT * w.scale)
		state_value(r, "title.controls_end", i32(window_title_controls_end(app, w)))
		state_valuef(r, "title.caption_start", "%g", f32(w.width) - ui.CAPTION_WIDTH * w.scale)
	}
}

// Title action pointer surface

@(private)
title_action_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return title_action_hit(w, x, y) != .None
}

@(private)
title_action_pointer_hover :: proc(
	app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event,
) {
	hover := owner == .Title_Action ? title_action_hit(w, f32(e.x), f32(e.y)) : Title_Action.None
	if hover != w.title_action_hover {w.title_action_hover, w.dirty = hover, true}
	if hover != .None {pointer_set(app, w, .Hand)}
}

@(private)
title_action_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	return TITLE_CONTROLS[title_action_hit(w, x, y)].tooltip
}

@(private)
title_action_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button == .Left {ui.armed_press(&w.title_action_armed, title_action_hit(w, f32(e.x), f32(e.y)))}
}

@(private)
title_action_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.title_action_armed) {return false}
	fired, ok := ui.armed_release(&w.title_action_armed, title_action_hit(w, f32(e.x), f32(e.y)))
	w.dirty = true
	if ok && fired != .None {run_action(app, w, TITLE_CONTROLS[fired].action)}
	return true
}

@(private)
title_action_cancel :: proc(_: ^App, w: ^Window) {
	w.title_action_hover = .None
	ui.armed_cancel(&w.title_action_armed)
}

@(private)
title_action_leave :: proc(_: ^App, w: ^Window) {
	w.title_action_hover = .None
}

// Tab orientation toggle pointer surface

@(private)
orientation_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return tab_orientation_button_hit(w, x, y)
}

@(private)
orientation_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	hovered := owner == .Tab_Orientation
	if hovered != w.tab_orientation_button_hovered {w.tab_orientation_button_hovered, w.dirty = hovered, true}
	if hovered {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private)
orientation_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	return w.tabs_horizontal ? "Show vertical tabs" : "Show horizontal tabs"
}

@(private)
orientation_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button == .Left {ui.armed_press(&w.tab_orientation_button_armed, true)}
}

@(private)
orientation_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.tab_orientation_button_armed) {return false}
	hit := tab_orientation_button_hit(w, f32(e.x), f32(e.y))
	fired, ok := ui.armed_release(&w.tab_orientation_button_armed, hit)
	w.dirty = true
	if ok && fired {toggle_tab_orientation(app)}
	return true
}

@(private)
orientation_cancel :: proc(_: ^App, w: ^Window) {
	w.tab_orientation_button_hovered = false
	ui.armed_cancel(&w.tab_orientation_button_armed)
}

@(private)
orientation_leave :: proc(_: ^App, w: ^Window) {
	w.tab_orientation_button_hovered = false
}
