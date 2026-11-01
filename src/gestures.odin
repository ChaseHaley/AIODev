package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

Gesture_State :: struct {
	buttons, cancelled, reported: input.Mouse_Buttons,
}

@(private)
gesture_clear :: proc(app: ^App, w: ^Window) {
	w.gesture.cancelled += w.gesture.buttons | w.header_buttons
	if ui.armed_down(w.find.armed) || w.selecting || w.dragging.count > 0 || w.rail_resizing ||
	   w.tab_drag.pressed || w.pane_drag.pressed || ui.armed_down(w.tab_close_armed) ||
	   ui.armed_down(w.caption_armed) || ui.armed_down(w.tab_orientation_button_armed) ||
	   w.editor.drag != .None || w.rename.dragging || w.workspace_picker.query.dragging {
		w.gesture.cancelled += {.Left}
	}
	w.gesture.buttons, w.gesture.reported, w.header_buttons = {}, {}, {}
	ui.armed_cancel(&w.find.armed)
	confirmation_release(w)
	w.find.hover = .None
	pane_header_cancel(w)
	w.tab_hover, w.tab_pressed = -1, false
	w.rail_hover, w.rail_pressed = -1, -1
	w.tab_orientation_button_hovered = false
	ui.armed_cancel(&w.tab_orientation_button_armed)
	ui.armed_cancel(&w.tab_close_armed)
	w.caption_hover = -1
	ui.armed_cancel(&w.caption_armed)
	w.selecting, w.autoscrolling, w.split_overlay = false, false, false
	w.scroll_drag = false
	w.rail_resizing = false
	ui.armed_cancel(&w.status.panel_side_armed)
	w.rename.dragging, w.workspace_picker.query.dragging = false, false
	link_hover_clear(w)
	if palette_active(app, w) {
		ui.palette_input_release(&app.palette)
		if ui.palette_slider_dragging(&app.palette) {ui.palette_edit_cancel(&app.palette)}
	}
	ui.editor_hover_clear(&w.editor)
	if w.editor.drag == .Process_Order {w.editor.drag = .None}
	ui.editor_release(&w.editor)
	leader_cancel(w)
	w.dirty = true
}

// The result is the caller's permission to keep using w: cancelling a preview can remove it.
@(require_results)
gesture_cancel :: proc(app: ^App, w: ^Window) -> bool {
	id := w.id
	gesture_clear(app, w)
	arrange_cancel(app, w)
	return window_find(app, id) == w
}

// Completion never falls through to fresh hit testing, even when its action removes w.
@(private)
gesture_complete :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button == .Left && w.scroll_drag {terminal_scrollbar_release(app, w, f32(e.x), f32(e.y)); return true}
	x, y := f32(e.x), f32(e.y)
	if e.button == .Left && ui.armed_down(w.status.panel_side_armed) {
		w.header_buttons -= {.Left}
		w.dirty = true
		_, ok := ui.armed_release(&w.status.panel_side_armed,
			status_rect_contains(status_panel_side_rect(app, w), x, y))
		if ok {status_panel_side_toggle(app)}
		return true
	}
	if e.button == .Left && w.find.open && ui.armed_down(w.find.armed) {
		entry := focused_session(app, w)
		l, enabled := find_controls(w, entry)
		on_find_outcome(app, w, entry, ui.find_mouse(&w.find, l, enabled, e.button, false, x, y))
		return true
	}
	if e.button == .Left &&
	   ui.armed_down(w.tab_orientation_button_armed) {
		fired, ok := ui.armed_release(&w.tab_orientation_button_armed, tab_orientation_button_hit(w, x, y))
		w.dirty = true
		if ok && fired {toggle_tab_orientation(app)}
		return true
	}
	if e.button == .Left && ui.armed_down(w.caption_armed) && !w.pane_drag.pressed && !w.tab_drag.pressed {
		fired, ok := ui.armed_release(
			&w.caption_armed,
			ui.caption_hit(f32(w.width), x, y, w.scale),
		)
		w.dirty = true
		if ok {platform.window_caption_action(&app.platform, w.id, fired)}
		return true
	}
	if confirmation_button(app, w, e) {return true}
	w.rail_pressed, w.tab_pressed, w.dirty = -1, false, true
	if e.button in w.header_buttons {
		if palette_active(app, w) {pane_header_cancel(w)}
		return pane_header_button(app, w, e)
	}
	if palette_active(app, w) {
		if e.button == .Left {on_palette_outcome(app, w, ui.palette_pointer_release(&app.palette), 0)}
		return true
	}
	if e.button != .Left {return false}
	if tab_interaction_release(app, w, x, y) {return true}
	if w.dragging.count > 0 {
		divider_drag(app, w, x, y)
		w.dragging, w.rail_resizing = {}, false
		return true
	}
	if w.tab_drag.pressed {tab_drag_release(app, w); rail_overlay_dismiss(app, w); return true}
	if w.pane_drag.pressed {_ = pane_drag_release(app, w); return true}
	if w.editor.drag == .Process_Order {
		_ = ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y)
		editor_outcome(app, w, ui.editor_release(&w.editor))
		return true
	}
	if settings_active(w) {editor_outcome(app, w, ui.editor_release(&w.editor)); return true}
	if w.selecting {selection_finish(app, w, x, y); return true}
	return false
}

