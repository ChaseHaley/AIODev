package main

import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:time"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave.
Pointer_Target :: enum u8 {
	Notice,
	// Modal surfaces take the whole window, including presses and releases that began elsewhere.
	Workspace_Picker,
	Tab_Menu,
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

// Everything a surface tells the pointer system. A new surface adds a target above and one entry here.
Pointer_Surface :: struct {
	// Whether the point lies on the surface while it is showing.
	claims:  proc(app: ^App, w: ^Window, x, y: f32) -> bool,
	// Runs for every surface on every move. The owner updates its hover and sets the cursor; every
	// other surface clears its own hover, cheaply when there is none.
	hover:   proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event),
	// A press the surface owns. A modal surface also receives every release while it is open.
	press:   proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event),
	// The release of a press the surface owned, wherever it lands; false passes it on to the shared
	// completion for confirmations, the palette and pane content. A release of a press the surface
	// swallowed ends there either way.
	release: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool,
	// The hovered control supplies a short label; the shared tooltip owns timing and drawing.
	tooltip: proc(app: ^App, w: ^Window, x, y: f32) -> string,
	// Capture loss: the surface drops its hover, armed control and drag, whether or not it holds a button.
	cancel:  proc(app: ^App, w: ^Window),
}

@(rodata)
pointer_surfaces := [Pointer_Target]Pointer_Surface {
	.Notice           = {
		notice_claims, notice_hover, notice_press, notice_release, notice_tooltip, notice_cancel,
	},
	.Workspace_Picker = {
		picker_claims, picker_hover, workspace_picker_button, nil, picker_tooltip, picker_cancel,
	},
	.Tab_Menu         = {tab_menu_claims, tab_menu_hover, tab_menu_button, nil, nil, nil},
	.Profile_Menu     = {profile_menu_claims, profile_menu_hover, profile_menu_press, nil, nil, nil},
	.Document_Menu    = {
		documents_claims, documents_hover, documents_press, nil, documents_tooltip, documents_cancel,
	},
	.Status_Inbox     = {inbox_claims, inbox_hover, status_inbox_button, nil, nil, nil},
	.Rename           = {rename_claims, rename_hover, rename_button, nil, nil, rename_cancel},
	.Caption          = {
		caption_claims, caption_hover, caption_press, caption_release, caption_tooltip, caption_cancel,
	},
	.Confirmation     = {
		confirmation_claims, confirmation_pointer_hover, confirmation_press, nil, nil, confirmation_cancel_press,
	},
	.Palette          = {palette_claims, palette_hover, palette_press, nil, palette_tooltip, palette_cancel},
	.Tab_Orientation  = {
		orientation_claims, orientation_hover, orientation_press, orientation_release, orientation_tooltip,
		orientation_cancel,
	},
	.Title_Action     = {
		title_action_claims, title_action_pointer_hover, title_action_press, title_action_release,
		title_action_tooltip, title_action_cancel,
	},
	.Find             = {find_claims, find_pointer_hover, find_press, find_release, find_tooltip, find_cancel},
	.Workspace_Button = {workspace_button_claims, workspace_button_hover, workspace_button_press, nil,
		workspace_button_tooltip, nil},
	.Status_Pill      = {pill_claims, pill_hover, pill_press, nil, pill_tooltip, nil},
	.Divider          = {
		divider_claims, divider_hover, divider_pointer_press, divider_release, nil, divider_pointer_cancel,
	},
	.Status_Panel     = {panel_claims, panel_hover, panel_press, panel_release, panel_tooltip, panel_cancel},
	.Tabs             = {tabs_claims, tabs_hover, tabs_press, tabs_release, tabs_tooltip, tabs_cancel},
	.Floating         = {
		floating_claims, floating_hover, floating_press, floating_release, floating_tooltip,
		floating_pointer_cancel,
	},
	.Pane_Header      = {
		header_claims, header_hover, pane_header_press, header_release, header_tooltip, header_cancel,
	},
	.Scrollbar        = {
		scrollbar_claims, scrollbar_hover, scrollbar_press, scrollbar_release, nil, scrollbar_cancel,
	},
	.Settings_Page    = {
		settings_claims, settings_hover, content_press, nil, settings_tooltip, settings_cancel,
	},
	.Markdown_Page    = {
		markdown_claims, markdown_hover, markdown_press, markdown_release, nil, markdown_gesture_clear,
	},
	.Content          = {content_claims, content_hover, content_press, nil, nil, content_cancel},
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
		if pointer_surfaces[target].claims(app, w, x, y) {return target}
	}
	return .Content
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {
	return target >= .Workspace_Picker && target <= .Rename
}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	for surface in pointer_surfaces {
		if surface.hover != nil {surface.hover(app, w, owner, e)}
	}
	tooltip_hover(app, w, owner, e)
}

