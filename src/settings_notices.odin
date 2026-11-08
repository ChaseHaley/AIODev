package main

import "aio:settings"
import "aio:ui"
import "core:log"
import "core:os"
import "core:time"

// Saving unrelated settings can move source lines without changing a diagnostic's identity.

settings_diagnostics_equal :: proc(a, b: []settings.Diagnostic) -> bool {
	if len(a) != len(b) {return false}
	for d in a {
		matches_a, matches_b := 0, 0
		for other in a {
			if d.key == other.key &&
			   d.kind == other.kind &&
			   d.identity == other.identity {matches_a += 1}
		}
		for other in b {
			if d.key == other.key &&
			   d.kind == other.kind &&
			   d.identity == other.identity {matches_b += 1}
		}
		if matches_a != matches_b {return false}
	}
	return true
}

show_settings_diagnostics :: proc(
	app: ^App,
	diagnostics: ^[dynamic]settings.Diagnostic,
	read_error: os.Error,
) {
	changed :=
		read_error != app.settings_read_error ||
		!settings_diagnostics_equal(app.settings_diagnostics[:], diagnostics[:])
	warnings_only := true
	for d in diagnostics {
		if d.kind == .Shortcut_Warning {
			log.warnf("Settings %s:%d, %s: %s", app.settings_path, d.line, d.key, d.message)
		} else {
			warnings_only = false
			log.errorf("Settings %s:%d, %s: %s", app.settings_path, d.line, d.key, d.message)
		}
	}
	settings.diagnostics_destroy(&app.settings_diagnostics)
	allocator := diagnostics.allocator
	app.settings_diagnostics = diagnostics^
	diagnostics^ = make([dynamic]settings.Diagnostic, allocator)
	app.settings_read_error = read_error
	if !changed {return}
	if read_error == nil && len(app.settings_diagnostics) == 0 {
		ui.notices_clear(&app.notices, u32(Notice_Key.Settings), app.animations, time.tick_now())
		return
	}
	kind: ui.Notice_Kind = .Warning
	text :=
		"The leader key and a shortcut overlap; only one is active. " +
		"Review Leader Key and shortcut assignments in Settings."
	if read_error != nil {
		kind = .Error
		text = "Could not read settings. Using defaults. Check the settings file's location and permissions."
	} else if !warnings_only {
		kind = .Error
		text = "Some settings could not be applied. Open Settings to review them; check the log for details."
	}
	key := u32(Notice_Key.Settings)
	ui.notices_put(&app.notices, key, kind, text, ERROR_NOTICE_DURATION, app.animations, time.tick_now())
}
