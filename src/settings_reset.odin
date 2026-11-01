package main

import "aio:settings"
import "aio:ui"
import "core:strings"

settings_reset_ask :: proc(app: ^App, w: ^Window) {
	if !w.editor.open {return}
	settings_reset_clear(w)
	value, err := strings.clone(w.editor.source)
	if err != nil {notify(app, .Error, "Could not prepare the settings reset."); return}
	w.settings_reset_source = value
	ui.confirm_open(&w.settings_reset_confirm)
	w.settings_reset_confirm.extended = true
	w.settings_reset_confirm.focus = .Cancel
	w.dirty = true
}

settings_reset_finish :: proc(app: ^App, w: ^Window, accepted: bool) {
	ui.confirm_close(&w.settings_reset_confirm)
	w.dirty = true
	if !accepted {return}
	defaults, err := settings.default_text()
	defer delete(defaults)
	if err != nil {notify(app, .Error, "Could not prepare factory defaults."); return}
	if result := settings_commit(app, w.settings_reset_source, defaults); result != .None {
		notify(app, .Error, "Could not reset settings. Reopen Settings and try again.")
		return
	}
	// A full reset also discards pending fields and program drafts on every open page.
	for window in app.windows {
		if window.editor.open {
			ui.editor_destroy(&window.editor)
			_ = settings_load_source(app, &window.editor, defaults)
			window.dirty = true
		}
	}
	notify(app, .Info, "All settings restored to factory defaults.")
}

settings_reset_clear :: proc(w: ^Window) {
	delete(w.settings_reset_source)
	w.settings_reset_source, w.settings_reset_confirm = "", {}
}