pointer_press :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Button_Event) {
	if e.pressed {tooltip_cancel(w)}
	pointer_surfaces[owner].press(app, w, e)
}

pointer_release :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: platform.Mouse_Button_Event,
) -> bool {
	release := pointer_surfaces[owner].release
	return release != nil && release(app, w, e)
}

@(private = "file")
move_point :: proc(e: platform.Mouse_Move_Event) -> (f32, f32) {return f32(e.x), f32(e.y)}

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
notice_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
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
notice_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button != .Left {return}
	hit := notice_hit(app, w, f32(e.x), f32(e.y))
	ui.notices_press(&app.notices, hit.close ? hit.id : 0)
}

// A notice press ends here even after the notices moved to another window, which cancelled it there.
@(private = "file")
notice_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
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

// Workspace picker

@(private = "file")
picker_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return workspace_picker_active(&w.workspace_picker)
}

@(private = "file")
picker_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Workspace_Picker {workspace_picker_hover(app, w, e)}
}

@(private = "file")
picker_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	icons := workspace_picker_mode(&w.workspace_picker) == .Icons
	if icons && render.rect_contains(workspace_icon_color_button(w), x, y) {
		return "Change icon color"
	}
	return ""
}

@(private = "file")
picker_cancel :: proc(app: ^App, w: ^Window) {
	ui.field_release(&w.workspace_picker.query)
	workspace_order_end(w)
	_ = workspace_order_animate(w, app.animations, time.tick_now())
}

// Tab menu

@(private = "file")
tab_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return tab_menu_shown(w)}

@(private = "file")
tab_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Tab_Menu {return}
	x, y := move_point(e)
	hit := tab_menu_hit(w, x, y)
	enabled := tab_menu_enabled(w, hit)
	if enabled && hit != w.tab_menu.selected {w.tab_menu.selected, w.dirty = hit, true}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private = "file")
tab_menu_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Tab_Menu)
	if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if tab_menu_enabled(w, hit) {
			w.tab_menu.selected = hit
			tab_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}

// Profile menu

@(private = "file")
profile_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return profile_menu_shown(w)}

@(private = "file")
profile_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Profile_Menu {return}
	x, y := move_point(e)
	shape := platform.Cursor_Shape.Arrow
	if hit := profile_menu_hit(w, x, y); hit >= 0 {
		if hit != ui.menu_selected(&w.profile_menu.menu) {
			ui.menu_select(&w.profile_menu.menu, hit)
			w.dirty = true
		}
		item := w.profile_menu.menu.items[hit]
		if item.enabled && !item.separator {shape = .Hand}
	}
	pointer_set(app, w, shape)
}

@(private = "file")
profile_menu_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = profile_menu_button(app, w, e)
}

// Document menu

@(private = "file")
documents_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return document_menu_shown(w)}

@(private = "file")
documents_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Document_Menu {return}
	x, y := move_point(e)
	document_menu_hover(app, w, x, y, .Left in e.buttons)
}

@(private = "file")
documents_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	document_menu_button(app, w, e)
}

@(private = "file")
documents_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	return document_menu_tooltip(w, x, y)
}

@(private = "file")
documents_cancel :: proc(_: ^App, w: ^Window) {
	ui.field_release(&w.document_menu.url)
}

// Activity inbox

@(private = "file")
inbox_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return status_inbox_shown(w)}

@(private = "file")
inbox_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Status_Inbox {status_inbox_move(app, w, f32(e.x), f32(e.y))}
}

// Rename field

@(private = "file")
rename_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return rename_shown(w)}

@(private = "file")
rename_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Rename {return}
	x, y := move_point(e)
	if w.rename.dragging && .Left in e.buttons {rename_pointer(app, w, x, false, true)}
	pointer_set(app, w, render.rect_contains(rename_field_rect(w), x, y) ? .Text : .Arrow)
}

