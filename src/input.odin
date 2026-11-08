package main

import "aio:commands"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:log"
import "core:math"
import "core:time"

// Terminal and settings scrolling moves this many lines per wheel notch.
@(private)
WHEEL_LINES :: 3

when AIO_CONTROL {
	// The wheel delta that scrolls `lines` lines, for synthetic input that names lines, not notches.
	wheel_delta_for_lines :: proc(lines: int) -> f32 {
		return f32(lines) / WHEEL_LINES
	}
}

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
			workspace_button_track(w, x, y)
			gesture_move(app, w, e)
		}
	case platform.Mouse_Leave_Event:
		if w := window_find(app, e.window); w != nil {
			pointer_leave(app, w)
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
	case platform.Tray_Event, platform.Tray_Notification_Event, platform.Tray_Menu_Event:
		tray_event(app, event)
	case platform.Notification_Error_Event:
		log.errorf("Windows notification delivery failed: HRESULT 0x%x", e.code)
		notify(app, .Error, "Windows could not deliver a status notification.")
	case platform.Activate_Request_Event:
		// Launching AIODev again means a fresh workspace window, as New Window does. With every
		// window hidden to the tray, it reopens the existing view instead.
		if app_tray_only(app) {show_window(app)} else {workspace_new(app, nil, true, name_it = false)}
	case platform.Settings_Event:
		refresh_animations(app)
	case platform.Wake_Event:
	}
}

// A key, typed text or the wheel, on its way to the surface that takes the window's input.
@(private = "file")
Overlay_Input :: union {
	Overlay_Key,
	Overlay_Text,
	Overlay_Wheel,
}

@(private = "file")
Overlay_Key :: struct {
	event:   input.Key_Event,
	// The key as the keyboard layout's letters name it; menus navigate by it.
	logical: input.Key_Event,
}

@(private = "file")
Overlay_Text :: struct {
	text: string,
}

// `rows` is whole wheel rows; the surfaces that take the wheel first see only `delta`.
@(private = "file")
Overlay_Wheel :: struct {
	delta: f32,
	rows:  int,
}

// The surfaces that take keys, text and the wheel ahead of everything else. A confirmation and the
// palette take them later: keys after the Activity inbox and a drag's Escape (the palette after the
// rail's Escape and the tab menu's keys too), the wheel in whole rows after the inbox, the Activity
// panel and the rail.
@(private = "file")
OVERLAY_FIRST :: bit_set[Overlay_Kind] {
	.Workspace_Picker,
	.Rename,
	.Chip_Name,
	.Tab_Menu,
	.Divider_Menu,
	.Profile_Menu,
	.Document_Menu,
}

// Each surface's keys, text and wheel side by side. Keys a surface takes have their release
// suppressed, except a confirmation's, which suppresses its own.
@(private = "file")
overlay_input :: proc(app: ^App, w: ^Window, kind: Overlay_Kind, event: Overlay_Input) {
	switch kind {
	case .None:
	case .Workspace_Picker:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			workspace_picker_key(app, w, e.logical)
		case Overlay_Text: workspace_picker_text(app, w, e.text)
		case Overlay_Wheel: workspace_picker_wheel(w, e.delta)
		}
	case .Rename, .Chip_Name:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			rename_key(app, w, e.event)
		case Overlay_Text:
			ui.field_text(&w.rename, e.text)
			w.dirty = true
		case Overlay_Wheel:
		}
	case .Tab_Menu:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			tab_menu_key(app, w, e.logical)
		case Overlay_Text:
		case Overlay_Wheel: tab_menu_wheel(w, int(math.sign(e.delta)))
		}
	case .Divider_Menu:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			dock_divider_menu_key(app, w, e.logical)
		case Overlay_Text:
		case Overlay_Wheel: dock_divider_menu_wheel(w, int(math.sign(e.delta)))
		}
	case .Profile_Menu:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			profile_menu_key(app, w, e.logical)
		case Overlay_Text:
		case Overlay_Wheel: profile_menu_wheel(w, int(math.sign(e.delta)))
		}
	case .Document_Menu:
		switch e in event {
		case Overlay_Key:
			key_suppress(w, e.event)
			document_menu_key(app, w, e.event, e.logical)
		case Overlay_Text: document_menu_text_input(app, w, e.text)
		case Overlay_Wheel: document_menu_wheel(app, w, int(math.sign(e.delta)))
		}
	case .Confirmation:
		switch e in event {
		case Overlay_Key: _ = confirmation_key(app, w, e.event)
		case Overlay_Text, Overlay_Wheel:
		}
	case .Palette:
		switch e in event {
		case Overlay_Key: palette_key_input(app, w, e.event, e.logical)
		case Overlay_Text: on_palette_outcome(app, w, ui.palette_text(&app.palette, &app.registry, e.text), 0)
		case Overlay_Wheel:
			on_palette_outcome(app, w, ui.palette_scroll(&app.palette, int(math.sign(f32(e.rows)))), 0)
		}
	}
}

