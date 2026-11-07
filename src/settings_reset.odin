package main

import "aio:settings"
import "aio:ui"
import "core:strings"

settings_reset_ask :: proc(app: ^App, w: ^Window) {
	if !ui.editor_loaded(&w.editor) {return}
	settings_reset_clear(w)
	value, err := strings.clone(ui.editor_source(&w.editor))
	if err != nil {notify(app, .Error, "Could not prepare the settings reset."); return}
	overlay_open(app, w, nil)
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
	// A full reset also discards pending fields and program drafts on every open page.
	result := settings_save_revision(app, w.settings_reset_source, defaults, Publish_Reset{defaults})
	if result != .None {
		notify(app, .Error, "Could not reset settings. Reopen Settings and try again.")
		return
	}
	notify(app, .Info, "All settings restored to factory defaults.")
}

settings_reset_clear :: proc(w: ^Window) {
	delete(w.settings_reset_source)
	w.settings_reset_source, w.settings_reset_confirm = "", {}
}
