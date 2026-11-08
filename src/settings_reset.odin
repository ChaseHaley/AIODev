package main

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
	confirmation_ask(app, w, Settings_Reset{value}, extended = true, focus = .Cancel)
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
	// A full reset also discards pending fields and program drafts on every open page.
	result := settings_change(app, Factory_Reset{}, Settings_Expected{reset.source})
	if result.status != .Applied {
		notify(app, .Error, settings_result_text(result, .Reset))
		return
	}
	notify(app, .Info, "All settings restored to factory defaults.")
}

settings_reset_destroy :: proc(reset: ^Settings_Reset) {
	delete(reset.source)
}
