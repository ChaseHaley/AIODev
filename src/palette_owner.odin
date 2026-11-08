package main

import "aio:commands"
import "aio:input"
import "aio:platform"
import "aio:settings"
import "aio:ui"
import "core:time"

// Presence owns the palette's Open/Closing phase; the app owns only its window. This view is the one
// mapping between them, so keeping a window through a closing fade needs no second hand-synced phase.
Palette_Owner_State :: union {
	Palette_Open,
	Palette_Closing,
}

Palette_Open :: struct {window: input.Window_Id}
Palette_Closing :: struct {window: input.Window_Id}

palette_owner_state :: proc(app: ^App) -> Palette_Owner_State {
	owner, owned := app.palette_owner.?
	if !owned {return nil}
	if ui.presence_is_open(app.palette.presence) {return Palette_Open{owner}}
	return Palette_Closing{owner}
}

// Advances the palette's fade; its window draws it, and keeps it until a fade-out settles.
palette_animate :: proc(app: ^App, now: time.Tick) {
	changed, settled := ui.presence_advance(&app.palette.presence, app.animations, now)
	owner := palette_owner_window(app)
	if owner == nil {return}
	if changed {owner.dirty = true}
	if settled {palette_release(app, owner)}
}

palette_animating :: proc(app: ^App) -> bool {
	return palette_owner_state(app) != nil && ui.presence_active(app.palette.presence)
}

// Zero means unowned at the external window-id boundary, not in the stored owner.
palette_owner_id :: proc(app: ^App) -> input.Window_Id {
	switch state in palette_owner_state(app) {
	case nil: return 0
	case Palette_Open: return state.window
	case Palette_Closing: return state.window
	}
	return 0
}

@(private = "file")
palette_owned_by :: proc(app: ^App, w: ^Window) -> bool {
	return w != nil && w.id != 0 && palette_owner_id(app) == w.id
}

palette_owner_window :: proc(app: ^App) -> ^Window {
	return window_find(app, palette_owner_id(app))
}

palette_active :: proc(app: ^App, w: ^Window) -> bool {
	state, open := palette_owner_state(app).(Palette_Open)
	return open && w != nil && state.window == w.id
}

// Open or Closing in w: the palette draws in w.
palette_visible :: proc(app: ^App, w: ^Window) -> bool {
	return palette_owned_by(app, w) && ui.presence_visible(app.palette.presence)
}

// Open to Closing: the palette fades out in w, which keeps it until the fade settles.
palette_close :: proc(app: ^App, w: ^Window) {
	if !palette_owned_by(app, w) {return}
	ui.palette_close(&app.palette)
	w.dirty = true
}

// Unowned at once, without a fade.
palette_release :: proc(app: ^App, w: ^Window) {
	if !palette_owned_by(app, w) {return}
	palette_close(app, w)
	ui.presence_reset(&app.palette.presence)
	app.palette_owner = nil
}

palette_open :: proc(app: ^App, w: ^Window) {
	palette_open_mode(app, w, .All)
}

