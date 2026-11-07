package main

import "aio:input"
import "aio:platform"
import "aio:ui"
import "aio:render"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave. Each surface's handlers live with
// its feature; this file composes them and holds the policy that decides between surfaces.
Pointer_Target :: enum u8 {
	Notice,
	Workspace_Picker,
	Tab_Menu,
	Divider_Menu,
	Profile_Menu,
	Document_Menu,
	Status_Inbox,
	Rename,
	// Window caption buttons, which stay usable over every overlay.
	Caption,
	// An open confirmation takes the rest of the window.
	Confirmation,
	// The command palette takes the rest of the window while it is open.
	Palette,
	Tab_Orientation,
	Title_Action,
	// The find bar floats over panes, headers and the Activity panel.
	Find,
	Workspace_Button,
	Status_Pill,
	Divider,
	Status_Panel,
	// The tab strip band or the rail, including an overlay rail above the panes.
	Tabs,
	// A floating pane's resize edges and the capsules of minimized floating panes. A floating pane also
	// hides the dividers below it.
	Floating,
	// Pane headers and a single pane's floating split controls.
	Pane_Header,
	Scrollbar,
	// A settings page shown in a pane.
	Settings_Page,
	// A Markdown document shown in a pane.
	Markdown_Page,
	// Terminal content, including its links, and anything uncovered.
	Content,
}

// What a drag a surface holds did with a move.
Pointer_Held :: enum u8 {
	// No drag of this surface is held, or it leaves this move to the surfaces.
	Free,
	// The drag followed the move, which ends there.
	Taken,
	// The move ended a drag whose release was missed. What lies under the pointer may have changed with
	// it, so routing resolves the target again.
	Ended,
}

// Everything a surface tells the pointer system: its handlers and its policy. A new surface adds a
// target above and one entry in pointer_surfaces.
Pointer_Surface :: struct {
	// Whether the point lies on the surface while it is showing.
	claims:       proc(app: ^App, w: ^Window, x, y: f32) -> bool,
	// Runs for every surface on every move. The owner updates its hover and sets the cursor; every
	// other surface clears its own hover, cheaply when there is none.
	hover:        proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event),
	// A press the surface owns. A modal surface also receives every release while it is open.
	press:        proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event),
	// The release of a press the surface owned, wherever it lands; false passes it on to the shared
	// completion for confirmations, the palette and pane content. A release of a press the surface
	// swallowed ends there either way.
	release:      proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool,
	// The hovered control supplies a short label; the shared tooltip owns timing and drawing.
	tooltip:      proc(app: ^App, w: ^Window, x, y: f32) -> string,
	// Capture loss: the surface drops its hover, armed control and drag, whether or not it holds a button.
	cancel:       proc(app: ^App, w: ^Window),
	// The pointer left the window: the surface drops its hover, as a move another surface owns does.
	leave:        proc(app: ^App, w: ^Window),
	// A drag the surface holds follows every move before hover runs; `under` is the surface under the
	// pointer. Only one drag is held at a time, since each starts with a Left press.
	held:         proc(app: ^App, w: ^Window, under: Pointer_Target, e: input.Mouse_Move_Event) -> Pointer_Held,
	// Takes the whole window while it shows: every press, every release that began elsewhere, and the
	// moves of held presses and of drags that have not started.
	modal:        bool,
	// A press here keeps the pointer with this surface until its release, whatever buttons a move
	// reports. The palette and a confirmation take the whole window while open, so a press on one that
	// has since closed keeps nothing.
	holds:        bool,
	// A press here hands the keyboard back from the find bar to the pane; the bar and its matches stay.
	blurs_find:   bool,
	// Lies in a pane, so a single pane's split controls show while the pointer is over it.
	in_pane:      bool,
	// A floating pane over the point hides the surface.
	under_floats: bool,
}

