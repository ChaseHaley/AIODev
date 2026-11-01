package main

import "aio:platform"
import "aio:render"
import "aio:ui"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave.
Pointer_Target :: enum u8 {
	// Modal surfaces take the whole window, including presses and releases that began elsewhere.
	Workspace_Picker,
	Tab_Menu,
	Profile_Menu,
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
	// Pane headers and a single pane's floating split controls.
	Pane_Header,
	Scrollbar,
	// A settings page shown in a pane.
	Settings_Page,
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
	// completion for confirmations, swallowed buttons, the palette and pane content.
	release: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool,
}

@(rodata)
pointer_surfaces := [Pointer_Target]Pointer_Surface {
	.Workspace_Picker = {picker_claims, picker_hover, workspace_picker_button, nil},
	.Tab_Menu         = {tab_menu_claims, tab_menu_hover, tab_menu_button, nil},
	.Profile_Menu     = {profile_menu_claims, profile_menu_hover, profile_menu_press, nil},
	.Status_Inbox     = {inbox_claims, inbox_hover, status_inbox_button, nil},
	.Rename           = {rename_claims, rename_hover, rename_button, nil},
	.Caption          = {caption_claims, caption_hover, caption_press, caption_release},
	.Confirmation     = {confirmation_claims, confirmation_pointer_hover, confirmation_press, nil},
	.Palette          = {palette_claims, palette_hover, palette_press, nil},
	.Tab_Orientation  = {orientation_claims, orientation_hover, orientation_press, orientation_release},
	.Title_Action     = {
		title_action_claims, title_action_pointer_hover, title_action_press, title_action_release,
	},
	.Find             = {find_claims, find_pointer_hover, find_press, find_release},
	.Workspace_Button = {workspace_button_claims, workspace_button_hover, workspace_button_press, nil},
	.Status_Pill      = {pill_claims, pill_hover, pill_press, nil},
	.Divider          = {divider_claims, divider_hover, divider_pointer_press, divider_release},
	.Status_Panel     = {panel_claims, panel_hover, panel_press, panel_release},
	.Tabs             = {tabs_claims, tabs_hover, tabs_press, tabs_release},
	.Pane_Header      = {header_claims, header_hover, header_press, nil},
	.Scrollbar        = {scrollbar_claims, scrollbar_hover, scrollbar_press, scrollbar_release},
	.Settings_Page    = {settings_claims, settings_hover, content_press, nil},
	.Content          = {content_claims, content_hover, content_press, nil},
}

// The topmost surface whose area holds the point. Below the modal surfaces, callers handle presses
// and drags that already hold the pointer before acting on the answer.
pointer_target :: proc(app: ^App, w: ^Window, x, y: f32) -> Pointer_Target {
	for target in Pointer_Target {
		if pointer_surfaces[target].claims(app, w, x, y) {return target}
	}
	return .Content
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {return target <= .Rename}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	for surface in pointer_surfaces {
		if surface.hover != nil {surface.hover(app, w, owner, e)}
	}
}

pointer_press :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Button_Event) {
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

@(private)
rect_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

@(private = "file")
move_point :: proc(e: platform.Mouse_Move_Event) -> (f32, f32) {return f32(e.x), f32(e.y)}

// Workspace picker

@(private = "file")
picker_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return workspace_picker_active(&w.workspace_picker)
}

@(private = "file")
picker_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Workspace_Picker {workspace_picker_hover(app, w, e)}
}

// Tab menu

@(private = "file")
tab_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return w.tab_menu.open}

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
	w.header_buttons += {e.button}
	if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if tab_menu_enabled(w, hit) {
			w.tab_menu.selected = hit
			tab_menu_choose(app, w)
		}
	} else {w.tab_menu.open, w.dirty = false, true}
}

// Profile menu

@(private = "file")
profile_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return w.profile_menu.open}

@(private = "file")
profile_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Profile_Menu {return}
	x, y := move_point(e)
	shape := platform.Cursor_Shape.Arrow
	if hit := profile_menu_hit(w, x, y); hit >= 0 {
		if hit != w.profile_menu.menu.selected {w.profile_menu.menu.selected, w.dirty = hit, true}
		item := w.profile_menu.menu.items[hit]
		if item.enabled && !item.separator {shape = .Hand}
	}
	pointer_set(app, w, shape)
}

@(private = "file")
profile_menu_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = profile_menu_button(app, w, e)
}

// Activity inbox

@(private = "file")
inbox_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return w.status.inbox_open}

@(private = "file")
inbox_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Status_Inbox {status_inbox_move(app, w, f32(e.x), f32(e.y))}
}

// Rename field

@(private = "file")
rename_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return w.rename_open}

@(private = "file")
rename_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Rename {return}
	x, y := move_point(e)
	if w.rename.dragging && .Left in e.buttons {rename_pointer(app, w, x, false, true)}
	pointer_set(app, w, rect_contains(rename_field_rect(w), x, y) ? .Text : .Arrow)
}

// A press outside the field finishes the rename and is swallowed with its release.
@(private = "file")
rename_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if !e.pressed {w.rename.dragging = false; return}
	x, y := f32(e.x), f32(e.y)
	if !rect_contains(rename_rect(w), x, y) {
		rename_finish(app, w, false)
		w.header_buttons += {e.button}
	} else if e.button == .Left && rect_contains(rename_field_rect(w), x, y) {
		rename_pointer(app, w, x, true, .Shift in e.modifiers)
	}
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
caption_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button != .Left || w.pane_drag.pressed || w.tab_drag.pressed {return}
	ui.armed_press(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
}

