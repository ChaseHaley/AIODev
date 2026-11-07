package main

import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:log"
import "core:os"
import "core:strings"

// Reading the settings file and applying a revision of it to the running app.

// The settings file as read, before any of it applies.
@(private)
Settings_Read :: struct {
	loaded:            settings.Settings,
	diagnostics:       [dynamic]settings.Diagnostic,
	// Owned exact parsed text, transferred by settings.load; lives through publication.
	source:            string,
	// The theme files and machine shells this read used; they replace the app's on success.
	inputs:            settings.Inputs,
	read_error:        os.Error,
	created, migrated: bool,
	migration_error:   settings.Save_Error,
}

// Reads the themes folder, the machine's shells and the settings file, or defaults when the file
// cannot be read. Fails only when neither is available.
@(private, require_results)
settings_read :: proc(app: ^App) -> (read: Settings_Read, ok: bool) {
	inputs, inputs_error := settings.inputs_read(settings.theme_directory(), shell_profiles_detect())
	if inputs_error != nil {log.errorf("recording theme files and shells failed: %v", inputs_error)}
	read.inputs = inputs
	comments, comment_count := binding_comments()
	read.loaded, read.diagnostics, read.created, read.migrated, read.migration_error, read.read_error =
		settings.load(
			app.settings_path,
			extra_comments = comments[:comment_count],
			inputs = &read.inputs,
			source_out = &read.source,
		)
	if read.read_error != nil {
		log.errorf("reading %s failed: %v", app.settings_path, read.read_error)
		defaults, default_error := settings.defaults()
		if default_error == nil {
			default_error = settings.profiles_apply_detection(&defaults, read.inputs.detected[:])
			if default_error != nil {settings.destroy(&defaults)}
		}
		if default_error != nil {
			log.errorf("loading default settings failed: %v", default_error)
			notify(
				app,
				.Error,
				"Could not load settings or defaults. Check the log and restart AIODev.",
			)
			settings.diagnostics_destroy(&read.diagnostics)
			settings.inputs_destroy(&read.inputs)
			return {}, false
		}
		read.loaded = defaults
	}
	return read, true
}

// The revision `read` came with becomes the one saves and pages are built with.
@(private)
settings_inputs_adopt :: proc(app: ^App, read: ^Settings_Read) {
	settings.inputs_destroy(&app.settings_inputs)
	app.settings_inputs, read.inputs = read.inputs, {}
}

// Reports what reading the file changed on disk, once the settings it read apply.
@(private)
settings_read_report :: proc(app: ^App, read: ^Settings_Read) {
	if read.created {
		log.infof("created %s", app.settings_path)
	}
	if (read.migrated || read.migration_error != .None) && !app.settings_migration_noticed {
		app.settings_migration_noticed = true
		if read.migrated {
			notify(
				app,
				.Info,
				"settings.ini was updated to the current format; existing shells are unchanged.",
			)
		} else {
			log.errorf("migrating settings failed: %v", read.migration_error)
			notify(
				app,
				.Error,
				"Could not update settings.ini to the current format. Its settings still apply; " +
				"check the settings file permissions.",
			)
		}
	}
}

// At startup nothing runs yet that a revision must reach, so the file only replaces the settings.
load_settings :: proc(app: ^App) {
	read, ok := settings_read(app)
	if !ok {return}
	defer settings.diagnostics_destroy(&read.diagnostics)
	defer delete(read.source)
	settings_inputs_adopt(app, &read)
	settings_apply_revision(app, read.loaded, &read.diagnostics, read.read_error)
	settings_read_report(app, &read)
}

// The one order every settings revision after startup takes, saved here or read from the file again:
// interactions holding old settings end, the revision replaces the running settings, windows and
// sessions apply it, and then the open settings pages show it.
@(private)
settings_revision_apply :: proc(
	app: ^App,
	loaded: settings.Settings,
	diagnostics: ^[dynamic]settings.Diagnostic,
	read_error: os.Error,
	publication: Settings_Publication,
) {
	settings_prepare_reload(app)
	settings_apply_revision(app, loaded, diagnostics, read_error)
	settings_apply_running(app)
	settings_publish(app, publication)
}

@(private)
settings_apply_revision :: proc(
	app: ^App,
	loaded: settings.Settings,
	diagnostics: ^[dynamic]settings.Diagnostic,
	read_error: os.Error = nil,
) {
	settings.destroy(&app.settings)
	app.settings = loaded
	process_poll_restart(app)
	for &entry in app.sessions {entry.process_padding = nil}
	apply_bindings(app, diagnostics)
	app.font_points = f32(loaded.font.size)
	show_settings_diagnostics(app, diagnostics, read_error)
}

@(private)
settings_prepare_reload :: proc(app: ^App) {
	refresh_animations(app)
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i >= len(app.windows) {continue}
		window := app.windows[i]
		_ = gesture_cancel(app, window)
	}
}

reload_settings :: proc(app: ^App, announce := true) {
	base := settings.profile_base(&app.settings.profiles)
	previous_shell := strings.clone(base.command, context.temp_allocator)
	previous_directory := strings.clone(base.directory, context.temp_allocator)
	read, ok := settings_read(app)
	if !ok {return}
	defer settings.diagnostics_destroy(&read.diagnostics)
	defer delete(read.source)
	settings_inputs_adopt(app, &read)
	publication: Settings_Publication = Publish_Unavailable{}
	if read.read_error == nil {publication = Publish_Reloaded{read.source}}
	settings_revision_apply(app, read.loaded, &read.diagnostics, read.read_error, publication)
	settings_read_report(app, &read)
	if announce {
		base = settings.profile_base(&app.settings.profiles)
		if previous_shell != base.command || previous_directory != base.directory {
			notify(app, .Info, "Shell settings apply the next time the shell restarts.")
		} else if app.settings_read_error == nil && len(app.settings_diagnostics) == 0 {
			notify(app, .Info, "Settings reloaded.")
		}
	}
}

@(private)
settings_apply_running :: proc(app: ^App) {
	if !ui.text_init(
		&app.ui_text, app.fonts, &app.cache, app.ui_text.size_px, app.settings.interface.font_family,
	) {notify(app, .Error, "Could not load an interface font.")}
	apply_fonts(app)
	apply_theme(app)
	for entry in app.sessions {
		term.set_colors(entry.session, terminal_colors(app.settings.colors))
		term.configure(entry.session, session_options(app))
	}
	for window in app.windows {
		window_apply_settings(app, window)
		rail_reveal_active(window)
	}
	status_apply_settings(app)
	shell_icon_load(app)
	program_icons_reload(app)
	control_cli_sync(app)
}