@(rodata)
pointer_surfaces := [Pointer_Target]Pointer_Surface {
	.Notice           = {
		claims = notice_claims, hover = notice_hover, press = notice_press, release = notice_release,
		tooltip = notice_tooltip, cancel = notice_cancel, leave = notice_leave, holds = true,
	},
	.Workspace_Picker = {
		claims = workspace_picker_claims, hover = workspace_picker_pointer_hover,
		press = workspace_picker_button, tooltip = workspace_picker_tooltip,
		cancel = workspace_picker_pointer_cancel, leave = workspace_picker_leave, modal = true,
	},
	.Tab_Menu         = {
		claims = tab_menu_claims, hover = tab_menu_hover, press = tab_menu_button, modal = true,
	},
	.Divider_Menu     = {
		claims = divider_menu_claims, hover = divider_menu_hover, press = divider_menu_button, modal = true,
	},
	.Profile_Menu     = {
		claims = profile_menu_claims, hover = profile_menu_hover, press = profile_menu_button, modal = true,
	},
	.Document_Menu    = {
		claims = document_menu_claims, hover = document_menu_pointer_hover, press = document_menu_button,
		tooltip = document_menu_tooltip, cancel = document_menu_pointer_cancel, leave = document_menu_leave,
		modal = true,
	},
	.Status_Inbox     = {
		claims = status_inbox_claims, hover = status_inbox_hover, press = status_inbox_button, modal = true,
	},
	.Rename           = {
		claims = rename_claims, hover = rename_hover, press = rename_button, cancel = rename_pointer_cancel,
		modal = true,
	},
	// No leave: Windows reports a leave as the pointer moves onto the maximize button, whose hover the
	// native caption moves keep; a caption move outside the client area clears it instead.
	.Caption          = {
		claims = caption_claims, hover = caption_hover, press = caption_press, release = caption_release,
		tooltip = caption_tooltip, cancel = caption_cancel, holds = true,
	},
	.Confirmation     = {
		claims = confirmation_claims, hover = confirmation_pointer_hover, press = confirmation_press,
		cancel = confirmation_pointer_cancel,
	},
	.Palette          = {
		claims = palette_claims, hover = palette_hover, press = palette_press, tooltip = palette_tooltip,
		cancel = palette_pointer_cancel,
	},
	.Tab_Orientation  = {
		claims = orientation_claims, hover = orientation_hover, press = orientation_press,
		release = orientation_release, tooltip = orientation_tooltip, cancel = orientation_cancel,
		leave = orientation_leave, holds = true,
	},
	.Title_Action     = {
		claims = title_action_claims, hover = title_action_pointer_hover, press = title_action_press,
		release = title_action_release, tooltip = title_action_tooltip, cancel = title_action_cancel,
		leave = title_action_leave, holds = true,
	},
	.Find             = {
		claims = find_claims, hover = find_pointer_hover, press = find_press, release = find_release,
		tooltip = find_tooltip, cancel = find_pointer_cancel, leave = find_leave, holds = true,
	},
	.Workspace_Button = {
		claims = workspace_button_claims, hover = workspace_button_hover, press = workspace_button_press,
		tooltip = workspace_button_tooltip, leave = workspace_button_leave, holds = true, blurs_find = true,
	},
	.Status_Pill      = {
		claims = status_pill_claims, hover = status_pill_hover, press = status_pill_press,
		tooltip = status_pill_tooltip, leave = status_pill_leave, holds = true, blurs_find = true,
		under_floats = true,
	},
	.Divider          = {
		claims = divider_claims, hover = divider_hover, press = divider_pointer_press, release = divider_release,
		cancel = divider_pointer_cancel, held = divider_held, holds = true, blurs_find = true,
	},
	.Status_Panel     = {
		claims = status_panel_claims, hover = status_panel_hover, press = status_panel_press,
		release = status_panel_release, tooltip = status_panel_tooltip, cancel = status_panel_cancel,
		leave = status_panel_leave, holds = true, blurs_find = true, under_floats = true,
	},
	.Tabs             = {
		claims = tabs_claims, hover = tabs_hover, press = tab_interaction_press, release = tabs_release,
		tooltip = tabs_tooltip, cancel = tabs_cancel, leave = tabs_leave, held = tabs_held, holds = true,
		blurs_find = true, under_floats = true,
	},
	.Floating         = {
		claims = floating_claims, hover = floating_hover, press = floating_press, release = floating_release,
		tooltip = floating_tooltip, cancel = floating_pointer_cancel, leave = floating_leave,
		held = floating_held, holds = true, blurs_find = true,
	},
	.Pane_Header      = {
		claims = header_claims, hover = header_hover, press = pane_header_press, release = header_release,
		tooltip = header_tooltip, cancel = header_cancel, leave = header_cancel, held = pane_drag_held,
		holds = true, blurs_find = true, in_pane = true,
	},
	.Scrollbar        = {
		claims = scrollbar_claims, hover = scrollbar_hover, press = scrollbar_press,
		release = scrollbar_release, cancel = scrollbar_cancel, leave = scrollbar_leave,
		held = scrollbar_held, holds = true, blurs_find = true, in_pane = true,
	},
	.Settings_Page    = {
		claims = settings_claims, hover = settings_pointer_hover, press = content_press,
		tooltip = settings_tooltip, cancel = settings_pointer_cancel, leave = settings_leave, holds = true,
		blurs_find = true, in_pane = true,
	},
	// Not in_pane: a lone Markdown pane's content does not reveal its split controls, as it never has.
	.Markdown_Page    = {
		claims = markdown_claims, hover = markdown_hover, press = markdown_press, release = markdown_release,
		cancel = markdown_gesture_clear, leave = markdown_leave, holds = true, blurs_find = true,
	},
	.Content          = {
		claims = content_claims, hover = content_hover, press = content_press, cancel = content_cancel,
		leave = content_leave, holds = true, blurs_find = true, in_pane = true,
	},
}