gesture_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if w.preparing {return}
	if e.pressed {
		w.gesture.cancelled -= {e.button}
		w.gesture.buttons += {e.button}
	} else {
		w.gesture.buttons -= {e.button}
		if e.button in w.gesture.cancelled {
			w.gesture.cancelled -= {e.button}
			return
		}
	}
	if workspace_picker_active(&w.workspace_picker) {
		workspace_picker_button(app, w, e)
		return
	}
	if w.tab_menu.open {
		if !e.pressed {return}
		w.header_buttons += {e.button}
		if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
			if tab_menu_enabled(w, hit) {
				w.tab_menu.selected = hit
				tab_menu_choose(app, w)
			}
		} else { w.tab_menu.open, w.dirty = false, true }
		return
	}
	if w.profile_menu.open {
		profile_menu_button(app, w, e)
		return
	}
	if w.status.inbox_open {
		status_inbox_button(app, w, e)
		return
	}
	if w.rename_open {
		r, field := rename_rect(w), rename_field_rect(w)
		x, y := f32(e.x), f32(e.y)
		if !e.pressed {w.rename.dragging = false}
		if e.pressed {
			if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
				rename_finish(app, w, false)
				w.header_buttons += {e.button}
			} else if e.button == .Left &&
			   x >= field.x &&
			   x < field.x + field.width &&
			   y >= field.y &&
			   y < field.y + field.height {
				rename_pointer(app, w, x, true, .Shift in e.modifiers)
			}
		}
		return
	}
	if !e.pressed {
		if gesture_complete(app, w, e) {return}
		if e.button in w.gesture.reported {
			w.gesture.reported -= {e.button}
			if entry := pane_at(app, w, e.x, e.y); entry != nil && reports_mouse(entry, e.modifiers) {
				term.send_mouse(entry.session, .Release, e.button, {}, e.modifiers, f32(e.x), f32(e.y))
			}
		}
		return
	}
	x, y := f32(e.x), f32(e.y)
	target := pointer_target(app, w, x, y)
	if ui.armed_down(w.find.armed) {target = .Find} else if w.selecting {target = .Content}
	w.dirty = true
	// A press below the find bar hands the keyboard back to the terminal; the bar and its matches stay.
	if target > .Find && w.find.focused {ui.find_blur(&w.find, &app.find_history)}
	left := e.button == .Left
	switch target {
	case .Caption:
		if left && !w.pane_drag.pressed && !w.tab_drag.pressed {
			ui.armed_press(&w.caption_armed, ui.caption_hit(f32(w.width), x, y, w.scale))
		}
	case .Confirmation:
		_ = confirmation_button(app, w, e)
	case .Palette:
		p := &app.palette
		l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
		if left && ui.palette_input_contains(l, x, y) && !ui.palette_popup_contains(p, l, x, y) {
			on_palette_outcome(
				app,
				w,
				ui.palette_input_press(p, l, &w.ui_text, x, y, w.scale, .Shift in e.modifiers),
				0,
			)
		} else {
			outcome, id := ui.palette_mouse_press(p, &app.registry, l, x, y, &w.ui_text)
			on_palette_outcome(app, w, outcome, id)
		}
	case .Tab_Orientation:
		if left {ui.armed_press(&w.tab_orientation_button_armed, true)}
	case .Find:
		entry := focused_session(app, w)
		l, enabled := find_controls(w, entry)
		on_find_outcome(app, w, entry, ui.find_mouse(&w.find, l, enabled, e.button, true, x, y))
	case .Workspace_Button:
		if left {workspace_picker_open(app, w)}
	case .Status_Pill:
		if left {status_inbox_toggle(app, w)}
	case .Divider:
		if left {_ = divider_press(app, w, x, y, e.time_ns)}
	case .Status_Panel:
		_ = status_panel_button(app, w, e)
	case .Tabs:
		_ = tab_interaction_press(app, w, e)
	case .Pane_Header:
		_ = pane_header_button(app, w, e)
	case .Scrollbar:
		_ = terminal_scrollbar_button(app, w, e)
	case .Content:
		content_press(app, w, e)
	}
}

