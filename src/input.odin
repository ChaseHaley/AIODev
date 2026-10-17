package main

import "core:log"
import "core:math"
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
	case platform.Mouse_Wheel_Event:
		if w := window_find(app, e.window); w != nil {
			on_wheel(app, w, e)
		}
	case platform.Resize_Event:
		if w := window_find(app, e.window); w != nil {
			window_resize(app, w, e.width, e.height)
		}
	case platform.Dpi_Event:
		if w := window_find(app, e.window); w != nil {
			window_set_dpi(app, w, e.dpi)
		}
	case platform.Focus_Event:
		if w := window_find(app, e.window); w != nil {
			on_focus(app, w, e.focused)
		}
	case platform.Close_Request_Event:
		if w := window_find(app, e.window); w != nil {
			hide_to_tray(app, w)
		}
	case platform.Tray_Event, platform.Activate_Request_Event:
		show_window(app)
	case platform.Tray_Menu_Event:
		switch e.id {
		case TRAY_OPEN: show_window(app)
		case TRAY_QUIT: app.running = false
		}
	case platform.Wake_Event:
	}
}

show_window :: proc(app: ^App) {
	if len(app.windows) == 0 {
		if !window_open(app) {
			notify(app, .Error, "Could not open the AIODev window.")
			return
		}
	}
	if app.options.inactive {
		if platform.window_show_inactive(&app.platform, app.windows[0].id) != .None {
			log.error("showing the inactive window failed")
		}
		return
	}
	if platform.window_focus(&app.platform, app.windows[0].id) != .None {
		log.error("focusing the window failed")
	}
}

hide_to_tray :: proc(app: ^App, w: ^Window) {
	ui.palette_close(&app.palette)
	window_close(app, w)
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
	if suppressed, ok := w.suppressed_key.?; ok && !e.pressed && suppressed.key == e.key {
		w.suppressed_key = nil
		return
	}
	if app.palette.open {
		outcome, id := ui.palette_key(&app.palette, &app.registry, e)
		on_palette_outcome(app, w, outcome, id)
		return
	}
	entry := focused_session(app, w)
	if entry == nil {
		return
	}
	if e.pressed {
		if action, found := shortcut_action(app, e); found {
			w.suppressed_key = e
			run_action(app, w, action)
			return
		}
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
			reset_blink(w)
		}
	}
	term.send_key(entry.session, e)
}

@(private)
on_text :: proc(app: ^App, w: ^Window, text: string) {
	if app.palette.open {
		on_palette_outcome(app, w, ui.palette_text(&app.palette, &app.registry, text), 0)
		return
	}
	if entry := focused_session(app, w); entry != nil && entry.status == .Running {
		term.send_text(entry.session, text)
		reset_blink(w)
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
	}
}

@(private)
pane_at :: proc(app: ^App, w: ^Window, x, y: i32) -> ^Session_Entry {
	pane, found := layout.hit_test(w.panes[:], f32(x), f32(y))
	if !found {
		return focused_session(app, w)
	}
	return session_find(app, pane.content.id)
}

@(private)
reports_mouse :: proc(entry: ^Session_Entry, modifiers: input.Modifiers) -> bool {
	return .Shift not_in modifiers && term.mouse_tracking(entry.session)
}

@(private)
on_mouse_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if app.palette.open {
		if e.pressed {
			l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
			outcome, id := ui.palette_mouse_press(&app.palette, l, f32(e.x), f32(e.y))
			on_palette_outcome(app, w, outcome, id)
		}
		return
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
	}
	x, y := f32(e.x), f32(e.y)
	if e.button == .Left && (w.selecting || !reports_mouse(entry, e.modifiers)) {
		if e.pressed {
			w.selecting = true
			term.selection_press(entry.session, x, y, e.time_ns)
		} else if w.selecting {
			w.selecting = false
			term.selection_release(entry.session, x, y)
			if app.settings.terminal.copy_on_select {
				copy_selection(app, entry, false)
			}
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
	x, y := f32(e.x), f32(e.y)
	if app.palette.open {
		l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		on_palette_outcome(app, w, ui.palette_mouse_move(&app.palette, l, x, y), 0)
		return
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
	}
	if w.selecting {
		term.selection_drag(entry.session, x, y)
		w.dirty = true
	} else if reports_mouse(entry, e.modifiers) {
		term.send_mouse(entry.session, .Motion, nil, e.buttons, e.modifiers, x, y)
	}
}

@(private)
on_wheel :: proc(app: ^App, w: ^Window, e: platform.Mouse_Wheel_Event) {
	w.wheel_remainder += e.delta_y * WHEEL_LINES
	rows := int(w.wheel_remainder)
	if rows == 0 {
		return
	}
	w.wheel_remainder -= f32(rows)
	if app.palette.open {
		on_palette_outcome(app, w, ui.palette_scroll(&app.palette, int(math.sign(f32(rows)))), 0)
		return
	}
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
		w.selecting = false
	}
	for entry in app.sessions {
		term.send_focus(entry.session, focused)
	}
}