// The workspace and tab chrome a linked window does not draw.
@(private = "file")
POINTER_LINKED_ABSENT :: bit_set[Pointer_Target] {
	.Tab_Orientation,
	.Title_Action,
	.Workspace_Button,
	.Status_Pill,
	.Status_Panel,
	.Tabs,
}

// The topmost surface whose area holds the point. Below the modal surfaces, callers handle presses
// and drags that already hold the pointer before acting on the answer.
pointer_target :: proc(app: ^App, w: ^Window, x, y: f32) -> Pointer_Target {
	for target in Pointer_Target {
		if window_linked(w) && target in POINTER_LINKED_ABSENT {continue}
		if pointer_surfaces[target].under_floats && floating_covers(w, x, y) {continue}
		if pointer_surfaces[target].claims(app, w, x, y) {return target}
	}
	return .Content
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {
	return pointer_surfaces[target].modal
}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	for surface in pointer_surfaces {
		if surface.hover != nil {surface.hover(app, w, owner, e)}
	}
	tooltip_hover(app, w, owner, e)
}

// The pointer left the window: every surface drops its hover through its own leave.
pointer_leave :: proc(app: ^App, w: ^Window) {
	tooltip_cancel(w)
	for surface in pointer_surfaces {
		if surface.leave != nil {surface.leave(app, w)}
	}
	w.dirty = true
}

// The held drag, if any, follows the move.
pointer_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	for surface in pointer_surfaces {
		if surface.held == nil {continue}
		if held := surface.held(app, w, under, e); held != .Free {return held}
	}
	return .Free
}

pointer_press :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Button_Event) {
	if e.pressed {tooltip_cancel(w)}
	pointer_surfaces[owner].press(app, w, e)
}

pointer_release :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: input.Mouse_Button_Event,
) -> bool {
	release := pointer_surfaces[owner].release
	return release != nil && release(app, w, e)
}


@(private = "file")
notice_hit :: proc(app: ^App, w: ^Window, x, y: f32) -> ui.Notice_Hit {
	if app.notice_window != w.id {return {}}
	return ui.notices_hit(&app.notices, &w.ui_text, f32(w.width), f32(w.height), w.scale, x, y)
}

@(private = "file")
notice_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return notice_hit(app, w, x, y).contains
}

@(private = "file")
notice_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	// Only the window holding the notices has their hover to change.
	if app.notice_window != w.id {return}
	hit := owner == .Notice ? notice_hit(app, w, f32(e.x), f32(e.y)) : ui.Notice_Hit{}
	if ui.notices_hover(&app.notices, hit.close ? hit.id : 0) {w.dirty = true}
	if owner == .Notice {pointer_set(app, w, hit.close ? .Hand : .Arrow)}
}

@(private = "file")
notice_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	return notice_hit(app, w, x, y).close ? "Dismiss notification" : ""
}

@(private = "file")
notice_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button != .Left {return}
	hit := notice_hit(app, w, f32(e.x), f32(e.y))
	ui.notices_press(&app.notices, hit.close ? hit.id : 0)
}

// A notice press ends here even after the notices moved to another window, which cancelled it there.
@(private = "file")
notice_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if app.notice_window != w.id {return true}
	if e.button == .Left {
		hit := notice_hit(app, w, f32(e.x), f32(e.y))
		if ui.notices_release(&app.notices, hit.close ? hit.id : 0) {
			for window in app.windows {window.dirty = true}
		}
	}
	_ = ui.notices_hover(&app.notices, 0)
	w.dirty = true
	return true
}

@(private = "file")
notice_cancel :: proc(app: ^App, w: ^Window) {
	if app.notice_window == w.id {ui.notices_pointer_cancel(&app.notices)}
}

@(private = "file")
notice_leave :: proc(app: ^App, w: ^Window) {
	if app.notice_window == w.id {_ = ui.notices_hover(&app.notices, 0)}
}

// Dock edge menu

@(private = "file")
divider_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return dock_divider_menu_shown(w)}

@(private = "file")
divider_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Divider_Menu {return}
	x, y := f32(e.x), f32(e.y)
	hit := dock_divider_menu_hit(w, x, y)
	enabled := hit >= 0 && w.divider_menu.items[hit].enabled
	if enabled && hit != ui.menu_selected(&w.divider_menu) {
		ui.menu_select(&w.divider_menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private = "file")
divider_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Divider_Menu)
	if hit := dock_divider_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if w.divider_menu.items[hit].enabled {
			ui.menu_select(&w.divider_menu, hit)
			dock_divider_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}