// A press on pane content focuses the pane, then reaches a settings page, a link, the selection or a
// program that reports the mouse.
@(private)
content_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	if !w.selecting {
		if pane, found := layout.hit_test(w.panes[:], x, y); found {pane_focus(app, w, pane.node)}
	}
	if settings_active(w) {
		if e.button == .Left {
			editor_outcome(
				app,
				w,
				ui.editor_press(&w.editor, settings_layout(w), &w.ui_text, x, y, .Shift in e.modifiers),
			)
		}
		return
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
	}
	if e.button == .Left && !w.selecting && .Control in e.modifiers {
		if link_click(app, w, x, y) {
			return
		}
	}
	if e.button == .Left && (w.selecting || !reports_mouse(entry, e.modifiers)) {
		w.selecting = true
		term.selection_press(entry.session, x, y, e.time_ns)
		w.dirty = true
		return
	}
	if reports_mouse(entry, e.modifiers) {
		w.gesture.reported += {e.button}
		term.send_mouse(entry.session, .Press, e.button, {e.button}, e.modifiers, x, y)
	}
}

gesture_move :: proc(app: ^App, w: ^Window, event: platform.Mouse_Move_Event) {
	if w.scroll_drag {terminal_scrollbar_move(app, w, f32(event.y)); return}
	if w.preparing {return}
	e := event
	e.buttons -= w.gesture.cancelled
	if event.buttons != {} && e.buttons == {} {return}
	if workspace_picker_active(&w.workspace_picker) || w.tab_menu.open || w.profile_menu.open ||
	   w.status.inbox_open || w.rename_open {
		terminal_scrollbar_hover_set(w, 0)
	}
	if workspace_picker_active(&w.workspace_picker) {
		link_hover_clear(w)
		workspace_picker_hover(app, w, e)
		return
	}
	if w.tab_menu.open {
		link_hover_clear(w)
		hit := tab_menu_hit(w, f32(e.x), f32(e.y))
		enabled := tab_menu_enabled(w, hit)
		if enabled && hit != w.tab_menu.selected {
			w.tab_menu.selected, w.dirty = hit, true
		}
		pointer_set(app, w, enabled ? .Hand : .Arrow)
		return
	}
	if w.profile_menu.open {
		link_hover_clear(w)
		shape := platform.Cursor_Shape.Arrow
		if hit := profile_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 {
			if hit != w.profile_menu.menu.selected {w.profile_menu.menu.selected, w.dirty = hit, true}
			item := w.profile_menu.menu.items[hit]
			if item.enabled && !item.separator {shape = .Hand}
		}
		pointer_set(app, w, shape)
		return
	}
	if w.status.inbox_open {
		link_hover_clear(w)
		status_inbox_move(app, w, f32(e.x), f32(e.y))
		return
	}
	if w.rename_open {
		link_hover_clear(w)
		field := rename_field_rect(w)
		x, y := f32(e.x), f32(e.y)
		inside :=
			x >= field.x && x < field.x + field.width && y >= field.y && y < field.y + field.height
		if w.rename.dragging && .Left in e.buttons {rename_pointer(app, w, x, false, true)}
		pointer_set(app, w, inside ? .Text : .Arrow)
		return
	}
	x, y := f32(e.x), f32(e.y)
	if w.dragging.count > 0 {
		if .Left not_in e.buttons {w.dragging, w.rail_resizing = {}, false; return}
		divider_drag(app, w, x, y)
		return
	}
	if w.tab_drag.pressed {
		if .Left not_in e.buttons {tab_drag_cancel(app, w)} else if tab_drag_move(app, w, x, y) {return}
	}
	if w.pane_drag.pressed {
		if .Left not_in e.buttons {
			pane_drag_cancel(app, w)
		} else if pane_drag_move(app, w, x, y, .Shift in e.modifiers) {
			pointer_set(app, w, .Resize_All)
			return
		}
	}
	target := pointer_target(app, w, x, y)
	// A press that began on a surface keeps the pointer there until it is released.
	if ui.armed_down(w.find.armed) {
		target = .Find
	} else if w.selecting || w.header_buttons != {} || w.editor.drag != .None || w.gesture.reported != {} {
		target = .Content
	}
	pointer_hover(app, w, target, x, y)
	switch target {
	case .Caption, .Tab_Orientation, .Workspace_Button, .Status_Pill, .Tabs:
		pointer_set(app, w, chrome_pointer(app, w, x, y))
	case .Confirmation:
		_ = confirmation_hover(app, w, x, y)
	case .Palette:
		l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		pointer_set(app, w, ui.palette_pointer(&app.palette, l, x, y))
		if ui.palette_slider_dragging(&app.palette) && .Left in e.buttons {
			on_palette_outcome(app, w, ui.palette_slider_drag(&app.palette, l, x), 0)
		} else if ui.palette_edit_text_dragging(&app.palette) && .Left in e.buttons {
			on_palette_outcome(app, w, ui.palette_edit_drag(&app.palette, l, &w.ui_text, x), 0)
		} else if app.palette.query.dragging && .Left in e.buttons {
			on_palette_outcome(
				app,
				w,
				ui.palette_input_drag(&app.palette, l, &w.ui_text, x, w.scale),
				0,
			)
		} else {
			on_palette_outcome(app, w, ui.palette_mouse_move(&app.palette, l, x, y), 0)
		}
	case .Find:
		l, available := find_controls(w, focused_session(app, w))
		pointer_set(app, w, ui.find_pointer(l, available, x, y))
	case .Divider:
		resize, _ := divider_cursor(w, x, y)
		pointer_set(app, w, resize)
	case .Status_Panel:
	// `pointer_hover` already gave the panel the pointer and set its cursor.
	case .Scrollbar:
		pointer_set(app, w, .Arrow)
	case .Pane_Header, .Content:
		content_move(app, w, e)
	}
}

