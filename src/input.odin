package main

import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
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

handle_event :: proc(app: ^App, event: platform.Event) {
	switch e in event {
	case input.Key_Event:
		if w := window_find(app, e.window); w != nil {
			on_key(app, w, e)
		}
	case input.Text_Event:
		if w := window_find(app, e.window); w != nil {
			on_text(app, w, e.text)
		}
	case input.Mouse_Button_Event:
		if w := window_find(app, e.window); w != nil {
			gesture_button(app, w, e)
		}
	case input.Mouse_Move_Event:
		if w := window_find(app, e.window); w != nil {
			x, y := f32(e.x), f32(e.y)
			if w.pointer != ([2]f32{x, y}) && w.gloss_hovered {w.dirty = true}
			w.pointer = {x, y}
			if hovered := render.rect_contains(workspace_button_rect(w), x, y);
			   hovered != w.workspace_hovered {
				w.workspace_hovered, w.dirty = hovered, true
			}
			gesture_move(app, w, e)
		}
	case platform.Mouse_Leave_Event:
		if w := window_find(app, e.window); w != nil {
			tooltip_cancel(w)
			w.find.hover = .None
			w.tab_hover, w.rail_hover = -1, -1
			gesture_tab_unpress(w)
			w.title_action_hover = .None
			if app.notice_window == w.id {_ = ui.notices_hover(&app.notices, 0)}
			floating_hover_clear(w)
			w.document_menu.menu.hover_part = .Row
			w.tab_orientation_button_hovered = false
			w.workspace_hovered = false
			w.workspace_picker.menu_hover = 0
			ui.editor_hover_clear(&w.editor)
			link_hover_clear(w)
			terminal_scrollbar_hover_set(w, 0)
			w.split_overlay = false
			for &view in w.views {
				view.header_hover = .None
				ui.armed_cancel(&view.header_armed)
			}
			w.dirty = true
		}
	case input.Mouse_Wheel_Event:
		if w := window_find(app, e.window); w != nil {
			on_wheel(app, w, e)
		}
	case platform.Resize_Event:
		if w := window_find(app, e.window); w != nil {
			if w.phase != .Preparing && !gesture_cancel(app, w) {return}
			window_resize(app, w, e.width, e.height)
		}
	case platform.Dpi_Event:
		if w := window_find(app, e.window); w != nil {
			if w.phase != .Preparing && !gesture_cancel(app, w) {return}
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
			switch {
			case w.phase == .Preparing:
				_ = gesture_cancel(app, w)
			case window_linked(w):
				pane_link_return(app, w)
			case:
				hide_to_tray(app, w)
			}
		}
	case platform.Tray_Event:
		show_window(app)
	case platform.Tray_Notification_Event:
		if e.token == 0 {
			show_window(app)
		} else {
			status_notification_clicked(app, u32(e.token))
		}
	case platform.Notification_Error_Event:
		log.errorf("Windows notification delivery failed: HRESULT 0x%x", e.code)
		notify(app, .Error, "Windows could not deliver a status notification.")
	case platform.Activate_Request_Event:
		// Launching AIODev again means a fresh workspace window, as New Window does. With every
		// window hidden to the tray, it reopens the existing view instead.
		if app_tray_only(app) {show_window(app)} else {workspace_new(app, nil, true, name_it = false)}
	case platform.Tray_Menu_Event:
		switch e.id {
		case TRAY_OPEN:
			show_window(app)
		case TRAY_QUIT:
			app_quit(app)
		}
	case platform.Settings_Event:
		refresh_animations(app)
	case platform.Wake_Event:
	}
}

