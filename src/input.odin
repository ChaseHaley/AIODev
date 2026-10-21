package main

import "core:log"
import "core:math"
import "core:time"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

@(private) TRAY_OPEN :: 1
@(private) TRAY_QUIT :: 2
@(private) WHEEL_LINES :: 3

@(private)
is_modifier_key :: proc(key: input.Key) -> bool {
	#partial switch key {
	case .Shift_Left, .Shift_Right, .Control_Left, .Control_Right, .Alt_Left, .Alt_Right,
	     .Meta_Left, .Meta_Right, .Caps_Lock, .Num_Lock:
		return true
	}
	return false
}

handle_event :: proc(app: ^App, event: platform.Event) {
	switch e in event {
	case platform.Key_Event:
		if w := window_find(app, e.window); w != nil {
			on_key(app, w, e)
		}
	case platform.Text_Event:
		if w := window_find(app, e.window); w != nil {
			on_text(app, w, e.text)
		}
	case platform.Mouse_Button_Event:
		if w := window_find(app, e.window); w != nil {
			on_mouse_button(app, w, e)
		}
	case platform.Mouse_Move_Event:
		if w := window_find(app, e.window); w != nil {
			on_mouse_move(app, w, e)
		}
	case platform.Mouse_Leave_Event:
		if w := window_find(app, e.window); w != nil {
			w.tab_hover = -1
			w.tab_pressed = false
			ui.editor_hover_clear(&w.editor)
			w.split_overlay = false
			for &view in w.views { view.header_hover, view.header_pressed = .None, .None }
			w.dirty = true
		}
	case platform.Mouse_Wheel_Event:
		if w := window_find(app, e.window); w != nil {
			on_wheel(app, w, e)
		}
	case platform.Resize_Event:
		if w := window_find(app, e.window); w != nil {
			if !w.preparing { arrange_cancel(app, w) }
			window_resize(app, w, e.width, e.height)
		}
	case platform.Dpi_Event:
		if w := window_find(app, e.window); w != nil {
			if !w.preparing { arrange_cancel(app, w) }
			window_set_dpi(app, w, e.dpi)
		}
	case platform.Focus_Event:
		if w := window_find(app, e.window); w != nil {
			on_focus(app, w, e.focused)
		}
	case platform.Capture_Lost_Event:
		if w := window_find(app, e.window); w != nil {
			arrange_cancel(app, w)
		}
	case platform.Close_Request_Event:
		if w := window_find(app, e.window); w != nil {
			if w.preparing { arrange_cancel(app, w) } else { hide_to_tray(app, w) }
		}
	case platform.Tray_Event, platform.Activate_Request_Event:
		show_window(app)
	case platform.Tray_Menu_Event:
		switch e.id {
		case TRAY_OPEN: show_window(app)
		case TRAY_QUIT: app.running = false
		}
	case platform.Settings_Event:
		refresh_animations(app)
	case platform.Wake_Event:
	}
}

show_window :: proc(app: ^App) {
	if len(app.windows) == 0 {
		workspace := app.workspaces[0]
		if len(workspace.tabs) == 0 && !tab_create(app, workspace) {
			notify(app, .Error, "Could not create a tab.")
			return
		}
		if !window_open(app, workspace) {
			notify(app, .Error, "Could not open the AIODev window.")
			return
		}
	}
	_ = window_activate(app, app.windows[0])
}

hide_to_tray :: proc(app: ^App, w: ^Window) {
	focus_leave(app, w)
	window_close(app, w)
	if len(app.windows) > 0 { return }
	if !app.tray_hint_shown {
		app.tray_hint_shown = true
		text := "Your shell keeps running. Click the tray icon to reopen AIODev, or use Quit to exit."
		if platform.tray_notify(&app.platform, "AIODev is still running", text) != .None {
			log.error("showing the tray notification failed")
		}
	}
}