// Tells every surface whether it owns the pointer, so hover leaves each surface the owner covers.
// Pane headers, links and settings pages under `.Pane_Header` or `.Content` update in `content_move`.
@(private)
pointer_hover :: proc(app: ^App, w: ^Window, target: Pointer_Target, x, y: f32) {
	caption := target == .Caption ? ui.caption_hit(f32(w.width), x, y, w.scale) : -1
	if caption != w.caption_hover {w.caption_hover, w.dirty = caption, true}
	toggle := target == .Tab_Orientation
	if toggle != w.tab_orientation_button_hovered {w.tab_orientation_button_hovered, w.dirty = toggle, true}
	tab_hover, rail_hover := -1, -1
	if target == .Tabs && w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		tab_hover = window_tab_hit(app, w, bar, x, y)
		chevron := tab_chevron_rect(app, w)
		if x >= chevron.x && x < chevron.x + chevron.width && y >= 0 && y < bar.height {
			tab_hover = bar.count + 1
		}
	} else if target == .Tabs {
		if layout, ok := rail_current_layout(w); ok {
			rail_hover = rail_tab_hit(w, layout, x, y)
			if rail_hover < 0 && ui.rail_footer_hit(layout, x, y) {
				rail_hover = ui.rail_profile_hit(layout, x, y) ? RAIL_PROFILE_ROW : RAIL_NEW_TAB_ROW
			}
		}
	}
	if w.tabs_horizontal && tab_hover != w.tab_hover {w.tab_hover, w.dirty = tab_hover, true}
	if rail_hover != w.rail_hover {w.rail_hover, w.dirty = rail_hover, true}
	// Points off every surface clear the hovers of surfaces that hit test the point themselves.
	off :: [2]f32{-1, -1}
	if w.find.open {
		at := target == .Find ? [2]f32{x, y} : off
		l, available := find_controls(w, focused_session(app, w))
		if ui.find_hover(&w.find, l, available, at.x, at.y) {w.dirty = true}
	}
	status := target == .Status_Panel || target == .Status_Pill ? [2]f32{x, y} : off
	_ = status_overview_move(app, w, status.x, status.y)
	terminal_scrollbar_hover_set(w, target == .Scrollbar ? terminal_scrollbar_at(app, w, x, y) : 0)
	if target != .Pane_Header && target != .Content {
		link_hover_clear(w)
		// A single pane's split controls still appear while the pointer crosses its scrollbar.
		split_overlay_update(w, x, y, target == .Scrollbar)
		pane_header_pointer(w, x, y, false)
	}
}

