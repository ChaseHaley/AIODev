package main

import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:input"
import "aio:instance"
import platform_api "aio:platform"
import "aio:perf"
import "aio:program_art"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

@(private)
FALLBACK_FONT_FAMILIES :: [?]string{"Cascadia Mono", "Consolas"}
@(private)
NOTICE_DURATION :: 6 * time.Second
@(private)
COPY_NOTICE_DURATION :: 2 * time.Second
@(private)
ERROR_NOTICE_DURATION :: 12 * time.Second
@(private)
PASTE_CONFIRM_DURATION :: 10 * time.Second
@(private)
PASTE_CONFIRM_TEXT ::
	"The clipboard text has line breaks, so the shell will run each line as a command. " +
	"Paste again within 10 seconds to confirm."

@(private)
Notice_Key :: enum u32 {
	Transient = 1,
	Settings,
	Font,
	Copy,
	Paste,
	Build_Info,
}

App :: struct {
	verify:                Verify,
	perf:                  perf.Stats,
	options:               instance.Options,
	paths:                 instance.Paths,
	app_id:                string,
	platform:              platform_api.Platform,
	platform_ready:        bool,
	settings_diagnostics:  [dynamic]settings.Diagnostic,
	settings_read_error:   os.Error,
	// Theme files and machine shells the running revision was read with; saves and pages reuse them.
	settings_inputs:       settings.Inputs,
	settings:              settings.Settings,
	markdown_panes:        [dynamic]^Markdown_Pane,
	next_markdown_id:      u32,
	markdown_deadline:     time.Tick,
	dialogs:               File_Dialogs,
	// The settings file this app reads and saves; app_init takes it from paths.
	settings_path:         string,
	log_path:              string,
	fonts:                 ^font.System,
	family:                font.Family,
	font_points:           f32,
	device:                ^render.Device,
	cache:                 glyphs.Cache,
	shell_icon:            Shell_Icon,
	processes:             Process_Worker,
	program_icons:         Program_Icon_Cache,
	program_art:           program_art.Catalogue,
	ui_text:               ui.Text,
	ui_ready:              bool,
	animations:            bool,
	theme:                 ui.Theme,
	registry:              commands.Registry,
	leader:                Maybe(commands.Shortcut),
	palette:               ui.Palette,
	find_history:          ui.Find_History,
	focus_jumps:           Focus_Jumps,
	// The window the palette is open or closing in; see palette_owner.odin.
	palette_owner:         Maybe(input.Window_Id),
	notices:               ui.Notices,
	notice_window:         input.Window_Id,
	window_focus_order:    u64,
	sessions:              [dynamic]Session_Entry,
	workspaces:            [dynamic]^Workspace,
	next_workspace_id:     u32,
	// The last session id session_open allocated; callers use the id it returns instead.
	next_session_id:       u32,
	windows:               [dynamic]^Window,
	run:                   App_Run,
	tray_hint_shown:       bool,
	settings_migration_noticed: bool,
	process_deadline:      time.Tick,
	// Only the real launch enables it, which also turns restoring on.
	layout_save:           Layout_Save,
	layout_saved:          string,
	// Hands web and file targets to the system; see target_open.odin.
	opener:                Target_Opener,
	cli:                   Cli_Pipe,
	// The directory holding aio.exe beside this executable, added to each shell's PATH; empty
	// when aio.exe is missing.
	cli_directory:         string,
	// How the most recently closed sessions ended; see session.odin.
	closed_sessions:       Closed_Sessions,
	// Panes and tabs closed explicitly, newest last, for Reopen Closed.
	closed:                [dynamic]Closed_Item,
}

@(private)
CLI_EXECUTABLE :: "aio.exe"

