package main

import "aio:settings"
import "aio:ui"
import "core:strings"

// The settings text the reset question was asked against. The reset saves over exactly that revision,
// so a file changed meanwhile is not overwritten unseen.
Settings_Reset :: struct {
	source: string,
}

settings_reset_ask :: proc(app: ^App, w: ^Window) {
	if !ui.editor_loaded(&w.editor) {return}
	value, err := strings.clone(ui.editor_source(&w.editor))
	if err != nil {notify(app, .Error, "Could not prepare the settings reset."); return}
	overlay_open(app, w, nil)
	confirmation_open(w, Settings_Reset{value}, extended = true, focus = .Cancel)
}

settings_reset_text :: proc() -> Confirmation_Text {
	return {
		title = "Reset all settings?",
		body = "Restore factory defaults, including shortcuts, profiles, themes and program rules.",
		label = "Reset",
	}
}

@(private)
settings_reset_finish :: proc(app: ^App, reset: Settings_Reset, accepted: bool) {
	if !accepted {return}
	defaults, err := settings.default_text()
	defer delete(defaults)
	if err != nil {notify(app, .Error, "Could not prepare factory defaults."); return}
	// A full reset also discards pending fields and program drafts on every open page.
	result := settings_save_revision(app, reset.source, defaults, Publish_Reset{defaults})
	if result != .None {
		notify(app, .Error, "Could not reset settings. Reopen Settings and try again.")
		return
	}
	notify(app, .Info, "All settings restored to factory defaults.")
}

settings_reset_destroy :: proc(reset: ^Settings_Reset) {
	delete(reset.source)
}
