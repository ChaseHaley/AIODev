package main

import "aio:commands"
import "aio:input"
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
	if !copy_selection_available(app, w) {app.palette.unavailable = commands.Command_Id(Action.Copy)}
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