@(require_results)
app_init :: proc(app: ^App) -> bool {
	perf.start(&app.perf)
	paths, paths_error := instance.paths(app.options)
	if paths_error != nil {
		log.errorf("locating the instance files failed: %v", paths_error)
		return false
	}
	app.paths = paths
	if app.paths.settings == "" {
		log.error("locating the settings file failed: no settings directory")
	} else if path, err := strings.clone(app.paths.settings); err != nil {
		log.errorf("constructing the settings path failed: %v", err)
		return false
	} else {
		app.settings_path = path
	}
	if app.options.data_dir != "" {
		if directory_error := os.mkdir_all(app.options.data_dir); directory_error != nil {
			log.errorf("creating the data directory failed: %v", directory_error)
			return false
		}
	}
	app.animations = platform_api.client_animations_enabled()
	ui.notices_init(&app.notices)
	if catalogue, err := program_art.catalogue_make(); err == nil {
		app.program_art = catalogue
	} else {
		log.errorf("parsing the bundled program artwork failed: %v", err)
	}
	app.registry = commands.create()
	if err := register_actions(&app.registry); err != .None {
		log.errorf("registering commands failed: %v", err)
		return false
	}
	if !palette_settings_init(app) {return false}
	palette_set_sources(app)
	ui.palette_set_values(
		&app.palette,
		{user = app, value = palette_setting_value, choices = palette_setting_choices},
	)
	if executable, err := os.get_executable_path(context.temp_allocator); err == nil {
		directory := filepath.dir(executable)
		if cli, join_error := filepath.join({directory, CLI_EXECUTABLE}, context.temp_allocator);
		   join_error == nil && os.exists(cli) {
			app.cli_directory = strings.clone(directory)
		}
	}
	load_settings(app)
	font_error: font.Error
	app.fonts, font_error = font.system_create()
	if font_error != .None {
		log.errorf("font system creation failed: %v", font_error)
		return false
	}
	render_error: render.Error
	app.device, render_error = render.device_create()
	if render_error != .None {
		log.errorf("graphics device creation failed: %v", render_error)
		return false
	}
	apply_text_gamma(app)
	glyphs.init(&app.cache, app.fonts, app.device)
	ui_size_px :=
		f32(app.settings.interface.font_size) * f32(platform_api.primary_dpi(&app.platform)) / 72
	if !ui.text_init(&app.ui_text, app.fonts, &app.cache, ui_size_px, app.settings.interface.font_family) {
		log.error("no interface font is available")
		return false
	}
	app.ui_ready = true
	shell_icon_load(app)
	apply_fonts(app)
	apply_theme(app)
	tray_init(app)
	platform_api.set_modal_loop_callback(
		&app.platform,
		proc(user: rawptr) {tick((^App)(user))},
		app,
	)
	if !layout_state_restore(app) {
		workspace := workspace_create_empty(app)
		if workspace == nil {return false}
		if _, created := tab_create(app, workspace); !created {return false}
		if !window_open(app, workspace) {return false}
	}
	verify_start(app)
	control_cli_sync(app)
	return true
}

app_destroy :: proc(app: ^App) {
	verify_destroy(app)
	control_cli_stop(app)
	delete(app.cli_directory)
	for len(app.windows) > 0 {
		window_close(app, app.windows[len(app.windows) - 1])
	}
	delete(app.windows)
	for &entry in app.sessions {
		session_entry_destroy(&entry)
	}
	delete(app.sessions)
	for workspace in app.workspaces {workspace_destroy(workspace)}
	delete(app.workspaces)
	if app.platform_ready {
		tray_destroy(app)
	}
	process_worker_destroy(&app.processes)
	program_icon_cache_destroy(&app.program_icons)
	program_art.catalogue_destroy(&app.program_art)
	glyphs.destroy(&app.cache)
	if app.device != nil {
		render.device_destroy(app.device)
	}
	if app.fonts != nil {
		font.system_destroy(app.fonts)
	}
	ui.palette_destroy(&app.palette)
	ui.find_history_destroy(&app.find_history)
	focus_jumps_destroy(&app.focus_jumps)
	file_dialogs_destroy(app)
	markdown_panes_destroy(app)
	ui.notices_destroy(&app.notices)
	commands.destroy(&app.registry)
	settings.destroy(&app.settings)
	settings.inputs_destroy(&app.settings_inputs)
	settings.diagnostics_destroy(&app.settings_diagnostics)
	delete(app.settings_path)
	instance.paths_destroy(&app.paths)
	delete(app.log_path)
	layout_state_disable(app)
	delete(app.layout_saved)
	closed_destroy(app)
	delete(app.app_id)
	if app.platform_ready {
		if platform_api.destroy(&app.platform) != .None {
			log.error("platform shutdown reported an error")
		}
	}
}

run :: proc(app: ^App) {
	for app_running(app) {
		if platform_api.wait_events(&app.platform, wait_timeout(app)) != .None {
			log.error("waiting for events failed")
		}
		tick(app)
	}
}