@(private)
on_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if w.phase == .Preparing {return}
	// Every surface ignores releases, so a consumed press's release is dropped before routing.
	if key_release_suppressed(w, e) {return}
	// Menus navigate by the layout's letters, so Ctrl+N and Ctrl+P match the palette on any layout.
	key := Overlay_Key{e, e}
	key.logical.key = commands.logical_key(e.key, e.unshifted)
	if drag_holds_dropdown(w) {
		key_suppress(w, e)
		if e.pressed && e.key == .Escape {_ = gesture_cancel(app, w)}
		return
	}
	kind := overlay_kind(app, w)
	if kind in OVERLAY_FIRST {
		overlay_input(app, w, kind, key)
		return
	}
	// The open Activity inbox keeps the keys it uses; every other key takes the normal route.
	if status_inbox_shown(w) && status_inbox_key(app, w, e, key.logical) {
		key_suppress(w, e)
		return
	}
	if e.pressed && e.key == .Escape && drag_active(w) != nil {
		key_suppress(w, e)
		_ = gesture_cancel(app, w)
		return
	}
	if kind == .Confirmation {
		overlay_input(app, w, kind, key)
		return
	}
	if e.pressed && e.key == .Escape && rail_overlay(w) {
		key_suppress(w, e)
		rail_overlay_dismiss(app, w)
		return
	}
	if kind != .Palette && tab_menu_key_open(app, w, e) {return}
	if kind == .Palette {
		overlay_input(app, w, kind, key)
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
	terminal_key(app, w, e)
}

@(private)
on_text :: proc(app: ^App, w: ^Window, text: string) {
	if w.phase == .Preparing {return}
	if kind := overlay_kind(app, w); kind != .None {
		overlay_input(app, w, kind, Overlay_Text{text})
		return
	}
	status_inbox_close(w)
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

// What the start every content pane's keys share found, for the pane to act on in its own order.
Content_Key :: struct {
	// The key as the keyboard layout's letters name it, for chords.
	logical:   input.Key_Event,
	// The leader was pressed twice, so the key goes to the pane, past every shortcut.
	literal:   bool,
	clipboard: Clipboard_Chord,
	// The shortcut a fresh press that is not literal runs; found is false otherwise.
	action:    Action,
	found:     bool,
}

// The start of the keys of the terminal, Markdown and settings panes: Escape closes a find bar that has
// the keyboard (when `find_escape`), then the leader chord. Consumed when either took the key. Each pane
// then decides between the clipboard chord, the shortcut and its own keys in its own order.
@(private)
content_key_prelude :: proc(
	app: ^App,
	w: ^Window,
	e: input.Key_Event,
	find_escape: bool,
) -> (
	key: Content_Key,
	consumed: bool,
) {
	if find_escape && e.pressed && e.key == .Escape && ui.find_has_keyboard(&w.find) && !leader_armed(w) {
		key_suppress(w, e)
		find_close(app, w, find_target(app, w))
		return {}, true
	}
	switch leader_key(app, w, e) {
	case .Consumed:
		return {}, true
	case .Literal:
		key.literal = true
	case .None:
	}
	key.logical = e
	key.logical.key = commands.logical_key(e.key, e.unshifted)
	key.clipboard = clipboard_chord(key.logical)
	if e.pressed && !key.literal {key.action, key.found = shortcut_action(app, e)}
	return key, false
}

// Keys for the focused terminal. Its Copy shortcut runs only for a native selection or the find bar; a
// fullscreen program owns its selection and receives the key.
@(private)
terminal_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	entry := focused_session(app, w)
	if entry == nil {
		return
	}
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	if key.found {
		// A held Copy key stays with the app once its first press copied and ended the selection.
		held_copy := key.action == .Copy && e.repeat && key_suppressed(w, e.key)
		if held_copy || action_available(app, w, key.action) {
			key_suppress(w, e)
			if !held_copy {run_action(app, w, key.action)}
			return
		}
	}
	status_inbox_typed(w, e)
	if ui.find_has_keyboard(&w.find) {
		find_bar_key(app, w, e, key.logical)
		return
	}
	if e.pressed {
		// A stopped session takes no keys; Restart Stopped Pane, on Enter by default, runs it again.
		if entry.status != .Running {return}
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
	if key.literal {
		up := e
		up.pressed, up.repeat, up.text = false, false, ""
		term.send_key(entry.session, up)
	}
}

@(private)
on_wheel :: proc(app: ^App, w: ^Window, e: input.Mouse_Wheel_Event) {
	if w.phase == .Preparing {return}
	if drag_wheel(app, w, e.delta_y) {return}
	kind := overlay_kind(app, w)
	if kind in OVERLAY_FIRST {
		overlay_input(app, w, kind, Overlay_Wheel{delta = e.delta_y})
		return
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
	if kind != .None {
		overlay_input(app, w, kind, Overlay_Wheel{e.delta_y, rows})
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
		window_focus_note(app, w)
	}
	window_notices_sync(app)
	if !focused {
		if !gesture_cancel(app, w) {return}
		window_overlays_cancel(app, w, true)
	}
	if entry := focus_session(app, w); entry != nil {term.send_focus(entry.session, focused)}
	if focused {status_focus_enter(app, w)}
}

// What the keyboard holds between events: the leader chord and the keys whose release is suppressed.
Key_State :: struct {
	leader:     Leader,
	suppressed: Suppressed_Keys,
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

// While the chord is armed, the leader's name shows over the focused pane.
window_leader_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !leader_armed(w) {return .Ok}
	leader, enabled := app.leader.?
	if !enabled {return .Ok}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	label := commands.shortcut_text(leader, buffer[:])
	tree := window_tree(w)
	if tree == nil {return .Ok}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
		r := pane.rect
		return ui.leader_status_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			{r.x, r.y, r.width, r.height},
			label,
			w.scale,
		)
	}
	return .Ok
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
