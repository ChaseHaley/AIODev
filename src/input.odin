package main

import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"
import "core:log"
import "core:math"
import "core:time"

@(private)
TRAY_OPEN :: 1
@(private)
TRAY_QUIT :: 2
@(private)
WHEEL_LINES :: 3

@(private)
is_modifier_key :: proc(key: input.Key) -> bool {
	#partial switch key {
	case .Shift_Left,
	     .Shift_Right,
	     .Control_Left,
	     .Control_Right,
	     .Alt_Left,
	     .Alt_Right,
	     .Meta_Left,
	     .Meta_Right,
	     .Caps_Lock,
	     .Num_Lock:
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
			gesture_button(app, w, e)
		}
	case platform.Mouse_Move_Event:
		if w := window_find(app, e.window); w != nil {
			x, y := f32(e.x), f32(e.y)
			w.pointer = {x, y}
			if hovered := workspace_rect_contains(workspace_button_rect(w), x, y);
			   hovered != w.workspace_hovered {
				w.workspace_hovered, w.dirty = hovered, true
			}
			gesture_move(app, w, e)
		}
	case platform.Mouse_Leave_Event:
		if w := window_find(app, e.window); w != nil {
			w.find.hover = .None
			w.tab_hover = -1
			w.tab_pressed = false
			w.workspace_hovered = false
			w.workspace_picker.menu_hover = 0
			ui.editor_hover_clear(&w.editor)
			w.split_overlay = false
			for &view in w.views {
				view.header_hover = .None
				ui.armed_cancel(&view.header_armed)
			}
			w.dirty = true
		}
	case platform.Mouse_Wheel_Event:
		if w := window_find(app, e.window); w != nil {
			on_wheel(app, w, e)
		}
	case platform.Resize_Event:
		if w := window_find(app, e.window); w != nil {
			if !w.preparing && !gesture_cancel(app, w) {return}
			window_resize(app, w, e.width, e.height)
		}
	case platform.Dpi_Event:
		if w := window_find(app, e.window); w != nil {
			if !w.preparing && !gesture_cancel(app, w) {return}
			window_set_dpi(app, w, e.dpi)
		}
	case platform.Focus_Event:
		if w := window_find(app, e.window); w != nil {
			on_focus(app, w, e.focused)
		}
	case platform.Capture_Lost_Event:
		if w := window_find(app, e.window); w != nil {
			_ = gesture_cancel(app, w)
		}
	case platform.Close_Request_Event:
		if w := window_find(app, e.window); w != nil {
			if w.preparing {_ = gesture_cancel(app, w)} else {hide_to_tray(app, w)}
		}
	case platform.Tray_Event, platform.Activate_Request_Event:
		show_window(app)
	case platform.Tray_Menu_Event:
		switch e.id {
		case TRAY_OPEN:
			show_window(app)
		case TRAY_QUIT:
			app.running = false
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
	if len(app.windows) > 0 {return}
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
	if w.preparing {return}
	// Menus navigate by the layout's letters, so Ctrl+N and Ctrl+P match the palette on any layout.
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	if workspace_picker_active(&w.workspace_picker) {
		if e.pressed {w.suppressed_key = e}
		workspace_picker_key(app, w, logical)
		return
	}
	if w.rename_open {
		if e.pressed {w.suppressed_key = e}
		rename_key(app, w, e)
		return
	}
	if w.tab_menu.open {
		if e.pressed {w.suppressed_key = e}
		tab_menu_key(app, w, logical)
		return
	}
	if w.profile_menu.open {
		if e.pressed {w.suppressed_key = e}
		profile_menu_key(app, w, logical)
		return
	}
	if suppressed, ok := w.suppressed_key.?; ok && !e.pressed && suppressed.key == e.key {
		w.suppressed_key = nil
		return
	}
	if e.pressed && e.key == .Escape && (w.pane_drag.active || w.tab_drag.active) {
		w.suppressed_key = e
		_ = gesture_cancel(app, w)
		return
	}
	if w.pending_close.confirm.open {
		pane_header_cancel(w)
		if e.pressed {w.suppressed_key = e}
		pending_close_outcome(app, w, ui.confirm_key(&w.pending_close.confirm, e))
		return
	}
	if w.pending_swap.confirm.open {
		pane_header_cancel(w)
		if e.pressed {w.suppressed_key = e}
		pane_swap_outcome(app, w, ui.confirm_key(&w.pending_swap.confirm, e))
		return
	}
	if !palette_active(app, w) &&
	   e.pressed &&
	   (e.key == .Context_Menu || e.key == .F10 && .Shift in e.modifiers) {
		bar := window_tab_bar(app, w)
		tab_menu_open(
			app,
			w,
			w.workspace.selected,
			bar.x + f32(w.workspace.selected) * bar.tab_width,
			bar.height,
		)
		w.suppressed_key = e
		return
	}
	if palette_active(app, w) {
		pane_header_cancel(w)
		if e.pressed {w.suppressed_key = e}
		p := &app.palette
		switch clipboard_chord(logical) {
		case .Copy:
			clipboard_copy(app, ui.palette_selection(p))
		case .Cut:
			if clipboard_copy(
				app,
				ui.palette_selection(p),
			) {on_palette_outcome(app, w, ui.palette_cut(p, &app.registry), 0)}
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
		case .Consumed:
			return
		case .Literal:
			literal = true
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
		case .Copy:
			clipboard_copy(app, ui.field_selected_text(&w.find.query))
		case .Cut:
			if clipboard_copy(
				app,
				ui.field_selected_text(&w.find.query),
			) {outcome = ui.find_text(&w.find, "")}
		case .Paste:
			paste_clipboard(app, w, entry)
		case .None:
			outcome = ui.find_key(&w.find, logical)
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
	if w.preparing {return}
	if workspace_picker_active(&w.workspace_picker) {workspace_picker_text(app, w, text); return}
	if w.tab_menu.open {return}
	if w.profile_menu.open {return}
	if w.rename_open {ui.field_text(&w.rename, text); w.dirty = true; return}
	if w.pending_close.confirm.open {return}
	if w.pending_swap.confirm.open {return}
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
pending_close_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Confirm_Outcome) {
	switch outcome {
	case .None:
	case .Changed:
		w.dirty = true
	case .Cancel:
		pending_close_finish(app, w, false)
	case .Accept:
		pending_close_finish(app, w, true)
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
		settings_reveal(app, w, {key = app.palette.chosen, search = .Clear, focus = .Control})
	}
}

@(private)
pane_at :: proc(app: ^App, w: ^Window, x, y: i32) -> ^Session_Entry {
	pane, found := layout.hit_test(w.panes[:], f32(x), f32(y))
	if w.selecting {return focused_session(app, w)}
	if !found {return nil}
	return session_find(app, pane.content.id)
}

@(private)
reports_mouse :: proc(entry: ^Session_Entry, modifiers: input.Modifiers) -> bool {
	return .Shift not_in modifiers && term.mouse_tracking(entry.session)
}

@(private)
on_wheel :: proc(app: ^App, w: ^Window, e: platform.Mouse_Wheel_Event) {
	if w.preparing {return}
	if workspace_picker_active(&w.workspace_picker) {
		workspace_picker_wheel(w, e.delta_y)
		return
	}
	if w.rename_open {return}
	if w.tab_menu.open {
		tab_menu_step(w, -int(math.sign(e.delta_y)), false)
		w.dirty = true
		return
	}
	if w.profile_menu.open {
		ui.menu_wheel(&w.profile_menu.menu, int(math.sign(e.delta_y)))
		w.dirty = true
		return
	}
	w.wheel_remainder += e.delta_y * WHEEL_LINES
	rows := int(w.wheel_remainder)
	if rows == 0 {
		return
	}
	w.wheel_remainder -= f32(rows)
	if w.pending_close.confirm.open {return}
	if w.pending_swap.confirm.open {return}
	if palette_active(app, w) {
		on_palette_outcome(app, w, ui.palette_scroll(&app.palette, int(math.sign(f32(rows)))), 0)
		return
	}
	if pane, found := settings_pane_under_pointer(w, f32(e.x), f32(e.y)); found {
		ui.editor_wheel(
			&w.editor,
			settings_layout_for(w, pane.rect),
			f32(e.x),
			f32(e.y),
			rows,
		)
		w.dirty = true
		return
	}
	if _, _, header := pane_header_hit(w, f32(e.x), f32(e.y)); header {return}
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
		if !gesture_cancel(app, w) {return}
		window_overlays_cancel(app, w, true)
	}
	if entry := focused_session(app, w); entry != nil {term.send_focus(entry.session, focused)}
}

@(private)
leader_cancel :: proc(w: ^Window) {
	if w.leader_until != {} {w.dirty = true}
	w.leader_until = {}
}

// Literal: the leader was pressed twice, so the caller delivers that key to whatever has the keyboard.
@(private)
Leader_Result :: enum {
	None,
	Consumed,
	Literal,
}

// Every surface that takes keys calls this first, except while a shortcut field records keys.
@(private)
leader_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> Leader_Result {
	if !e.pressed || is_modifier_key(e.key) {return .None}
	if w.leader_until != {} {
		if leader, enabled := app.leader.?;
		   enabled &&
		   e.repeat &&
		   commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) {return .Consumed}
		pending := time.tick_diff(time.tick_now(), w.leader_until) > 0
		leader_cancel(w)
		if pending {
			w.suppressed_key = e
			if leader, enabled := app.leader.?;
			   enabled &&
			   commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) {return .Literal}
			if e.key == .Escape {return .Consumed}
			chord := e
			chord.modifiers += {.Leader}
			if action, found := shortcut_action(app, chord); found {run_action(app, w, action)}
			return .Consumed
		}
	}
	if leader, enabled := app.leader.?; enabled {
		if commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) {
			w.suppressed_key = e
			if !e.repeat {
				w.leader_until = time.tick_add(time.tick_now(), 2 * time.Second)
				w.dirty = true
			}
			return .Consumed
		}
	}
	return .None
}

@(private)
pointer_set :: proc(app: ^App, w: ^Window, shape: platform.Cursor_Shape) {
	if shape == w.pointer_shape {return}
	if platform.window_set_cursor(&app.platform, w.id, shape) != .None {
		log.error("setting the pointer cursor failed")
	} else {w.pointer_shape = shape}
}