// Moves over pane content and pane headers: header buttons, links, settings pages, the selection and
// programs that report the mouse.
@(private)
content_move :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	enabled := !w.selecting
	split_overlay_update(w, x, y, enabled)
	over_header, header_action := pane_header_pointer(w, x, y, enabled)
	shape: platform.Cursor_Shape = over_header || w.header_buttons != {} ? .Arrow : .Text
	if over_header && header_action != .None && w.header_buttons == {} {shape = .Hand}
	if y < ui.TITLE_BAR_HEIGHT * w.scale {
		shape = w.header_buttons == {} ? chrome_pointer(app, w, x, y) : .Arrow
	}
	entry := pane_at(app, w, e.x, e.y)
	if shape == .Text && entry == nil && !w.selecting {shape = .Arrow}
	resize, over_divider := divider_cursor(w, x, y)
	if over_divider && w.header_buttons == {} {shape = resize}
	link_hovered := false
	if enabled && !over_header && !over_divider && w.header_buttons == {} &&
	   y >= ui.TITLE_BAR_HEIGHT * w.scale {
		link_hovered = link_hover_update(app, w, x, y)
	} else {
		link_hover_clear(w)
	}
	if link_hovered {shape = .Hand}
	over_settings := false
	if enabled && !over_header && w.header_buttons == {} && !over_divider {
		if pane, found := settings_pane_under_pointer(w, x, y); found {
			l := settings_layout_for(w, pane.rect)
			changed := ui.editor_hover(&w.editor, l, x, y)
			if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) {changed = true}
			if changed {w.dirty = true}
			shape = ui.editor_pointer(&w.editor, l, x, y)
			over_settings = true
		}
	}
	pointer_set(app, w, shape)
	if over_header || w.header_buttons != {} || over_settings {return}
	if entry == nil {
		return
	}
	if w.selecting {
		term.selection_drag(entry.session, x, y)
		w.pointer = {x, y}
		autoscroll_follow(w, entry)
		w.dirty = true
	} else if reports_mouse(entry, e.modifiers) {
		held := e.buttons & w.gesture.reported
		if e.buttons != {} && held == {} {return}
		term.send_mouse(entry.session, .Motion, nil, held, e.modifiers, x, y)
	}
}

@(private)
selection_finish :: proc(app: ^App, w: ^Window, x, y: f32) {
	entry := focused_session(app, w)
	w.selecting, w.autoscrolling = false, false
	if entry == nil {return}
	term.selection_release(entry.session, x, y)
	if app.settings.terminal.copy_on_select {copy_selection(app, entry, false)}
	w.dirty = true
}