@(private)
on_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if w.preparing { return }
	// Menus navigate by the layout's letters, so Ctrl+N and Ctrl+P match the palette on any layout.
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	if w.workspace_picker.open {
		if e.pressed { w.suppressed_key = e }
		workspace_picker_key(app, w, logical)
		return
	}
	if w.rename_open {
		if e.pressed { w.suppressed_key = e }
		rename_key(app, w, e)
		return
	}
	if w.tab_menu.open {
		if e.pressed { w.suppressed_key = e }
		tab_menu_key(app, w, logical)
		return
	}
	if suppressed, ok := w.suppressed_key.?; ok && !e.pressed && suppressed.key == e.key {
		w.suppressed_key = nil
		return
	}
	if e.pressed && e.key == .Escape && (w.pane_drag.active || w.tab_drag.active) {
		arrange_cancel(app, w)
		w.suppressed_key = e
		return
	}
	if w.close_confirm.open {
		pane_header_cancel(w)
		if e.pressed { w.suppressed_key = e }
		close_confirm_outcome(app, w, ui.confirm_key(&w.close_confirm, e))
		return
	}
	if !palette_active(app, w) && e.pressed &&
	   (e.key == .Context_Menu || e.key == .F10 && .Shift in e.modifiers) {
		bar := window_tab_bar(app, w)
		tab_menu_open(app, w, w.workspace.selected, bar.x+f32(w.workspace.selected)*bar.tab_width, bar.height)
		w.suppressed_key = e
		return
	}
	if palette_active(app, w) {
		pane_header_cancel(w)
		if e.pressed { w.suppressed_key = e }
		p := &app.palette
		switch clipboard_chord(logical) {
		case .Copy: clipboard_copy(app, ui.palette_selection(p))
		case .Cut:
			if clipboard_copy(app, ui.palette_selection(p)) { on_palette_outcome(app, w, ui.palette_cut(p, &app.registry), 0) }
		case .Paste:
			if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
				on_palette_outcome(app, w, ui.palette_paste(p, &app.registry, text), 0)
			}
		case .None:
			outcome, id := ui.palette_key(p, &app.registry, logical)
			on_palette_outcome(app, w, outcome, id)
		}
		return
	}
	if settings_active(w) {
		settings_key(app, w, e)
		return
	}
	entry := focused_session(app, w)
	if entry == nil {
		return
	}
	literal := false
	if e.pressed {
		if w.find.open && e.key == .Escape && w.leader_until == {} {
			w.suppressed_key = e
			find_close(w, entry)
			return
		}
		switch leader_key(app, w, e) {
		case .Consumed: return
		case .Literal: literal = true
		case .None:
			if action, found := shortcut_action(app, e); found {
				w.suppressed_key = e
				run_action(app, w, action)
				return
			}
		}
	}
	// The find bar has the keyboard: keys edit the query and none reach the shell.
	if w.find.open {
		outcome: ui.Find_Outcome
		switch clipboard_chord(logical) {
		case .Copy: clipboard_copy(app, ui.field_selected_text(&w.find.query))
		case .Cut:
			if clipboard_copy(app, ui.field_selected_text(&w.find.query)) { outcome = ui.find_text(&w.find, "") }
		case .Paste: paste_clipboard(app, w, entry)
		case .None: outcome = ui.find_key(&w.find, logical)
		}
		if outcome == .Closed {
			w.suppressed_key = e
		}
		on_find_outcome(w, entry, outcome)
		return
	}
	if e.pressed {
		if entry.status != .Running {
			if e.key == .Enter || e.key == .Numpad_Enter {
				w.suppressed_key = e
				session_restart(app, entry)
			}
			return
		}
		if !is_modifier_key(e.key) {
			if term.has_selection(entry.session) {
				term.clear_selection(entry.session)
			}
			paste_confirm_cancel(app, w)
			reset_blink(w)
		}
	}
	term.send_key(entry.session, e)
	// The leader's own release stays suppressed, so the shell receives the whole keystroke now.
	if literal {
		up := e
		up.pressed, up.repeat, up.text = false, false, ""
		term.send_key(entry.session, up)
	}
}

@(private)
on_text :: proc(app: ^App, w: ^Window, text: string) {
	if w.preparing { return }
	if w.workspace_picker.open { workspace_picker_text(app, w, text); return }
	if w.tab_menu.open { return }
	if w.rename_open { ui.field_text(&w.rename, text); w.dirty = true; return }
	if w.close_confirm.open { return }
	if palette_active(app, w) {
		on_palette_outcome(app, w, ui.palette_text(&app.palette, &app.registry, text), 0)
		return
	}
	if settings_active(w) {
		ui.editor_text(&w.editor, text)
		w.dirty = true
		return
	}
	if w.find.open {
		on_find_outcome(w, focused_session(app, w), ui.find_text(&w.find, text))
		return
	}
	if entry := focused_session(app, w); entry != nil && entry.status == .Running {
		term.send_text(entry.session, text)
		reset_blink(w)
	}
}