// A press outside the dialog finishes the rename and is swallowed with its release. The workspace chip
// field is not modal: the press leaves it, keeping the name typed so far when it can, and still reaches
// what it landed on.
@(private = "file")
rename_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if !e.pressed {ui.field_release(&w.rename); return}
	x, y := f32(e.x), f32(e.y)
	if chip_name_shown(w) && !render.rect_contains(rename_rect(w), x, y) {
		overlay_close(app, w, .Leave)
		target := pointer_target(app, w, x, y)
		gesture_hand_off(w, e.button, target)
		pointer_press(app, w, target, e)
		return
	}
	if !render.rect_contains(rename_rect(w), x, y) {
		rename_finish(app, w, false)
		gesture_swallow(w, e.button, .Rename)
	} else if e.button == .Left && render.rect_contains(rename_field_rect(w), x, y) {
		rename_pointer(app, w, x, true, .Shift in e.modifiers)
	}
}

@(private = "file")
rename_cancel :: proc(_: ^App, w: ^Window) {
	ui.field_release(&w.rename)
}

// Caption buttons

@(private = "file")
caption_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return ui.caption_hit(f32(w.width), x, y, w.scale) >= 0
}

@(private = "file")
caption_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := move_point(e)
	caption := owner == .Caption ? ui.caption_hit(f32(w.width), x, y, w.scale) : -1
	if caption != w.caption_hover {w.caption_hover, w.dirty = caption, true}
	if owner == .Caption {pointer_set(app, w, chrome_pointer(app, w, x, y))}
}

@(private = "file")
caption_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	switch ui.caption_hit(f32(w.width), x, y, w.scale) {
	case 0: return "Minimize"
	case 1: return w.maximized ? "Restore" : "Maximize"
	case 2: return window_linked(w) ? "Return pane to tab" : "Close window"
	case: return ""
	}
}

@(private = "file")
caption_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button != .Left || drag_held(w) {return}
	ui.armed_press(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
}

@(private = "file")
caption_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.caption_armed) || drag_held(w) {
		return false
	}
	fired, ok := ui.armed_release(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
	w.dirty = true
	if ok {platform.window_caption_action(&app.platform, w.id, fired)}
	return true
}

@(private = "file")
caption_cancel :: proc(_: ^App, w: ^Window) {
	w.caption_hover = -1
	ui.armed_cancel(&w.caption_armed)
}

// Confirmation

@(private = "file")
confirmation_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return confirmation_current(w) != nil}

@(private = "file")
confirmation_pointer_hover :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: platform.Mouse_Move_Event,
) {
	if owner == .Confirmation {_ = confirmation_hover(app, w, f32(e.x), f32(e.y))}
}

@(private = "file")
confirmation_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = confirmation_button(app, w, e)
}

@(private = "file")
confirmation_cancel_press :: proc(_: ^App, w: ^Window) {
	confirmation_release(w)
}

// Command palette

@(private = "file")
palette_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return palette_active(app, w)}

@(private = "file")
palette_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Palette {return}
	x, y := move_point(e)
	p := &app.palette
	l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
	pointer_set(app, w, ui.palette_pointer(p, l, x, y))
	on_palette_outcome(app, w, ui.palette_pointer_move(p, l, &w.ui_text, x, y, .Left in e.buttons), 0)
}

@(private = "file")
palette_tooltip :: proc(app: ^App, _: ^Window, _, _: f32) -> string {
	p := &app.palette
	return p.reset_hover >= 0 && ui.palette_editing(p) == .None ? "Reset setting" : ""
}

@(private = "file")
palette_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	p := &app.palette
	l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
	if e.button == .Left && ui.palette_input_contains(l, x, y) && !ui.palette_popup_contains(p, l, x, y) {
		outcome := ui.palette_input_press(p, l, &w.ui_text, x, y, w.scale, .Shift in e.modifiers)
		on_palette_outcome(app, w, outcome, 0)
		return
	}
	outcome, id := ui.palette_mouse_press(p, &app.registry, l, x, y, &w.ui_text)
	on_palette_outcome(app, w, outcome, id)
}

@(private = "file")
palette_cancel :: proc(app: ^App, w: ^Window) {
	if palette_active(app, w) {ui.palette_drag_cancel(&app.palette)}
}

// Tab orientation toggle

@(private = "file")
orientation_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return tab_orientation_button_hit(w, x, y)
}

@(private = "file")
orientation_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	hovered := owner == .Tab_Orientation
	if hovered != w.tab_orientation_button_hovered {w.tab_orientation_button_hovered, w.dirty = hovered, true}
	if hovered {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private = "file")
orientation_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	return w.tabs_horizontal ? "Show vertical tabs" : "Show horizontal tabs"
}

@(private = "file")
orientation_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {ui.armed_press(&w.tab_orientation_button_armed, true)}
}

