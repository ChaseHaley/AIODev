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
	w.rail_resizing = false
	w.rename.dragging, w.workspace_picker.query.dragging = false, false
	link_hover_clear(w)
	if palette_active(app, w) {ui.palette_input_release(&app.palette)}
	ui.editor_hover_clear(&w.editor)
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
	x, y := f32(e.x), f32(e.y)
	if e.button == .Left && w.rail_resizing {
		rail_resize_move(app, w, x)
		w.rail_resizing = false
		return true
	}
	if e.button == .Left && w.find.open && ui.armed_down(w.find.armed) {
		entry := focused_session(app, w)
		l, enabled := find_controls(w, entry)
		on_find_outcome(w, entry, ui.find_mouse(&w.find, l, enabled, e.button, false, x, y))
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
		if e.button == .Left {ui.palette_input_release(&app.palette)}
		return true
	}
	if e.button != .Left {return false}
	if tab_interaction_release(app, w, x, y) {return true}
	if w.dragging.count > 0 {w.dragging = {}; return true}
	if w.tab_drag.pressed {tab_drag_release(app, w); rail_overlay_dismiss(app, w); return true}
	if w.pane_drag.pressed {_ = pane_drag_release(app, w); return true}
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
	caption := ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale)
	if e.button == .Left && caption >= 0 && !w.pane_drag.pressed && !w.tab_drag.pressed {
		ui.armed_press(&w.caption_armed, caption)
		w.dirty = true
		return
	}
	if confirmation_button(app, w, e) {return}
	w.dirty = true

	if palette_active(app, w) {
		p := &app.palette
		l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
		if e.pressed && e.button == .Left && ui.palette_input_contains(l, f32(e.x), f32(e.y)) {
			on_palette_outcome(
				app,
				w,
				ui.palette_input_press(
					p,
					l,
					&w.ui_text,
					f32(e.x),
					f32(e.y),
					w.scale,
					.Shift in e.modifiers,
				),
				0,
			)
		} else if e.pressed {
			outcome, id := ui.palette_mouse_press(p, &app.registry, l, f32(e.x), f32(e.y))
			on_palette_outcome(app, w, outcome, id)
		}
		return
	}
	x, y := f32(e.x), f32(e.y)

	if e.pressed && e.button == .Left && tab_orientation_button_hit(w, x, y) {
		ui.armed_press(&w.tab_orientation_button_armed, true)
		return
	}

	if w.find.open && !w.selecting {
		entry := focused_session(app, w)
		l, enabled := find_controls(w, entry)
		if ui.armed_down(w.find.armed) || ui.find_contains(l, x, y) {
			on_find_outcome(w, entry, ui.find_mouse(&w.find, l, enabled, e.button, e.pressed, x, y))
			return
		}
	}
	if e.pressed && e.button == .Left && y < ui.TITLE_BAR_HEIGHT * w.scale &&
	   x >= tab_orientation_button_rect(w).x + tab_orientation_button_rect(w).width &&
	   x < workspace_button_width(w) {
		workspace_picker_open(app, w)
		return
	}
	if e.button == .Left && rail_resize_hit(w, x, y) {
		w.rail_resizing = true
		w.rail_resize_offset = x - rail_width_pixels(w)
		pointer_set(app, w, .Resize_Horizontal)
		return
	}
	if tab_interaction_press(app, w, e) {return}
	if e.button == .Left && e.pressed && divider_press(app, w, x, y, e.time_ns) { return }
	if pane_header_button(app, w, e) { return }
	if e.pressed && !w.selecting {
		if pane, found := layout.hit_test(w.panes[:], x, y); found {pane_focus(app, w, pane.node)}
	}
	if settings_active(w) {
		if e.button == .Left && e.pressed {
			editor_outcome(
				app,
				w,
				ui.editor_press(
					&w.editor,
					settings_layout(w),
					&w.ui_text,
					x,
					y,
					.Shift in e.modifiers,
				),
			)
		}
		return
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
	}
	if e.button == .Left && e.pressed && !w.selecting && .Control in e.modifiers {
		if link_click(app, w, x, y) {
			return
		}
	}
	if e.button == .Left && (w.selecting || !reports_mouse(entry, e.modifiers)) {
		if e.pressed {
			w.selecting = true
			term.selection_press(entry.session, x, y, e.time_ns)
		}
		w.dirty = true
		return
	}
	if reports_mouse(entry, e.modifiers) {
		w.gesture.reported += {e.button}
		term.send_mouse(entry.session, .Press, e.button, {e.button}, e.modifiers, x, y)
	}
}