@(private)
close_confirm_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Confirm_Outcome) {
	switch outcome {
	case .None:
	case .Changed: w.dirty = true
	case .Cancel: close_confirm_finish(app, w, false)
	case .Accept: close_confirm_finish(app, w, true)
	}
}

@(private)
on_palette_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Outcome, id: commands.Command_Id) {
	switch outcome {
	case .None:
	case .Changed, .Closed:
		w.dirty = true
	case .Run:
		w.dirty = true
		run_action(app, w, Action(id))
	case .Open_Setting:
		w.dirty = true
		editor_open(app, w)
		if w.editor.open {
			ui.field_set(&w.editor.filter, "")
			ui.editor_filter(&w.editor)
		}
		if w.editor.open && ui.editor_select_key(&w.editor, app.palette.chosen) &&
		   ui.editor_row(&w.editor).kind != .Shortcut {
			w.editor.focus = .Control
		}
	}
}

@(private)
pane_at :: proc(app: ^App, w: ^Window, x, y: i32) -> ^Session_Entry {
	pane, found := layout.hit_test(w.panes[:], f32(x), f32(y))
	if w.selecting { return focused_session(app, w) }
	if !found { return nil }
	return session_find(app, pane.content.id)
}

@(private)
reports_mouse :: proc(entry: ^Session_Entry, modifiers: input.Modifiers) -> bool {
	return .Shift not_in modifiers && term.mouse_tracking(entry.session)
}