@(private = "file")
orientation_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.tab_orientation_button_armed) {return false}
	hit := tab_orientation_button_hit(w, f32(e.x), f32(e.y))
	fired, ok := ui.armed_release(&w.tab_orientation_button_armed, hit)
	w.dirty = true
	if ok && fired {toggle_tab_orientation(app)}
	return true
}

@(private = "file")
orientation_cancel :: proc(_: ^App, w: ^Window) {
	w.tab_orientation_button_hovered = false
	ui.armed_cancel(&w.tab_orientation_button_armed)
}

// Find bar

@(private = "file")
find_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if !ui.find_is_open(&w.find) {return false}
	l, _ := find_controls(w, find_target(app, w))
	return ui.find_contains(l, x, y)
}

@(private = "file")
find_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Find || !ui.find_is_open(&w.find) {
		if w.find.hover != .None {w.find.hover, w.dirty = .None, true}
		if owner == .Find {pointer_set(app, w, .Arrow)}
		return
	}
	x, y := move_point(e)
	l, available := find_controls(w, find_target(app, w))
	if ui.find_hover(&w.find, l, available, x, y) {w.dirty = true}
	pointer_set(app, w, ui.find_pointer(l, available, x, y))
}

@(private = "file")
find_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	#partial switch w.find.hover {
	case .Case_Toggle: return "Match case"
	case .Regex_Toggle: return "Use regular expression"
	case .Older: return "Previous match"
	case .Newer: return "Next match"
	case .Close: return "Close find"
	case:
	}
	return ""
}

@(private = "file")
find_cancel :: proc(_: ^App, w: ^Window) {
	ui.armed_cancel(&w.find.armed)
	w.find.hover = .None
}

@(private = "file")
find_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	target := find_target(app, w)
	l, enabled := find_controls(w, target)
	on_find_outcome(app, w, target, ui.find_mouse(&w.find, l, enabled, e.button, true, f32(e.x), f32(e.y)))
}

@(private = "file")
find_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.find_is_open(&w.find) || !ui.armed_down(w.find.armed) {return false}
	target := find_target(app, w)
	l, enabled := find_controls(w, target)
	on_find_outcome(app, w, target, ui.find_mouse(&w.find, l, enabled, e.button, false, f32(e.x), f32(e.y)))
	return true
}

// Workspace button

@(private = "file")
workspace_button_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return y >= 0 && y < window_title_height(w) && x >= title_actions_end(w) &&
		x < workspace_button_width(w)
}

@(private = "file")
workspace_button_hover :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: platform.Mouse_Move_Event,
) {
	if owner == .Workspace_Button {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private = "file")
workspace_button_tooltip :: proc(_: ^App, _: ^Window, _, _: f32) -> string {return "Workspaces"}

@(private = "file")
workspace_button_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {workspace_picker_chip_press(app, w, e.time_ns)}
}

// Activity pill

@(private = "file")
pill_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return !floating_covers(w, x, y) && render.rect_contains(status_pill_rect(app, w), x, y)
}

@(private = "file")
pill_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	hovered := owner == .Status_Pill
	if hovered != w.status.pill_hover {w.status.pill_hover, w.dirty = hovered, true}
	if hovered {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private = "file")
pill_tooltip :: proc(_: ^App, _: ^Window, _, _: f32) -> string {return "Activity"}

@(private = "file")
pill_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {status_inbox_toggle(app, w)}
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
divider_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Divider {return}
	resize, _ := divider_cursor(w, f32(e.x), f32(e.y))
	pointer_set(app, w, resize)
}

@(private = "file")
divider_pointer_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {_ = divider_press(app, w, f32(e.x), f32(e.y), e.time_ns)}
	if e.button == .Right {dock_divider_menu_open(app, w, f32(e.x), f32(e.y))}
}

@(private = "file")
divider_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	return e.button == .Left && divider_drag_release(app, w, f32(e.x), f32(e.y))
}

@(private = "file")
divider_pointer_cancel :: proc(_: ^App, w: ^Window) {
	divider_cancel(w)
}

// Activity panel

@(private = "file")
panel_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return !floating_covers(w, x, y) && status_panel_contains(app, w, x, y)
}

@(private = "file")
panel_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Status_Panel {
		_ = status_overview_move(app, w, f32(e.x), f32(e.y))
		return
	}
	status_overview_leave(w)
}

@(private = "file")
panel_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	switch status_panel_button_at(app, w, x, y) {
	case .Side:
		return "Move activity panel"
	case .View:
		return app.settings.status.panel_view == .Comfy ? "Switch to Dense" : "Switch to Comfy"
	case .None:
	}
	return status_panel_row_tooltip(app, w, x, y)
}