// One iteration of the main loop; also driven by the platform during modal resize loops.
tick :: proc(app: ^App) {
	events, err := platform_api.poll_events(&app.platform)
	if err != .None {
		log.errorf("polling events failed: %v", err)
	}
	for event in events {
		handle_event(app, event)
	}
	if len(events) > 0 {layout_state_touch(app)}
	update_sessions(app)
	markdown_find_tick(app)
	update_processes(app)
	if ready, unreadable := program_icons_adopt(app); ready || unreadable != "" {
		if unreadable != "" {
			notify(app, .Error, fmt.tprintf("Could not read %s as a PNG program icon.", unreadable))
		}
		mark_all_dirty(app)
	}
	update_motion(app)
	if ui.notices_expire(&app.notices, app.animations, time.tick_now()) {
		mark_all_dirty(app)
	}
	// A dwell can create or discard the trailing preview window.
	for i := 0; i < len(app.windows); i += 1 {pane_drag_tick(app, app.windows[i], time.tick_now())}
	pane_links_sync(app)
	window_notices_sync(app)
	for window in app.windows {
		now := time.tick_now()
		leader_expire(window, now)
		paste_confirm_expire(window, now)
		cursor_blink_tick(window, now)
		capture_hold_tick(window, now)
		selection_autoscroll_tick(app, window, now)
		tooltip_tick(window, now)
		status_spin_tick(window)
		status_taskbar_follow(app, window)
		switch window.phase {
		case .Preparing:
			window.dirty = false
			continue
		case .Hidden, .Closing:
			continue
		case .Shown:
		}
		if window.dirty {
			window_render(app, window)
			verify_presented(app, window)
		}
	}
	verify_tick(app)
	control_cli_tick(app)
	focus_jumps_track(app)
	layout_state_tick(app)
	file_dialogs_tick(app)
	markdown_tick(app)
	free_all(context.temp_allocator)
}

@(private)
wait_timeout :: proc(app: ^App) -> u32 {
	// Spinner frames are already paced by the swap chain, including on high-refresh displays.
	for window in app.windows {
		if status_spin_active(window) {return 0}
	}
	if motion_active(app) {return 16}
	INFINITE :: max(u32)
	deadline, found := ui.notices_deadline(&app.notices)
	if app.process_deadline != {} &&
	   (!found || time.tick_diff(app.process_deadline, deadline) > 0) {
		deadline, found = app.process_deadline, true
	}
	if next, scheduled := layout_state_deadline(app);
	   scheduled && (!found || time.tick_diff(next, deadline) > 0) {
		deadline, found = next, true
	}
	if app.markdown_deadline != {} &&
	   (!found || time.tick_diff(app.markdown_deadline, deadline) > 0) {
		deadline, found = app.markdown_deadline, true
	}
	if next, pending := verify_deadline(app);
	   pending && (!found || time.tick_diff(next, deadline) > 0) {
		deadline, found = next, true
	}
	for window in app.windows {
		if next, pending := tooltip_deadline(window);
		   pending && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if next, armed := drag_hover_deadline(window);
		   armed && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if next, armed := leader_deadline(window);
		   armed && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if next, blinking := cursor_blink_deadline(window);
		   blinking && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if next, held := capture_hold_deadline(window);
		   held && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if next, autoscrolling := selection_autoscroll_deadline(window);
		   autoscrolling && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
	}
	for entry in app.sessions {
		if term.search_pending(entry.session) {
			return 0
		}
	}
	if markdown_find_pending(app) {return 0}
	if !found {
		return INFINITE
	}
	remaining := time.tick_diff(time.tick_now(), deadline)
	return u32(clamp(time.duration_milliseconds(remaining) + 1, 0, 60_000))
}

mark_all_dirty :: proc(app: ^App) {
	for window in app.windows {
		window.dirty = true
	}
}

@(private)
wake_platform :: proc(user: rawptr) {
	if platform_api.wake((^platform_api.Platform)(user)) != .None {
		log.error("waking the main loop failed")
	}
}