// Opens the palette in w, taking it from any other window. Cancelling w's gesture can remove w, so the
// palette leaves its previous window only once w is known to remain.
palette_open_mode :: proc(app: ^App, w: ^Window, mode: ui.Palette_Mode) {
	if w == nil || w.id == 0 {return}
	if !gesture_cancel(app, w) {return}
	if previous := palette_owner_window(app); previous != nil && previous != w {
		palette_release(app, previous)
	}
	window_overlays_cancel(app, w)
	app.palette.unavailable = nil
	for command in app.registry.items {
		if !action_available(app, w, Action(command.id)) {app.palette.unavailable = command.id}
	}
	app.palette_owner = w.id
	app.palette.leader = app.leader
	ui.palette_open_mode(&app.palette, &app.registry, mode)
	ui.palette_fit(&app.palette, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// The palette's settings: every schema setting with a row of its own, then the page sections the
// palette can jump to. The palette borrows the table for the app's lifetime.
@(require_results)
palette_settings_init :: proc(app: ^App) -> bool {
	@(static) table: [len(settings.SCHEMA) + len(Settings_Section)]ui.Palette_Setting
	@(static, rodata)
	schema := settings.SCHEMA
	count := 0
	for entry in schema {
		if entry.embedded {continue}
		table[count] = ui.palette_setting(entry)
		count += 1
	}
	for section in SETTINGS_SECTIONS {
		if section.palette_key == "" {continue}
		table[count] = {key = section.palette_key, title = section.title, group = section.title}
		count += 1
	}
	return ui.palette_init(&app.palette, table[:count]) == nil
}

when AIO_CONTROL {
	// The palette's verification keys. Only the window that owns the palette reports its contents.
	palette_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		owner := palette_owner_id(app)
		owns := w != nil && owner == w.id
		p := &app.palette
		layout: ui.Palette_Layout
		item, value := "", ""
		edit := ui.Palette_Edit_Kind.None
		if owns {
			layout = ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
			edit = ui.palette_editing(p)
			if p.selected >= 0 && p.selected < len(p.results) {
				selected := p.results[p.selected]
				item = ui.palette_result_name(p, selected)
				// The saved value of the selected setting row, read the way its palette control reads it.
				if selected.kind == .Setting {value, _ = palette_setting_value(app, item)}
				if selected.command != nil {
					value = commands.shortcut_set_text(selected.command.shortcuts, context.temp_allocator)
				}
			}
		}
		state_value(r, "palette.window", owner)
		state_value(r, "palette.open", palette_active(app, w))
		state_text(r, "palette.query", owns ? ui.palette_query(p) : "")
		state_text(r, "palette.mode", owns ? ui.palette_mode_word(p.mode) : "all")
		state_text(r, "palette.prefix", owns ? ui.palette_mode_prefix(p.mode) : "")
		state_value(r, "palette.selected", owns ? p.selected : 0)
		state_value(r, "palette.items", owns ? len(p.results) : 0)
		state_text(r, "palette.item", item)
		state_value(r, "palette.scroll", owns ? p.scroll : 0)
		state_value(r, "palette.edit", edit)
		state_text(r, "palette.value", value)
		state_value(r, "palette.rows", layout.rows)
		state_valuef(r, "palette.row_height", "%g", layout.row_height)
		state_rect(r, "palette.panel", layout.panel)
		state_rect(r, "palette.input", layout.input)
		state_rect(r, "palette.list", layout.list)
		for mode in ui.Palette_Mode {
			state_rect(r, state_key("palette.mode.%s", ui.palette_mode_word(mode)), layout.modes[mode])
		}
	}
}

// Command palette pointer surface

@(private)
palette_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return palette_active(app, w)}

@(private)
palette_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Palette {return}
	x, y := f32(e.x), f32(e.y)
	p := &app.palette
	l := ui.palette_layout(p, f32(w.width), f32(w.height), w.scale)
	pointer_set(app, w, ui.palette_pointer(p, l, x, y))
	on_palette_outcome(app, w, ui.palette_pointer_move(p, l, &w.ui_text, x, y, .Left in e.buttons), 0)
}

@(private)
palette_tooltip :: proc(app: ^App, _: ^Window, _, _: f32) -> string {
	p := &app.palette
	return p.reset_hover >= 0 && ui.palette_editing(p) == .None ? "Reset setting" : ""
}

@(private)
palette_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
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

@(private)
palette_pointer_cancel :: proc(app: ^App, w: ^Window) {
	if palette_active(app, w) {ui.palette_drag_cancel(&app.palette)}
}

// Keys while the palette shows: a shortcut field records them, text fields keep their clipboard chords,
// and the rest navigate by the layout's letters.
@(private)
palette_key_input :: proc(app: ^App, w: ^Window, e, logical: input.Key_Event) {
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
			saved := settings_save_value(app, value.key, value.value, "Could not save the setting.")
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