@(private)
on_mouse_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if w.preparing { return }
	if w.workspace_picker.open {
		p := &w.workspace_picker
		x, y := f32(e.x), f32(e.y)
		if !e.pressed { p.query.dragging = false; w.header_buttons -= {e.button}; return }
		w.header_buttons += {e.button}
		r, _ := workspace_picker_rect(w)
		if x < r.x || x >= r.x+r.width || y < r.y || y >= r.y+r.height {
			p.open, w.dirty = false, true
		} else if e.button == .Left {
			workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
		}
		return
	}
	if w.tab_menu.open {
		if !e.pressed { return }
		w.header_buttons += {e.button}
		if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
			if tab_menu_enabled(w, hit) {
				w.tab_menu.selected = hit
				tab_menu_choose(app, w)
			}
		} else { w.tab_menu.open, w.dirty = false, true }
		return
	}
	if w.rename_open {
		r, field := rename_rect(w), rename_field_rect(w)
		x, y := f32(e.x), f32(e.y)
		if !e.pressed { w.rename.dragging = false }
		if e.pressed {
			if x < r.x || x >= r.x+r.width || y < r.y || y >= r.y+r.height {
				rename_finish(app, w, false)
				w.header_buttons += {e.button}
			} else if e.button == .Left && x >= field.x && x < field.x+field.width &&
				y >= field.y && y < field.y+field.height {
				rename_pointer(app, w, x, true, .Shift in e.modifiers)
			}
		}
		return
	}
	caption := ui.caption_hit(f32(w.width), f32(e.x), f32(e.y), w.scale)
	if e.button == .Left && (caption >= 0 || w.caption_pressed >= 0) &&
	   !w.pane_drag.pressed && !w.tab_drag.pressed {
		if e.pressed { w.caption_pressed = caption } else {
			pressed := w.caption_pressed
			w.caption_pressed = -1
			if caption == pressed { platform.window_caption_action(&app.platform, w.id, caption) }
		}
		w.dirty = true
		return
	}
	if w.close_confirm.open {
		l := ui.confirm_layout(f32(w.width), f32(w.height), w.scale, w.close_confirm.extended)
		close_confirm_outcome(app, w, ui.confirm_mouse(&w.close_confirm, l, e.button, e.pressed, f32(e.x), f32(e.y)))
		return
	}
	w.tab_pressed = e.pressed && e.button == .Left &&
		window_tab_hit(w, window_tab_bar(app, w), f32(e.x), f32(e.y)) >= 0
	w.dirty = true
	if !e.pressed && e.button in w.header_buttons {
		if settings_active(w) || palette_active(app, w) { pane_header_cancel(w) }
		if pane_header_button(app, w, e) { return }
	}
	if palette_active(app, w) {
		p := &app.palette
		l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
		if e.button == .Left && !e.pressed { ui.palette_input_release(p) }
		if e.pressed && e.button == .Left && ui.palette_input_contains(l, f32(e.x), f32(e.y)) {
			on_palette_outcome(app, w, ui.palette_input_press(p, l, &w.ui_text, f32(e.x), w.scale,
				.Shift in e.modifiers), 0)
		} else if e.pressed {
			outcome, id := ui.palette_mouse_press(p, l, f32(e.x), f32(e.y))
			on_palette_outcome(app, w, outcome, id)
		}
		return
	}
	x, y := f32(e.x), f32(e.y)
	bar := window_tab_bar(app, w)
	if e.button == .Left && !e.pressed && w.tab_close_pressed >= 0 {
		index := w.tab_close_pressed
		w.tab_close_pressed = -1
		if window_tab_close_hit(w, bar, x, y) == index { tab_close_request(app, w, index) }
		return
	}
	if e.button == .Left && !e.pressed {
		if w.dragging.count > 0 { w.dragging = {}; return }
		if w.tab_drag.pressed { tab_drag_release(w); return }
		if settings_active(w) { editor_outcome(app, w, ui.editor_release(&w.editor)) }
		if w.selecting { selection_finish(app, w, x, y); return }
	}
	if y < bar.height {
		if e.pressed {
			if e.button == .Left && x >= 0 && x < bar.x { workspace_picker_open(app, w); return }
			index := window_tab_hit(w, bar, x, y)
			palette_x := bar.x+f32(bar.count)*bar.tab_width+bar.button_width
			if e.button == .Left && x >= palette_x && x < palette_x+bar.button_width {
				run_action(app, w, .Command_Palette)
			} else if e.button == .Left && window_tab_close_hit(w, bar, x, y) >= 0 {
				w.tab_close_pressed = index
			} else if index == bar.count && e.button == .Left { tab_new(app, w) }
			else if index >= 0 && index < bar.count {
				if e.button == .Right { tab_menu_open(app, w, index, x, y) }
				else if e.button == .Middle { tab_close_request(app, w, index) }
				else if e.button == .Left {
					tab_pointer_select(app, w, index, .Control in e.modifiers, .Shift in e.modifiers)
					tab_press(w, index, x, bar.tab_width, e.modifiers & {.Control, .Shift} != {})
				}
			}
		}
		return
	}
	if settings_active(w) {
		if e.button == .Left && e.pressed {
			editor_outcome(app, w, ui.editor_press(&w.editor, settings_layout(w), &w.ui_text, x, y,
				.Shift in e.modifiers))
		}
		return
	}
	if e.button == .Left && e.pressed && divider_press(app, w, x, y, e.time_ns) { return }
	if w.find.open && !w.selecting && ui.find_contains(f32(w.width), w.scale, x, y) {
		return
	}
	if pane_header_button(app, w, e) { return }
	if e.pressed && !w.selecting {
		if pane, found := layout.hit_test(w.panes[:], x, y); found { pane_focus(app, w, pane.node) }
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
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
		action: term.Mouse_Action = e.pressed ? .Press : .Release
		held := e.pressed ? input.Mouse_Buttons{e.button} : {}
		term.send_mouse(entry.session, action, e.button, held, e.modifiers, x, y)
	}
}