@(private = "file")
panel_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = status_panel_button(app, w, e)
}

@(private = "file")
panel_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.status.panel_button_armed) {return false}
	w.dirty = true
	button := status_panel_button_at(app, w, f32(e.x), f32(e.y))
	if fired, ok := ui.armed_release(&w.status.panel_button_armed, button); ok {
		status_panel_button_fire(app, fired)
	}
	return true
}

@(private = "file")
panel_cancel :: proc(_: ^App, w: ^Window) {
	ui.armed_cancel(&w.status.panel_button_armed)
}

// Tab strip and rail

@(private = "file")
tabs_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return !floating_covers(w, x, y) && tab_interaction_hit(app, w, x, y, .Left).kind != .Outside
}

@(private = "file")
tabs_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := move_point(e)
	tab_hover, rail_hover := -1, -1
	if owner == .Tabs && w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		tab_hover = window_tab_hit(app, w, bar, x, y)
		chevron := tab_chevron_rect(app, w)
		if x >= chevron.x && x < chevron.x + chevron.width && y >= 0 && y < bar.height {
			tab_hover = bar.count + 1
		}
	} else if owner == .Tabs {
		if layout, ok := rail_current_layout(w); ok {
			rail_hover = rail_tab_hit(w, layout, x, y)
			if rail_hover < 0 && ui.rail_footer_hit(layout, x, y) {
				rail_hover = ui.rail_profile_hit(layout, x, y) ? RAIL_PROFILE_ROW : RAIL_NEW_TAB_ROW
			}
		}
	}
	if w.tabs_horizontal && tab_hover != w.tab_hover {w.tab_hover, w.dirty = tab_hover, true}
	if rail_hover != w.rail_hover {w.rail_hover, w.dirty = rail_hover, true}
	if owner == .Tabs {pointer_set(app, w, chrome_pointer(app, w, x, y))}
}

@(private = "file")
tabs_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if window_tab_close_hit(app, w, bar, x, y) >= 0 {return "Close tab"}
		if x >= tab_chevron_rect(app, w).x {return "Choose profile"}
		if window_tab_hit(app, w, bar, x, y) == bar.count {return "New tab"}
	} else if layout, ok := rail_current_layout(w); ok {
		if row := rail_tab_hit(w, layout, x, y); row >= 0 {
			close := rail_tab_close_rect(w, layout, row)
			if render.rect_contains(close, x, y) {return "Close tab"}
		}
		if ui.rail_footer_hit(layout, x, y) {
			if ui.rail_profile_hit(layout, x, y) {return "Choose profile"}
		}
	}
	return ""
}

@(private = "file")
tabs_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = tab_interaction_press(app, w, e)
}

// A tab close fires on a matching release; a tab drag settles wherever it is released.
@(private = "file")
tabs_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	w.dirty = true
	if tab_interaction_release(app, w, f32(e.x), f32(e.y)) {return true}
	if !tab_drag_held(w) {return false}
	tab_drag_finish(app, w)
	return true
}

@(private = "file")
tabs_cancel :: proc(_: ^App, w: ^Window) {
	w.tab_hover, w.rail_hover = -1, -1
	ui.armed_cancel(&w.tab_close_armed)
}

// Pane headers, and a single pane's split controls, which show while the pointer is in the pane's top
// band and no surface above the pane covers it.

@(private = "file")
header_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, hit := pane_header_hit(w, x, y)
	return hit
}

@(private = "file")
header_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := move_point(e)
	in_pane := owner == .Pane_Header || owner == .Scrollbar || owner == .Settings_Page || owner == .Content
	split_overlay_update(w, x, y, in_pane && !selection_active(w))
	over, action := pane_header_pointer(w, x, y, owner == .Pane_Header && !selection_active(w))
	if owner != .Pane_Header {return}
	pointer_set(app, w, over && action != .None && !gesture_swallowing(w) ? .Hand : .Arrow)
}

@(private = "file")
header_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	_, action, _ := pane_header_hit(w, x, y)
	#partial switch action {
	case .Documents: return "Documents"
	case .Split_Right: return "Split right"
	case .Split_Down: return "Split down"
	case .Zoom: return "Zoom"
	case .Fill_Window: return w.pane_fill == .Content ? "Exit fill window" : "Fill window"
	case .Linked_Window: return window_linked(w) ? "Return pane to tab" : "Move pane to linked window"
	case .Dock: return "Move to a float"
	case .Close: return "Close pane"
	case:
	}
	return ""
}