@(private = "file")
caption_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.caption_armed) || w.pane_drag.pressed || w.tab_drag.pressed {
		return false
	}
	fired, ok := ui.armed_release(&w.caption_armed, ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale))
	w.dirty = true
	if ok {platform.window_caption_action(&app.platform, w.id, fired)}
	return true
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
	held := .Left in e.buttons
	switch {
	case held && ui.palette_slider_dragging(p):
		on_palette_outcome(app, w, ui.palette_slider_drag(p, l, x), 0)
	case held && ui.palette_edit_text_dragging(p):
		on_palette_outcome(app, w, ui.palette_edit_drag(p, l, &w.ui_text, x), 0)
	case held && p.query.dragging:
		on_palette_outcome(app, w, ui.palette_input_drag(p, l, &w.ui_text, x, w.scale), 0)
	case:
		on_palette_outcome(app, w, ui.palette_mouse_move(p, l, x, y), 0)
	}
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

// Find bar

@(private = "file")
find_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if !w.find.open {return false}
	l, _ := find_controls(w, focused_session(app, w))
	return ui.find_contains(l, x, y)
}

@(private = "file")
find_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner != .Find || !w.find.open {
		if w.find.hover != .None {w.find.hover, w.dirty = .None, true}
		if owner == .Find {pointer_set(app, w, .Arrow)}
		return
	}
	x, y := move_point(e)
	l, available := find_controls(w, focused_session(app, w))
	if ui.find_hover(&w.find, l, available, x, y) {w.dirty = true}
	pointer_set(app, w, ui.find_pointer(l, available, x, y))
}

@(private = "file")
find_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	entry := focused_session(app, w)
	l, enabled := find_controls(w, entry)
	on_find_outcome(app, w, entry, ui.find_mouse(&w.find, l, enabled, e.button, true, f32(e.x), f32(e.y)))
}

@(private = "file")
find_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !w.find.open || !ui.armed_down(w.find.armed) {return false}
	entry := focused_session(app, w)
	l, enabled := find_controls(w, entry)
	on_find_outcome(app, w, entry, ui.find_mouse(&w.find, l, enabled, e.button, false, f32(e.x), f32(e.y)))
	return true
}

// Workspace button

@(private = "file")
workspace_button_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return y >= 0 && y < ui.TITLE_BAR_HEIGHT * w.scale && x >= title_actions_end(w) &&
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
workspace_button_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {workspace_picker_open(app, w)}
}

// Activity pill

@(private = "file")
pill_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return status_rect_contains(status_pill_rect(app, w), x, y)
}

@(private = "file")
pill_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	hovered := owner == .Status_Pill
	if hovered != w.status.pill_hover {w.status.pill_hover, w.dirty = hovered, true}
	if hovered {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private = "file")
pill_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button == .Left {status_inbox_toggle(app, w)}
}

// Dividers

@(private = "file")
divider_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
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
}

@(private = "file")
divider_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || w.dragging.count == 0 {return false}
	divider_drag(app, w, f32(e.x), f32(e.y))
	w.dragging, w.rail_resizing = {}, false
	return true
}

// Activity panel

@(private = "file")
panel_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return status_panel_contains(app, w, x, y)}

@(private = "file")
panel_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Status_Panel {
		_ = status_overview_move(app, w, f32(e.x), f32(e.y))
		return
	}
	s := &w.status
	if s.hover_surface != .None || s.hover >= 0 || s.panel_side_hover {
		s.hover_surface, s.hover, s.panel_side_hover, w.dirty = .None, -1, false, true
	}
}

@(private = "file")
panel_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = status_panel_button(app, w, e)
}

@(private = "file")
panel_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.status.panel_side_armed) {return false}
	w.header_buttons -= {.Left}
	w.dirty = true
	side := status_rect_contains(status_panel_side_rect(app, w), f32(e.x), f32(e.y))
	_, ok := ui.armed_release(&w.status.panel_side_armed, side)
	if ok {status_panel_side_toggle(app)}
	return true
}

// Tab strip and rail

@(private = "file")
tabs_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return tab_interaction_hit(app, w, x, y, .Left).kind != .Outside
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
tabs_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = tab_interaction_press(app, w, e)
}

// A tab close fires on a matching release; a tab drag settles wherever it is released.
@(private = "file")
tabs_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	w.rail_pressed, w.tab_pressed, w.dirty = -1, false, true
	if tab_interaction_release(app, w, f32(e.x), f32(e.y)) {return true}
	if !w.tab_drag.pressed {return false}
	tab_drag_release(app, w)
	rail_overlay_dismiss(app, w)
	return true
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
	split_overlay_update(w, x, y, in_pane && !w.selecting)
	over, action := pane_header_pointer(w, x, y, owner == .Pane_Header && !w.selecting)
	if owner != .Pane_Header {return}
	pointer_set(app, w, over && action != .None && w.header_buttons == {} ? .Hand : .Arrow)
}

@(private = "file")
header_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	_ = pane_header_button(app, w, e)
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
	if e.button != .Left || !w.scroll_drag {return false}
	terminal_scrollbar_release(app, w, f32(e.x), f32(e.y))
	return true
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
		   p.hover_profile_item >= 0 {
			ui.editor_hover_clear(p)
			w.dirty = true
		}
		return
	}
	x, y := move_point(e)
	pane, found := settings_pane_under_pointer(w, x, y)
	if !found {
		pointer_set(app, w, .Arrow)
		return
	}
	l := settings_layout_for(w, pane.rect)
	changed := ui.editor_hover(&w.editor, l, x, y)
	if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) {changed = true}
	if changed {w.dirty = true}
	pointer_set(app, w, ui.editor_pointer(&w.editor, l, x, y))
}

// Terminal content

@(private = "file")
content_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return true}

@(private = "file")
content_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if owner == .Content {content_move(app, w, e)} else {link_hover_clear(w)}
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