@(private)
on_mouse_move :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	if w.preparing { return }
	if w.workspace_picker.open {
		if w.workspace_picker.query.dragging && .Left in e.buttons {
			workspace_picker_pointer(app, w, f32(e.x), false, true)
		} else if hit := workspace_picker_hit(w, f32(e.x), f32(e.y)); hit >= 0 {
			w.workspace_picker.selected, w.dirty = hit, true
		}
		pointer_set(app, w, .Arrow)
		return
	}
	if w.tab_menu.open {
		if hit := tab_menu_hit(w, f32(e.x), f32(e.y)); tab_menu_enabled(w, hit) && hit != w.tab_menu.selected {
			w.tab_menu.selected, w.dirty = hit, true
		}
		pointer_set(app, w, .Arrow)
		return
	}
	if w.rename_open {
		field := rename_field_rect(w)
		x, y := f32(e.x), f32(e.y)
		inside := x >= field.x && x < field.x+field.width && y >= field.y && y < field.y+field.height
		if w.rename.dragging && .Left in e.buttons { rename_pointer(app, w, x, false, true) }
		pointer_set(app, w, inside ? .Text : .Arrow)
		return
	}
	x, y := f32(e.x), f32(e.y)
	caption := ui.caption_hit(f32(w.width), x, y, w.scale)
	if caption != w.caption_hover { w.caption_hover = caption; w.dirty = true }
	if w.close_confirm.open {
		if ui.confirm_hover(&w.close_confirm,
			ui.confirm_layout(f32(w.width), f32(w.height), w.scale, w.close_confirm.extended), x, y) {
			w.dirty = true
		}
		pointer_set(app, w, .Arrow)
		return
	}
	hover := window_tab_hit(w, window_tab_bar(app, w), x, y)
	if hover != w.tab_hover {
		w.tab_hover = hover
		w.dirty = true
	}
	if w.dragging.count > 0 {
		if .Left not_in e.buttons { w.dragging = {}; return }
		divider_drag(app, w, x, y)
		return
	}
	if w.tab_drag.pressed {
		if .Left not_in e.buttons { tab_drag_cancel(app, w) } else if tab_drag_move(app, w, x) { return }
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
		split_overlay_update(w, x, y, false)
		pane_header_pointer(w, x, y, false)
		l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		pointer_set(app, w, ui.palette_input_contains(l, x, y) ? .Text : .Arrow)
		if app.palette.query.dragging && .Left in e.buttons {
			on_palette_outcome(app, w, ui.palette_input_drag(&app.palette, l, &w.ui_text, x, w.scale), 0)
		} else {
			on_palette_outcome(app, w, ui.palette_mouse_move(&app.palette, l, x, y), 0)
		}
		return
	}
	if settings_active(w) {
		l := settings_layout(w)
		changed := ui.editor_hover(&w.editor, l, x, y)
		if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) { changed = true }
		if changed { w.dirty = true }
		over_text := y >= window_tab_bar(app, w).height && ui.editor_over_text(&w.editor, l, x, y)
		pointer_set(app, w, over_text ? .Text : .Arrow)
		return
	}
	enabled := !w.selecting && !(w.find.open && ui.find_contains(f32(w.width), w.scale, x, y))
	split_overlay_update(w, x, y, enabled)
	over_header := pane_header_pointer(w, x, y, enabled)
	shape: platform.Cursor_Shape = over_header || w.header_buttons != {} ? .Arrow : .Text
	bar := window_tab_bar(app, w)
	if y < bar.height { shape = .Arrow }
	if resize, found := divider_cursor(w, x, y); found && w.header_buttons == {} { shape = resize }
	pointer_set(app, w, shape)
	if over_header || w.header_buttons != {} { return }
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
		term.send_mouse(entry.session, .Motion, nil, e.buttons, e.modifiers, x, y)
	}
}

@(private)
on_wheel :: proc(app: ^App, w: ^Window, e: platform.Mouse_Wheel_Event) {
	if w.preparing { return }
	if w.workspace_picker.open {
		p := &w.workspace_picker
		p.selected = clamp(p.selected-int(math.sign(e.delta_y)), 0, workspace_picker_count(w)-1)
		w.dirty = true
		return
	}
	if w.rename_open { return }
	if w.tab_menu.open {
		tab_menu_step(w, -int(math.sign(e.delta_y)), false)
		w.dirty = true
		return
	}
	w.wheel_remainder += e.delta_y * WHEEL_LINES
	rows := int(w.wheel_remainder)
	if rows == 0 {
		return
	}
	w.wheel_remainder -= f32(rows)
	if w.close_confirm.open { return }
	if palette_active(app, w) {
		on_palette_outcome(app, w, ui.palette_scroll(&app.palette, int(math.sign(f32(rows)))), 0)
		return
	}
	if settings_active(w) {
		ui.editor_wheel(&w.editor, settings_layout(w), f32(e.x), f32(e.y), rows)
		w.dirty = true
		return
	}
	if _, _, header := pane_header_hit(w, f32(e.x), f32(e.y)); header { return }
	if entry := pane_at(app, w, e.x, e.y); entry != nil {
		term.scroll(entry.session, rows, e.modifiers, f32(e.x), f32(e.y))
		w.dirty = true
	}
}