show_window :: proc(app: ^App) {
	if len(app.workspaces) == 0 {return}
	if app_tray_only(app) {
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
	_ = window_activate(app, window_primary(app))
}

hide_to_tray :: proc(app: ^App, w: ^Window) {
	focus_leave(app, w)
	window_close(app, w)
	if !app_tray_only(app) {return}
	if app.settings.window.tray_notification && !app.tray_hint_shown {
		app.tray_hint_shown = true
		text := "Your shell keeps running. Click the tray icon to reopen AIODev, or use Quit to exit."
		if platform.tray_notify(&app.platform, "AIODev is still running", text) != .None {
			log.error("showing the tray notification failed")
		}
	}
}

@(private)
on_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if w.phase == .Preparing {return}
	// Every surface ignores releases, so a consumed press's release is dropped before routing.
	if key_release_suppressed(w, e) {return}
	// Menus navigate by the layout's letters, so Ctrl+N and Ctrl+P match the palette on any layout.
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	if drag_holds_dropdown(w) {
		key_suppress(w, e)
		if e.pressed && e.key == .Escape {_ = gesture_cancel(app, w)}
		return
	}
	kind := overlay_kind(app, w)
	switch kind {
	case .Workspace_Picker:
		key_suppress(w, e)
		workspace_picker_key(app, w, logical)
		return
	case .Rename, .Chip_Name:
		key_suppress(w, e)
		rename_key(app, w, e)
		return
	case .Tab_Menu, .Divider_Menu:
		key_suppress(w, e)
		tab_menu_key(app, w, logical)
		return
	case .Profile_Menu:
		key_suppress(w, e)
		profile_menu_key(app, w, logical)
		return
	case .Document_Menu:
		key_suppress(w, e)
		document_menu_key(app, w, e, logical)
		return
	// A confirmation and the palette take keys below, after the inbox and the drags' Escape.
	case .Confirmation, .Palette, .None:
	}
	if status_inbox_shown(w) {
		key_suppress(w, e)
		status_inbox_key(app, w, logical)
		return
	}
	if e.pressed && e.key == .Escape && drag_active(w) != nil {
		key_suppress(w, e)
		_ = gesture_cancel(app, w)
		return
	}
	if kind == .Confirmation {
		_ = confirmation_key(app, w, e)
		return
	}
	if e.pressed && e.key == .Escape && rail_overlay(w) {
		key_suppress(w, e)
		rail_overlay_dismiss(app, w)
		return
	}
	if kind != .Palette &&
	   e.pressed &&
	   !window_linked(w) &&
	   (e.key == .Context_Menu || e.key == .F10 && .Shift in e.modifiers) {
		if w.tabs_horizontal {
			bar := window_tab_bar(app, w)
			tab_menu_open(
				app,
				w,
				w.workspace.selected,
				bar.x + tab_position(w, w.workspace.selected) * bar.tab_width,
				bar.height,
			)
		} else {
			row := rail_row_rect_for_tab(w, w.workspace.selected)
			if row.height <= 0 {
				row = {16, ui.TITLE_BAR_HEIGHT * w.scale, 1, 1}
			}
			tab_menu_open(
				app,
				w,
				w.workspace.selected,
				row.x + 16 * w.scale,
				row.y + row.height,
			)
		}
		key_suppress(w, e)
		return
	}
	if kind == .Palette {
		pane_header_cancel(w)
		key_suppress(w, e)
		p := &app.palette
		if ui.palette_editing(p) == .Shortcut {
			outcome, id := ui.palette_key(p, &app.registry, e)
			on_palette_outcome(app, w, outcome, id)
			return
		}
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
	if markdown_active(w) {
		markdown_key(app, w, e)
		return
	}
	entry := focused_session(app, w)
	if entry == nil {
		return
	}
	literal := false
	if e.pressed {
		if ui.find_has_keyboard(&w.find) && e.key == .Escape && !leader_armed(w) {
			key_suppress(w, e)
			find_close(app, w, entry)
			return
		}
		switch leader_key(app, w, e) {
		case .Consumed:
			return
		case .Literal:
			literal = true
		case .None:
			if action, found := shortcut_action(app, e); found {
				repeated := e.repeat && key_suppressed(w, e.key)
				// A fullscreen program owns its selection; only a native selection claims its copy key.
				if action != .Copy || ui.find_has_keyboard(&w.find) || repeated ||
				   copy_selection_available(app, w) {
					key_suppress(w, e)
					if !repeated || action != .Copy {run_action(app, w, action)}
					return
				}
			}
		}
	}
	if ui.find_has_keyboard(&w.find) {
		find_bar_key(app, w, e, logical)
		return
	}
	if e.pressed {
		if entry.status != .Running {
			if e.key == .Enter || e.key == .Numpad_Enter {
				key_suppress(w, e)
				session_restart(app, entry)
			}
			return
		}
		if !input.is_modifier_key(e.key) {
			if term.has_selection(entry.session) {
				term.clear_selection(entry.session)
			}
			paste_confirm_cancel(app, w)
			cursor_blink_reset(w)
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
	if w.phase == .Preparing {return}
	switch overlay_kind(app, w) {
	case .Workspace_Picker:
		workspace_picker_text(app, w, text)
		return
	case .Tab_Menu, .Divider_Menu, .Profile_Menu, .Confirmation:
		return
	case .Document_Menu:
		document_menu_text_input(app, w, text)
		return
	case .Rename, .Chip_Name:
		ui.field_text(&w.rename, text)
		w.dirty = true
		return
	case .Palette:
		on_palette_outcome(app, w, ui.palette_text(&app.palette, &app.registry, text), 0)
		return
	case .None:
	}
	if settings_active(w) {
		ui.editor_text(&w.editor, text)
		w.dirty = true
		return
	}
	if ui.find_has_keyboard(&w.find) {
		on_find_outcome(app, w, find_target(app, w), ui.find_text(&w.find, text))
		return
	}
	if entry := focused_session(app, w); entry != nil && entry.status == .Running {
		term.send_text(entry.session, text)
		cursor_blink_reset(w)
	}
}

@(private)
on_palette_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Outcome, id: commands.Command_Id) {
	// The outcome that names a choice is the only one that may act on it.
	chosen := ui.palette_chosen_take(&app.palette)
	switch outcome {
	case .None:
	case .Changed, .Closed:
		w.dirty = true
	case .Run:
		w.dirty = true
		run_action(app, w, Action(id))
	case .Open_Setting:
		w.dirty = true
		if setting, ok := chosen.(ui.Chosen_Setting); ok {
			settings_reveal(
				app,
				pane_link_acting_window(app, w),
				{key = setting.key, search = .Clear, focus = .Control},
			)
		}
	case .Set_Setting:
		w.dirty = true
		if value, ok := chosen.(ui.Chosen_Value); ok {
			saved, _ := settings_save_value(app, value.key, value.value, "Could not save the setting.")
			ui.palette_binding_saved(&app.palette, saved)
		}
	case .Open_Tab:
		w.dirty = true
		if tab, ok := chosen.(ui.Chosen_Tab); ok {
			palette_activate_tab(app, pane_link_acting_window(app, w), tab.id)
		}
	case .Open_Workspace:
		w.dirty = true
		if workspace, ok := chosen.(ui.Chosen_Workspace); ok {
			palette_activate_workspace(app, pane_link_acting_window(app, w), u32(workspace.id))
		}
	}
}

@(private)
pane_at :: proc(app: ^App, w: ^Window, x, y: i32) -> ^Session_Entry {
	pane, found := layout.hit_test(w.panes[:], f32(x), f32(y))
	if selection_active(w) {return selection_entry(app, w)}
	if !found {return nil}
	return workspace_session_for_content(app, pane.content)
}

@(private)
reports_mouse :: proc(entry: ^Session_Entry, modifiers: input.Modifiers) -> bool {
	return .Shift not_in modifiers && term.mouse_tracking(entry.session)
}

@(private)
on_wheel :: proc(app: ^App, w: ^Window, e: input.Mouse_Wheel_Event) {
	if w.phase == .Preparing {return}
	if drag_wheel(app, w, e.delta_y) {return}
	kind := overlay_kind(app, w)
	switch kind {
	case .Workspace_Picker:
		workspace_picker_wheel(w, e.delta_y)
		return
	case .Rename, .Chip_Name:
		return
	case .Tab_Menu, .Divider_Menu:
		tab_menu_step(w, -int(math.sign(e.delta_y)), false)
		w.dirty = true
		return
	case .Profile_Menu:
		profile_menu_wheel(w, int(math.sign(e.delta_y)))
		return
	case .Document_Menu:
		document_menu_wheel(app, w, int(math.sign(e.delta_y)))
		return
	// A confirmation and the palette take whole wheel rows below, after the inbox, the Activity panel and
	// the rail.
	case .Confirmation, .Palette, .None:
	}
	if status_inbox_shown(w) {
		status_inbox_wheel(app, w, e.delta_y)
		return
	}
	if status_panel_wheel(app, w, f32(e.x), f32(e.y), e.delta_y) {return}
	rail_area_rect := rail_area(w)
	if rail_visible(w) &&
	   f32(e.x) >= rail_area_rect.x &&
	   f32(e.x) < rail_area_rect.x + rail_area_rect.width &&
	   f32(e.y) >= rail_area_rect.y &&
	   f32(e.y) < rail_area_rect.y + rail_area_rect.height {
		if layout, ok := rail_current_layout(w); ok {
			step := f32(math.sign(e.delta_y)) * 3 * layout.row_height
			w.rail_scroll = ui.rail_scroll_clamped(layout, w.rail_scroll - step)
			w.dirty = true
		}
		return
	}
	w.wheel_remainder += e.delta_y * WHEEL_LINES
	rows := int(w.wheel_remainder)
	if rows == 0 {
		return
	}
	w.wheel_remainder -= f32(rows)
	if kind == .Confirmation {return}
	if kind == .Palette {
		on_palette_outcome(app, w, ui.palette_scroll(&app.palette, int(math.sign(f32(rows)))), 0)
		return
	}
	if pane, found := settings_pane_under_pointer(w, f32(e.x), f32(e.y)); found {
		ui.editor_wheel(
			&w.editor,
			settings_layout_for(w, pane),
			f32(e.x),
			f32(e.y),
			rows,
		)
		w.dirty = true
		return
	}
	if _, _, header := pane_header_hit(w, f32(e.x), f32(e.y)); header {return}
	if markdown_wheel(app, w, f32(e.x), f32(e.y), rows) {return}
	if entry := pane_at(app, w, e.x, e.y); entry != nil {
		term.scroll(entry.session, rows, e.modifiers, f32(e.x), f32(e.y))
		w.dirty = true
	}
}

@(private)
on_focus :: proc(app: ^App, w: ^Window, focused: bool) {
	w.focused = focused
	w.dirty = true
	if focused {
		app.focus_jumps.window = w.id
		app.window_focus_order += 1
		w.focus_order = app.window_focus_order
	}
	window_notices_sync(app)
	if !focused {
		if !gesture_cancel(app, w) {return}
		window_overlays_cancel(app, w, true)
	}
	if entry := focus_session(app, w); entry != nil {term.send_focus(entry.session, focused)}
	if focused {status_focus_enter(app, w)}
}

// Leader chord mode: nil is Idle; Armed waits until `until` for the key that completes the chord.
Leader :: union {
	Leader_Armed,
}

Leader_Armed :: struct {
	until: time.Tick,
}

LEADER_TIMEOUT :: 2 * time.Second

leader_armed :: proc(w: ^Window) -> bool {
	return w.leader != nil
}

leader_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	armed, ok := w.leader.(Leader_Armed)
	return armed.until, ok
}

@(private)
leader_arm :: proc(w: ^Window, now: time.Tick) {
	w.leader = Leader_Armed{time.tick_add(now, LEADER_TIMEOUT)}
	w.dirty = true
}

@(private)
leader_cancel :: proc(w: ^Window) {
	if w.leader != nil {w.dirty = true}
	w.leader = nil
}

// Returns to Idle once the chord window has passed; a key arriving later is not part of a chord.
@(private)
leader_expire :: proc(w: ^Window, now: time.Tick) {
	if until, armed := leader_deadline(w); armed && time.tick_diff(now, until) <= 0 {leader_cancel(w)}
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
leader_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> Leader_Result {
	if !e.pressed || input.is_modifier_key(e.key) {return .None}
	leader, enabled := app.leader.?
	is_leader := enabled && commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted)
	// A held leader's repeats keep the chord armed.
	if leader_armed(w) && is_leader && e.repeat {return .Consumed}
	leader_expire(w, time.tick_now())
	if leader_armed(w) {
		leader_cancel(w)
		key_suppress(w, e)
		if is_leader {return .Literal}
		if e.key == .Escape {return .Consumed}
		chord := e
		chord.modifiers += {.Leader}
		if action, found := shortcut_action(app, chord); found {run_action(app, w, action)}
		return .Consumed
	}
	if is_leader {
		key_suppress(w, e)
		if !e.repeat {leader_arm(w, time.tick_now())}
		return .Consumed
	}
	return .None
}

// Keys whose press a surface consumed, so their release must not reach the terminal. A set, because
// a second key can be pressed and consumed while the first is still held.
Suppressed_Keys :: [input.Key]bool

// The only writer of the suppression on a press: the surface consumed this key.
@(private)
key_suppress :: proc(w: ^Window, e: input.Key_Event) {
	if e.pressed {w.suppressed[e.key] = true}
}

key_suppressed :: proc(w: ^Window, key: input.Key) -> bool {
	return w.suppressed[key]
}

// Every key event passes here first. A release of a suppressed key ends its suppression and is
// consumed; a fresh press supersedes a suppression whose release went to another window.
@(private)
key_release_suppressed :: proc(w: ^Window, e: input.Key_Event) -> bool {
	held := w.suppressed[e.key]
	if !e.repeat {w.suppressed[e.key] = false}
	return held && !e.pressed
}

@(private)
pointer_set :: proc(app: ^App, w: ^Window, shape: platform.Cursor_Shape) {
	if shape == w.pointer_shape {return}
	when AIO_CONTROL {app.verify.pointer_updates += 1}
	// A window without a native window yet, or any longer, has no pointer to change.
	#partial switch platform.window_set_cursor(&app.platform, w.id, shape) {
	case .None: w.pointer_shape = shape
	case .Invalid_Window:
	case: log.error("setting the pointer cursor failed")
	}
}