// Caption buttons

@(private = "file")
caption_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return ui.caption_hit(f32(w.width), x, y, w.scale) != nil
}

@(private = "file")
caption_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	caption: Maybe(platform.Caption_Button)
	if owner == .Caption {caption = ui.caption_hit(f32(w.width), x, y, w.scale)}
	if caption != w.caption_hover {w.caption_hover, w.dirty = caption, true}
	if owner == .Caption {pointer_set(app, w, chrome_pointer(app, w, x, y))}
}

@(private = "file")
caption_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	button, hit := ui.caption_hit(f32(w.width), x, y, w.scale).?
	if !hit {return ""}
	switch button {
	case .Minimize: return "Minimize"
	case .Maximize: return w.maximized ? "Restore" : "Maximize"
	case .Close: return window_linked(w) ? "Return pane to tab" : "Close window"
	}
	return ""
}

@(private = "file")
caption_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button != .Left || drag_held(w) {return}
	ui.armed_press(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
}

@(private = "file")
caption_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.caption_armed) || drag_held(w) {
		return false
	}
	fired, ok := ui.armed_release(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
	w.dirty = true
	if button, has := fired.?; ok && has {platform.window_caption_action(&app.platform, w.id, button)}
	return true
}

@(private = "file")
caption_cancel :: proc(_: ^App, w: ^Window) {
	w.caption_hover = nil
	ui.armed_cancel(&w.caption_armed)
}

// Dividers

@(private = "file")
divider_claims :: proc(_: ^App, w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return false}
	if render.rect_contains(w.float_capsule_group, x, y) {return false}
	_, over := divider_cursor(w, x, y)
	return over
}

@(private = "file")
divider_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Divider {return}
	resize, _ := divider_cursor(w, f32(e.x), f32(e.y))
	pointer_set(app, w, resize)
}

@(private = "file")
divider_pointer_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button == .Left {_ = divider_press(app, w, f32(e.x), f32(e.y), e.time_ns)}
	if e.button == .Right {dock_divider_menu_open(app, w, f32(e.x), f32(e.y))}
}

@(private = "file")
divider_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	return e.button == .Left && divider_drag_release(app, w, f32(e.x), f32(e.y))
}

@(private = "file")
divider_pointer_cancel :: proc(_: ^App, w: ^Window) {
	divider_cancel(w)
}

// A held divider follows the pointer unless a modal surface opened over it; a move without Left ends
// the drag whose release was missed.
@(private = "file")
divider_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	if divider_dragging(w) == nil || pointer_modal(under) {return .Free}
	if .Left not_in e.buttons {divider_cancel(w); return .Taken}
	divider_drag(app, w, f32(e.x), f32(e.y))
	return .Taken
}

// Floating panes

@(private = "file")
floating_leave :: proc(_: ^App, w: ^Window) {
	floating_hover_clear(w)
}

@(private = "file")
floating_held :: proc(app: ^App, w: ^Window, _: Pointer_Target, e: input.Mouse_Move_Event) -> Pointer_Held {
	return floating_pointer_move(app, w, e) ? .Taken : .Free
}

// Pane headers, and a single pane's split controls, which show while the pointer is in the pane's top
// band and no surface above the pane covers it.

@(private = "file")
header_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, hit := pane_header_hit(w, x, y)
	return hit
}

@(private = "file")
header_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	in_pane := pointer_surfaces[owner].in_pane
	split_overlay_update(w, x, y, in_pane && !selection_active(w))
	over, action := pane_header_pointer(w, x, y, owner == .Pane_Header && !selection_active(w))
	if owner != .Pane_Header {return}
	pointer_set(app, w, over && action != .None && !gesture_swallowing(w) ? .Hand : .Arrow)
}

@(private = "file")
header_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	_, action, _ := pane_header_hit(w, x, y)
	return pane_header_tooltip(w, action)
}

// The header swallows its presses, so it also finishes a release that lands anywhere.
@(private = "file")
header_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if palette_active(app, w) {pane_header_cancel(w)}
	pane_header_release(app, w, e)
	return true
}

@(private = "file")
header_cancel :: proc(_: ^App, w: ^Window) {
	pane_header_cancel(w)
	w.split_overlay = false
}

// A pane drag follows the pointer once it has started, or while no modal surface is under it.
@(private = "file")
pane_drag_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	if _, pane := pane_drag_grab(w); !pane {return .Free}
	if drag_active(w) == nil && pointer_modal(under) {return .Free}
	if .Left not_in e.buttons {pane_drag_cancel(app, w); return .Ended}
	if !pane_drag_move(app, w, f32(e.x), f32(e.y), .Shift in e.modifiers) {return .Free}
	pointer_set(app, w, .Resize_All)
	return .Taken
}