@(private)
on_focus :: proc(app: ^App, w: ^Window, focused: bool) {
	w.focused = focused
	w.dirty = true
	if !focused {
		icon_input := w.workspace_picker.open && w.workspace_picker.icons
		window_overlays_cancel(app, w)
		// The OS emoji picker may take focus before delivering its text to the icon field.
		w.workspace_picker.open = icon_input
		pane_header_clear(w)
		w.tab_pressed = false
		w.tab_hover = -1
		w.tab_close_pressed = -1
		w.caption_hover, w.caption_pressed = -1, -1
		ui.editor_hover_clear(&w.editor)
		w.leader_until = {}
		w.selecting, w.autoscrolling = false, false
		w.split_overlay = false
		arrange_cancel(app, w)
		ui.editor_release(&w.editor)
	}
	if entry := focused_session(app, w); entry != nil { term.send_focus(entry.session, focused) }
}

@(private)
Clipboard_Chord :: enum { None, Copy, Cut, Paste }

// Clipboard chords for text fields, including the terminal's Ctrl+Shift forms.
@(private)
clipboard_chord :: proc(e: platform.Key_Event) -> Clipboard_Chord {
	if !e.pressed { return .None }
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	control := modifiers == {.Control} || modifiers == {.Control, .Shift}
	switch {
	case control && e.key == .C, modifiers == {.Control} && e.key == .Insert: return .Copy
	case control && e.key == .X, modifiers == {.Shift} && e.key == .Delete: return .Cut
	case control && e.key == .V, modifiers == {.Shift} && e.key == .Insert: return .Paste
	}
	return .None
}

@(private)
clipboard_copy :: proc(app: ^App, text: string) -> bool {
	if text == "" { return false }
	if !platform.clipboard_set_text(&app.platform, text) {
		notify(app, .Error, "Could not copy to the clipboard.")
		return false
	}
	return true
}

@(private)
leader_cancel :: proc(w: ^Window) {
	if w.leader_until != {} { w.dirty = true }
	w.leader_until = {}
}

// Literal: the leader was pressed twice, so the caller delivers that key to whatever has the keyboard.
@(private)
Leader_Result :: enum { None, Consumed, Literal }

// Every surface that takes keys calls this first, except while a shortcut field records keys.
@(private)
leader_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> Leader_Result {
	if !e.pressed || is_modifier_key(e.key) { return .None }
	if w.leader_until != {} {
		if leader, enabled := app.leader.?; enabled && e.repeat &&
		   commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) { return .Consumed }
		pending := time.tick_diff(time.tick_now(), w.leader_until) > 0
		leader_cancel(w)
		if pending {
			w.suppressed_key = e
			if leader, enabled := app.leader.?; enabled &&
			   commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) { return .Literal }
			if e.key == .Escape { return .Consumed }
			chord := e
			chord.modifiers += {.Leader}
			if action, found := shortcut_action(app, chord); found { run_action(app, w, action) }
			return .Consumed
		}
	}
	if leader, enabled := app.leader.?; enabled {
		if commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) {
			w.suppressed_key = e
			if !e.repeat {
				w.leader_until = time.tick_add(time.tick_now(), 2*time.Second)
				w.dirty = true
			}
			return .Consumed
		}
	}
	return .None
}

@(private)
selection_finish :: proc(app: ^App, w: ^Window, x, y: f32) {
	entry := focused_session(app, w)
	w.selecting, w.autoscrolling = false, false
	if entry == nil { return }
	term.selection_release(entry.session, x, y)
	if app.settings.terminal.copy_on_select { copy_selection(app, entry, false) }
	w.dirty = true
}

@(private)
pointer_set :: proc(app: ^App, w: ^Window, shape: platform.Cursor_Shape) {
	if shape == w.pointer_shape { return }
	if platform.window_set_cursor(&app.platform, w.id, shape) != .None {
		log.error("setting the pointer cursor failed")
	} else { w.pointer_shape = shape }
}