// The header swallows its presses, so it also finishes a release that lands anywhere.
@(private = "file")
header_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if palette_active(app, w) {pane_header_cancel(w)}
	pane_header_release(app, w, e)
	return true
}

@(private = "file")
header_cancel :: proc(_: ^App, w: ^Window) {
	pane_header_cancel(w)
	w.split_overlay = false
}

// Terminal scrollbars

@(private = "file")
scrollbar_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return terminal_scrollbar_at(app, w, x, y) != 0
}

@(private = "file")
scrollbar_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Scrollbar {
		terminal_scrollbar_hover_set(w, 0)
		return
	}
	terminal_scrollbar_hover_set(w, terminal_scrollbar_at(app, w, f32(e.x), f32(e.y)))
	pointer_set(app, w, .Arrow)
}

@(private = "file")
scrollbar_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = terminal_scrollbar_button(app, w, e)
}

@(private = "file")
scrollbar_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	return e.button == .Left && terminal_scrollbar_release(app, w, f32(e.x), f32(e.y))
}

@(private = "file")
scrollbar_cancel :: proc(_: ^App, w: ^Window) {
	terminal_scrollbar_cancel(w)
}

// Settings pages

@(private = "file")
settings_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, found := settings_pane_under_pointer(w, x, y)
	return found
}

@(private = "file")
settings_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Settings_Page {
		p := &w.editor
		if p.hover_item >= 0 || p.hover_reset >= 0 || p.hover_outline >= 0 || p.hover_clear ||
		   p.hover_profile_item >= 0 || p.popup_bar_hover {
			ui.editor_hover_clear(p)
			w.dirty = true
		}
		return
	}
	x, y := move_point(e)
	pane, found := settings_pane_under_pointer(w, x, y)
	if !found {
		// A held scrollbar follows the pointer anywhere, as it does on every other surface, and
		// collapses on release because the pointer is no longer over it.
		if w.editor.popup_bar_hover {w.editor.popup_bar_hover, w.dirty = false, true}
		if ui.editor_scrollbar_dragging(&w.editor) && .Left in e.buttons &&
		   ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y) {w.dirty = true}
		pointer_set(app, w, .Arrow)
		return
	}
	l := settings_layout_for(w, pane)
	changed := ui.editor_hover(&w.editor, l, x, y)
	if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) {changed = true}
	if changed {w.dirty = true}
	pointer_set(app, w, ui.editor_pointer(&w.editor, l, x, y))
}

@(private = "file")
settings_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	return w.editor.hover_reset >= 0 ? "Reset setting" : ""
}

@(private = "file")
settings_cancel :: proc(_: ^App, w: ^Window) {
	ui.editor_hover_clear(&w.editor)
	ui.editor_pointer_cancel(&w.editor)
}

// Terminal content

@(private = "file")
content_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return true}

@(private = "file")
content_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Content {content_move(app, w, e)} else {link_hover_clear(w)}
}

@(private = "file")
content_cancel :: proc(_: ^App, w: ^Window) {
	selection_cancel(w)
	link_hover_clear(w)
}

@(private = "file")
title_action_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return title_action_hit(w, x, y) != .None
}

@(private = "file")
title_action_pointer_hover :: proc(
	app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event,
) {
	hover := owner == .Title_Action ? title_action_hit(w, f32(e.x), f32(e.y)) : Title_Action.None
	if hover != w.title_action_hover {w.title_action_hover, w.dirty = hover, true}
	if hover != .None {pointer_set(app, w, .Hand)}
}

@(private = "file")
title_action_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	#partial switch title_action_hit(w, x, y) {
	case .Settings: return "Settings"
	case .Palette: return "Command palette"
	case:
	}
	return ""
}

@(private = "file")
title_action_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {ui.armed_press(&w.title_action_armed, title_action_hit(w, f32(e.x), f32(e.y)))}
}

@(private = "file")
title_action_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.title_action_armed) {return false}
	fired, ok := ui.armed_release(&w.title_action_armed, title_action_hit(w, f32(e.x), f32(e.y)))
	w.dirty = true
	if ok {
		switch fired {
		case .None:
		case .Settings: editor_open(app, w)
		case .Palette: palette_open(app, w)
		}
	}
	return true
}

@(private = "file")
title_action_cancel :: proc(_: ^App, w: ^Window) {
	w.title_action_hover = .None
	ui.armed_cancel(&w.title_action_armed)
}