gesture_move :: proc(app: ^App, w: ^Window, event: platform.Mouse_Move_Event) {
	if w.preparing {return}
	e := event
	e.buttons -= w.gesture.cancelled
	if event.buttons != {} && e.buttons == {} {return}
	if workspace_picker_active(&w.workspace_picker) {
		link_hover_clear(w)
		workspace_picker_hover(app, w, e)
		return
	}
	if w.tab_menu.open {
		link_hover_clear(w)
		if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); tab_menu_enabled(w, hit) && hit != w.tab_menu.selected {
			w.tab_menu.selected, w.dirty = hit, true
		}
		pointer_set(app, w, .Arrow)
		return
	}
	if w.profile_menu.open {
		link_hover_clear(w)
		if hit := profile_menu_hit(w, f32(e.x), f32(e.y));
		   hit >= 0 && hit != w.profile_menu.menu.selected {
			w.profile_menu.menu.selected, w.dirty = hit, true
		}
		pointer_set(app, w, .Arrow)
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
	caption := ui.caption_hit(f32(w.width), x, y, w.scale)
	if caption != w.caption_hover {w.caption_hover = caption; w.dirty = true}
	if confirmation_hover(app, w, x, y) {return}
	toggle_hover := tab_orientation_button_hit(w, x, y)
	if toggle_hover != w.tab_orientation_button_hovered {
		w.tab_orientation_button_hovered, w.dirty = toggle_hover, true
	}
	rail_hover := -1
	rail_area_rect := rail_area(w)
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		hover := window_tab_hit(app, w, bar, x, y)
		chevron := tab_chevron_rect(app, w)
		if x >= chevron.x && x < chevron.x + chevron.width && y >= 0 && y < bar.height {
			hover = bar.count + 1
		}
		if hover != w.tab_hover {
			w.tab_hover = hover
			w.dirty = true
		}
	} else if rail_visible(w) &&
	   x >= rail_area_rect.x &&
	   x < rail_area_rect.x + rail_area_rect.width &&
	   y >= rail_area_rect.y &&
	   y < rail_area_rect.y + rail_area_rect.height {
		if layout, ok := rail_current_layout(w); ok {
			rail_hover = rail_tab_hit(w, layout, x, y)
			if rail_hover < 0 && ui.rail_footer_hit(layout, x, y) {
				rail_hover = ui.rail_profile_hit(layout, x, y) ? RAIL_PROFILE_ROW : RAIL_NEW_TAB_ROW
			}
		}
	}
	if rail_hover != w.rail_hover {
		w.rail_hover = rail_hover
		w.dirty = true
	}
	if w.dragging.count > 0 {
		if .Left not_in e.buttons {w.dragging = {}; return}
		divider_drag(app, w, x, y)
		return
	}
	if w.rail_resizing {
		if .Left not_in e.buttons {
			w.rail_resizing = false
		} else {
			rail_resize_move(app, w, x)
			pointer_set(app, w, .Resize_Horizontal)
			return
		}
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
	if palette_active(app, w) {
		link_hover_clear(w)
		split_overlay_update(w, x, y, false)
		pane_header_pointer(w, x, y, false)
		l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		pointer_set(app, w, ui.palette_over_text(l, x, y) ? .Text : .Arrow)
		if app.palette.query.dragging && .Left in e.buttons {
			on_palette_outcome(
				app,
				w,
				ui.palette_input_drag(&app.palette, l, &w.ui_text, x, w.scale),
				0,
			)
		} else {
			on_palette_outcome(app, w, ui.palette_mouse_move(&app.palette, l, x, y), 0)
		}
		return
	}
	if w.find.open && !w.selecting {
		l, available := find_controls(w, focused_session(app, w))
		if ui.find_hover(&w.find, l, available, x, y) { w.dirty = true }
		if ui.find_contains(l, x, y) || ui.armed_down(w.find.armed) {
			link_hover_clear(w)
			split_overlay_update(w, x, y, false)
			pane_header_pointer(w, x, y, false)
			pointer_set(app, w, ui.find_hit(l, x, y) == .None ? .Text : .Arrow)
			return
		}
	}
	if rail_resize_hit(w, x, y) {
		split_overlay_update(w, x, y, false)
		pane_header_pointer(w, x, y, false)
		link_hover_clear(w)
		pointer_set(app, w, .Resize_Horizontal)
		return
	}
	if rail_visible(w) &&
	   x >= rail_area_rect.x &&
	   x < rail_area_rect.x + rail_area_rect.width &&
	   y >= rail_area_rect.y &&
	   y < rail_area_rect.y + rail_area_rect.height {
		split_overlay_update(w, x, y, false)
		pane_header_pointer(w, x, y, false)
		pointer_set(app, w, .Arrow)
		return
	}
	enabled := !w.selecting
	split_overlay_update(w, x, y, enabled)
	over_header := pane_header_pointer(w, x, y, enabled)
	shape: platform.Cursor_Shape = over_header || w.header_buttons != {} ? .Arrow : .Text
	if y < ui.TITLE_BAR_HEIGHT * w.scale {shape = .Arrow}
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
			shape = ui.editor_over_text(&w.editor, l, x, y) ? .Text : .Arrow
			over_settings = true
		}
	}
	pointer_set(app, w, shape)
	if over_header || w.header_buttons != {} || over_settings {return}
	entry := pane_at(app, w, e.x, e.y)
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