initial_geometry :: proc(app: ^App) -> term.Geometry {
	scale := f32(platform_api.primary_dpi(&app.platform)) / 96
	metrics := window_metrics(app, scale)
	// A new window as it shows once opened and its settings apply, before it has a size.
	template := Window {
		scale              = scale,
		metrics            = metrics,
		rail_default_width = f32(app.settings.tabs.rail_width),
		tabs_horizontal    = app.settings.tabs.orientation == .Horizontal,
	}
	box, width, height, _ := pane_box_for_grid(
		app,
		template,
		u16(app.settings.window.columns),
		u16(app.settings.window.rows),
		pane_insets(app, scale, nil),
	)
	return {
		columns = box.columns,
		rows = box.rows,
		cell_width = u32(metrics.cell_width),
		cell_height = u32(metrics.cell_height),
		padding_left = u32(box.origin.x),
		padding_top = u32(box.origin.y),
		surface_width = u32(width),
		surface_height = u32(height),
	}
}

@(private)
update_sessions :: proc(app: ^App) {
	workspace_status_changed := false
	// Exit cleanup removes only the current entry; earlier entries remain valid.
	for i := len(app.sessions) - 1; i >= 0; i -= 1 {
		entry := &app.sessions[i]
		s := entry.session
		if term.search_pending(s) {
			before := term.search_summary(s)
			term.search_update(s)
			if term.search_summary(s) != before {
				mark_all_dirty(app)
			}
		}
		if term.take_status_change(s) {
			workspace_status_changed = true
			layout_state_touch(app)
			status, changed := session_status_sync(entry)
			if changed {mark_all_dirty(app)}
			if status.kind == .Exited && close_exited_session(app, entry.id) {continue}
		}
		if term.take_title_change(s) {
			layout_state_touch(app)
			pane_header_refresh(entry)
			session_titles_changed(app, entry.id)
		}
		if term.take_program_status_change(s) {
			workspace_status_changed = true
			status_refresh(app, entry)
			if status_watched(app, entry) {term.program_status_acknowledge(s)}
			mark_all_dirty(app)
		}
		if term.take_bell(s) {
			for window in app.windows {
				if !window.focused && window.phase == .Shown &&
				   platform_api.window_flash(&app.platform, window.id) != .None {
					log.error("flashing the window failed")
				}
			}
		}
	}
	if workspace_status_changed {
		workspace_picker_status_changed(app)
		for window in app.windows {status_taskbar_update(app, window)}
	}
	for window in app.windows {
		generation := window_generation(app, window)
		if generation != window.generation {
			window.generation = generation
			link_hover_refresh(app, window)
			window.dirty = true
		}
	}
}

notify :: proc(app: ^App, kind: ui.Notice_Kind, text: string) {
	duration := kind == .Error || kind == .Warning ? ERROR_NOTICE_DURATION : NOTICE_DURATION
	key := u32(Notice_Key.Transient)
	ui.notices_put(&app.notices, key, kind, text, duration, app.animations, time.tick_now())
	mark_all_dirty(app)
}

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
	app.process_deadline = {}
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

// Resolves the configured terminal font, falling back to fonts every Windows install has.
apply_fonts :: proc(app: ^App) {
	family, err := font.family_load(app.fonts, app.settings.font.family)
	if err == .None {
		app.family = family
		ui.notices_clear(&app.notices, u32(Notice_Key.Font), app.animations, time.tick_now())
		return
	}
	for name in FALLBACK_FONT_FAMILIES {
		if fallback, fallback_error := font.family_load(app.fonts, name); fallback_error == .None {
			app.family = fallback
			text := fmt.tprintf(
				"Font \"%s\" is not installed. Using %s.",
				app.settings.font.family,
				name,
			)
			ui.notices_put(
				&app.notices, u32(Notice_Key.Font), .Error, text, ERROR_NOTICE_DURATION, app.animations,
				time.tick_now(),
			)
			return
		}
	}
	log.errorf("no terminal font could be loaded: %v", err)
}

apply_theme :: proc(app: ^App) {
	app.theme = ui.theme_from(app.settings.active_theme, app.settings.interface)
}

@(private)
terminal_colors :: proc(c: settings.Color_Settings) -> term.Colors {
	colors := term.Colors {
		foreground = c.foreground,
		background = c.background,
		cursor     = c.cursor,
	}
	for value, i in c.palette {
		colors.palette[i] = value
	}
	return colors
}

set_font_points :: proc(app: ^App, points: f32) {
	zoom := settings.FONT_SIZE_ZOOM
	app.font_points = clamp(points, f32(zoom.minimum), f32(zoom.maximum))
	for window in app.windows {
		window_apply_settings(app, window)
	}
}

apply_text_gamma :: proc(app: ^App) {
	render.set_text_gamma(app.device, font.text_gamma(app.fonts))
}
